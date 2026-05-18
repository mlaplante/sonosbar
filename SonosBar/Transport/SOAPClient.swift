//
//  SOAPClient.swift
//  SonosBar
//
//  Low-level SOAP envelope builder and HTTP transport. Knows nothing
//  about Sonos semantics — it just sends an action to a service and
//  returns the response body as parsed XML.
//
//  The SOAP envelope for Sonos is always shaped like:
//
//      <?xml version="1.0" encoding="utf-8"?>
//      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
//                  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
//        <s:Body>
//          <u:ActionName xmlns:u="urn:schemas-upnp-org:service:Foo:1">
//            <Arg1>val1</Arg1>
//            <Arg2>val2</Arg2>
//          </u:ActionName>
//        </s:Body>
//      </s:Envelope>
//
//  Responses come back in the same shape with <u:ActionNameResponse>.
//  Faults arrive with HTTP 500 and a <s:Fault> body that we surface as
//  SonosError.soapFault.
//

import Foundation

actor SOAPClient {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        // Sonos speakers are local; we shouldn't be sitting on a request
        // for more than a couple of seconds. Anything longer means the
        // speaker is offline or the LAN is hosed.
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        // We deliberately don't pool many connections — each speaker is
        // a separate host and Sonos's HTTP server tolerates new sockets
        // fine.
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config)
    }

    /// Sends an action to a service and returns the parsed response root.
    ///
    /// - Parameters:
    ///   - action: e.g. "Play", "SetVolume", "GetZoneGroupState".
    ///   - service: which Sonos service to target.
    ///   - arguments: ordered list of (name, value) pairs. Order matters
    ///     for some actions (the Sonos firmware doesn't always tolerate
    ///     re-ordered children).
    ///   - player: the speaker to send the request to.
    /// - Returns: the parsed response root (`<s:Envelope>`).
    func send(
        action: String,
        service: SOAPService,
        arguments: [(name: String, value: String)] = [],
        to player: DiscoveredPlayer
    ) async throws -> XMLNode {

        let url = player.baseURL.appendingPathComponent(service.controlPath)
        let body = Self.envelope(action: action, service: service, arguments: arguments)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        // SOAPACTION uses double quotes and # as the action separator —
        // this exact format is required, with the quotes.
        request.setValue("\"\(service.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        Log.transport.debug("SOAP → \(player.zoneName) \(service.serviceType)#\(action)")

        // Retry transient transport failures. Sonos speakers occasionally
        // drop the first request (radio sleep, brief LAN hiccup) and
        // recover on the next try a few hundred ms later. Three attempts
        // with short backoff covers virtually every real-world flake
        // without making genuine outages slow to surface.
        let data: Data
        let response: URLResponse
        let backoffsMillis: [UInt64] = [0, 200, 600]
        var lastError: (any Error)?
        var attempt = 0
        var fetched: (Data, URLResponse)?
        for delay in backoffsMillis {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
            attempt += 1
            do {
                fetched = try await session.data(for: request)
                lastError = nil
                break
            } catch {
                // A cancellation is a lifecycle event, not a reachability
                // problem — bail immediately so we don't retry three
                // times and surface a misleading "unreachable: cancelled".
                if (error as? URLError)?.code == .cancelled || error is CancellationError {
                    throw CancellationError()
                }
                lastError = error
                Log.transport.debug("SOAP attempt \(attempt) failed for \(action): \(error.localizedDescription)")
            }
        }
        if let f = fetched {
            (data, response) = f
        } else {
            throw SonosError.unreachable(underlying: lastError?.localizedDescription ?? "unknown")
        }

        guard let http = response as? HTTPURLResponse else {
            throw SonosError.malformedResponse(detail: "non-HTTP response")
        }

        // Sonos returns 200 for success, 500 for SOAP fault. Anything
        // else (404, 403) means we hit the wrong endpoint or the
        // service is disabled on this device.
        switch http.statusCode {
        case 200:
            break
        case 500:
            // Try to extract a SOAP fault from the body. If we can't,
            // surface it as a generic httpError so we don't lose info.
            if let fault = Self.extractFault(from: data) {
                throw fault
            }
            throw SonosError.httpError(status: 500)
        default:
            throw SonosError.httpError(status: http.statusCode)
        }

        do {
            return try XMLNode.parse(data)
        } catch {
            throw SonosError.malformedResponse(detail: "could not parse XML response")
        }
    }

    // MARK: - Envelope building

    private static func envelope(
        action: String,
        service: SOAPService,
        arguments: [(name: String, value: String)]
    ) -> String {
        var args = ""
        for arg in arguments {
            args += "      <\(arg.name)>\(escape(arg.value))</\(arg.name)>\n"
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(service.serviceType)">
        \(args)    </u:\(action)>
          </s:Body>
        </s:Envelope>
        """
    }

    /// XML-escape argument values. Sonos URIs (think Spotify track URIs)
    /// contain & and < that need escaping.
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&apos;"
            default:   out.append(c)
            }
        }
        return out
    }

    // MARK: - Fault extraction

    private static func extractFault(from data: Data) -> SonosError? {
        guard let root = try? XMLNode.parse(data) else { return nil }

        // The fault structure is:
        //   <s:Fault>
        //     <faultcode>s:Client</faultcode>
        //     <faultstring>UPnPError</faultstring>
        //     <detail>
        //       <UPnPError>
        //         <errorCode>701</errorCode>
        //       </UPnPError>
        //     </detail>
        //   </s:Fault>
        guard let upnpError = root.descendants(named: "UPnPError").first,
              let codeStr = upnpError.first("errorCode")?.trimmed,
              let code = Int(codeStr) else {
            return nil
        }

        let desc = Self.upnpErrorDescription(code: code)
        return SonosError.soapFault(code: code, description: desc)
    }

    /// A few well-known Sonos UPnP error codes. Far from exhaustive —
    /// Sonos documents ~100 of them — but covers the ones a controller
    /// hits in practice.
    private static func upnpErrorDescription(code: Int) -> String {
        switch code {
        case 401: return "Invalid Action"
        case 402: return "Invalid Args"
        case 501: return "Action Failed"
        case 600: return "Argument Value Invalid"
        case 701: return "Transition not available (already in target state?)"
        case 702: return "No contents"
        case 705: return "Transport is locked"
        case 706: return "Write error"
        case 711: return "Illegal seek target"
        case 712: return "Play mode not supported"
        case 714: return "Illegal MIME type"
        case 718: return "Channel mismatch"
        case 800: return "Unknown error"
        case 1003: return "Subscription ID required"
        default:  return "UPnP error \(code)"
        }
    }
}
