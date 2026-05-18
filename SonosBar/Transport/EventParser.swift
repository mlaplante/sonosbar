//
//  EventParser.swift
//  SonosBar
//
//  GENA NOTIFY bodies for Sonos services are shaped like:
//
//    <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
//      <e:property>
//        <LastChange>&lt;Event xmlns=...&gt;...&lt;/Event&gt;</LastChange>
//      </e:property>
//    </e:propertyset>
//
//  The interesting content is in <LastChange> as escaped XML, requiring
//  a second parse. The inner <Event> uses val attributes for scalar
//  values rather than text content (a UPnP quirk).
//
//  We expose typed decoders for the events the UI actually cares about.
//

import Foundation

enum EventParser {

    /// Decoded RenderingControl event — volume/mute changes for a single player.
    struct RenderingControlEvent: Sendable {
        var volume: Int?
        var muted: Bool?
    }

    /// Decoded AVTransport event — playback state and current track URI.
    struct AVTransportEvent: Sendable {
        var state: PlaybackState?
        var currentTrackURI: String?
        var trackMetadata: String?    // Raw DIDL — parse on demand if needed.
    }

    /// Decoded ZoneGroupTopology event — full topology in <ZoneGroupState>.
    struct ZoneGroupTopologyEvent: Sendable {
        var zoneGroupStateXML: String?
    }

    // MARK: - Decoders

    static func renderingControl(from body: Data) throws -> RenderingControlEvent {
        let inner = try parseLastChange(body)
        var event = RenderingControlEvent()

        // Master channel only — Sonos sends per-channel events for
        // LeftMaster/RightMaster on stereo-paired speakers; we ignore
        // those for v1.
        for node in inner.descendants(named: "Volume") {
            guard node.attributes["channel"] == "Master" else { continue }
            if let v = node.attributes["val"], let i = Int(v) { event.volume = i }
        }
        for node in inner.descendants(named: "Mute") {
            guard node.attributes["channel"] == "Master" else { continue }
            if let v = node.attributes["val"] { event.muted = (v == "1") }
        }
        return event
    }

    static func avTransport(from body: Data) throws -> AVTransportEvent {
        let inner = try parseLastChange(body)
        var event = AVTransportEvent()

        if let s = inner.descendants(named: "TransportState").first?.attributes["val"] {
            event.state = PlaybackState(rawValue: s)
        }
        if let u = inner.descendants(named: "CurrentTrackURI").first?.attributes["val"] {
            event.currentTrackURI = u
        }
        if let m = inner.descendants(named: "CurrentTrackMetaData").first?.attributes["val"] {
            event.trackMetadata = m
        }
        return event
    }

    static func zoneGroupTopology(from body: Data) throws -> ZoneGroupTopologyEvent {
        let root = try XMLNode.parse(body)
        var event = ZoneGroupTopologyEvent()
        // ZoneGroupTopology events deliver <ZoneGroupState> directly as
        // a property (not via LastChange).
        if let stateNode = root.descendants(named: "ZoneGroupState").first {
            event.zoneGroupStateXML = stateNode.trimmed
        }
        return event
    }

    // MARK: - LastChange unwrapping

    private static func parseLastChange(_ body: Data) throws -> XMLNode {
        let outer = try XMLNode.parse(body)
        guard let lastChange = outer.descendants(named: "LastChange").first?.trimmed,
              !lastChange.isEmpty else {
            throw SonosError.malformedResponse(detail: "event body missing LastChange")
        }
        return try XMLNode.parse(lastChange)
    }
}
