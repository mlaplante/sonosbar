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
    }

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
        readRequest(on: conn, accumulated: Data())
    }

    private func drop(_ wrapper: ConnectionWrapper) {
        connections.remove(wrapper)
        wrapper.conn.cancel()
    }

    /// Recursively read until we have a parseable request, then dispatch.
    /// `nonisolated` because the NWConnection callback runs off-actor.
    /// `buffer` is passed by value on each recursion to avoid capturing
    /// mutable state across the @Sendable closure boundary.
    private nonisolated func readRequest(on conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }

            var buffer = accumulated
            if let data, !data.isEmpty { buffer.append(data) }

            if let error {
                Log.events.error("Event recv error: \(error.localizedDescription)")
                conn.cancel()
                return
            }

            if let event = Self.parseRequest(buffer) {
                // Respond 200 OK immediately — UPnP spec wants a fast ack.
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                conn.send(content: response, completion: .contentProcessed { _ in
                    conn.cancel()
                })

                Task { await self.dispatch(event) }
                return
            }

            if isComplete {
                conn.cancel()
                return
            }

            self.readRequest(on: conn, accumulated: buffer)
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

        return Event(sid: sid, seq: seq, body: Data(body))
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
