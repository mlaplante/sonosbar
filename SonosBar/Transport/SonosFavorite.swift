//
//  SonosFavorite.swift
//  SonosBar
//
//  Mirrors a Sonos "favorite" — what shows up in the Sonos app under
//  My Sonos / Favorites. Could be a Spotify playlist, a TuneIn station,
//  an Apple Music album, etc. We don't distinguish kinds because the
//  play path is the same for every type: SetAVTransportURI with the
//  favorite's <res> URI + DIDL metadata, then Play.
//

import Foundation

struct SonosFavorite: Sendable, Hashable, Identifiable {

    var id: String { uri }

    /// Display title — e.g. "Discover Weekly", "BBC Radio 1".
    let title: String

    /// The URI to play — typically x-rincon-cpcontainer:... or x-sonosapi-stream:...
    /// Sonos firmware interprets the scheme to know which service to invoke.
    let uri: String

    /// Album-art URL, if the service provided one. Resolved against the
    /// player's base URL by the transport layer so it's already absolute.
    let albumArtURL: URL?

    /// DIDL-Lite metadata blob. Required when calling SetAVTransportURI —
    /// without it, queue-based favorites won't play correctly. We capture
    /// it as raw XML and pass it through opaquely.
    let metadata: String
}
