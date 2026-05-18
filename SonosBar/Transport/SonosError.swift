//
//  SonosError.swift
//  SonosBar
//
//  Unified error surface for everything below the domain layer.
//  Domain code should never see a URLError or XML parse error directly —
//  it sees a SonosError that's already classified into a useful bucket.
//

import Foundation

enum SonosError: Error, CustomStringConvertible, Sendable {

    /// Network reached the device but it didn't respond with valid SOAP.
    case soapFault(code: Int, description: String)

    /// HTTP 4xx/5xx that wasn't a SOAP fault (e.g. 404 — wrong service path).
    case httpError(status: Int)

    /// Couldn't reach the speaker at all (offline, wrong IP, timeout).
    case unreachable(underlying: String)

    /// Response parsed but expected element was missing or malformed.
    case malformedResponse(detail: String)

    /// Caller asked for something nonsensical, e.g. volume > 100.
    case invalidArgument(String)

    /// Used by the cloud transport (future): token expired and refresh failed.
    case unauthorized

    var description: String {
        switch self {
        case .soapFault(let code, let desc):
            return "Sonos returned error \(code): \(desc)"
        case .httpError(let status):
            return "HTTP \(status) from speaker"
        case .unreachable(let why):
            return "Could not reach speaker: \(why)"
        case .malformedResponse(let detail):
            return "Unexpected response: \(detail)"
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .unauthorized:
            return "Not authorised"
        }
    }
}
