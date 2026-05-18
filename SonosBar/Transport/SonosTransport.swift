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

    func playbackSnapshot(of player: DiscoveredPlayer) async throws -> PlaybackSnapshot

    // MARK: - Volume (RenderingControl service)

    func getVolume(of player: DiscoveredPlayer) async throws -> VolumeSnapshot
    func setVolume(_ volume: Int, on player: DiscoveredPlayer) async throws
    func setMute(_ muted: Bool, on player: DiscoveredPlayer) async throws

    // MARK: - Topology (ZoneGroupTopology service)

    func getZoneGroups(via player: DiscoveredPlayer) async throws -> [ZoneGroup]

    // MARK: - Favorites (ContentDirectory service) — chunk 9

    func getFavorites(via player: DiscoveredPlayer) async throws -> [SonosFavorite]
    func play(favorite: SonosFavorite, on player: DiscoveredPlayer) async throws

    // MARK: - Sleep timer (AVTransport service) — chunk 10

    /// Zero seconds clears the timer.
    func setSleepTimer(seconds: Int, on player: DiscoveredPlayer) async throws

    /// Returns remaining seconds, or 0 if no timer is set.
    func getSleepTimerRemaining(on player: DiscoveredPlayer) async throws -> Int
}
