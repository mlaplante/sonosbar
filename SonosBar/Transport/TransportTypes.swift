//
//  TransportTypes.swift
//  SonosBar
//
//  Value types returned by the transport layer. These are intentionally
//  thin — they map almost 1:1 to what SOAP/UPnP returns. The domain layer
//  (chunk 4) composes these into richer structures.
//

import Foundation

/// Mirror of UPnP's TransportState enum.
enum PlaybackState: String, Sendable, Equatable {
    case playing       = "PLAYING"
    case paused        = "PAUSED_PLAYBACK"
    case stopped       = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMedia       = "NO_MEDIA_PRESENT"

    /// Convenience for "the user thinks something is playing".
    var isActive: Bool {
        self == .playing || self == .transitioning
    }
}

/// Currently-playing track metadata. Most fields can be empty for
/// line-in or radio stations that don't supply DIDL metadata.
struct TrackInfo: Sendable, Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    /// Album art URL. Sonos returns this as a relative path that needs
    /// to be resolved against the player's base URL.
    var albumArtURL: URL? = nil
    /// Total track duration in seconds. 0 for streams.
    var duration: TimeInterval = 0
    /// Current playback position in seconds.
    var position: TimeInterval = 0
    /// URI of the current track. Useful for "is this still the same track?"
    var trackURI: String = ""
}

/// Current playback state + the track it applies to.
struct PlaybackSnapshot: Sendable, Equatable {
    var state: PlaybackState = .stopped
    var track: TrackInfo = TrackInfo()
}

/// Group-level volume payload.
struct VolumeSnapshot: Sendable, Equatable {
    var volume: Int = 0           // 0...100
    var muted: Bool = false
}

/// A single zone-group member as reported by ZoneGroupTopology.
struct ZoneGroupMember: Sendable, Equatable, Hashable {
    let uuid: String
    let zoneName: String
    let host: String
    let isCoordinator: Bool
}

/// A zone group — one coordinator plus zero or more secondary members.
/// All members play the same audio in sync.
struct ZoneGroup: Sendable, Equatable, Hashable {
    let id: String              // typically "<coordinatorUUID>:<gen>"
    let coordinatorUUID: String
    let members: [ZoneGroupMember]

    /// A friendly name. If there's one member, it's just that zone.
    /// Otherwise it's "Kitchen + 2" style.
    var displayName: String {
        guard let coord = members.first(where: { $0.uuid == coordinatorUUID }) else {
            return members.first?.zoneName ?? "Group"
        }
        let others = members.count - 1
        return others > 0 ? "\(coord.zoneName) + \(others)" : coord.zoneName
    }
}
