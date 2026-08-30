//
//  EventServer.swift
//  SonosBar
//
//  Tiny HTTP server that listens for UPnP GENA NOTIFY callbacks from
//  Sonos speakers. We can't use URLSession for this — GENA events are
//  unsolicited HTTP POSTs from the speaker TO us, so we need an actual
//  listening socket.
//
//  This is exactly where reaching for a third-party Swift HTTP server
//  (Vapor, Swifter) would be overkill. We're parsing one HTTP method
//  (NOTIFY), responding with one status (200 OK), and routing on the
//  SID header. NWListener + NWConnection do it in ~150 lines.
//
//  Lifecycle:
//    start() → bind a port, return it. Handler fires per NOTIFY.
//    stop()  → tear everything down (called on app quit).
//

import Foundation
import Network

actor EventServer {

    struct Event: Sendable {
        let sid: String   // Subscription ID — matches a SUBSCRIBE response.
        let seq: Int      // Sequence number, monotonically increasing per SID.
        let body: Data    // Raw XML; parsing is the subscriber's job.
        /// Host the NOTIFY arrived from, `%scope`-stripped. nil if the
        /// endpoint couldn't be read. The coordinator uses this to reject
        /// a spoofed NOTIFY whose SID it recognises but whose source IP
        /// isn't the speaker that SID belongs to.
        var remoteHost: String? = nil
    }

    /// Upper bound on simultaneously-held connections. A GENA burst on a
    /// topology change plus two subs per speaker across a large household
    /// is well under this; the cap only exists to stop a LAN host from
    /// opening sockets without bound and holding buffered request data.
    private static let maxConnections = 64

    /// A connection that hasn't produced a parseable request within this
    /// window is dropped — defends against a peer that opens a socket and
    /// dribbles bytes (or nothing) to pin a ~1MB buffer indefinitely.
    private static let connectionIdleTimeout: Duration = .seconds(10)

    private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private var handler: (@Sendable (Event) async -> Void)?
    private var connections: Set<ConnectionWrapper> = []

    /// Wraps NWConnection in a Hashable shell so we can hold them in a Set.
    private final class ConnectionWrapper: Hashable, @unchecked Sendable {
        let conn: NWConnection
        init(_ c: NWConnection) { self.conn = c }
        static func == (l: ConnectionWrapper, r: ConnectionWrapper) -> Bool { l === r }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    /// Bind a port and start listening. Returns the assigned port.
    func start(handler: @escaping @Sendable (Event) async -> Void) async throws -> UInt16 {
        self.handler = handler

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        self.listener = listener

        let state = ResumeFlag()
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    guard state.tryResume() else { return }
                    if let p = listener.port?.rawValue {
                        cont.resume(returning: p)
                    } else {
                        cont.resume(throwing: SonosError.unreachable(underlying: "no port assigned"))
                    }
                case .failed(let err):
                    guard state.tryResume() else { return }
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                Task { await self.accept(conn) }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        self.port = port
        Log.events.info("Event server listening on port \(port)")
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in connections { c.conn.cancel() }
        connections.removeAll()
        Log.events.info("Event server stopped")
    }

    private func accept(_ conn: NWConnection) {
        guard connections.count < Self.maxConnections else {
            Log.events.error("Event connection cap (\(Self.maxConnections)) reached; refusing new connection")
            conn.cancel()
            return
        }
        let wrapper = ConnectionWrapper(conn)
        connections.insert(wrapper)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.drop(wrapper) }
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        readRequest(on: conn, remoteHost: Self.remoteHost(of: conn), accumulated: Data())

        // Idle-timeout watchdog: if this connection is still open (never
        // produced a parseable request, so drop() was never called) after
        // the window, tear it down. A completed request cancels the
        // connection, which removes the wrapper first, making this a no-op.
        Task { [weak self] in
            try? await Task.sleep(for: Self.connectionIdleTimeout)
            await self?.dropIfPresent(wrapper)
        }
    }

    private func dropIfPresent(_ wrapper: ConnectionWrapper) {
        guard connections.contains(wrapper) else { return }
        Log.events.debug("Event connection idle-timed out; dropping")
        drop(wrapper)
    }

    private func drop(_ wrapper: ConnectionWrapper) {
        connections.remove(wrapper)
        wrapper.conn.cancel()
    }

    /// Hard cap on one request's total size. Real NOTIFY bodies top out in
    /// the tens of KB (ZoneGroupState is the biggest); anything larger —
    /// a malformed Content-Length, or any LAN host feeding us garbage,
    /// since nothing authenticates the sender — must not grow the buffer
    /// forever.
    private static let maxRequestBytes = 1 << 20

    /// Recursively read until we have a parseable request, then dispatch.
    /// `nonisolated` because the NWConnection callback runs off-actor.
    /// `buffer` is passed by value on each recursion to avoid capturing
    /// mutable state across the @Sendable closure boundary.
    private nonisolated func readRequest(on conn: NWConnection, remoteHost: String?, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }

            var buffer = accumulated
            if let data, !data.isEmpty { buffer.append(data) }

            if buffer.count > Self.maxRequestBytes {
                Log.events.error("Event request exceeded \(Self.maxRequestBytes) bytes; dropping connection")
                conn.cancel()
                return
            }

            if let error {
                Log.events.error("Event recv error: \(error.localizedDescription)")
                conn.cancel()
                return
            }

            if var event = Self.parseRequest(buffer) {
                event.remoteHost = remoteHost
                // Respond 200 OK immediately — UPnP spec wants a fast ack.
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                conn.send(content: response, completion: .contentProcessed { _ in
                    conn.cancel()
                })

                let finalEvent = event
                Task { await self.dispatch(finalEvent) }
                return
            }

            if isComplete {
                conn.cancel()
                return
            }

            self.readRequest(on: conn, remoteHost: remoteHost, accumulated: buffer)
        }
    }

    private func dispatch(_ event: Event) async {
        if let handler {
            await handler(event)
        }
    }

    /// Parse a complete HTTP request from accumulated bytes, or return nil
    /// if more data is needed.
    private static func parseRequest(_ data: Data) -> Event? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<sep.lowerBound]
        let body = data[sep.upperBound...]

        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        var sid: String?
        var seq: Int = 0
        var contentLength: Int?

        for line in headerString.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("sid:") {
                sid = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("seq:") {
                seq = Int(line.dropFirst(4).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }

        if let len = contentLength, body.count < len { return nil }
        guard let sid else { return nil }

        return Event(sid: sid, seq: seq, body: slicedBody(body, contentLength: contentLength))
    }

    /// Best-effort remote host of an accepted connection, `%scope`-stripped.
    /// Used to bind a NOTIFY to the speaker its SID belongs to.
    private static func remoteHost(of conn: NWConnection) -> String? {
        switch conn.endpoint {
        case .hostPort(let host, _):
            return normalizedHost(host)
        default:
            return nil
        }
    }

    private static func normalizedHost(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let v4):
            return v4.debugDescription.split(separator: "%").first.map(String.init)
        case .ipv6(let v6):
            return v6.debugDescription.split(separator: "%").first.map(String.init)
        case .name(let n, _):
            return n
        @unknown default:
            return nil
        }
    }

    /// Normalizes a plain host string the same way `remoteHost` does, so the
    /// coordinator can compare a NOTIFY's source against a stored speaker
    /// host (which arrives from several parse paths). Strips a `%scope`
    /// suffix and surrounding IPv6 brackets.
    static func canonicalHost(_ host: String) -> String {
        var h = host.split(separator: "%").first.map(String.init) ?? host
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return h
    }

    /// Trims the body to the declared Content-Length. A sender that declares
    /// a short length and then keeps writing (up to the 1MB cap) must not
    /// hand the excess to the XML parser — only the advertised bytes are the
    /// request. With no Content-Length, the accumulated body is the request.
    /// Pure and internal so the parser harness can assert it.
    static func slicedBody(_ body: some DataProtocol, contentLength: Int?) -> Data {
        guard let len = contentLength, len >= 0, len < body.count else { return Data(body) }
        return Data(body.prefix(len))
    }
}
