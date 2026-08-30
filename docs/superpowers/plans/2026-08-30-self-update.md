# SonosBar Self-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SonosBar verifies, downloads, and installs its own updates from GitHub Releases, prompting the user in the popover instead of sending them to a web page.

**Architecture:** An Ed25519-signed JSON manifest (`appcast.json` + `appcast.json.sig`) published as release assets. The app verifies the signature over raw bytes with CryptoKit, checks the payload zip's SHA-256 against the verified manifest, gates the unpacked bundle on identifier+version, then hands off to a detached shell helper that waits for app exit, swaps the bundle, and relaunches. No Sparkle, no dependencies.

**Tech Stack:** Swift 6 / CryptoKit / AppKit / plain-executable test harness (`Tests/ParserTests/main.swift`) / GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-30-self-update-design.md`

## Global Constraints

- No external dependencies. `Package.swift` stays dependency-free.
- Everything in `SonosBar/Util/` is compiled into the test harness by `scripts/run-parser-tests.sh` with `-enable-upcoming-feature StrictConcurrency -enable-upcoming-feature ExistentialAny` on Command Line Tools-only machines. **New Util files may import Foundation/Observation/CryptoKit/AppKit but never SwiftUI** (macro plugins are unavailable there).
- Bundle identifier: `app.sonosbar.SonosBar`. Platform floor: macOS `26.0`.
- Info.plist keys introduced here: `SBUpdateFeedURL`, `SBUpdatePublicKey` (NOT Sparkle's `SU*` names).
- Feed URL: `https://github.com/mlaplante/sonosbar/releases/latest/download/appcast.json`; signature at the same URL + `.sig`.
- Version comparison is `UpdateChecker.version(_:isNewerThan:)` — already exists, already tested; reuse, never duplicate.
- Tests are `expect(...)`/`expectEqual(...)` calls appended to `Tests/ParserTests/main.swift`; run with `./scripts/run-parser-tests.sh`. There is no XCTest.
- Full build check: `swift build 2>&1 | tail -5` (SwiftUI files aren't covered by the harness).
- The private signing key never appears in the repo, in code, in tests, or in shell history (env var only). Tests generate throwaway keypairs inline.

---

### Task 1: UpdateManifest — strict model + decoder

**Files:**
- Create: `SonosBar/Util/UpdateManifest.swift`
- Test: `Tests/ParserTests/main.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct UpdateManifest: Equatable, Sendable` with `let version: String`, `let build: String`, `let url: URL`, `let sha256: String`, `let bundleIdentifier: String`, `let minimumSystemVersion: String`, `let releaseNotesURL: URL`, `let pubDate: String`
  - `static func decode(_ data: Data) throws -> UpdateManifest`
  - `enum UpdateManifestError: Error, Equatable { case notAnObject; case missingField(String); case unknownField(String); case malformed(String) }`

- [ ] **Step 1: Write the failing tests** — append to `Tests/ParserTests/main.swift` before the `// MARK: - Summary` section:

```swift
// MARK: - UpdateManifest strict decoding

let goodManifestJSON = """
{"version":"0.6.0","build":"10",\
"url":"https://github.com/mlaplante/sonosbar/releases/download/v0.6.0/SonosBar-0.6.0.app.zip",\
"sha256":"75a0522babf73807f054bfdfac1b65993788d813821814d88fc3abb896ea9c93",\
"bundleIdentifier":"app.sonosbar.SonosBar","minimumSystemVersion":"26.0",\
"releaseNotesURL":"https://github.com/mlaplante/sonosbar/releases/tag/v0.6.0",\
"pubDate":"2026-08-30T12:00:00Z"}
"""
do {
    let m = try UpdateManifest.decode(Data(goodManifestJSON.utf8))
    expectEqual(m.version, "0.6.0", "manifest version decodes")
    expectEqual(m.bundleIdentifier, "app.sonosbar.SonosBar", "manifest bundle id decodes")
    expectEqual(m.url.host, "github.com", "manifest url decodes")
} catch {
    expect(false, "good manifest decodes: \(error)")
}

// Missing field fails closed.
let missingSha = goodManifestJSON.replacingOccurrences(
    of: "\"sha256\":\"75a0522babf73807f054bfdfac1b65993788d813821814d88fc3abb896ea9c93\",",
    with: "")
expect((try? UpdateManifest.decode(Data(missingSha.utf8))) == nil, "missing sha256 rejected")

// Unknown field fails closed (defense against manifest-format confusion).
let extraField = goodManifestJSON.replacingOccurrences(
    of: "\"version\":\"0.6.0\"",
    with: "\"version\":\"0.6.0\",\"evil\":\"x\"")
expect((try? UpdateManifest.decode(Data(extraField.utf8))) == nil, "unknown field rejected")

// Wrong type fails closed.
let wrongType = goodManifestJSON.replacingOccurrences(
    of: "\"build\":\"10\"", with: "\"build\":10")
expect((try? UpdateManifest.decode(Data(wrongType.utf8))) == nil, "non-string build rejected")

// Not JSON at all.
expect((try? UpdateManifest.decode(Data("<html>".utf8))) == nil, "non-JSON rejected")

// Invalid URL string.
let badURL = goodManifestJSON.replacingOccurrences(
    of: "https://github.com/mlaplante/sonosbar/releases/download/v0.6.0/SonosBar-0.6.0.app.zip",
    with: " ")
expect((try? UpdateManifest.decode(Data(badURL.utf8))) == nil, "unparseable url rejected")
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/run-parser-tests.sh`
Expected: compile FAILURE — `cannot find 'UpdateManifest' in scope`.

- [ ] **Step 3: Implement** — create `SonosBar/Util/UpdateManifest.swift`:

```swift
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
```

- [ ] **Step 4: Run tests** — `./scripts/run-parser-tests.sh` → all pass, including the pre-existing ones.
- [ ] **Step 5: Full build** — `swift build 2>&1 | tail -3` → succeeds.
- [ ] **Step 6: Commit** — `git add SonosBar/Util/UpdateManifest.swift Tests/ParserTests/main.swift && git commit -m "Add strict update-manifest decoder"`

---

### Task 2: UpdateSignature — Ed25519 verification

**Files:**
- Create: `SonosBar/Util/UpdateSignature.swift`
- Test: `Tests/ParserTests/main.swift` (append; also add `import CryptoKit` under the existing `import Foundation`)

**Interfaces:**
- Consumes: nothing.
- Produces: `enum UpdateSignature` with `static func verify(manifestBytes: Data, signatureBase64: String, publicKeyBase64: String) -> Bool`. Never throws; any malformed input returns `false`.

- [ ] **Step 1: Write the failing tests** — add `import CryptoKit` at the top of `Tests/ParserTests/main.swift`, then append:

```swift
// MARK: - UpdateSignature Ed25519 verification

let sigTestKey = Curve25519.Signing.PrivateKey()
let sigTestPub = sigTestKey.publicKey.rawRepresentation.base64EncodedString()
let manifestBytes = Data(goodManifestJSON.utf8)
let goodSig = (try? sigTestKey.signature(for: manifestBytes))?.base64EncodedString() ?? ""

expect(UpdateSignature.verify(manifestBytes: manifestBytes,
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub),
       "valid signature verifies")
expect(!UpdateSignature.verify(manifestBytes: manifestBytes + Data("x".utf8),
                               signatureBase64: goodSig,
                               publicKeyBase64: sigTestPub),
       "tampered bytes rejected")
let attackerKey = Curve25519.Signing.PrivateKey()
let attackerSig = (try? attackerKey.signature(for: manifestBytes))?.base64EncodedString() ?? ""
expect(!UpdateSignature.verify(manifestBytes: manifestBytes,
                               signatureBase64: attackerSig,
                               publicKeyBase64: sigTestPub),
       "attacker-signed manifest rejected")
expect(!UpdateSignature.verify(manifestBytes: manifestBytes,
                               signatureBase64: "not base64!!!",
                               publicKeyBase64: sigTestPub),
       "garbage signature rejected")
expect(!UpdateSignature.verify(manifestBytes: manifestBytes,
                               signatureBase64: goodSig,
                               publicKeyBase64: "AAAA"),
       "wrong-length public key rejected")
expect(!UpdateSignature.verify(manifestBytes: manifestBytes,
                               signatureBase64: goodSig,
                               publicKeyBase64: ""),
       "empty public key rejected")
```

- [ ] **Step 2: Run to verify failure** — `./scripts/run-parser-tests.sh` → compile FAILURE: `cannot find 'UpdateSignature' in scope`.
- [ ] **Step 3: Implement** — create `SonosBar/Util/UpdateSignature.swift`:

```swift
//
//  UpdateSignature.swift
//  SonosBar
//
//  Ed25519 verification of the release manifest. The app is distributed
//  unsigned (ad-hoc), so this signature is the ENTIRE update-integrity
//  guarantee — the matching private key exists only as a CI secret.
//  Verification runs over the raw downloaded bytes BEFORE any JSON
//  parsing; nothing from an unverified manifest is ever trusted.
//  scripts/sign-update.swift is the producing side of this format.
//

import Foundation
import CryptoKit

enum UpdateSignature {

    /// Returns true only if `signatureBase64` is a valid Ed25519 signature
    /// over `manifestBytes` by the key `publicKeyBase64`. All failures —
    /// bad base64, wrong key length, mismatch — are equal: false.
    static func verify(manifestBytes: Data,
                       signatureBase64: String,
                       publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let sigData = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return publicKey.isValidSignature(sigData, for: manifestBytes)
    }
}
```

- [ ] **Step 4: Run tests** — `./scripts/run-parser-tests.sh` → all pass.
- [ ] **Step 5: Commit** — `git add SonosBar/Util/UpdateSignature.swift Tests/ParserTests/main.swift && git commit -m "Add Ed25519 manifest verification"`

---

### Task 3: UpdateChecker rework — verified-manifest flow with legacy fallback

**Files:**
- Modify: `SonosBar/Util/UpdateChecker.swift`
- Test: `Tests/ParserTests/main.swift` (append)

**Interfaces:**
- Consumes: `UpdateManifest.decode`, `UpdateSignature.verify` (Tasks 1–2).
- Produces (existing API preserved: `updateAvailable`, `latestVersion`, `releaseURL`, `currentVersion`, `start()`, `check()`, `version(_:isNewerThan:)`):
  - `private(set) var verifiedManifest: UpdateManifest?` — non-nil ⇒ the in-app install path is available. `nil` with `updateAvailable == true` ⇒ legacy badge (open browser).
  - `static func evaluate(manifestBytes: Data, signatureBase64: String, publicKeyBase64: String, currentVersion: String) -> UpdateManifest?` — pure; returns the manifest only if the signature verifies, it decodes, AND `version` is newer than `currentVersion`.

- [ ] **Step 1: Write the failing tests** — append to `Tests/ParserTests/main.swift`:

```swift
// MARK: - UpdateChecker.evaluate (signed-manifest gate)

expect(UpdateChecker.evaluate(manifestBytes: manifestBytes,
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.5.1")?.version == "0.6.0",
       "evaluate accepts newer signed manifest")
expect(UpdateChecker.evaluate(manifestBytes: manifestBytes,
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.6.0") == nil,
       "evaluate rejects same version")
expect(UpdateChecker.evaluate(manifestBytes: manifestBytes,
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.7.0") == nil,
       "evaluate rejects older manifest (no downgrade)")
expect(UpdateChecker.evaluate(manifestBytes: manifestBytes,
                              signatureBase64: attackerSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.5.1") == nil,
       "evaluate rejects bad signature even when version is newer")
expect(UpdateChecker.evaluate(manifestBytes: Data("{}".utf8),
                              signatureBase64: goodSig,
                              publicKeyBase64: sigTestPub,
                              currentVersion: "0.5.1") == nil,
       "evaluate rejects signature/content mismatch")
```

- [ ] **Step 2: Run to verify failure** — `./scripts/run-parser-tests.sh` → compile FAILURE: no member `evaluate`.
- [ ] **Step 3: Implement.** In `SonosBar/Util/UpdateChecker.swift`:

(a) Replace the header comment block (lines 1–9) with:

```swift
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
```

(b) Inside the class, after the `releaseURL` property, add:

```swift
    /// Non-nil only when a signed manifest fetched from the feed verified
    /// against SBUpdatePublicKey and advertises a newer version. This is
    /// the gate for the in-app install path; the legacy fields above only
    /// gate the "open the releases page" badge.
    private(set) var verifiedManifest: UpdateManifest?

    /// Embedded verification key (base64, 32 bytes). Empty until release
    /// keys are generated; empty disables the signed path entirely.
    let publicKey =
        Bundle.main.infoDictionary?["SBUpdatePublicKey"] as? String ?? ""

    /// Release feed location. The UserDefaults override exists for the
    /// end-to-end test harness (scripts/test-update-e2e.sh) — a debug
    /// hook, deliberately undocumented in user-facing surfaces.
    var feedURL: URL? {
        if let override = UserDefaults.standard.string(forKey: "debug.updateFeedURL") {
            return URL(string: override)
        }
        return (Bundle.main.infoDictionary?["SBUpdateFeedURL"] as? String)
            .flatMap(URL.init(string:))
    }
```

(c) Rename the existing `check()` to `legacyCheck()` (same body). Add the new `check()`:

```swift
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
            // or equal signed manifest means there IS no update.
            if UpdateSignature.verify(manifestBytes: manifestBytes,
                                      signatureBase64: signature,
                                      publicKeyBase64: publicKey) {
                verifiedManifest = nil
                latestVersion = nil
                return true
            }
            return false
        }
        verifiedManifest = manifest
        latestVersion = manifest.version
        releaseURL = manifest.releaseNotesURL
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
```

- [ ] **Step 4: Run tests** — `./scripts/run-parser-tests.sh` → all pass.
- [ ] **Step 5: Full build** — `swift build 2>&1 | tail -3` → succeeds (UI still compiles; no UI file changed).
- [ ] **Step 6: Commit** — `git add SonosBar/Util/UpdateChecker.swift Tests/ParserTests/main.swift && git commit -m "Rework update checker around the signed feed"`

---

### Task 4: Key generation + manifest signing scripts

**Files:**
- Create: `scripts/generate-update-keys.swift`
- Create: `scripts/sign-update.swift`

**Interfaces:**
- Consumes: the manifest format from Task 1 (opaque bytes — the signer never parses).
- Produces:
  - `swift scripts/generate-update-keys.swift` → prints `PUBLIC:  <base64>` and `PRIVATE: <base64>` lines.
  - `UPDATE_ED_PRIVATE_KEY=<base64> swift scripts/sign-update.swift <manifest-path>` → writes `<manifest-path>.sig` (base64 text) compatible with `UpdateSignature.verify`.

- [ ] **Step 1: Create `scripts/generate-update-keys.swift`:**

```swift
#!/usr/bin/env swift
// generate-update-keys.swift
//
// One-time generation of the SonosBar update-signing keypair. Run at a
// keyboard, never in CI:
//
//   swift scripts/generate-update-keys.swift
//
// Then:
//   * PUBLIC  -> Info.plist, value of SBUpdatePublicKey
//   * PRIVATE -> GitHub repo secret UPDATE_ED_PRIVATE_KEY, plus a durable
//                offline backup. Losing it strands every installed client
//                on manual updates; leaking it hands code execution to
//                whoever holds it. It must never touch the repo.

import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
print("PUBLIC:  \(key.publicKey.rawRepresentation.base64EncodedString())")
print("PRIVATE: \(key.rawRepresentation.base64EncodedString())")
print("")
print("Public key  -> SBUpdatePublicKey in SonosBar/Resources/Info.plist")
print("Private key -> GitHub secret UPDATE_ED_PRIVATE_KEY (and an offline backup)")
```

- [ ] **Step 2: Create `scripts/sign-update.swift`:**

```swift
#!/usr/bin/env swift
// sign-update.swift
//
// CI-side signer for the release manifest. Reads the private key from
// the UPDATE_ED_PRIVATE_KEY environment variable (never argv — argv is
// visible in process listings) and signs the EXACT bytes of the manifest
// file. The verifier (UpdateSignature.swift) checks those same raw
// bytes, so the manifest must not be reformatted after signing.
//
//   UPDATE_ED_PRIVATE_KEY=<base64> swift scripts/sign-update.swift dist/appcast.json
//
// Writes dist/appcast.json.sig (base64 text). Exits non-zero on any problem.

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <manifest-path>\n".utf8))
    exit(64)
}
let manifestPath = CommandLine.arguments[1]
guard let keyBase64 = ProcessInfo.processInfo.environment["UPDATE_ED_PRIVATE_KEY"],
      !keyBase64.isEmpty else {
    FileHandle.standardError.write(Data("UPDATE_ED_PRIVATE_KEY is not set\n".utf8))
    exit(64)
}
guard let keyData = Data(base64Encoded: keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("UPDATE_ED_PRIVATE_KEY is not a valid Ed25519 key\n".utf8))
    exit(65)
}
guard let manifest = FileManager.default.contents(atPath: manifestPath) else {
    FileHandle.standardError.write(Data("cannot read \(manifestPath)\n".utf8))
    exit(66)
}
let signature = try key.signature(for: manifest)
try signature.base64EncodedString().write(toFile: manifestPath + ".sig",
                                          atomically: true, encoding: .utf8)
print("signed \(manifestPath) -> \(manifestPath).sig")
```

- [ ] **Step 3: Round-trip verification** (throwaway keys in a temp dir; none of this persists):

```bash
cd "$(mktemp -d)"
KEYS=$(swift /Users/mlaplante/Sites/sonosbar/scripts/generate-update-keys.swift)
PUB=$(echo "$KEYS" | awk '/^PUBLIC:/{print $2}')
PRIV=$(echo "$KEYS" | awk '/^PRIVATE:/{print $2}')
printf '{"version":"9.9.9"}' > appcast.json
UPDATE_ED_PRIVATE_KEY="$PRIV" swift /Users/mlaplante/Sites/sonosbar/scripts/sign-update.swift appcast.json
cat > verify.swift <<EOF
import CryptoKit, Foundation
let m = FileManager.default.contents(atPath: "appcast.json")!
let s = try String(contentsOfFile: "appcast.json.sig", encoding: .utf8)
let k = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: "$PUB")!)
print(k.isValidSignature(Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines))!, for: m) ? "ROUNDTRIP OK" : "ROUNDTRIP FAILED")
EOF
swift verify.swift
```

Expected: `ROUNDTRIP OK`. Also verify failure modes: running sign-update without the env var exits 64; with `UPDATE_ED_PRIVATE_KEY=garbage` exits 65.

- [ ] **Step 4: Commit** — `git add scripts/generate-update-keys.swift scripts/sign-update.swift && git commit -m "Add update key generation and manifest signing scripts"`

---

### Task 5: UpdateInstaller pure guards — refusal + payload gate

**Files:**
- Create: `SonosBar/Util/UpdateInstaller.swift` (pure parts only; orchestration is Task 6)
- Test: `Tests/ParserTests/main.swift` (append)

**Interfaces:**
- Consumes: `UpdateManifest` (Task 1), `UpdateChecker.version(_:isNewerThan:)` (existing).
- Produces:
  - `enum UpdateRefusal: Equatable, Sendable { case translocated; case notWritable; case osTooOld }` with `var explanation: String`
  - `static func refusalReason(bundlePath: String, parentWritable: Bool, osVersion: String, minimumSystemVersion: String) -> UpdateRefusal?`
  - `enum PayloadRejection: Equatable, Sendable { case unreadablePlist; case identifierMismatch(String); case versionMismatch(String) }`
  - `static func validatePayload(infoPlist: [String: Any]?, manifest: UpdateManifest, expectedBundleID: String) -> PayloadRejection?` (nil = accepted)
  - Task 6 adds to this same type: `final class UpdateInstaller` is declared here as `@MainActor @Observable` with the statics; Task 6 fills in state + orchestration.

- [ ] **Step 1: Write the failing tests** — append to `Tests/ParserTests/main.swift`:

```swift
// MARK: - UpdateInstaller refusal conditions

expectEqual(UpdateInstaller.refusalReason(
        bundlePath: "/private/var/folders/x/AppTranslocation/y/d/SonosBar.app",
        parentWritable: true, osVersion: "27.0", minimumSystemVersion: "26.0"),
    .translocated, "translocated bundle refused")
expectEqual(UpdateInstaller.refusalReason(
        bundlePath: "/Applications/SonosBar.app",
        parentWritable: false, osVersion: "27.0", minimumSystemVersion: "26.0"),
    .notWritable, "unwritable parent refused")
expectEqual(UpdateInstaller.refusalReason(
        bundlePath: "/Applications/SonosBar.app",
        parentWritable: true, osVersion: "26.0", minimumSystemVersion: "27.0"),
    .osTooOld, "manifest demanding newer OS refused")
expect(UpdateInstaller.refusalReason(
        bundlePath: "/Applications/SonosBar.app",
        parentWritable: true, osVersion: "27.0", minimumSystemVersion: "26.0") == nil,
    "normal install location accepted")

// MARK: - UpdateInstaller payload gate

let gateManifest = try! UpdateManifest.decode(Data(goodManifestJSON.utf8))
expectEqual(UpdateInstaller.validatePayload(
        infoPlist: nil, manifest: gateManifest, expectedBundleID: "app.sonosbar.SonosBar"),
    .unreadablePlist, "missing payload plist rejected")
expectEqual(UpdateInstaller.validatePayload(
        infoPlist: ["CFBundleIdentifier": "com.attacker.payload",
                    "CFBundleShortVersionString": "0.6.0"],
        manifest: gateManifest, expectedBundleID: "app.sonosbar.SonosBar"),
    .identifierMismatch("com.attacker.payload"), "foreign bundle id rejected")
expectEqual(UpdateInstaller.validatePayload(
        infoPlist: ["CFBundleIdentifier": "app.sonosbar.SonosBar",
                    "CFBundleShortVersionString": "0.5.0"],
        manifest: gateManifest, expectedBundleID: "app.sonosbar.SonosBar"),
    .versionMismatch("0.5.0"), "payload version != manifest rejected")
expect(UpdateInstaller.validatePayload(
        infoPlist: ["CFBundleIdentifier": "app.sonosbar.SonosBar",
                    "CFBundleShortVersionString": "0.6.0"],
        manifest: gateManifest, expectedBundleID: "app.sonosbar.SonosBar") == nil,
    "matching payload accepted")
```

- [ ] **Step 2: Run to verify failure** — `./scripts/run-parser-tests.sh` → compile FAILURE.
- [ ] **Step 3: Implement** — create `SonosBar/Util/UpdateInstaller.swift`:

```swift
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
```

- [ ] **Step 4: Run tests** — `./scripts/run-parser-tests.sh` → all pass.
- [ ] **Step 5: Commit** — `git add SonosBar/Util/UpdateInstaller.swift Tests/ParserTests/main.swift && git commit -m "Add installer refusal and payload gates"`

---

### Task 6: Helper script + install orchestration

**Files:**
- Modify: `SonosBar/Util/UpdateInstaller.swift` (extend the class from Task 5)
- Create: `scripts/test-update-helper.sh`

**Interfaces:**
- Consumes: everything from Tasks 1, 3, 5.
- Produces:
  - `enum UpdateInstallState: Equatable, Sendable { case idle; case working(String); case refused(UpdateRefusal); case failed(String) }`
  - on `UpdateInstaller`: `private(set) var state: UpdateInstallState`, `func install(manifest: UpdateManifest) async`, `static func helperScript() -> String`, `static var lastUpdateErrorFile: URL`, `func consumeLastUpdateError() -> String?`
  - Helper contract: `sh swap.sh <pid> <src.app> <dst.app> <errfile>`. Timeout waiting for `<pid>` → touch nothing, record error, exit 1. Swap failure → restore original, **relaunch it**, record error, exit 1. Success → relaunch new version, exit 0. Backup path: `<dst-dir>/.SonosBar-update-backup`.

- [ ] **Step 1: Write the failing helper tests** — create `scripts/test-update-helper.sh` (committed; runnable in CI later):

```bash
#!/usr/bin/env bash
# test-update-helper.sh
#
# Exercises the detached swap helper OUTSIDE the app: extracts the script
# text from UpdateInstaller.swift via a tiny Swift shim, then drives its
# failure modes against dummy bundles in a temp dir. These paths run after
# NSApp.terminate in production, where nothing else can observe them —
# which is exactly why they get their own harness.
#
# Usage: ./scripts/test-update-helper.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

# Obtain the exact production helper text.
cat > "$WORK/dump.swift" <<EOF
import Foundation
print(helperScriptForTesting())
EOF
# helperScriptForTesting is a free function in UpdateInstaller.swift kept
# outside the @MainActor class precisely so this dump can call it.
swiftc -o "$WORK/dump" \
    -enable-upcoming-feature StrictConcurrency \
    "$ROOT/SonosBar/Util/UpdateInstaller.swift" \
    "$ROOT/SonosBar/Util/UpdateManifest.swift" \
    "$ROOT/SonosBar/Util/UpdateChecker.swift" \
    "$ROOT/SonosBar/Util/UpdateSignature.swift" \
    "$ROOT/SonosBar/Util/Log.swift" \
    "$WORK/dump.swift"
"$WORK/dump" > "$WORK/swap.sh"

check() { # name condition
    if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi
}

make_bundle() { # path version
    mkdir -p "$1/Contents/MacOS"
    printf '#!/bin/sh\nsleep 300\n' > "$1/Contents/MacOS/Dummy"
    chmod +x "$1/Contents/MacOS/Dummy"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $2" \
        "$1/Contents/Info.plist" >/dev/null
}

# --- Case 1: wait-loop timeout must leave the bundle untouched ---
make_bundle "$WORK/dst1.app" 1.0.0
make_bundle "$WORK/src1.app" 2.0.0
touch "$WORK/dst1.app/Contents/CANARY"
sleep 300 & HOLD=$!   # a pid that will NOT exit
SB_WAIT_TICKS=3 sh "$WORK/swap.sh" "$HOLD" "$WORK/src1.app" "$WORK/dst1.app" "$WORK/err1" || true
kill "$HOLD" 2>/dev/null || true
check "timeout leaves bundle untouched" '[ -f "$WORK/dst1.app/Contents/CANARY" ]'
check "timeout recorded an error"        '[ -s "$WORK/err1" ]'

# A pid guaranteed to be dead: spawn a no-op and reap it. A literal
# like 99999 can collide with a real long-lived process, hanging the
# helper's wait loop for the full cap.
sh -c 'exit 0' & DEADPID=$!
wait "$DEADPID" 2>/dev/null || true

# --- Case 2: swap failure must restore AND relaunch the original ---
make_bundle "$WORK/dst2.app" 1.0.0
touch "$WORK/dst2.app/Contents/CANARY"
SB_OPEN=/usr/bin/true sh "$WORK/swap.sh" "$DEADPID" "$WORK/nonexistent.app" "$WORK/dst2.app" "$WORK/err2" || true
check "failed swap restores original"   '[ -f "$WORK/dst2.app/Contents/CANARY" ]'
check "failed swap recorded an error"   '[ -s "$WORK/err2" ]'
check "failed swap attempted relaunch"  'grep -q "relaunched-original" "$WORK/err2"'
check "no leftover backup"              '[ ! -e "$WORK/.SonosBar-update-backup" ]'

# --- Case 3: happy path swaps and relaunches the new version ---
make_bundle "$WORK/dst3.app" 1.0.0
make_bundle "$WORK/src3.app" 2.0.0
SB_OPEN=/usr/bin/true sh "$WORK/swap.sh" "$DEADPID" "$WORK/src3.app" "$WORK/dst3.app" "$WORK/err3"
V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORK/dst3.app/Contents/Info.plist")
check "happy path installed new version" '[ "$V" = "2.0.0" ]'
check "happy path left no error file"    '[ ! -s "$WORK/err3" ]'
check "happy path left no backup"        '[ ! -e "$WORK/.SonosBar-update-backup" ]'

echo; echo "$((9 - FAILURES))/9 helper checks passed"  # 9 = total check calls
exit $((FAILURES == 0 ? 0 : 1))
```

Then `chmod +x scripts/test-update-helper.sh`.

- [ ] **Step 2: Run to verify failure** — `./scripts/test-update-helper.sh` → FAILS: `helperScriptForTesting` undefined.
- [ ] **Step 3: Implement.** Append to `SonosBar/Util/UpdateInstaller.swift` (inside the class, after `validatePayload`):

```swift
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
```

- [ ] **Step 4: Run helper tests** — `./scripts/test-update-helper.sh` → 9/9 pass.
- [ ] **Step 5: Run harness + build** — `./scripts/run-parser-tests.sh` and `swift build 2>&1 | tail -3` → both pass.
- [ ] **Step 6: Commit** — `git add SonosBar/Util/UpdateInstaller.swift scripts/test-update-helper.sh && git commit -m "Add install orchestration and tested swap helper"`

---

### Task 7: Info.plist keys + popover UI + wiring

**Files:**
- Modify: `SonosBar/Resources/Info.plist`
- Create: `SonosBar/UI/UpdateCard.swift`
- Modify: `SonosBar/UI/MenuBarRootView.swift` (badge block at ~line 183; card at top of the VStack)
- Modify: `SonosBar/App/SonosBarApp.swift` (AppDelegate + environment)

**Interfaces:**
- Consumes: `UpdateChecker.verifiedManifest` (Task 3), `UpdateInstaller.install(manifest:)`, `.state`, `.consumeLastUpdateError()` (Task 6).
- Produces: `UpdateCard` SwiftUI view; `AppDelegate.installer: UpdateInstaller`.

- [ ] **Step 1: Info.plist.** Add before the closing `</dict>`:

```xml
    <!-- Self-update feed. The public key verifies appcast.json.sig; it is
         EMPTY until release keys are generated (scripts/
         generate-update-keys.swift), which disables the in-app update
         path entirely — the checker falls back to the legacy GitHub API
         badge. NOT Sparkle's SU* keys: SonosBar rolls its own updater
         (docs/superpowers/specs/2026-08-30-self-update-design.md). -->
    <key>SBUpdateFeedURL</key>
    <string>https://github.com/mlaplante/sonosbar/releases/latest/download/appcast.json</string>

    <key>SBUpdatePublicKey</key>
    <string></string>
```

- [ ] **Step 2: Create `SonosBar/UI/UpdateCard.swift`:**

```swift
//
//  UpdateCard.swift
//  SonosBar
//
//  The in-popover update surface. Lives INSIDE the popover on purpose:
//  SonosBar is LSUIElement, and detached windows in agent apps are a
//  known source of unreachable-window bugs. Shown only when there is
//  something to say — a verified update, progress, or a failure.
//

import SwiftUI

struct UpdateCard: View {

    @Environment(UpdateChecker.self) private var updates
    @Environment(UpdateInstaller.self) private var installer

    var body: some View {
        if let manifest = updates.verifiedManifest {
            card(manifest)
        }
    }

    @ViewBuilder
    private func card(_ manifest: UpdateManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch installer.state {
            case .idle:
                HStack {
                    Text("SonosBar \(manifest.version) is available")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Link("Notes", destination: manifest.releaseNotesURL)
                        .font(.caption2)
                    Button("Install") {
                        Task { await installer.install(manifest: manifest) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            case .working(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.caption)
                }
            case .refused(let refusal):
                // Refusal is soft: explain, and offer the manual path.
                Text(refusal.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Link("Download from GitHub", destination: manifest.releaseNotesURL)
                    .font(.caption2)
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                Link("Download from GitHub", destination: manifest.releaseNotesURL)
                    .font(.caption2)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 3: MenuBarRootView.** (a) Insert `UpdateCard()` immediately after `tabBar` in the body `VStack`. (b) Replace the footer badge block:

```swift
                if updates.updateAvailable, let url = updates.releaseURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
```

with a version that only opens the browser when there is NO verified manifest (the card owns the in-app path — this is the legacy-fallback badge from the spec's migration section):

```swift
                if updates.updateAvailable, updates.verifiedManifest == nil,
                   let url = updates.releaseURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
```

- [ ] **Step 4: SonosBarApp wiring.** In `AppDelegate`, after `let updates = UpdateChecker()` add `let installer = UpdateInstaller()`. In the `MenuBarExtra` content, after `.environment(appDelegate.updates)` add `.environment(appDelegate.installer)`. In `applicationDidFinishLaunching`, after `updates.start()` add:

```swift
        if let failure = installer.consumeLastUpdateError() {
            Log.app.error("Previous update did not complete: \(failure)")
        }
```

(Surfacing in the popover UI can ride the `failed` state later; launch-log visibility is the required floor — the file must be consumed so it doesn't go stale.)

- [ ] **Step 5: Build + behavior check** — `swift build 2>&1 | tail -3` succeeds; `./scripts/run-parser-tests.sh` still passes. With an empty `SBUpdatePublicKey`, `verifiedManifest` stays nil, so users see exactly today's badge — safe to ship.
- [ ] **Step 6: Commit** — `git add SonosBar/Resources/Info.plist SonosBar/UI/UpdateCard.swift SonosBar/UI/MenuBarRootView.swift SonosBar/App/SonosBarApp.swift && git commit -m "Add in-popover update card behind the signed feed"`

---

### Task 8: Settings — auto-check toggle + manual check + login-item re-register

**Files:**
- Modify: `SonosBar/Persistence/SettingsStore.swift`
- Modify: `SonosBar/UI/SettingsView.swift`
- Modify: `SonosBar/Util/UpdateChecker.swift` (honor the toggle)
- Modify: `SonosBar/App/SonosBarApp.swift` (re-register mitigation)

**Interfaces:**
- Consumes: `SettingsStore` patterns (didSet → UserDefaults; init reads with default), `LaunchAtLogin.isEnabled` / `LaunchAtLogin.set(enabled:)`.
- Produces: `SettingsStore.autoCheckForUpdates: Bool` (default **true**, matching current always-on behavior).

- [ ] **Step 1: SettingsStore.** After the `rememberLastZone` property add:

```swift
    /// Check the release feed for updates once a day. On by default —
    /// matches the always-on behavior that predates this toggle.
    var autoCheckForUpdates: Bool {
        didSet {
            Self.defaults.set(autoCheckForUpdates, forKey: Key.autoCheckForUpdates)
        }
    }
```

In `init()` after the `rememberLastZone` line:

```swift
        self.autoCheckForUpdates = (Self.defaults.object(forKey: Key.autoCheckForUpdates) as? Bool) ?? true
```

In `enum Key`: `static let autoCheckForUpdates = "settings.autoCheckForUpdates"`.

- [ ] **Step 2: UpdateChecker honors the toggle.** Change `start()`'s poll loop body from `await self?.check()` to:

```swift
                // Respect the settings toggle per-iteration, not at start():
                // flipping it must take effect without a relaunch.
                if UserDefaults.standard.object(forKey: "settings.autoCheckForUpdates") as? Bool ?? true {
                    await self?.check()
                }
```

(UserDefaults directly rather than injecting SettingsStore: the checker is compiled into the CLT-only test harness, and the key literal matches `SettingsStore.Key`.)

- [ ] **Step 3: SettingsView.** Inject checker/installer: add `@Environment(UpdateChecker.self) private var updates` under the coordinator line, and in `SonosBarApp.swift`'s `Settings` scene add `.environment(appDelegate.updates)`. Then insert after the "General" section:

```swift
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settings.autoCheckForUpdates)
                    .toggleStyle(.switch)
                HStack {
                    Button("Check for Updates…") {
                        Task { await updates.check() }
                    }
                    if let latest = updates.latestVersion, updates.updateAvailable {
                        Text("\(latest) available — open the SonosBar menu to install")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("SonosBar \(updates.currentVersion) is current")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
```

Also fix the stale hardcoded `Text("SonosBar 0.1.0")` in the About section → `Text("SonosBar \(updates.currentVersion)")`.

- [ ] **Step 4: Login-item re-register.** Ad-hoc signatures differ per build (different cdhash), so `SMAppService` registration may be invalidated by a bundle swap — "launch at login" would silently turn off after an update (spec: residual risks). In `applicationDidFinishLaunching`, after the `consumeLastUpdateError` block:

```swift
        // An update swaps the bundle; ad-hoc signatures differ per build,
        // which can invalidate the SMAppService login-item registration.
        // If the user wants launch-at-login but the system lost it,
        // re-register quietly.
        if coordinator.settings.launchAtLogin && !LaunchAtLogin.isEnabled {
            LaunchAtLogin.set(enabled: true)
        }
```

(Verify the exact property/method names against `SonosBar/Persistence/LaunchAtLogin.swift` before writing — `isEnabled` is a static computed property checking `SMAppService.mainApp.status == .enabled`.)

- [ ] **Step 5: Build + tests** — `swift build 2>&1 | tail -3` and `./scripts/run-parser-tests.sh` → pass.
- [ ] **Step 6: Commit** — `git add SonosBar/Persistence/SettingsStore.swift SonosBar/UI/SettingsView.swift SonosBar/Util/UpdateChecker.swift SonosBar/App/SonosBarApp.swift && git commit -m "Add update settings and post-swap login-item repair"`

---

### Task 9: CI — stamp versions, sign manifest, publish assets

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `scripts/sign-update.swift` (Task 4), secret `UPDATE_ED_PRIVATE_KEY` (exists only after the human key step — see Task 11).
- Produces: release assets `SonosBar-X.Y.Z.dmg`, `SonosBar-X.Y.Z.app.zip`, `appcast.json`, `appcast.json.sig`.

- [ ] **Step 1: Stamp versions.** Insert a step after "Resolve version" and before the build:

```yaml
      - name: Stamp version into Info.plist
        run: |
          /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${{ steps.ver.outputs.version }}" SonosBar/Resources/Info.plist
          /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${{ steps.ver.outputs.version }}" SonosBar/Resources/Info.plist
```

(Both keys from the tag, per the spec — `CFBundleVersion` was hand-pinned at `9` and would otherwise drift forever.)

- [ ] **Step 2: Run the helper tests in CI.** After the "Run parser tests" step:

```yaml
      - name: Run update-helper tests
        run: ./scripts/test-update-helper.sh
```

- [ ] **Step 3: Build the signed manifest.** After the "Zip .app as fallback artifact" step:

```yaml
      - name: Build signed update manifest
        if: github.event_name == 'push'
        env:
          UPDATE_ED_PRIVATE_KEY: ${{ secrets.UPDATE_ED_PRIVATE_KEY }}
        run: |
          V="${{ steps.ver.outputs.version }}"
          SHA=$(shasum -a 256 "build/SonosBar-$V.app.zip" | awk '{print $1}')
          # Written as one exact byte stream; sign-update.swift signs these
          # raw bytes and UpdateSignature.swift verifies the same bytes, so
          # this file must never be reformatted after this point.
          printf '{"version":"%s","build":"%s","url":"https://github.com/mlaplante/sonosbar/releases/download/v%s/SonosBar-%s.app.zip","sha256":"%s","bundleIdentifier":"app.sonosbar.SonosBar","minimumSystemVersion":"26.0","releaseNotesURL":"https://github.com/mlaplante/sonosbar/releases/tag/v%s","pubDate":"%s"}' \
            "$V" "$V" "$V" "$V" "$SHA" "$V" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > dist/appcast.json
          if [ -n "$UPDATE_ED_PRIVATE_KEY" ]; then
            swift scripts/sign-update.swift dist/appcast.json
          else
            echo "::warning::UPDATE_ED_PRIVATE_KEY not set — release will ship without a signed manifest (in-app updates disabled for this release)"
          fi
```

- [ ] **Step 4: Attach the new assets.** In the "Create GitHub Release" step's `files:` list, append:

```yaml
            dist/appcast.json
            dist/appcast.json.sig
```

And note the zip is no longer a "fallback artifact" — update the step name `Zip .app as fallback artifact` → `Zip .app (update payload)`.

- [ ] **Step 5: Validate workflow syntax** — `actionlint .github/workflows/release.yml` if available, else `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))" && echo YAML-OK`.
- [ ] **Step 6: Commit** — `git add .github/workflows/release.yml && git commit -m "Publish signed update manifest with releases"`

---

### Task 10: End-to-end validation against a local feed

**Files:**
- Create: `scripts/test-update-e2e.sh`

**Interfaces:**
- Consumes: everything. Uses the `debug.updateFeedURL` UserDefaults override (Task 3) plus a `debug.updateAutoInstall` flag to be added here.

- [ ] **Step 1: Add the auto-install debug hook.** In `UpdateCard.swift`, add inside `card(_:)`'s `.idle` case handling — an `.onAppear` on the card's outer VStack:

```swift
        .onAppear {
            // E2E harness hook (scripts/test-update-e2e.sh): install
            // without a click. Debug-only; never set by the app.
            if UserDefaults.standard.bool(forKey: "debug.updateAutoInstall"),
               case .idle = installer.state {
                Task { await installer.install(manifest: manifest) }
            }
        }
```

- [ ] **Step 2: Create `scripts/test-update-e2e.sh`:**

```bash
#!/usr/bin/env bash
# test-update-e2e.sh
#
# Full-cycle proof: builds the CURRENT tree twice (as versions 98.0.0 and
# 99.0.0), signs a manifest with throwaway keys, serves it over localhost,
# installs 98.0.0 into a temp dir, launches it with debug feed+auto-install
# overrides, and verifies it replaces itself with 99.0.0 and relaunches.
#
# Run manually before any release that touches the updater. NOT in CI:
# it launches a real GUI app (SSDP discovery, hotkey registration).
# QUIRK: uses the app's real bundle id defaults domain; restores the
# debug keys afterwards.
#
# Usage: ./scripts/test-update-e2e.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
PORT=8788
cleanup() {
    pkill -f "$WORK/install/SonosBar.app" 2>/dev/null || true
    pkill -f "http.server $PORT" 2>/dev/null || true
    defaults delete app.sonosbar.SonosBar debug.updateFeedURL 2>/dev/null || true
    defaults delete app.sonosbar.SonosBar debug.updateAutoInstall 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Throwaway signing keys"
KEYS=$(swift "$ROOT/scripts/generate-update-keys.swift")
PUB=$(echo "$KEYS" | awk '/^PUBLIC:/{print $2}')
PRIV=$(echo "$KEYS" | awk '/^PRIVATE:/{print $2}')

build_version() { # version outdir
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" "$ROOT/SonosBar/Resources/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :SBUpdatePublicKey $PUB" "$ROOT/SonosBar/Resources/Info.plist"
    (cd "$ROOT" && ./scripts/build-app.sh release >/dev/null)
    mkdir -p "$2"
    ditto "$ROOT/build/SonosBar.app" "$2/SonosBar.app"
}

echo "==> Building v98 and v99 from the current tree"
ORIG_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/SonosBar/Resources/Info.plist")
build_version 98.0.0 "$WORK/old"
build_version 99.0.0 "$WORK/new"
# Restore the tree's plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ORIG_VER" "$ROOT/SonosBar/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SBUpdatePublicKey " "$ROOT/SonosBar/Resources/Info.plist"

echo "==> Signed manifest for v99"
mkdir -p "$WORK/serve"
(cd "$WORK/new" && ditto -c -k --keepParent SonosBar.app "$WORK/serve/SonosBar-99.0.0.app.zip")
SHA=$(shasum -a 256 "$WORK/serve/SonosBar-99.0.0.app.zip" | awk '{print $1}')
printf '{"version":"99.0.0","build":"99.0.0","url":"http://127.0.0.1:%s/SonosBar-99.0.0.app.zip","sha256":"%s","bundleIdentifier":"app.sonosbar.SonosBar","minimumSystemVersion":"26.0","releaseNotesURL":"http://127.0.0.1:%s/notes","pubDate":"2026-01-01T00:00:00Z"}' \
    "$PORT" "$SHA" "$PORT" > "$WORK/serve/appcast.json"
UPDATE_ED_PRIVATE_KEY="$PRIV" swift "$ROOT/scripts/sign-update.swift" "$WORK/serve/appcast.json"

echo "==> Serving feed on :$PORT; installing v98"
(cd "$WORK/serve" && nohup python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &)
mkdir -p "$WORK/install"
ditto "$WORK/old/SonosBar.app" "$WORK/install/SonosBar.app"
defaults write app.sonosbar.SonosBar debug.updateFeedURL "http://127.0.0.1:$PORT/appcast.json"
defaults write app.sonosbar.SonosBar debug.updateAutoInstall -bool true

echo "==> Launching v98 (it should replace itself with v99)"
open "$WORK/install/SonosBar.app"
for i in $(seq 1 60); do
    V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$WORK/install/SonosBar.app/Contents/Info.plist" 2>/dev/null || echo "?")
    [ "$V" = "99.0.0" ] && break
    sleep 1
done

V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORK/install/SonosBar.app/Contents/Info.plist")
RUNNING=$(pgrep -f "$WORK/install/SonosBar.app" | head -1 || true)
echo "installed version: $V; running pid: ${RUNNING:-none}"
if [ "$V" = "99.0.0" ] && [ -n "$RUNNING" ]; then
    echo "E2E: PASS — app replaced itself and relaunched"
else
    echo "E2E: FAIL"; exit 1
fi
```

Then `chmod +x scripts/test-update-e2e.sh`.

**CAUTION for the executor:** this launches a second real SonosBar instance while the user's copy runs from /Applications. The debug UserDefaults keys and the auto-install flag are cleaned up by the trap; the update card only auto-installs when a verified feed override is present, so the user's `/Applications` copy (empty `SBUpdatePublicKey` at this point — its `verifiedManifest` is always nil) is unaffected. The temp copy triggers the update-card `.onAppear` only when the popover opens — **if the card requires opening the popover, `open` alone won't trigger it.** Move the auto-install hook from `UpdateCard.onAppear` into `UpdateChecker.check()`'s success path if the E2E times out (that is: in `checkSignedFeed`, after `verifiedManifest = manifest`, add the same `debug.updateAutoInstall` check calling the installer via a weak reference wired in AppDelegate). Do NOT ship without the E2E passing.

- [ ] **Step 3: Run it** — `./scripts/test-update-e2e.sh` → `E2E: PASS`. If the popover-gating issue bites (see caution), apply the fallback wiring and re-run.
- [ ] **Step 4: Verify the user's real app is untouched** — `defaults read app.sonosbar.SonosBar debug.updateFeedURL` errors (key gone); `/Applications/SonosBar.app` version unchanged; original SonosBar process still running.
- [ ] **Step 5: Commit** — `git add scripts/test-update-e2e.sh SonosBar/UI/UpdateCard.swift && git commit -m "Add end-to-end self-update test against a local feed"`

---

### Task 11: Human key ceremony + README (BLOCKED on user — do not execute)

**Files:**
- Modify: `README.md` (release-process section)
- Modify: `SonosBar/Resources/Info.plist` (real public key)

The user must run, at a keyboard:

```bash
swift scripts/generate-update-keys.swift
# PUBLIC  -> paste into SBUpdatePublicKey in SonosBar/Resources/Info.plist
# PRIVATE -> GitHub repo secret UPDATE_ED_PRIVATE_KEY:
#   gh secret set UPDATE_ED_PRIVATE_KEY --repo mlaplante/sonosbar
# ...and store an offline backup (password manager / printed copy).
```

Until then: releases ship with the `::warning::` from Task 9 and no manifest signature; installed apps keep using the legacy badge. Nothing breaks — the signed path simply stays dormant. After the key lands: commit the Info.plist public key, tag the first self-updating release, and verify `appcast.json` + `.sig` appear as release assets and that the checker on that build shows the card for the *next* release.

---

## Verification checklist (after all tasks)

- [ ] `./scripts/run-parser-tests.sh` — all pass
- [ ] `./scripts/test-update-helper.sh` — 9/9
- [ ] `./scripts/test-update-e2e.sh` — PASS, user's app untouched
- [ ] `swift build -c release 2>&1 | tail -3` — clean
- [ ] No private-key material committed: `git grep -l 'PRIVATE:' -- ':!scripts/generate-update-keys.swift' ':!docs'` returns nothing, and `SBUpdatePublicKey` in Info.plist is still empty until Task 11
