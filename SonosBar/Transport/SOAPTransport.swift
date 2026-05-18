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
        let response = try await client.send(
            action: "Browse",
            service: .contentDirectory,
            arguments: [
                ("ObjectID", "FV:2"),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", "*"),
                ("StartingIndex", "0"),
                ("RequestedCount", "1000"),
                ("SortCriteria", "")
            ],
            to: player
        )

        // The <Result> element is escaped DIDL-Lite XML.
        guard let didlText = response.descendants(named: "Result").first?.trimmed,
              !didlText.isEmpty else {
            return []
        }
        let didl = try XMLNode.parse(didlText)

        return didl.descendants(named: "item").compactMap { item -> SonosFavorite? in
            let title = item.descendants(named: "title").first?.trimmed ?? ""

            // The favorite's playable URI is in <res> of the item.
            // The "real" metadata for SetAVTransportURI is in the
            // <r:resMD> ("r:" is Sonos's resource-metadata namespace).
            guard let res = item.first("res")?.trimmed, !res.isEmpty else { return nil }

            // <r:resMD> contains an escaped DIDL document we want to
            // pass through verbatim to SetAVTransportURI.
            let metadata = item.descendants(named: "resMD").first?.trimmed
                ?? Self.synthesizeDIDL(title: title, uri: res)

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
                metadata: metadata
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
    private static func synthesizeDIDL(title: String, uri: String) -> String {
        return #"""
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
          <item id="-1" parentID="-1" restricted="true">
            <dc:title>\#(title)</dc:title>
            <res>\#(uri)</res>
            <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>
          </item>
        </DIDL-Lite>
        """#
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
        var track = TrackInfo()
        let body = positionInfo.descendants(named: "GetPositionInfoResponse").first ?? positionInfo

        track.duration = parseDuration(body.first("TrackDuration")?.trimmed ?? "0:00:00")
        track.position = parseDuration(body.first("RelTime")?.trimmed ?? "0:00:00")
        track.trackURI = body.first("TrackURI")?.trimmed ?? ""

        if let didl = body.first("TrackMetaData")?.trimmed,
           !didl.isEmpty,
           didl != "NOT_IMPLEMENTED",
           let didlRoot = try? XMLNode.parse(didl),
           let item = didlRoot.descendants(named: "item").first {

            track.title = item.first("title")?.trimmed
                ?? item.descendants(named: "title").first?.trimmed ?? ""
            track.artist = item.descendants(named: "creator").first?.trimmed ?? ""
            track.album = item.descendants(named: "album").first?.trimmed ?? ""

            if let art = item.descendants(named: "albumArtURI").first?.trimmed, !art.isEmpty {
                track.albumArtURL = URL(string: art, relativeTo: baseURL)?.absoluteURL
            }
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

    fileprivate static func parseZoneGroups(from root: XMLNode) -> [ZoneGroup] {
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
