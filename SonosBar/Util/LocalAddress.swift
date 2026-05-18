//
//  LocalAddress.swift
//  SonosBar
//
//  Determines the local IP address that a remote host on the LAN would
//  see us at. We need this for GENA subscriptions: the CALLBACK header
//  has to be an URL the speaker can reach back to.
//
//  Approach: open a UDP socket to the remote host (no data is actually
//  sent), then read the local endpoint the kernel chose. This picks the
//  correct interface on multi-homed machines (e.g. a MacBook with both
//  WiFi and a USB Ethernet adapter active) without us having to walk
//  the interface list and guess.
//
//  Why not getifaddrs? Because "which interface is the LAN one" is a
//  decision the kernel already makes when routing packets. Asking it
//  via a probe socket is more reliable than heuristics over the
//  interface list.
//

import Foundation
import Network

enum LocalAddress {

    /// Returns the local IP we'd use to reach `remoteHost`, as a string,
    /// or nil if we can't figure it out.
    static func preferred(for remoteHost: String) async -> String? {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(remoteHost),
            port: 1400
        )
        // UDP, not TCP — UDP "connect" sets the destination without
        // actually sending anything, so we don't poke the speaker.
        let conn = NWConnection(to: endpoint, using: .udp)
        let state = ResumeFlag()

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            conn.stateUpdateHandler = { connState in
                switch connState {
                case .ready:
                    guard state.tryResume() else { return }
                    let address = Self.extractLocalAddress(from: conn)
                    conn.cancel()
                    cont.resume(returning: address)
                case .failed, .cancelled:
                    guard state.tryResume() else { return }
                    conn.cancel()
                    cont.resume(returning: nil)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func extractLocalAddress(from conn: NWConnection) -> String? {
        guard let endpoint = conn.currentPath?.localEndpoint else { return nil }
        switch endpoint {
        case .hostPort(let host, _):
            return Self.hostToString(host)
        default:
            return nil
        }
    }

    private static func hostToString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let v4):
            // Strip scope ID if present.
            return v4.debugDescription.split(separator: "%").first.map(String.init)
        case .ipv6(let v6):
            // For IPv6 we'd want to wrap in brackets for URL use; for
            // GENA Sonos doesn't speak IPv6 anyway, so this branch is
            // mostly defensive.
            return v6.debugDescription.split(separator: "%").first.map(String.init)
        case .name(let n, _):
            return n
        @unknown default:
            return nil
        }
    }

    /// Thread-safe once-only flag for resuming a continuation from
    /// multiple state-change paths in a callback-based API.
    private final class ResumeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func tryResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }
}
