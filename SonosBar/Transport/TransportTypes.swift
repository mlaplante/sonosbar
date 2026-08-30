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
    /// 1-based position in the play queue (GetPositionInfo <Track>).
    /// 0 when nothing is queued (radio streams, line-in).
    var queueIndex: Int = 0
}

/// One entry of the play queue (ContentDirectory "Q:0").
struct QueueItem: Sendable, Equatable, Identifiable {
    /// 1-based queue position — what AVTransport Seek(TRACK_NR) expects.
    let index: Int
    let title: String
    let artist: String
    let album: String
    let albumArtURL: URL?

    var id: Int { index }
}

/// Shuffle/repeat decomposition of Sonos's single PlayMode string.
struct PlayMode: Sendable, Equatable {
    enum RepeatMode: Sendable, Equatable { case off, all, one }

    var shuffle: Bool = false
    var repeatMode: RepeatMode = .off

    init() {}

    init(rawValue: String) {
        switch rawValue {
        case "REPEAT_ALL":         (shuffle, repeatMode) = (false, .all)
        case "REPEAT_ONE":         (shuffle, repeatMode) = (false, .one)
        case "SHUFFLE_NOREPEAT":   (shuffle, repeatMode) = (true, .off)
        case "SHUFFLE":            (shuffle, repeatMode) = (true, .all)
        case "SHUFFLE_REPEAT_ONE": (shuffle, repeatMode) = (true, .one)
        default:                   (shuffle, repeatMode) = (false, .off)
        }
    }

    var rawValue: String {
        switch (shuffle, repeatMode) {
        case (false, .off): return "NORMAL"
        case (false, .all): return "REPEAT_ALL"
        case (false, .one): return "REPEAT_ONE"
        case (true, .off):  return "SHUFFLE_NOREPEAT"
        case (true, .all):  return "SHUFFLE"
        case (true, .one):  return "SHUFFLE_REPEAT_ONE"
        }
    }
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
    /// Bonded satellites (the second half of a stereo pair, surrounds,
    /// subs) report Invisible="1". They move with their bonded partner
    /// and must not be offered for grouping or per-speaker volume.
    let isInvisible: Bool
}

/// A zone group — one coordinator plus zero or more secondary members.
/// All members play the same audio in sync.
struct ZoneGroup: Sendable, Equatable, Hashable {
    let id: String              // typically "<coordinatorUUID>:<gen>"
    let coordinatorUUID: String
    let members: [ZoneGroupMember]

    /// Members the user can see and act on — bonded satellites excluded.
    var visibleMembers: [ZoneGroupMember] {
        members.filter { !$0.isInvisible }
    }

    /// A friendly name. If there's one visible member, it's just that
    /// zone. Otherwise it's "Kitchen + 2" style, counting visible zones
    /// only — a stereo pair is one zone, not two.
    var displayName: String {
        guard let coord = members.first(where: { $0.uuid == coordinatorUUID }) else {
            return members.first?.zoneName ?? "Group"
        }
        let others = visibleMembers.count(where: { $0.uuid != coordinatorUUID })
        return others > 0 ? "\(coord.zoneName) + \(others)" : coord.zoneName
    }
}
