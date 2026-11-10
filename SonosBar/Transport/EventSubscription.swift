//
//  EventSubscription.swift
//  SonosBar
//
//  Manages a single GENA subscription's lifecycle:
//    1. SUBSCRIBE to the speaker, get back a SID and a TIMEOUT.
//    2. Hold the SID so incoming NOTIFYs can be routed back.
//    3. Renew before the timeout expires (~half the timeout window).
//    4. UNSUBSCRIBE on shutdown so the speaker stops sending traffic.
//
//  GENA isn't a standard HTTP method, so we hand-roll the SUBSCRIBE
//  request via NWConnection. URLSession refuses non-standard methods.
//

import Foundation
import Network

actor EventSubscription {

    /// The kinds of events we care about. Each Sonos service has its own
    /// event path; we wrap that in a typed enum for clarity at call sites.
    enum Topic: Sendable {
        case avTransport          // playback state, current track, transitions
        case renderingControl     // volume, mute, EQ
        case zoneGroupTopology    // grouping changes

        var service: SOAPService {
            switch self {
            case .avTransport:       return .avTransport
            case .renderingControl:  return .renderingControl
            case .zoneGroupTopology: return .zoneGroupTopology
            }
        }
    }

    let player: DiscoveredPlayer
    let topic: Topic
    let callbackPort: UInt16

    /// Subscription ID assigned by the speaker.
    private(set) var sid: String?

    /// Seconds until the subscription expires. Speakers grant a value
    /// somewhere between 60-1800 depending on firmware version.
    private(set) var timeout: Int = 0

    private var renewTask: Task<Void, Never>?

    /// Called when recovery replaces the SID with a new one (old SID may be
    /// nil if it was already lost). The coordinator routes NOTIFYs by SID, so
    /// without this a self-healed subscription delivers events that are
    /// silently dropped as unknown.
    typealias SIDChangeHandler = @Sendable (_ old: String?, _ new: String) async -> Void
    private let onSIDChange: SIDChangeHandler?

    init(player: DiscoveredPlayer, topic: Topic, callbackPort: UInt16,
         onSIDChange: SIDChangeHandler? = nil) {
        self.player = player
        self.topic = topic
        self.callbackPort = callbackPort
        self.onSIDChange = onSIDChange
    }

    // MARK: - Subscribe / renew / unsubscribe

    /// Initial subscription. Sets up auto-renewal.
    func subscribe(callbackHost: String) async throws {
        let (newSid, newTimeout) = try await sendSubscribe(callbackHost: callbackHost, renewSID: nil)
        self.sid = newSid
        self.timeout = newTimeout
        scheduleRenewal(callbackHost: callbackHost)
        Log.events.info("Subscribed \(self.topic.service.serviceType) on \(self.player.zoneName) sid=\(newSid) ttl=\(newTimeout)s")
    }

    func unsubscribe() async {
        renewTask?.cancel()
        renewTask = nil
        guard let sid else { return }
        do {
            try await sendUnsubscribe(sid: sid)
            Log.events.info("Unsubscribed \(self.topic.service.serviceType) on \(self.player.zoneName)")
        } catch {
            Log.events.error("Unsubscribe failed: \(String(describing: error))")
        }
        self.sid = nil
    }

    private func scheduleRenewal(callbackHost: String) {
        renewTask?.cancel()
        // Renew at roughly half the granted timeout. With a 60s grant
        // that's a renewal every 30s. Safer than waiting until just
        // before expiry — packet loss happens.
        let renewIn = max(self.timeout / 2, 15)
        renewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(renewIn))
            guard let self else { return }
            await self.renew(callbackHost: callbackHost)
        }
    }

    private func renew(callbackHost: String) async {
        guard let existingSID = sid else {
            // SID lost — re-subscribe from scratch.
            await resubscribeWithBackoff(callbackHost: callbackHost, replacing: nil)
            return
        }
        do {
            let (_, newTimeout) = try await sendSubscribe(callbackHost: callbackHost, renewSID: existingSID)
            self.timeout = newTimeout
            scheduleRenewal(callbackHost: callbackHost)
        } catch {
            Log.events.error("Renewal failed for \(self.topic.service.serviceType) on \(self.player.zoneName): \(String(describing: error)). Re-subscribing.")
            self.sid = nil
            await resubscribeWithBackoff(callbackHost: callbackHost, replacing: existingSID)
        }
    }

    /// Fresh SUBSCRIBE, retried with backoff until it succeeds or this
    /// subscription is torn down (unsubscribe() cancels renewTask, which is
    /// the task this runs on). Never gives up on its own: a speaker that was
    /// unplugged for an hour should start updating again when it's back.
    private func resubscribeWithBackoff(callbackHost: String, replacing stale: String?) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let (newSid, newTimeout) = try await sendSubscribe(callbackHost: callbackHost, renewSID: nil)
                guard !Task.isCancelled else {
                    // Torn down while the request was in flight — don't leave
                    // an orphan subscription pointing at us on the speaker.
                    try? await sendUnsubscribe(sid: newSid)
                    return
                }
                self.sid = newSid
                self.timeout = newTimeout
                await onSIDChange?(stale, newSid)
                Log.events.info("Re-subscribed \(self.topic.service.serviceType) on \(self.player.zoneName) sid=\(newSid)")
                scheduleRenewal(callbackHost: callbackHost)
                return
            } catch {
                let delay = ReconnectPolicy.resubscribeDelay(attempt: attempt)
                Log.events.error("Re-subscribe \(self.topic.service.serviceType) on \(self.player.zoneName) failed (attempt \(attempt + 1)); retrying in \(delay)")
                try? await Task.sleep(for: delay)
                attempt += 1
            }
        }
    }

    // MARK: - Raw GENA over NWConnection

    /// Sends SUBSCRIBE (new or renew). Returns (sid, timeoutSeconds).
    private func sendSubscribe(callbackHost: String, renewSID: String?) async throws -> (String, Int) {
        // GENA SUBSCRIBE request — note this is not a standard HTTP method.
        var request = ""
        request += "SUBSCRIBE \(topic.service.eventPath) HTTP/1.1\r\n"
        request += "HOST: \(player.host):\(player.port)\r\n"
        if let renewSID {
            request += "SID: \(renewSID)\r\n"
        } else {
            request += "CALLBACK: <http://\(NetHost.bracketed(callbackHost)):\(callbackPort)/>\r\n"
            request += "NT: upnp:event\r\n"
        }
        // We ask for 30 minutes; the speaker may shorten this.
        request += "TIMEOUT: Second-1800\r\n"
        request += "\r\n"

        let response = try await sendRaw(request)
        return try parseSubscribeResponse(response)
    }

    private func sendUnsubscribe(sid: String) async throws {
        var request = ""
        request += "UNSUBSCRIBE \(topic.service.eventPath) HTTP/1.1\r\n"
        request += "HOST: \(player.host):\(player.port)\r\n"
        request += "SID: \(sid)\r\n"
        request += "\r\n"
        _ = try await sendRaw(request)
    }

    /// Sends a raw HTTP-shaped request over a one-shot TCP connection
    /// and returns the response bytes as a string. Used because
    /// URLSession won't issue SUBSCRIBE/UNSUBSCRIBE methods.
    private func sendRaw(_ request: String) async throws -> String {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(player.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(player.port))
        )
        let conn = NWConnection(to: endpoint, using: .tcp)

        // ResumeFlag wraps the once-only continuation completion in a
        // reference type so the @Sendable closures from NWConnection can
        // safely share access.
        let state = ResumeFlag()

        return try await withCheckedThrowingContinuation { cont in
            @Sendable func resume(_ result: Result<String, any Error>) {
                guard state.tryResume() else { return }
                conn.cancel()
                cont.resume(with: result)
            }

            // NWConnection has no request deadline of its own, and a speaker
            // that accepts the TCP connection but never answers the SUBSCRIBE
            // would otherwise park this continuation forever — stalling the
            // whole sequential subscribeAll() chain in the coordinator.
            // Deliberately no retry here: blindly re-sending SUBSCRIBE can
            // duplicate subscriptions on the speaker; renewal/re-subscribe
            // logic above owns recovery.
            Task {
                try? await Task.sleep(for: .seconds(5))
                resume(.failure(SonosError.unreachable(underlying: "GENA request timed out")))
            }

            conn.stateUpdateHandler = { connState in
                switch connState {
                case .ready:
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { err in
                        if let err {
                            resume(.failure(err))
                            return
                        }
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, err in
                            if let err {
                                resume(.failure(err))
                                return
                            }
                            let str = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            resume(.success(str))
                        }
                    })
                case .failed(let err):
                    resume(.failure(err))
                case .waiting(let err):
                    // .waiting means the connection attempt was refused or has
                    // no route and NWConnection would keep retrying internally.
                    // For a one-shot LAN request, fail fast instead.
                    resume(.failure(err))
                case .cancelled:
                    resume(.failure(SonosError.unreachable(underlying: "connection cancelled")))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private func parseSubscribeResponse(_ response: String) throws -> (String, Int) {
        var sid: String?
        var timeout: Int = 1800

        for line in response.split(separator: "\r\n", omittingEmptySubsequences: true) {
            let lower = line.lowercased()
            if lower.hasPrefix("sid:") {
                sid = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("timeout:") {
                let raw = line.dropFirst("timeout:".count).trimmingCharacters(in: .whitespaces)
                // Format is always "Second-1800".
                if let dashIdx = raw.firstIndex(of: "-") {
                    timeout = Int(raw[raw.index(after: dashIdx)...]) ?? 1800
                }
            }
        }

        guard let sid else {
            throw SonosError.malformedResponse(detail: "SUBSCRIBE response missing SID")
        }
        return (sid, timeout)
    }
}
