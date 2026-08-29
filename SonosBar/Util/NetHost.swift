//
//  NetHost.swift
//  SonosBar
//
//  Host-string plumbing for URLs and raw HTTP headers. Sonos LANs are
//  IPv4 in practice, but host strings flow in from parsed URLs, SSDP
//  LOCATION headers, and the kernel's local-endpoint report — an IPv6
//  literal in any of those would break "http://\(host):\(port)" string
//  interpolation (unbracketed colons), and a force-unwrapped
//  URL(string:) would then crash. Build through URLComponents instead,
//  which brackets IPv6 hosts itself.
//

import Foundation

enum NetHost {

    /// http URL for a raw host + port, nil only for hosts no URL can
    /// represent. Handles IPv6 literals by delegating bracketing to
    /// URLComponents.
    static func httpURL(host: String, port: Int, path: String = "") -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }

    /// Host formatted for hand-built HTTP header values (GENA CALLBACK):
    /// IPv6 literals need brackets, everything else passes through.
    static func bracketed(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}
