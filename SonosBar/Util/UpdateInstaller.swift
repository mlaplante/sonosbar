//
//  UpdateInstaller.swift
//  SonosBar
//
//  Downloads, verifies, and installs an update described by a verified
//  UpdateManifest. The dangerous parts are factored as pure static
//  functions so the test harness can exercise them; the orchestration
//  (download -> unpack -> gate -> swap -> relaunch) lives on the
//  @Observable instance the popover binds to.
//
//  The point of no return is NSApp.terminate: past it the app cannot
//  report anything, so everything after is owned by a detached shell
//  helper that waits for exit, swaps, relaunches — and on ANY failure
//  brings the original app back and records why (see helperScript).
//

import Foundation
import Observation
import AppKit
import CryptoKit

/// Why the in-app install path is declining. Refusal is a normal outcome
/// (the badge falls back to opening the releases page), not an error.
enum UpdateRefusal: Equatable, Sendable {
    case translocated
    case notWritable
    case osTooOld

    var explanation: String {
        switch self {
        case .translocated:
            "SonosBar is running from a read-only location (probably the DMG). Drag it to Applications first."
        case .notWritable:
            "SonosBar can't replace itself here — the folder isn't writable."
        case .osTooOld:
            "This update needs a newer version of macOS."
        }
    }
}

/// Why an unpacked payload was rejected before being allowed to replace us.
enum PayloadRejection: Equatable, Sendable {
    case unreadablePlist
    case identifierMismatch(String)
    case versionMismatch(String)
}

@MainActor
@Observable
final class UpdateInstaller {

    // MARK: - Pure guards (compiled into the test harness)

    /// Checks whether self-replacement is safe from this location.
    /// All inputs are passed in (not read from the environment) so the
    /// harness can probe every branch.
    static func refusalReason(bundlePath: String,
                              parentWritable: Bool,
                              osVersion: String,
                              minimumSystemVersion: String) -> UpdateRefusal? {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if !parentWritable { return .notWritable }
        if UpdateChecker.version(minimumSystemVersion, isNewerThan: osVersion) { return .osTooOld }
        return nil
    }

    /// Gates the unpacked bundle before it may replace the running app.
    /// The zip's hash already matched the signed manifest at this point;
    /// this is the second, independent check on what was inside it.
    static func validatePayload(infoPlist: [String: Any]?,
                                manifest: UpdateManifest,
                                expectedBundleID: String) -> PayloadRejection? {
        guard let infoPlist,
              let id = infoPlist["CFBundleIdentifier"] as? String,
              let version = infoPlist["CFBundleShortVersionString"] as? String
        else { return .unreadablePlist }
        if id != expectedBundleID { return .identifierMismatch(id) }
        if version != manifest.version { return .versionMismatch(version) }
        return nil
    }
}
