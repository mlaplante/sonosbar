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

    // MARK: - State the popover binds to

    private(set) var state: UpdateInstallState = .idle

    /// Where the helper records post-terminate failures for the next
    /// launch to surface. The app cannot see these happen live — its UI
    /// is gone by then.
    static var lastUpdateErrorFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SonosBar/last-update-error.txt")
    }

    /// Reads and deletes the helper's failure note, if any. Called once
    /// at launch; returning non-nil means "the last update didn't
    /// complete" should be shown in the popover.
    func consumeLastUpdateError() -> String? {
        let file = Self.lastUpdateErrorFile
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              !text.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: file)
        return text
    }

    // MARK: - Orchestration

    /// Runs the whole install: download, hash-check, unpack, gate, then
    /// hand off to the detached helper and terminate. Every step before
    /// the handoff can fail safely into `state`; nothing on disk is
    /// touched until the helper takes over.
    func install(manifest: UpdateManifest) async {
        let bundleURL = Bundle.main.bundleURL
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        if let refusal = Self.refusalReason(
            bundlePath: bundleURL.path,
            parentWritable: FileManager.default.isWritableFile(
                atPath: bundleURL.deletingLastPathComponent().path),
            osVersion: "\(osv.majorVersion).\(osv.minorVersion)",
            minimumSystemVersion: manifest.minimumSystemVersion) {
            state = .refused(refusal)
            return
        }
        do {
            state = .working("Downloading \(manifest.version)…")
            var request = URLRequest(url: manifest.url, timeoutInterval: 300)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (zip, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateInstallFailure.download
            }

            state = .working("Verifying…")
            let digest = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.sha256.lowercased() else {
                throw UpdateInstallFailure.hashMismatch
            }

            state = .working("Preparing…")
            let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sonosbar-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipFile = workDir.appendingPathComponent("update.zip")
            try zip.write(to: zipFile)

            // ditto, never unzip: unzip mangles bundle symlinks and
            // resource forks.
            let unpackDir = workDir.appendingPathComponent("unpacked")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zipFile.path, unpackDir.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw UpdateInstallFailure.unpack }

            guard let appName = try FileManager.default
                .contentsOfDirectory(atPath: unpackDir.path)
                .first(where: { $0.hasSuffix(".app") }) else {
                throw UpdateInstallFailure.noAppInArchive
            }
            let newApp = unpackDir.appendingPathComponent(appName)
            let plist = NSDictionary(
                contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
                as? [String: Any]
            if let rejection = Self.validatePayload(
                infoPlist: plist, manifest: manifest,
                expectedBundleID: Bundle.main.bundleIdentifier ?? "app.sonosbar.SonosBar") {
                throw UpdateInstallFailure.payloadRejected(rejection)
            }

            // Handoff. The helper is detached (reparented to launchd) so
            // it survives our termination.
            let errorDir = Self.lastUpdateErrorFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: errorDir, withIntermediateDirectories: true)
            let script = workDir.appendingPathComponent("swap.sh")
            try helperScriptForTesting().write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = [script.path, "\(getpid())", newApp.path,
                                bundleURL.path, Self.lastUpdateErrorFile.path]
            try helper.run()

            state = .working("Restarting…")
            Log.app.info("Update handoff: helper pid \(helper.processIdentifier), terminating for swap")
            NSApp.terminate(nil)
        } catch let failure as UpdateInstallFailure {
            state = .failed(failure.explanation)
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }
}

/// The popover's view of install progress. `refused` is a soft outcome —
/// the UI falls back to the "open releases page" badge.
enum UpdateInstallState: Equatable, Sendable {
    case idle
    case working(String)
    case refused(UpdateRefusal)
    case failed(String)
}

enum UpdateInstallFailure: Error {
    case download
    case hashMismatch
    case unpack
    case noAppInArchive
    case payloadRejected(PayloadRejection)

    var explanation: String {
        switch self {
        case .download: "The download failed. Try again later."
        case .hashMismatch: "The download didn't match the signed release. Update aborted."
        case .unpack: "The update archive couldn't be unpacked."
        case .noAppInArchive: "The update archive didn't contain an app."
        case .payloadRejected: "The downloaded app didn't match the signed release. Update aborted."
        }
    }
}

/// The detached swap helper. A free function (not a class member) so
/// scripts/test-update-helper.sh can compile this file and dump the exact
/// production text without instantiating main-actor machinery.
///
/// Contract: sh swap.sh <pid> <src.app> <dst.app> <errfile>
///   * SB_WAIT_TICKS overrides the exit-wait cap (default 300 x 0.1s = 30s;
///     the app's .terminateLater watchdog replies within 5s, so 30s is a
///     wide margin). On timeout the app is evidently still alive: touch
///     NOTHING, record why, bail.
///   * SB_OPEN overrides /usr/bin/open (tests substitute /usr/bin/true).
///   * Backup goes to <dst-dir>/.SonosBar-update-backup — dot-prefixed so
///     a leftover from a crash is never indexed as a second visible app;
///     same volume, so the rename is atomic.
///   * Any failure after the old app exited MUST bring the original back
///     AND relaunch it: past NSApp.terminate nobody else can, and the
///     alternative is a menu bar icon that silently never returns.
func helperScriptForTesting() -> String {
    """
    #!/bin/sh
    PID="$1"; SRC="$2"; DST="$3"; ERR="$4"
    OPEN="${SB_OPEN:-/usr/bin/open}"
    CAP="${SB_WAIT_TICKS:-300}"
    BACKUP="$(dirname "$DST")/.SonosBar-update-backup"
    fail() { printf '%s\\n' "$1" >> "$ERR"; exit 1; }
    n=0
    while kill -0 "$PID" 2>/dev/null; do
        n=$((n+1))
        [ "$n" -gt "$CAP" ] && fail "timeout: app (pid $PID) never exited; bundle untouched"
        sleep 0.1
    done
    rm -rf "$BACKUP"
    mv "$DST" "$BACKUP" || fail "could not move old bundle aside"
    if ditto "$SRC" "$DST"; then
        rm -rf "$BACKUP"
    else
        rm -rf "$DST"
        mv "$BACKUP" "$DST" || fail "restore failed: SonosBar may need reinstalling from GitHub"
        "$OPEN" "$DST"
        fail "swap failed; relaunched-original"
    fi
    xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
    "$OPEN" "$DST" || fail "swap succeeded but relaunch failed; open SonosBar from Applications"
    exit 0
    """
}
