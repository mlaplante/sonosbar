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

/// Equalizer settings from RenderingControl. Bass/treble are the Sonos
/// range −10…+10 (verified against a live device SCPD); loudness is a
/// per-speaker boolean.
struct EQSettings: Sendable, Equatable {
    var bass: Int = 0             // -10...10
    var treble: Int = 0          // -10...10
    var loudness: Bool = true    // Sonos ships loudness on by default

    /// Clamp helper shared by the setters so the UI can't push an
    /// out-of-range value the speaker would reject with a SOAP fault.
    static func clampEQ(_ value: Int) -> Int { max(-10, min(10, value)) }
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

    /// Re-resolves a selected group ID against fresh topology.
    ///
    /// Group IDs are `<coordinatorUUID>:<generation>`, and Sonos bumps the
    /// generation every time a group re-forms (a speaker joins/leaves, a
    /// stereo pair re-bonds). Falling back to `groups.first` whenever the
    /// exact ID vanished silently retargeted the controls at an unrelated
    /// zone, e.g. a TV soundbar that rejects Pause/Next with UPnP 701.
    /// Instead, follow the same speakers into whatever group they're in now.
    static func resolveSelection(
        previousID: String?,
        previousGroup: ZoneGroup? = nil,
        in groups: [ZoneGroup]
    ) -> String? {
        guard let previousID else { return groups.first?.id }
        if groups.contains(where: { $0.id == previousID }) { return previousID }

        let prevCoordinator = previousGroup?.coordinatorUUID
            ?? previousID.split(separator: ":", maxSplits: 1).first.map(String.init)
            ?? previousID

        // Same coordinator, new generation.
        if let g = groups.first(where: { $0.coordinatorUUID == prevCoordinator }) { return g.id }
        // The old coordinator joined another group.
        if let g = groups.first(where: { $0.members.contains { $0.uuid == prevCoordinator } }) {
            return g.id
        }
        // Coordinator gone (asleep/removed): follow any other former member.
        if let prev = previousGroup {
            let prevMembers = Set(prev.members.map(\.uuid))
            if let g = groups.first(where: { $0.members.contains { prevMembers.contains($0.uuid) } }) {
                return g.id
            }
        }
        return groups.first?.id
    }

    /// The group the controls should target after a topology change.
    ///
    /// The user's explicit pick (`preferred`) wins whenever its speakers are
    /// in the topology, even if the current selection is still a valid
    /// group. Otherwise a fallback taken while those speakers were briefly
    /// absent (reboot, overnight firmware update) stuck forever: the
    /// fallback group never vanished, so nothing re-resolved.
    static func effectiveSelection(
        preferred: ZonePreference?,
        currentID: String?,
        previousGroup: ZoneGroup?,
        in groups: [ZoneGroup]
    ) -> String? {
        if let preferred, let id = preferred.resolve(in: groups) { return id }
        if let currentID, groups.contains(where: { $0.id == currentID }) { return currentID }
        return resolveSelection(previousID: currentID, previousGroup: previousGroup, in: groups)
    }
}

/// The zone the user explicitly chose, by speaker identity rather than by
/// group ID (whose generation suffix changes on every regroup).
struct ZonePreference: Equatable {
    var coordinatorUUID: String
    var memberUUIDs: Set<String>

    init(coordinatorUUID: String, memberUUIDs: Set<String>) {
        self.coordinatorUUID = coordinatorUUID
        self.memberUUIDs = memberUUIDs
    }

    init(group: ZoneGroup) {
        self.init(coordinatorUUID: group.coordinatorUUID,
                  memberUUIDs: Set(group.members.map(\.uuid)))
    }

    /// Rebuilds a preference from persisted state. `savedGroupID` is a
    /// `<coordinatorUUID>:<generation>` ID; members may be empty for
    /// settings written before members were persisted.
    init?(savedGroupID: String?, memberUUIDs: Set<String>) {
        guard let savedGroupID, !savedGroupID.isEmpty,
              let coord = savedGroupID.split(separator: ":", maxSplits: 1).first
        else { return nil }
        self.init(coordinatorUUID: String(coord), memberUUIDs: memberUUIDs)
    }

    /// The group holding the preferred speakers, or nil when none are present.
    func resolve(in groups: [ZoneGroup]) -> String? {
        if let g = groups.first(where: { $0.coordinatorUUID == coordinatorUUID }) { return g.id }
        if let g = groups.first(where: { $0.members.contains { $0.uuid == coordinatorUUID } }) {
            return g.id
        }
        if !memberUUIDs.isEmpty,
           let g = groups.first(where: { $0.members.contains { memberUUIDs.contains($0.uuid) } }) {
            return g.id
        }
        return nil
    }
}
