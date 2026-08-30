//
//  SOAPTransport.swift
//  SonosBar
//
//  The one concrete SonosTransport implementation in v1.0. Maps each
//  protocol method to one or two SOAP actions.
//

import Foundation

struct SOAPTransport: SonosTransport {

    private let client: SOAPClient

    init(client: SOAPClient = SOAPClient()) {
        self.client = client
    }

    // MARK: - Playback

    func play(on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "Play",
            service: .avTransport,
            arguments: [("InstanceID", "0"), ("Speed", "1")],
            to: player
        )
    }

    func pause(on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "Pause",
            service: .avTransport,
            arguments: [("InstanceID", "0")],
            to: player
        )
    }

    func next(on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "Next",
            service: .avTransport,
            arguments: [("InstanceID", "0")],
            to: player
        )
    }

    func previous(on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "Previous",
            service: .avTransport,
            arguments: [("InstanceID", "0")],
            to: player
        )
    }

    func seek(toSeconds seconds: Int, on player: DiscoveredPlayer) async throws {
        let clamped = max(0, seconds)
        let h = clamped / 3600
        let m = (clamped % 3600) / 60
        let s = clamped % 60
        let target = String(format: "%02d:%02d:%02d", h, m, s)
        _ = try await client.send(
            action: "Seek",
            service: .avTransport,
            arguments: [
                ("InstanceID", "0"),
                ("Unit", "REL_TIME"),
                ("Target", target)
            ],
            to: player
        )
    }

    func playbackSnapshot(of player: DiscoveredPlayer) async throws -> PlaybackSnapshot {
        async let transportTask = client.send(
            action: "GetTransportInfo",
            service: .avTransport,
            arguments: [("InstanceID", "0")],
            to: player
        )
        async let positionTask = client.send(
            action: "GetPositionInfo",
            service: .avTransport,
            arguments: [("InstanceID", "0")],
            to: player
        )

        let (transportXML, positionXML) = try await (transportTask, positionTask)

        let stateString = transportXML.descendants(named: "CurrentTransportState").first?.trimmed ?? "STOPPED"
        let state = PlaybackState(rawValue: stateString) ?? .stopped
        let track = Self.parseTrack(from: positionXML, baseURL: player.baseURL)
        return PlaybackSnapshot(state: state, track: track)
    }

    func seek(toTrack index: Int, on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "Seek",
            service: .avTransport,
            arguments: [
                ("InstanceID", "0"),
                ("Unit", "TRACK_NR"),
                ("Target", "\(max(1, index))")
            ],
            to: player
        )
    }

    // MARK: - Volume

    func getVolume(of player: DiscoveredPlayer) async throws -> VolumeSnapshot {
        async let volumeTask = client.send(
            action: "GetVolume",
            service: .renderingControl,
            arguments: [("InstanceID", "0"), ("Channel", "Master")],
            to: player
        )
        async let muteTask = client.send(
            action: "GetMute",
            service: .renderingControl,
            arguments: [("InstanceID", "0"), ("Channel", "Master")],
            to: player
        )
        let (volumeXML, muteXML) = try await (volumeTask, muteTask)
        let volumeStr = volumeXML.descendants(named: "CurrentVolume").first?.trimmed ?? "0"
        let muteStr = muteXML.descendants(named: "CurrentMute").first?.trimmed ?? "0"
        return VolumeSnapshot(volume: Int(volumeStr) ?? 0, muted: muteStr == "1")
    }

    func setVolume(_ volume: Int, on player: DiscoveredPlayer) async throws {
        guard (0...100).contains(volume) else {
            throw SonosError.invalidArgument("volume must be 0...100, got \(volume)")
        }
        _ = try await client.send(
            action: "SetVolume",
            service: .renderingControl,
            arguments: [
                ("InstanceID", "0"),
                ("Channel", "Master"),
                ("DesiredVolume", "\(volume)")
            ],
            to: player
        )
    }

    func setMute(_ muted: Bool, on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "SetMute",
            service: .renderingControl,
            arguments: [
                ("InstanceID", "0"),
                ("Channel", "Master"),
                ("DesiredMute", muted ? "1" : "0")
            ],
            to: player
        )
    }

    // MARK: - Group volume (GroupRenderingControl service)

    func setGroupVolume(_ volume: Int, on coordinator: DiscoveredPlayer) async throws {
        guard (0...100).contains(volume) else {
            throw SonosError.invalidArgument("group volume must be 0...100, got \(volume)")
        }
        _ = try await client.send(
            action: "SetGroupVolume",
            service: .groupRenderingControl,
            arguments: [("InstanceID", "0"), ("DesiredVolume", "\(volume)")],
            to: coordinator
        )
    }

    func getGroupVolume(of coordinator: DiscoveredPlayer) async throws -> Int {
        let response = try await client.send(
            action: "GetGroupVolume",
            service: .groupRenderingControl,
            arguments: [("InstanceID", "0")],
            to: coordinator
        )
        let raw = response.descendants(named: "CurrentVolume").first?.trimmed ?? "0"
        return Int(raw) ?? 0
    }

    func setGroupMute(_ muted: Bool, on coordinator: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "SetGroupMute",
            service: .groupRenderingControl,
            arguments: [("InstanceID", "0"), ("DesiredMute", muted ? "1" : "0")],
            to: coordinator
        )
    }

    func getGroupMute(of coordinator: DiscoveredPlayer) async throws -> Bool {
        let response = try await client.send(
            action: "GetGroupMute",
            service: .groupRenderingControl,
            arguments: [("InstanceID", "0")],
            to: coordinator
        )
        return response.descendants(named: "CurrentMute").first?.trimmed == "1"
    }

    // MARK: - EQ (RenderingControl service)

    func getEQ(of player: DiscoveredPlayer) async throws -> EQSettings {
        async let bassTask = client.send(
            action: "GetBass",
            service: .renderingControl,
            arguments: [("InstanceID", "0")],
            to: player
        )
        async let trebleTask = client.send(
            action: "GetTreble",
            service: .renderingControl,
            arguments: [("InstanceID", "0")],
            to: player
        )
        async let loudnessTask = client.send(
            action: "GetLoudness",
            service: .renderingControl,
            arguments: [("InstanceID", "0"), ("Channel", "Master")],
            to: player
        )
        let (bassXML, trebleXML, loudnessXML) = try await (bassTask, trebleTask, loudnessTask)
        let bass = Int(bassXML.descendants(named: "CurrentBass").first?.trimmed ?? "0") ?? 0
        let treble = Int(trebleXML.descendants(named: "CurrentTreble").first?.trimmed ?? "0") ?? 0
        let loud = loudnessXML.descendants(named: "CurrentLoudness").first?.trimmed == "1"
        return EQSettings(bass: EQSettings.clampEQ(bass),
                          treble: EQSettings.clampEQ(treble),
                          loudness: loud)
    }

    func setBass(_ bass: Int, on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "SetBass",
            service: .renderingControl,
            arguments: [("InstanceID", "0"), ("DesiredBass", "\(EQSettings.clampEQ(bass))")],
            to: player
        )
    }

    func setTreble(_ treble: Int, on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "SetTreble",
            service: .renderingControl,
            arguments: [("InstanceID", "0"), ("DesiredTreble", "\(EQSettings.clampEQ(treble))")],
            to: player
        )
    }

    func setLoudness(_ enabled: Bool, on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "SetLoudness",
            service: .renderingControl,
            arguments: [
                ("InstanceID", "0"),
                ("Channel", "Master"),
                ("DesiredLoudness", enabled ? "1" : "0")
            ],
            to: player
        )
    }

    // MARK: - Topology

    func getZoneGroups(via player: DiscoveredPlayer) async throws -> [ZoneGroup] {
        let response = try await client.send(
            action: "GetZoneGroupState",
            service: .zoneGroupTopology,
            arguments: [],
            to: player
        )
        guard let stateText = response.descendants(named: "ZoneGroupState").first?.trimmed,
              !stateText.isEmpty else {
            throw SonosError.malformedResponse(detail: "missing ZoneGroupState")
        }
        let stateRoot = try XMLNode.parse(stateText)
        return Self.parseZoneGroups(from: stateRoot)
    }

    // MARK: - Queue

    func getQueue(via player: DiscoveredPlayer) async throws -> [QueueItem] {
        var items: [QueueItem] = []
        var startingIndex = 0
        let pageSize = 200

        // Same paging contract as favorites; queues cap at 1000 tracks on
        // current firmware, so the bound is generous.
        for _ in 0..<10 {
            let response = try await client.send(
                action: "Browse",
                service: .contentDirectory,
                arguments: [
                    ("ObjectID", "Q:0"),
                    ("BrowseFlag", "BrowseDirectChildren"),
                    ("Filter", "*"),
                    ("StartingIndex", "\(startingIndex)"),
                    ("RequestedCount", "\(pageSize)"),
                    ("SortCriteria", "")
                ],
                to: player
            )
            guard let didlText = response.descendants(named: "Result").first?.trimmed,
                  !didlText.isEmpty else { break }
            let didl = try XMLNode.parse(didlText)
            items += Self.parseQueueItems(from: didl, startingAt: startingIndex + 1, baseURL: player.baseURL)

            let returned = Int(response.descendants(named: "NumberReturned").first?.trimmed ?? "0") ?? 0
            let total = Int(response.descendants(named: "TotalMatches").first?.trimmed ?? "0") ?? 0
            startingIndex += returned
            if returned == 0 || startingIndex >= total { break }
        }
        return items
    }

    // Internal (not private) so the parser test harness can exercise it.
    static func parseQueueItems(from didl: XMLNode, startingAt firstIndex: Int, baseURL: URL) -> [QueueItem] {
        return didl.descendants(named: "item").enumerated().map { offset, item in
            let art = item.descendants(named: "albumArtURI").first?.trimmed
            return QueueItem(
                index: firstIndex + offset,
                title: item.descendants(named: "title").first?.trimmed ?? "",
                artist: item.descendants(named: "creator").first?.trimmed ?? "",
                album: item.descendants(named: "album").first?.trimmed ?? "",
                albumArtURL: art.flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: baseURL)?.absoluteURL }
            )
        }
    }

    // MARK: - Grouping

    func join(player: DiscoveredPlayer, toCoordinatorUUID coordinatorUUID: String) async throws {
        // Joining a group is "play the coordinator's stream": an
        // x-rincon: URI naming the coordinator, no metadata. The joined
        // player's bonded satellites follow automatically.
        _ = try await client.send(
            action: "SetAVTransportURI",
            service: .avTransport,
            arguments: [
                ("InstanceID", "0"),
                ("CurrentURI", "x-rincon:\(coordinatorUUID)"),
                ("CurrentURIMetaData", "")
            ],
            to: player
        )
    }

    func leaveGroup(player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "BecomeCoordinatorOfStandaloneGroup",
            service: .avTransport,
            arguments: [("InstanceID", "0")],
            to: player
        )
    }

    // MARK: - Favorites (chunk 9)
    //
    // Favorites live in the ContentDirectory service at ObjectID "FV:2".
    // We Browse that container, then parse each <item> from the
    // DIDL-Lite result.
    //
    // Play path: SetAVTransportURI(uri, didl-metadata), then Play.
    // The DIDL metadata is essential — Sonos won't play queue-based
    // favorites (Spotify playlists, Apple Music albums) without it.

    func getFavorites(via player: DiscoveredPlayer) async throws -> [SonosFavorite] {
        var favorites: [SonosFavorite] = []
        var startingIndex = 0
        let pageSize = 200

        // Page until TotalMatches is exhausted; the fixed iteration bound
        // (25 pages / 5000 favorites) only guards against a firmware bug
        // reporting inconsistent counts.
        for _ in 0..<25 {
            let response = try await client.send(
                action: "Browse",
                service: .contentDirectory,
                arguments: [
                    ("ObjectID", "FV:2"),
                    ("BrowseFlag", "BrowseDirectChildren"),
                    ("Filter", "*"),
                    ("StartingIndex", "\(startingIndex)"),
                    ("RequestedCount", "\(pageSize)"),
                    ("SortCriteria", "")
                ],
                to: player
            )

            // The <Result> element is escaped DIDL-Lite XML.
            guard let didlText = response.descendants(named: "Result").first?.trimmed,
                  !didlText.isEmpty else {
                break
            }
            let didl = try XMLNode.parse(didlText)
            favorites += Self.parseFavorites(from: didl, player: player)

            let returned = Int(response.descendants(named: "NumberReturned").first?.trimmed ?? "0") ?? 0
            let total = Int(response.descendants(named: "TotalMatches").first?.trimmed ?? "0") ?? 0
            startingIndex += returned
            if returned == 0 || startingIndex >= total { break }
        }
        return favorites
    }

    // Internal (not private) so the parser test harness can exercise it.
    static func parseFavorites(from didl: XMLNode, player: DiscoveredPlayer) -> [SonosFavorite] {
        return didl.descendants(named: "item").compactMap { item -> SonosFavorite? in
            let title = item.descendants(named: "title").first?.trimmed ?? ""

            // <r:resMD> contains an escaped DIDL document we want to
            // pass through verbatim to SetAVTransportURI.
            let resMD = item.descendants(named: "resMD").first?.trimmed

            // The favorite's playable URI is usually in <res> of the item —
            // but container-style favorites (Sonos Radio category pages and
            // the like) ship an EMPTY <res>. Some of those carry a real URI
            // inside the resMD DIDL; the rest have only a container id, and
            // the speaker rejects every URI built from it with UPnP 714
            // (verified live) — those are listed as unplayable rather than
            // silently dropped, which used to hide most of the Favorites
            // tab (caught by the parser tests).
            var res = item.first("res")?.trimmed ?? ""
            var isPlayable = !res.isEmpty
            if res.isEmpty,
               let resMD,
               let mdRoot = try? XMLNode.parse(resMD),
               let innerItem = mdRoot.descendants(named: "item").first {
                if let innerRes = innerItem.first("res")?.trimmed, !innerRes.isEmpty {
                    res = innerRes
                    isPlayable = true
                } else if let id = innerItem.attributes["id"], !id.isEmpty {
                    // Unique identifier for the row; never sent to a speaker.
                    res = "x-rincon-cpcontainer:" + id
                }
            }
            guard !res.isEmpty else { return nil }

            let metadata = resMD ?? Self.synthesizeDIDL(title: title, uri: res)

            let albumArt: URL? = {
                if let art = item.descendants(named: "albumArtURI").first?.trimmed, !art.isEmpty {
                    return URL(string: art, relativeTo: player.baseURL)?.absoluteURL
                }
                return nil
            }()

            return SonosFavorite(
                title: title,
                uri: res,
                albumArtURL: albumArt,
                metadata: metadata,
                isPlayable: isPlayable
            )
        }
    }

    func play(favorite: SonosFavorite, on player: DiscoveredPlayer) async throws {
        // Order matters: SetAVTransportURI first, then Play.
        // Calling Play without the SetAVTransportURI just resumes
        // whatever was playing before.
        _ = try await client.send(
            action: "SetAVTransportURI",
            service: .avTransport,
            arguments: [
                ("InstanceID", "0"),
                ("CurrentURI", favorite.uri),
                ("CurrentURIMetaData", favorite.metadata)
            ],
            to: player
        )
        try await play(on: player)
    }

    /// Fallback DIDL when a favorite doesn't carry resMD — synthesises
    /// a minimal envelope so SetAVTransportURI still works for simple
    /// stream URIs (TuneIn radio, line-in).
    // Internal (not private) so the parser harness can assert escaping.
    static func synthesizeDIDL(title: String, uri: String) -> String {
        // Escape here: this DIDL is sent as the CurrentURIMetaData argument,
        // which SOAPClient escapes at the envelope level and the speaker
        // then un-escapes and re-parses as XML. Without escaping the inner
        // fields, a favorite title containing `<`/`&` (e.g. a maliciously
        // named shared playlist) injects DIDL structure into the speaker.
        let t = SOAPClient.escape(title)
        let u = SOAPClient.escape(uri)
        return #"""
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
          <item id="-1" parentID="-1" restricted="true">
            <dc:title>\#(t)</dc:title>
            <res>\#(u)</res>
            <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>
          </item>
        </DIDL-Lite>
        """#
    }

    // MARK: - Play mode

    func getPlayMode(of player: DiscoveredPlayer) async throws -> (mode: PlayMode, crossfade: Bool) {
        async let settingsTask = client.send(
            action: "GetTransportSettings",
            service: .avTransport,
            arguments: [("InstanceID", "0")],
            to: player
        )
        async let crossfadeTask = client.send(
            action: "GetCrossfadeMode",
            service: .avTransport,
            arguments: [("InstanceID", "0")],
            to: player
        )
        let (settingsXML, crossfadeXML) = try await (settingsTask, crossfadeTask)
        let raw = settingsXML.descendants(named: "PlayMode").first?.trimmed ?? "NORMAL"
        let crossfade = crossfadeXML.descendants(named: "CrossfadeMode").first?.trimmed == "1"
        return (PlayMode(rawValue: raw), crossfade)
    }

    func setPlayMode(_ mode: PlayMode, on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "SetPlayMode",
            service: .avTransport,
            arguments: [("InstanceID", "0"), ("NewPlayMode", mode.rawValue)],
            to: player
        )
    }

    func setCrossfade(_ enabled: Bool, on player: DiscoveredPlayer) async throws {
        _ = try await client.send(
            action: "SetCrossfadeMode",
            service: .avTransport,
            arguments: [("InstanceID", "0"), ("CrossfadeMode", enabled ? "1" : "0")],
            to: player
        )
    }

    // MARK: - Sleep timer (chunk 10)

    func setSleepTimer(seconds: Int, on player: DiscoveredPlayer) async throws {
        // Sonos expects "HH:MM:SS" or empty string to clear.
        let value: String
        if seconds <= 0 {
            value = ""
        } else {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            let s = seconds % 60
            value = String(format: "%02d:%02d:%02d", h, m, s)
        }
        _ = try await client.send(
            action: "ConfigureSleepTimer",
            service: .avTransport,
            arguments: [
                ("InstanceID", "0"),
                ("NewSleepTimerDuration", value)
            ],
            to: player
        )
    }

    func getSleepTimerRemaining(on player: DiscoveredPlayer) async throws -> Int {
        let response = try await client.send(
            action: "GetRemainingSleepTimerDuration",
            service: .avTransport,
            arguments: [("InstanceID", "0")],
            to: player
        )
        // Response includes <RemainingSleepTimerDuration> — "HH:MM:SS" or "".
        guard let raw = response.descendants(named: "RemainingSleepTimerDuration").first?.trimmed,
              !raw.isEmpty else { return 0 }
        return Int(Self.parseDuration(raw))
    }

    // MARK: - Parsing helpers

    private static func parseTrack(from positionInfo: XMLNode, baseURL: URL) -> TrackInfo {
        // No fallback to the envelope root: the fields below are direct
        // children of the response element, so nothing could be found there.
        guard let body = positionInfo.descendants(named: "GetPositionInfoResponse").first else {
            return TrackInfo()
        }

        var track = body.first("TrackMetaData").flatMap {
            parseDIDLTrack(fromDIDL: $0.trimmed, baseURL: baseURL)
        } ?? TrackInfo()

        track.duration = parseDuration(body.first("TrackDuration")?.trimmed ?? "0:00:00")
        track.position = parseDuration(body.first("RelTime")?.trimmed ?? "0:00:00")
        track.trackURI = body.first("TrackURI")?.trimmed ?? ""
        track.queueIndex = Int(body.first("Track")?.trimmed ?? "0") ?? 0

        return track
    }

    /// Parses track metadata out of a DIDL-Lite document — the shape shared
    /// by GetPositionInfo's TrackMetaData and the CurrentTrackMetaData field
    /// of AVTransport GENA events. Duration comes from the res node's
    /// attribute when present; position never travels in DIDL.
    static func parseDIDLTrack(fromDIDL didl: String, baseURL: URL) -> TrackInfo? {
        guard !didl.isEmpty,
              didl != "NOT_IMPLEMENTED",
              let didlRoot = try? XMLNode.parse(didl),
              let item = didlRoot.descendants(named: "item").first else { return nil }

        var track = TrackInfo()
        track.title = item.first("title")?.trimmed
            ?? item.descendants(named: "title").first?.trimmed ?? ""
        track.artist = item.descendants(named: "creator").first?.trimmed ?? ""
        track.album = item.descendants(named: "album").first?.trimmed ?? ""

        if let art = item.descendants(named: "albumArtURI").first?.trimmed, !art.isEmpty {
            track.albumArtURL = URL(string: art, relativeTo: baseURL)?.absoluteURL
        }
        if let dur = item.first("res")?.attributes["duration"] {
            track.duration = parseDuration(dur)
        }
        return track
    }

    private static func parseDuration(_ s: String) -> TimeInterval {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        var total: Double = 0
        for part in parts {
            total = total * 60 + part
        }
        return total
    }

    /// Internal (not fileprivate) so the coordinator can reuse it for
    /// ZoneGroupTopology event payloads — same XML shape as GetZoneGroupState.
    static func parseZoneGroups(from root: XMLNode) -> [ZoneGroup] {
        return root.descendants(named: "ZoneGroup").compactMap { groupNode in
            guard let coord = groupNode.attributes["Coordinator"],
                  let groupID = groupNode.attributes["ID"] else { return nil }
            let members: [ZoneGroupMember] = groupNode.all("ZoneGroupMember").compactMap { m in
                guard let uuid = m.attributes["UUID"],
                      let zone = m.attributes["ZoneName"] else { return nil }
                let host = m.attributes["Location"].flatMap(URL.init(string:))?.host ?? ""
                return ZoneGroupMember(
                    uuid: uuid,
                    zoneName: zone,
                    host: host,
                    isCoordinator: uuid == coord,
                    isInvisible: m.attributes["Invisible"] == "1"
                )
            }
            return ZoneGroup(id: groupID, coordinatorUUID: coord, members: members)
        }
    }
}
