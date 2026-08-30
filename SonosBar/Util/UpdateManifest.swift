//
//  UpdateManifest.swift
//  SonosBar
//
//  The signed release manifest (appcast.json). Decoding is deliberately
//  strict — unknown fields, missing fields, and wrong types all throw —
//  because this document is the root of trust for the self-updater:
//  anything we didn't explicitly expect is treated as hostile, not
//  tolerated. JSONSerialization rather than Codable because Codable
//  cannot reject unknown keys.
//

import Foundation

enum UpdateManifestError: Error, Equatable {
    case notAnObject
    case missingField(String)
    case unknownField(String)
    case malformed(String)
}

struct UpdateManifest: Equatable, Sendable {
    let version: String
    let build: String
    let url: URL
    let sha256: String
    let bundleIdentifier: String
    let minimumSystemVersion: String
    let releaseNotesURL: URL
    let pubDate: String

    private static let knownKeys: Set<String> = [
        "version", "build", "url", "sha256", "bundleIdentifier",
        "minimumSystemVersion", "releaseNotesURL", "pubDate",
    ]

    static func decode(_ data: Data) throws -> UpdateManifest {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw UpdateManifestError.notAnObject
        }
        if let stranger = dict.keys.first(where: { !knownKeys.contains($0) }) {
            throw UpdateManifestError.unknownField(stranger)
        }
        func string(_ key: String) throws -> String {
            guard let value = dict[key] as? String else {
                throw dict[key] == nil
                    ? UpdateManifestError.missingField(key)
                    : UpdateManifestError.malformed(key)
            }
            return value
        }
        func webURL(_ key: String) throws -> URL {
            let raw = try string(key)
            guard let url = URL(string: raw), url.scheme == "https" || url.scheme == "http",
                  url.host != nil else {
                throw UpdateManifestError.malformed(key)
            }
            return url
        }
        return UpdateManifest(
            version: try string("version"),
            build: try string("build"),
            url: try webURL("url"),
            sha256: try string("sha256"),
            bundleIdentifier: try string("bundleIdentifier"),
            minimumSystemVersion: try string("minimumSystemVersion"),
            releaseNotesURL: try webURL("releaseNotesURL"),
            pubDate: try string("pubDate")
        )
    }
}
