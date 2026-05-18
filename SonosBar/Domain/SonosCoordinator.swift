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
    /// Remaining sleep-timer seconds for the selected group. 0 = inactive.
    private(set) var sleepTimerRemaining: Int = 0

    // MARK: - Favorites (chunk 9)
    private(set) var favorites: [SonosFavorite] = []
    private(set) var favoritesLoading = false

    // MARK: - Dependencies

    private let discovery: SSDPDiscovery
    private let transport: any SonosTransport
    private let eventServer = EventServer()
    let settings: SettingsStore

    private var subscriptionIndex: [String: (uuid: String, topic: EventSubscription.Topic)] = [:]
    private var subscriptions: [EventSubscription] = []

    private let volumeDebouncer = Debouncer<Int>(interval: .milliseconds(120))
    private var memberVolumeDebouncers: [String: Debouncer<Int>] = [:]
    private var sleepTimerPollTask: Task<Void, Never>?

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
        await refreshSelectedGroup()
    }

    func shutdown() async {
        sleepTimerPollTask?.cancel()
        for sub in subscriptions { await sub.unsubscribe() }
        subscriptions.removeAll()
        subscriptionIndex.removeAll()
        await eventServer.stop()
    }

    /// Tries cached IPs in parallel; returns only those that respond.
    /// Cheaper than waiting for SSDP timeout on networks where multicast is iffy.
    private func preflightCachedHosts() async -> [DiscoveredPlayer] {
        let hosts = settings.lastKnownHosts
        guard !hosts.isEmpty else { return [] }

        return await withTaskGroup(of: DiscoveredPlayer?.self) { group in
            for (uuid, host) in hosts {
                group.addTask { [transport] in
                    // We don't have the full DiscoveredPlayer from cache —
                    // do a quick description fetch to validate it's still
                    // there and refresh its metadata.
                    return await Self.probe(host: host, expectedUUID: uuid, transport: transport)
                }
            }
            var found: [DiscoveredPlayer] = []
            for await p in group { if let p { found.append(p) } }
            return found
        }
    }

    private static func probe(host: String, expectedUUID: String, transport: any SonosTransport) async -> DiscoveredPlayer? {
        // Reuse the SSDP description parser by constructing the URL directly.
        let url = URL(string: "http://\(host):1400/xml/device_description.xml")!
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let root = try XMLNode.parse(data)
            guard let device = root.descendants(named: "device").first,
                  let udn = device.first("UDN")?.trimmed else { return nil }
            let uuid = udn.hasPrefix("uuid:") ? String(udn.dropFirst("uuid:".count)) : udn
            guard uuid == expectedUUID else { return nil }
            let model = device.first("modelName")?.trimmed ?? "Sonos"
            let zoneName = device.first("roomName")?.trimmed ?? "Unnamed"
            let household = device.first("householdId")?.trimmed
            return DiscoveredPlayer(uuid: uuid, host: host, port: 1400, model: model, zoneName: zoneName, household: household)
        } catch {
            return nil
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

        var subscribedTopology = false
        for player in players.values {
            for topic in [EventSubscription.Topic.avTransport, .renderingControl] {
                let sub = EventSubscription(player: player, topic: topic, callbackPort: callbackPort)
                do {
                    try await sub.subscribe(callbackHost: callbackHost)
                    if let sid = await sub.sid {
                        subscriptionIndex[sid] = (player.uuid, topic)
                        subscriptions.append(sub)
                    }
                } catch {
                    Log.events.error("Subscribe \(topic.service.serviceType) failed on \(player.zoneName)")
                }
            }
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

        var snap = playback[group.id] ?? PlaybackSnapshot()
        if let s = decoded.state { snap.state = s }
        if let uri = decoded.currentTrackURI, uri != snap.track.trackURI {
            if let player = players[uuid] {
                Task { @MainActor in
                    if let snap2 = try? await self.transport.playbackSnapshot(of: player) {
                        self.playback[group.id] = snap2
                    }
                }
            } else {
                snap.track.trackURI = uri
            }
        }
        playback[group.id] = snap
    }

    private func handleTopology(body: Data) async {
        guard let decoded = try? EventParser.zoneGroupTopology(from: body),
              let xml = decoded.zoneGroupStateXML,
              let root = try? XMLNode.parse(xml) else { return }
        let newGroups = SOAPTransport.parseZoneGroupsForEvents(from: root)
        self.groups = newGroups
        if let sel = selectedGroupID, !newGroups.contains(where: { $0.id == sel }) {
            self.selectedGroupID = newGroups.first?.id
        }
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
        do {
            let (p, v) = try await (playbackTask, volumeTask)
            self.playback[group.id] = p
            self.volumes[group.id] = v
        } catch let error as SonosError {
            self.lastError = error
        } catch {
            Log.domain.error("Group state fetch failed")
        }
    }

    private func ingestPlayers(_ found: [DiscoveredPlayer]) {
        var map: [String: DiscoveredPlayer] = [:]
        for p in found {
            map[p.uuid] = p
            settings.recordHost(uuid: p.uuid, host: p.host)
        }
        if !map.isEmpty {
            self.players = map
        }
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

    // MARK: - Sleep timer (chunk 10)

    func setSleepTimer(minutes: Int) async {
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else { return }
        do {
            try await transport.setSleepTimer(seconds: minutes * 60, on: coord)
            sleepTimerRemaining = minutes * 60
            startSleepTimerPolling()
        } catch {
            Log.domain.error("setSleepTimer failed")
        }
    }

    func clearSleepTimer() async {
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else { return }
        do {
            try await transport.setSleepTimer(seconds: 0, on: coord)
            sleepTimerRemaining = 0
            sleepTimerPollTask?.cancel()
            sleepTimerPollTask = nil
        } catch {
            Log.domain.error("clearSleepTimer failed")
        }
    }

    private func startSleepTimerPolling() {
        sleepTimerPollTask?.cancel()
        sleepTimerPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                guard let group = self.selectedGroup,
                      let coord = self.coordinator(of: group) else { return }
                if let remaining = try? await self.transport.getSleepTimerRemaining(on: coord) {
                    self.sleepTimerRemaining = remaining
                    if remaining == 0 {
                        self.sleepTimerPollTask?.cancel()
                        self.sleepTimerPollTask = nil
                    }
                }
            }
        }
    }

    // MARK: - Favorites (chunk 9)

    func loadFavorites() async {
        guard let player = players.values.first else { return }
        favoritesLoading = true
        defer { favoritesLoading = false }
        do {
            favorites = try await transport.getFavorites(via: player)
        } catch {
            Log.domain.error("Favorites load failed")
        }
    }

    func play(favorite: SonosFavorite) async {
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else { return }
        do {
            try await transport.play(favorite: favorite, on: coord)
            await refreshSelectedGroup()
        } catch let error as SonosError {
            self.lastError = error
        } catch {
            Log.domain.error("Play favorite failed")
        }
    }

    private func runOnSelectedCoordinator(
        _ body: @escaping @Sendable (DiscoveredPlayer) async throws -> Void
    ) async {
        guard let group = selectedGroup,
              let coord = coordinator(of: group) else { return }
        do {
            try await body(coord)
        } catch let error as SonosError {
            self.lastError = error
        } catch {
            Log.domain.error("Transport action failed")
        }
    }
}

// MARK: - SOAPTransport extension for re-using parseZoneGroups on event payloads

extension SOAPTransport {
    static func parseZoneGroupsForEvents(from root: XMLNode) -> [ZoneGroup] {
        return root.descendants(named: "ZoneGroup").compactMap { groupNode in
            guard let coord = groupNode.attributes["Coordinator"],
                  let groupID = groupNode.attributes["ID"] else { return nil }
            let members: [ZoneGroupMember] = groupNode.all("ZoneGroupMember").compactMap { m in
                guard let uuid = m.attributes["UUID"],
                      let zone = m.attributes["ZoneName"] else { return nil }
                let host = m.attributes["Location"].flatMap(URL.init(string:))?.host ?? ""
                return ZoneGroupMember(uuid: uuid, zoneName: zone, host: host, isCoordinator: uuid == coord)
            }
            return ZoneGroup(id: groupID, coordinatorUUID: coord, members: members)
        }
    }
}
