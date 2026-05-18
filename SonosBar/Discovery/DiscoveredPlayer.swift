//
//  DiscoveredPlayer.swift
//  SonosBar
//
//  Output of the discovery layer: a single Sonos device on the LAN.
//  This is intentionally minimal — just enough to talk to the device.
//  The richer domain model (groups, zones, transport state) lives in
//  Domain/ and is built on top of multiple DiscoveredPlayers.
//

import Foundation

struct DiscoveredPlayer: Hashable, Sendable {

    /// The Sonos-internal UUID, e.g. "RINCON_5CAAFD123456789".
    /// Stable across reboots and IP changes — this is the canonical ID.
    let uuid: String

    /// IPv4 address the speaker is reachable at on the LAN.
    let host: String

    /// Always 1400 in practice but kept explicit for future-proofing.
    let port: Int

    /// Human-readable model, e.g. "Sonos Play:5", "Sonos One SL".
    let model: String

    /// User-assigned zone name, e.g. "Kitchen", "Living Room".
    let zoneName: String

    /// Household ID — speakers in the same Sonos account share this.
    /// Used to filter out neighbours' speakers if they bleed onto your LAN
    /// (this happens in apartment buildings and shared WiFi setups).
    let household: String?

    /// Base URL for SOAP control and device description.
    var baseURL: URL {
        // Force-unwrap is safe: host comes from a parsed URL response;
        // port is a constant; scheme is hardcoded.
        URL(string: "http://\(host):\(port)")!
    }
}
