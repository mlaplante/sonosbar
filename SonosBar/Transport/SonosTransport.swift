//
//  SonosTransport.swift
//  SonosBar
//
//  The single boundary between "how we talk to Sonos" and everything else.
//
//  v1.0 ships exactly one implementation: SOAPTransport (local UPnP).
//  This protocol exists anyway because:
//
//    1. Tests: a MockTransport lets us exercise the domain layer offline.
//    2. Hedging: if Sonos ever ships a real local REST API, or if we want
//       to add cloud as a remote-control fallback, we swap implementations
//       without touching anything above.
//    3. Clarity: this file is the canonical list of what the rest of the
//       app needs from "talking to Sonos".
//
//  Method shape conventions:
//    * Read methods are non-mutating and idempotent.
//    * Write methods return Void on success; failures throw.
//    * All methods are async.
//

import Foundation

protocol SonosTransport: Sendable {

    // MARK: - Playback (AVTransport service)

    func play(on player: DiscoveredPlayer) async throws
    func pause(on player: DiscoveredPlayer) async throws
    func next(on player: DiscoveredPlayer) async throws
    func previous(on player: DiscoveredPlayer) async throws

    /// Seek within the current track. Seconds is clamped to [0, duration]
    /// by the implementation; the speaker will refuse out-of-range seeks
    /// for non-seekable streams (e.g. live radio).
    func seek(toSeconds seconds: Int, on player: DiscoveredPlayer) async throws

    func playbackSnapshot(of player: DiscoveredPlayer) async throws -> PlaybackSnapshot

    /// Jumps to the 1-based queue position on the player's current queue.
    func seek(toTrack index: Int, on player: DiscoveredPlayer) async throws

    // MARK: - Volume (RenderingControl service)

    func getVolume(of player: DiscoveredPlayer) async throws -> VolumeSnapshot
    func setVolume(_ volume: Int, on player: DiscoveredPlayer) async throws
    func setMute(_ muted: Bool, on player: DiscoveredPlayer) async throws

    /// Group volume via GroupRenderingControl: one call to the group
    /// coordinator scales the whole group's mix, which per-speaker
    /// RenderingControl SetVolume does not. Send to the coordinator.
    func setGroupVolume(_ volume: Int, on coordinator: DiscoveredPlayer) async throws
    func getGroupVolume(of coordinator: DiscoveredPlayer) async throws -> Int
    func setGroupMute(_ muted: Bool, on coordinator: DiscoveredPlayer) async throws
    func getGroupMute(of coordinator: DiscoveredPlayer) async throws -> Bool

    // MARK: - EQ (RenderingControl service)

    /// Bass/treble/loudness for a single speaker (the group coordinator in
    /// practice). Bass/treble are −10…10; loudness is boolean.
    func getEQ(of player: DiscoveredPlayer) async throws -> EQSettings
    func setBass(_ bass: Int, on player: DiscoveredPlayer) async throws
    func setTreble(_ treble: Int, on player: DiscoveredPlayer) async throws
    func setLoudness(_ enabled: Bool, on player: DiscoveredPlayer) async throws

    // MARK: - Topology (ZoneGroupTopology service)

    func getZoneGroups(via player: DiscoveredPlayer) async throws -> [ZoneGroup]

    // MARK: - Grouping (AVTransport service)

    /// Joins `player` (and its bonded satellites) to the group led by
    /// `coordinatorUUID`. The player starts playing that group's audio.
    func join(player: DiscoveredPlayer, toCoordinatorUUID coordinatorUUID: String) async throws

    /// Removes `player` from its current group; it becomes a standalone
    /// group of its own and stops playing the group's audio.
    func leaveGroup(player: DiscoveredPlayer) async throws

    // MARK: - Favorites (ContentDirectory service) — chunk 9

    func getFavorites(via player: DiscoveredPlayer) async throws -> [SonosFavorite]
    func play(favorite: SonosFavorite, on player: DiscoveredPlayer) async throws

    // MARK: - Queue (ContentDirectory service)

    /// The group's current play queue. Ask the group COORDINATOR — the
    /// queue lives on it; members return their own (empty) queues.
    func getQueue(via player: DiscoveredPlayer) async throws -> [QueueItem]

    // MARK: - Play mode (AVTransport service)

    func getPlayMode(of player: DiscoveredPlayer) async throws -> (mode: PlayMode, crossfade: Bool)
    func setPlayMode(_ mode: PlayMode, on player: DiscoveredPlayer) async throws
    func setCrossfade(_ enabled: Bool, on player: DiscoveredPlayer) async throws

    // MARK: - Sleep timer (AVTransport service) — chunk 10

    /// Zero seconds clears the timer.
    func setSleepTimer(seconds: Int, on player: DiscoveredPlayer) async throws

    /// Returns remaining seconds, or 0 if no timer is set.
    func getSleepTimerRemaining(on player: DiscoveredPlayer) async throws -> Int
}
