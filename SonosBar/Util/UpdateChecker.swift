//
//  UpdateChecker.swift
//  SonosBar
//
//  Finds out whether a newer release exists. Primary path: fetch the
//  Ed25519-signed manifest (appcast.json + .sig) from the release feed,
//  verify it against SBUpdatePublicKey, and expose `verifiedManifest`
//  for the in-app installer. Fallback path (no key configured, or any
//  fetch/verify failure): the legacy GitHub API check, which can only
//  offer "open the releases page". Checks once at launch and every 24h;
//  failures are silent — an update hint is a nicety, never worth an
//  error surface.
//

import Foundation
import Observation

@MainActor
@Observable
final class UpdateChecker {

    private(set) var latestVersion: String?
    private(set) var releaseURL: URL?

    /// Non-nil only when a signed manifest fetched from the feed verified
    /// against SBUpdatePublicKey and advertises a newer version. This is
    /// the gate for the in-app install path; the legacy fields above only
    /// gate the "open the releases page" badge.
    private(set) var verifiedManifest: UpdateManifest?

    /// E2E harness seam (scripts/test-update-e2e.sh): lets checkSignedFeed
    /// trigger an install without the popover ever opening. Weak, and
    /// wired by AppDelegate — UpdateChecker does not own an installer in
    /// production; this exists solely so a headless run of the debug
    /// auto-install flag has somewhere to call.
    weak var installer: UpdateInstaller?

    /// Embedded verification key (base64, 32 bytes). Empty until release
    /// keys are generated; empty disables the signed path entirely.
    let publicKey =
        Bundle.main.infoDictionary?["SBUpdatePublicKey"] as? String ?? ""

    /// Release feed location. The UserDefaults override exists for the
    /// end-to-end test harness (scripts/test-update-e2e.sh) — a debug
    /// hook, deliberately undocumented in user-facing surfaces.
    var feedURL: URL? {
        #if DEBUG
        // E2E harness seam only (compiled out of release builds): redirect
        // the feed to a localhost server. A release build ignores this key
        // so a co-installed process can't repoint the update feed by writing
        // the app's UserDefaults domain.
        if let override = UserDefaults.standard.string(forKey: "debug.updateFeedURL") {
            return URL(string: override)
        }
        #endif
        return (Bundle.main.infoDictionary?["SBUpdateFeedURL"] as? String)
            .flatMap(URL.init(string:))
    }

    let currentVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return Self.version(latestVersion, isNewerThan: currentVersion)
    }

    private var pollTask: Task<Void, Never>?

    func start() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Respect the settings toggle per-iteration, not at start():
                // flipping it must take effect without a relaunch.
                if UserDefaults.standard.object(forKey: "settings.autoCheckForUpdates") as? Bool ?? true {
                    await self?.check()
                }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func check() async {
        if !publicKey.isEmpty, let feedURL, await checkSignedFeed(feedURL) {
            return
        }
        verifiedManifest = nil
        await legacyCheck()
    }

    /// Returns true only if a manifest was fetched AND verified AND is
    /// newer — the caller falls back to the legacy path otherwise. The
    /// distinction matters: "feed unreachable" must not hide an update
    /// the legacy path could still surface.
    private func checkSignedFeed(_ feed: URL) async -> Bool {
        guard let sigURL = URL(string: feed.absoluteString + ".sig") else { return false }
        var manifestRequest = URLRequest(url: feed, timeoutInterval: 10)
        manifestRequest.cachePolicy = .reloadIgnoringLocalCacheData
        var sigRequest = URLRequest(url: sigURL, timeoutInterval: 10)
        sigRequest.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (manifestBytes, mResponse) = try? await URLSession.shared.data(for: manifestRequest),
              (mResponse as? HTTPURLResponse)?.statusCode == 200,
              let (sigBytes, sResponse) = try? await URLSession.shared.data(for: sigRequest),
              (sResponse as? HTTPURLResponse)?.statusCode == 200,
              let signature = String(data: sigBytes, encoding: .utf8)
        else { return false }

        guard let manifest = Self.evaluate(manifestBytes: manifestBytes,
                                           signatureBase64: signature,
                                           publicKeyBase64: publicKey,
                                           currentVersion: currentVersion)
        else {
            // Verified-and-current is also a successful outcome: an older
            // or equal signed manifest means there IS no update. But a
            // signed manifest that fails strict decoding is a failure —
            // fall back to the legacy path rather than silently going dark.
            if UpdateSignature.verify(manifestBytes: manifestBytes,
                                      signatureBase64: signature,
                                      publicKeyBase64: publicKey),
               let current = try? UpdateManifest.decode(manifestBytes),
               !Self.version(current.version, isNewerThan: currentVersion) {
                verifiedManifest = nil
                latestVersion = nil
                return true
            }
            return false
        }
        verifiedManifest = manifest
        latestVersion = manifest.version
        releaseURL = manifest.releaseNotesURL

        #if DEBUG
        // E2E harness seam only (compiled out of release builds): install
        // without a click. The popover-gated UpdateCard hook can't fire
        // headless. Gated so a release build can never be driven into an
        // unattended self-install by a written UserDefaults key.
        if UserDefaults.standard.bool(forKey: "debug.updateAutoInstall") {
            let installer = self.installer
            Task { @MainActor in await installer?.install(manifest: manifest) }
        }
        #endif
        return true
    }

    /// Pure decision core, separated for the test harness: signature over
    /// raw bytes first, strict decode second, version gate third.
    static func evaluate(manifestBytes: Data,
                         signatureBase64: String,
                         publicKeyBase64: String,
                         currentVersion: String) -> UpdateManifest? {
        guard UpdateSignature.verify(manifestBytes: manifestBytes,
                                     signatureBase64: signatureBase64,
                                     publicKeyBase64: publicKeyBase64),
              let manifest = try? UpdateManifest.decode(manifestBytes),
              version(manifest.version, isNewerThan: currentVersion)
        else { return nil }
        return manifest
    }

    func legacyCheck() async {
        guard let url = URL(string: "https://api.github.com/repos/mlaplante/sonosbar/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }

        latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // Don't hand an unvalidated URL from the API response to
        // NSWorkspace.open (which accepts file: and custom schemes).
        // Allowlist https + github.com; fall back to the canonical page.
        releaseURL = Self.sanitizedReleaseURL(json["html_url"] as? String)
            ?? URL(string: "https://github.com/mlaplante/sonosbar/releases/latest")
    }

    /// Accepts only an https URL on github.com; nil for anything else
    /// (file:, other schemes/hosts, unparseable). Pure, harness-tested.
    static func sanitizedReleaseURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }

    /// Numeric dotted-component comparison; missing components count as 0.
    static func version(_ a: String, isNewerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
