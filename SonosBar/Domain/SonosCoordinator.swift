//
//  SonosCoordinator.swift
//  SonosBar
//
//  Single source of truth bridging transport + events + UI + persistence.
//
//  Threading: @MainActor + @Observable means UI reads are cheap. All
//  network work is done via async calls to actor-isolated dependencies.
//
//  Persistence integration (chunk 8):
//    * On bootstrap, restore last-selected group ID if `rememberLastZone`.
//    * Record each discovered player's host IP, so on next launch we
//      can preflight cached IPs in parallel with SSDP for faster bootstrap.
//    * Save lastSelectedGroupID whenever the user changes selection.
//

import Foundation
import Observation

@MainActor
@Observable
final class SonosCoordinator {

    // MARK: - Public state

    private(set) var players: [String: DiscoveredPlayer] = [:]
    private(set) var groups: [ZoneGroup] = []
    var selectedGroupID: String? {
        didSet {
            if settings.rememberLastZone {
                settings.lastSelectedGroupID = selectedGroupID
            }
        }
    }

    private(set) var volumes: [String: VolumeSnapshot] = [:]
    private(set) var playback: [String: PlaybackSnapshot] = [:]
    private(set) var isInitialising = true
    private(set) var lastError: SonosError?

    // MARK: - Per-speaker (member) volumes — chunk 10
    /// Keyed by player UUID. Updated by RenderingControl events from
    /// individual members, not just coordinators.
    private(set) var memberVolumes: [String: VolumeSnapshot] = [:]

    // MARK: - Sleep timer state (chunk 10)
    /// Remaining sleep-timer seconds keyed by group ID. Keyed per group so
    /// switching the popover to another zone neither shows nor clobbers a
    /// timer that belongs to a different group.
    private(set) var sleepTimers: [String: Int] = [:]

    /// Remaining sleep-timer seconds for the selected group. 0 = inactive.
    var sleepTimerRemaining: Int {
        selectedGroupID.flatMap { sleepTimers[$0] } ?? 0
    }

    // MARK: - Favorites (chunk 9)
    private(set) var favorites: [SonosFavorite] = []
    private(set) var favoritesLoading = false

    // MARK: - Queue
    /// Play queue of the selected group's coordinator, loaded on demand
    /// when the Queue tab opens.
    private(set) var queue: [QueueItem] = []
    private(set) var queueLoading = false

    // MARK: - Play mode
    /// Shuffle/repeat and crossfade keyed by group ID.
    private(set) var playModes: [String: PlayMode] = [:]
    private(set) var crossfades: [String: Bool] = [:]

    // MARK: - Dependencies

    private let discovery: SSDPDiscovery
    private let transport: any SonosTransport
    private let eventServer = EventServer()
    let settings: SettingsStore

    private var subscriptionIndex: [String: (uuid: String, topic: EventSubscription.Topic)] = [:]
    private var subscriptions: [EventSubscription] = []
    /// Players that already hold av/rendering subscriptions, so
    /// subscribeAll() can run again after discovery/topology changes
    /// without duplicating subscriptions on already-covered speakers.
    private var subscribedPlayerUUIDs: Set<String> = []
    private var subscribedTopology = false

    private let volumeDebouncer = Debouncer<Int>(interval: .milliseconds(120))
    private var memberVolumeDebouncers: [String: Debouncer<Int>] = [:]
    private var sleepTimerPollTasks: [String: Task<Void, Never>] = [:]

    init(
        discovery: SSDPDiscovery = SSDPDiscovery(),
        transport: any SonosTransport = SOAPTransport(),
        settings: SettingsStore = SettingsStore()
    ) {
        self.discovery = discovery
        self.transport = transport
        self.settings = settings
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        // Kick off SSDP and last-known-host preflight concurrently —
        // whichever returns first wins for "what speakers are out there?".
        async let ssdpTask = discovery.search()
        async let cacheTask = preflightCachedHosts()

        let (fresh, cached) = await (ssdpTask, cacheTask)

        // Prefer SSDP results when present; fall back to cache.
        let players = fresh.isEmpty ? cached : fresh
        ingestPlayers(players)

        guard let probe = self.players.values.first else {
            isInitialising = false
            return
        }

        do {
            let g = try await transport.getZoneGroups(via: probe)
            self.groups = g
            self.selectedGroupID = restoreOrPickGroup(g)
        } catch {
            Log.domain.error("Initial topology fetch failed: \(String(describing: error))")
        }

        do {
            try await startEventServer()
            await subscribeAll()
        } catch {
            Log.domain.error("Event subscription bootstrap failed: \(String(describing: error))")
        }

        await refreshSelectedGroup()
        await loadFavorites()
        isInitialising = false
    }

    func refresh() async {
        let found = await discovery.search()
        ingestPlayers(found)
        await refreshTopology()
        // Cover any speakers that appeared since bootstrap — without this,
        // a speaker added mid-session never gets event subscriptions and
        // its volume/playback state silently stops updating.
        await subscribeAll()
        await refreshSelectedGroup()
    }

    func shutdown() async {
        for task in sleepTimerPollTasks.values { task.cancel() }
        sleepTimerPollTasks.removeAll()
        for sub in subscriptions { await sub.unsubscribe() }
        subscriptions.removeAll()
        subscriptionIndex.removeAll()
        subscribedPlayerUUIDs.removeAll()
        subscribedTopology = false
        await eventServer.stop()
    }

    /// Tries cached IPs in parallel; returns only those that respond.
    /// Cheaper than waiting for SSDP timeout on networks where multicast is iffy.
    /// A cached IP that answers as some *other* device (DHCP handed it to
    /// somebody else, speaker retired) is forgotten so the cache doesn't
    /// accumulate stale entries forever; one that simply doesn't answer is
    /// kept — the speaker may just be powered off today.
    private func preflightCachedHosts() async -> [DiscoveredPlayer] {
        let hosts = settings.lastKnownHosts
        guard !hosts.isEmpty else { return [] }

        let outcomes = await withTaskGroup(of: (String, ProbeOutcome).self) { group in
            for (uuid, host) in hosts {
                group.addTask {
                    // We don't have the full DiscoveredPlayer from cache —
                    // do a quick description fetch to validate it's still
                    // there and refresh its metadata.
                    return (uuid, await Self.probe(host: host, expectedUUID: uuid))
                }
            }
            var collected: [(String, ProbeOutcome)] = []
            for await entry in group { collected.append(entry) }
            return collected
        }

        var found: [DiscoveredPlayer] = []
        for (uuid, outcome) in outcomes {
            switch outcome {
            case .found(let player): found.append(player)
            case .mismatch:          settings.forgetHost(uuid: uuid)
            case .unreachable:       break
            }
        }
        return found
    }

    private enum ProbeOutcome: Sendable {
        case found(DiscoveredPlayer)
        /// Something answered, but it isn't the expected speaker.
        case mismatch
        /// Nothing answered — offline, not necessarily gone.
        case unreachable
    }

    private static func probe(host: String, expectedUUID: String) async -> ProbeOutcome {
        guard let url = NetHost.httpURL(host: host, port: 1400, path: "/xml/device_description.xml") else {
            return .mismatch
        }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let root = try? XMLNode.parse(data),
                  let device = root.descendants(named: "device").first,
                  let udn = device.first("UDN")?.trimmed else { return .mismatch }
            let uuid = udn.hasPrefix("uuid:") ? String(udn.dropFirst("uuid:".count)) : udn
            guard uuid == expectedUUID else { return .mismatch }
            let model = device.first("modelName")?.trimmed ?? "Sonos"
            let zoneName = device.first("roomName")?.trimmed ?? "Unnamed"
            let household = device.first("householdId")?.trimmed
            return .found(DiscoveredPlayer(uuid: uuid, host: host, port: 1400, model: model, zoneName: zoneName, household: household))
        } catch {
            return .unreachable
        }
    }

    // MARK: - Event server + subscriptions

    private func startEventServer() async throws {
        _ = try await eventServer.start(handler: { [weak self] event in
            await self?.handleEvent(event)
        })
    }

    private func subscribeAll() async {
        let callbackPort = await eventServer.port
        guard callbackPort > 0 else { return }

        guard let firstPlayer = players.values.first,
              let callbackHost = await LocalAddress.preferred(for: firstPlayer.host) else { return }

        Log.events.info("Subscribing using callback http://\(callbackHost):\(callbackPort)/")

        for player in players.values where !subscribedPlayerUUIDs.contains(player.uuid) {
            var covered = true
            for topic in [EventSubscription.Topic.avTransport, .renderingControl] {
                let sub = EventSubscription(player: player, topic: topic, callbackPort: callbackPort)
                do {
                    try await sub.subscribe(callbackHost: callbackHost)
                    if let sid = await sub.sid {
                        subscriptionIndex[sid] = (player.uuid, topic)
                        subscriptions.append(sub)
                    } else {
                        covered = false
                    }
                } catch {
                    covered = false
                    Log.events.error("Subscribe \(topic.service.serviceType) failed on \(player.zoneName)")
                }
            }
            if covered { subscribedPlayerUUIDs.insert(player.uuid) }
            if !subscribedTopology {
                let sub = EventSubscription(player: player, topic: .zoneGroupTopology, callbackPort: callbackPort)
                do {
                    try await sub.subscribe(callbackHost: callbackHost)
                    if let sid = await sub.sid {
                        subscriptionIndex[sid] = (player.uuid, .zoneGroupTopology)
                        subscriptions.append(sub)
                        subscribedTopology = true
                    }
                } catch { }
            }
        }
    }

    private func handleEvent(_ event: EventServer.Event) async {
        guard let routing = subscriptionIndex[event.sid] else { return }
        switch routing.topic {
        case .renderingControl:
            await handleRenderingControl(uuid: routing.uuid, body: event.body)
        case .avTransport:
            await handleAVTransport(uuid: routing.uuid, body: event.body)
        case .zoneGroupTopology:
            await handleTopology(body: event.body)
        }
    }

    private func handleRenderingControl(uuid: String, body: Data) async {
        guard let decoded = try? EventParser.renderingControl(from: body) else { return }

        // Update per-member cache for chunk 10 UI.
        var memberSnap = memberVolumes[uuid] ?? VolumeSnapshot()
        if let v = decoded.volume { memberSnap.volume = v }
        if let m = decoded.muted  { memberSnap.muted = m }
        memberVolumes[uuid] = memberSnap

        // Also update the group-level snapshot if this is the coordinator.
        if let group = groups.first(where: { $0.coordinatorUUID == uuid }) {
            var snap = volumes[group.id] ?? VolumeSnapshot()
            if let v = decoded.volume { snap.volume = v }
            if let m = decoded.muted  { snap.muted = m }
            volumes[group.id] = snap
        }
    }

    private func handleAVTransport(uuid: String, body: Data) async {
        guard let decoded = try? EventParser.avTransport(from: body) else { return }
        guard let group = groups.first(where: { $0.coordinatorUUID == uuid }) else { return }

        if let pm = decoded.playMode { playModes[group.id] = pm }
        if let cf = decoded.crossfade { crossfades[group.id] = cf }

        var snap = playback[group.id] ?? PlaybackSnapshot()
        if let s = decoded.state { snap.state = s }
        if let uri = decoded.currentTrackURI, uri != snap.track.trackURI {
            // The event usually carries the new track's DIDL. Apply it
            // synchronously so the card doesn't flash the previous track's
            // title/art while the SOAP round-trip below is in flight.
            if let player = players[uuid],
               var track = decoded.trackMetadata.flatMap({
                   SOAPTransport.parseDIDLTrack(fromDIDL: $0, baseURL: player.baseURL)
               }) {
                track.trackURI = uri
                snap.track = track
            } else {
                // No metadata in the event — showing nothing beats showing
                // the previous track's fields against the new URI.
                snap.track = TrackInfo()
                snap.track.trackURI = uri
            }
            // Position (and duration for streams) never travels in the
            // event; fetch the full snapshot to fill those in.
            if let player = players[uuid] {
                Task { @MainActor in
                    if let snap2 = try? await self.transport.playbackSnapshot(of: player) {
                        self.playback[group.id] = snap2
                    }
                }
            }
        }
        playback[group.id] = snap
    }

    private func handleTopology(body: Data) async {
        guard let decoded = try? EventParser.zoneGroupTopology(from: body),
              let xml = decoded.zoneGroupStateXML,
              let root = try? XMLNode.parse(xml) else { return }
        let newGroups = SOAPTransport.parseZoneGroups(from: root)
        self.groups = newGroups
        if let sel = selectedGroupID, !newGroups.contains(where: { $0.id == sel }) {
            self.selectedGroupID = newGroups.first?.id
        }
        await adoptNewMembers(from: newGroups)
    }

    /// Topology events can announce speakers we've never discovered (added
    /// to the household mid-session). Probe them by the host the event
    /// carries and bring them under event coverage.
    private func adoptNewMembers(from groups: [ZoneGroup]) async {
        let unknown = groups.flatMap(\.members)
            .filter { players[$0.uuid] == nil && !$0.host.isEmpty }
        guard !unknown.isEmpty else { return }

        var discovered: [DiscoveredPlayer] = []
        for member in unknown {
            if case .found(let p) = await Self.probe(host: member.host, expectedUUID: member.uuid) {
                discovered.append(p)
            }
        }
        guard !discovered.isEmpty else { return }
        ingestPlayers(discovered)
        await subscribeAll()
    }

    // MARK: - Polled refresh

    private func refreshTopology() async {
        guard let probe = players.values.first else { return }
        do {
            self.groups = try await transport.getZoneGroups(via: probe)
            if let sel = selectedGroupID, !groups.contains(where: { $0.id == sel }) {
                self.selectedGroupID = groups.first?.id
            } else if selectedGroupID == nil {
                self.selectedGroupID = restoreOrPickGroup(groups)
            }
        } catch {
            Log.domain.error("Topology refresh failed")
        }
    }

    func refreshSelectedGroup() async {
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else { return }
        async let playbackTask = transport.playbackSnapshot(of: coord)
        async let volumeTask = transport.getVolume(of: coord)
        async let playModeTask = transport.getPlayMode(of: coord)
        do {
            let (p, v, pm) = try await (playbackTask, volumeTask, playModeTask)
            self.playback[group.id] = p
            self.volumes[group.id] = v
            self.playModes[group.id] = pm.mode
            self.crossfades[group.id] = pm.crossfade
            self.lastError = nil
        } catch is CancellationError {
            // Lifecycle cancellation — not a real failure.
        } catch let error as SonosError {
            self.lastError = error
        } catch {
            Log.domain.error("Group state fetch failed")
        }
    }

    private func ingestPlayers(_ found: [DiscoveredPlayer]) {
        guard !found.isEmpty else { return }
        // Merge rather than replace: a speaker that slept through one SSDP
        // sweep would otherwise vanish from `players`, leaving its group's
        // transport buttons silently dead until the next successful sweep.
        var map = self.players
        for p in found {
            map[p.uuid] = p
            settings.recordHost(uuid: p.uuid, host: p.host)
        }
        self.players = map
    }

    // MARK: - Selection

    var selectedGroup: ZoneGroup? {
        guard let id = selectedGroupID else { return nil }
        return groups.first(where: { $0.id == id })
    }

    func coordinator(of group: ZoneGroup) -> DiscoveredPlayer? {
        players[group.coordinatorUUID]
    }

    private func restoreOrPickGroup(_ groups: [ZoneGroup]) -> String? {
        if settings.rememberLastZone,
           let last = settings.lastSelectedGroupID,
           groups.contains(where: { $0.id == last }) {
            return last
        }
        return groups.first?.id
    }

    func select(group: ZoneGroup) {
        selectedGroupID = group.id
        Task { await refreshSelectedGroup() }
    }

    // MARK: - Transport actions

    func play() async {
        await runOnSelectedCoordinator { try await self.transport.play(on: $0) }
    }

    func pause() async {
        await runOnSelectedCoordinator { try await self.transport.pause(on: $0) }
    }

    func togglePlayPause() async {
        let isPlaying = (selectedGroup.flatMap { playback[$0.id]?.state } ?? .stopped).isActive
        if isPlaying { await pause() } else { await play() }
    }

    func next() async {
        await runOnSelectedCoordinator { try await self.transport.next(on: $0) }
    }

    func previous() async {
        await runOnSelectedCoordinator { try await self.transport.previous(on: $0) }
    }

    func seek(toSeconds seconds: Int) async {
        await runOnSelectedCoordinator { try await self.transport.seek(toSeconds: seconds, on: $0) }
        await refreshSelectedGroup()
    }

    // MARK: - Volume

    func setVolume(_ volume: Int) {
        guard let group = selectedGroup else { return }
        volumes[group.id, default: VolumeSnapshot()].volume = volume

        let transport = self.transport
        let coordPlayer = coordinator(of: group)
        Task { [volumeDebouncer] in
            await volumeDebouncer.submit(volume) { v in
                guard let player = coordPlayer else { return }
                try? await transport.setVolume(v, on: player)
            }
        }
    }

    /// Per-speaker volume — used by chunk 10 UI for stereo pairs and
    /// adjusting individual members of a group.
    func setMemberVolume(_ volume: Int, on member: ZoneGroupMember) {
        guard let player = players[member.uuid] else { return }
        memberVolumes[member.uuid, default: VolumeSnapshot()].volume = volume

        // One debouncer per member so adjacent members don't share state.
        if memberVolumeDebouncers[member.uuid] == nil {
            memberVolumeDebouncers[member.uuid] = Debouncer<Int>(interval: .milliseconds(120))
        }
        guard let debouncer = memberVolumeDebouncers[member.uuid] else { return }

        let transport = self.transport
        Task {
            await debouncer.submit(volume) { v in
                try? await transport.setVolume(v, on: player)
            }
        }
    }

    func nudgeVolume(by delta: Int) {
        guard let group = selectedGroup else { return }
        let current = volumes[group.id]?.volume ?? 0
        setVolume(max(0, min(100, current + delta)))
    }

    func setMute(_ muted: Bool) async {
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else { return }
        do {
            try await transport.setMute(muted, on: coord)
            volumes[group.id, default: VolumeSnapshot()].muted = muted
        } catch {
            Log.domain.error("setMute failed")
        }
    }

    // MARK: - Queue

    func loadQueue() async {
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else {
            queue = []
            return
        }
        queueLoading = true
        defer { queueLoading = false }
        do {
            queue = try await transport.getQueue(via: coord)
        } catch is CancellationError {
        } catch {
            Log.domain.error("Queue load failed")
            queue = []
        }
    }

    /// Jumps playback to the given 1-based queue position and plays.
    func play(queueIndex: Int) async {
        await runOnSelectedCoordinator {
            try await self.transport.seek(toTrack: queueIndex, on: $0)
            try await self.transport.play(on: $0)
        }
        await refreshSelectedGroup()
    }

    // MARK: - Grouping

    /// Pulls the zone identified by `memberUUID` into the selected group.
    func joinSelectedGroup(memberUUID: String) async {
        guard let group = selectedGroup else { return }
        guard let player = players[memberUUID] else {
            lastError = .unreachable(underlying: "That speaker is not reachable right now")
            return
        }
        do {
            try await transport.join(player: player, toCoordinatorUUID: group.coordinatorUUID)
            lastError = nil
        } catch is CancellationError {
        } catch let error as SonosError {
            lastError = error
        } catch {
            Log.domain.error("Join group failed")
        }
        // The GENA topology event usually lands within a couple of
        // seconds; refresh explicitly so the checkmarks don't lag it.
        await refreshTopology()
    }

    /// Splits the zone identified by `memberUUID` out of its group.
    /// The group's coordinator can't be removed this way — the UI pins it.
    func removeFromGroup(memberUUID: String) async {
        guard memberUUID != selectedGroup?.coordinatorUUID else { return }
        guard let player = players[memberUUID] else {
            lastError = .unreachable(underlying: "That speaker is not reachable right now")
            return
        }
        do {
            try await transport.leaveGroup(player: player)
            lastError = nil
        } catch is CancellationError {
        } catch let error as SonosError {
            lastError = error
        } catch {
            Log.domain.error("Leave group failed")
        }
        await refreshTopology()
    }

    // MARK: - Play mode actions

    var selectedPlayMode: PlayMode {
        selectedGroupID.flatMap { playModes[$0] } ?? PlayMode()
    }

    var selectedCrossfade: Bool {
        selectedGroupID.flatMap { crossfades[$0] } ?? false
    }

    func toggleShuffle() async {
        var mode = selectedPlayMode
        mode.shuffle.toggle()
        await apply(playMode: mode)
    }

    func cycleRepeat() async {
        var mode = selectedPlayMode
        switch mode.repeatMode {
        case .off: mode.repeatMode = .all
        case .all: mode.repeatMode = .one
        case .one: mode.repeatMode = .off
        }
        await apply(playMode: mode)
    }

    private func apply(playMode: PlayMode) async {
        guard let group = selectedGroup else { return }
        playModes[group.id] = playMode   // optimistic; event confirms
        await runOnSelectedCoordinator { try await self.transport.setPlayMode(playMode, on: $0) }
    }

    func toggleCrossfade() async {
        guard let group = selectedGroup else { return }
        let target = !selectedCrossfade
        crossfades[group.id] = target
        await runOnSelectedCoordinator { try await self.transport.setCrossfade(target, on: $0) }
    }

    // MARK: - Group all / ungroup all

    /// Pulls every visible zone in the household into the selected group.
    func groupAll() async {
        guard let group = selectedGroup else { return }
        let outsiders = groups
            .filter { $0.id != group.id }
            .flatMap(\.visibleMembers)
        for member in outsiders {
            if let player = players[member.uuid] {
                try? await transport.join(player: player, toCoordinatorUUID: group.coordinatorUUID)
            }
        }
        await refreshTopology()
    }

    /// Splits every non-coordinator zone out of the selected group.
    func ungroupAll() async {
        guard let group = selectedGroup else { return }
        for member in group.visibleMembers where member.uuid != group.coordinatorUUID {
            if let player = players[member.uuid] {
                try? await transport.leaveGroup(player: player)
            }
        }
        await refreshTopology()
    }

    // MARK: - Sleep timer (chunk 10)

    func setSleepTimer(minutes: Int) async {
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else { return }
        do {
            try await transport.setSleepTimer(seconds: minutes * 60, on: coord)
            sleepTimers[group.id] = minutes * 60
            startSleepTimerPolling(groupID: group.id)
        } catch {
            Log.domain.error("setSleepTimer failed")
        }
    }

    func clearSleepTimer() async {
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else { return }
        do {
            try await transport.setSleepTimer(seconds: 0, on: coord)
            stopSleepTimerTracking(groupID: group.id)
        } catch {
            Log.domain.error("clearSleepTimer failed")
        }
    }

    /// Polls the group the timer was set on — not the live selection, which
    /// the user is free to change while the timer runs.
    private func startSleepTimerPolling(groupID: String) {
        sleepTimerPollTasks[groupID]?.cancel()
        sleepTimerPollTasks[groupID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                guard let group = self.groups.first(where: { $0.id == groupID }) else {
                    // The group re-formed or vanished — its ID (and the timer
                    // tracked under it) no longer exists.
                    self.stopSleepTimerTracking(groupID: groupID)
                    return
                }
                guard let coord = self.coordinator(of: group) else {
                    // Coordinator temporarily undiscovered — try again next tick.
                    continue
                }
                if let remaining = try? await self.transport.getSleepTimerRemaining(on: coord) {
                    self.sleepTimers[groupID] = remaining
                    if remaining == 0 {
                        self.stopSleepTimerTracking(groupID: groupID)
                        return
                    }
                }
            }
        }
    }

    private func stopSleepTimerTracking(groupID: String) {
        sleepTimers[groupID] = nil
        sleepTimerPollTasks[groupID]?.cancel()
        sleepTimerPollTasks[groupID] = nil
    }

    // MARK: - Favorites (chunk 9)

    func loadFavorites() async {
        // players.values.first is a random dictionary pick, and bonded
        // satellites (stereo-pair/surround members) answer ContentDirectory
        // Browse with a SOAP fault — verified on this household's Main
        // Bedroom One SL pair. Prefer the selected group's coordinator,
        // then try the rest until one answers.
        var candidates: [DiscoveredPlayer] = []
        if let group = selectedGroup, let coord = coordinator(of: group) {
            candidates.append(coord)
        }
        candidates += players.values.filter { p in !candidates.contains(where: { $0.uuid == p.uuid }) }
        guard !candidates.isEmpty else { return }

        favoritesLoading = true
        defer { favoritesLoading = false }
        for player in candidates {
            do {
                favorites = try await transport.getFavorites(via: player)
                return
            } catch {
                Log.domain.error("Favorites load failed via \(player.zoneName); trying next player")
            }
        }
        Log.domain.error("Favorites load failed on every known player")
    }

    func play(favorite: SonosFavorite) async {
        guard favorite.isPlayable else {
            lastError = .invalidArgument("\"\(favorite.title)\" can only be played from the Sonos app")
            return
        }
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else { return }
        do {
            try await transport.play(favorite: favorite, on: coord)
            self.lastError = nil
            await refreshSelectedGroup()
        } catch is CancellationError {
            // Lifecycle cancellation — not a real failure.
        } catch let error as SonosError {
            self.lastError = error
        } catch {
            Log.domain.error("Play favorite failed")
        }
    }


    private func runOnSelectedCoordinator(
        _ body: @escaping @Sendable (DiscoveredPlayer) async throws -> Void
    ) async {
        guard let group = selectedGroup else { return }
        guard let coord = coordinator(of: group) else {
            // Known group but its coordinator isn't in `players` right now
            // (asleep, mid-rediscovery). Surface it instead of silently
            // ignoring the user's action.
            self.lastError = .unreachable(underlying: "\(group.displayName) is not reachable right now")
            return
        }
        do {
            try await body(coord)
            self.lastError = nil
        } catch is CancellationError {
            // Lifecycle cancellation — not a real failure.
        } catch let error as SonosError {
            self.lastError = error
        } catch {
            Log.domain.error("Transport action failed")
        }
    }
}
