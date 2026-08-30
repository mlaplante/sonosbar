# SonosBar self-update — design

**Date:** 2026-08-30
**Status:** approved for implementation (spike validated)
**Supersedes:** the browser-opening badge in `Util/UpdateChecker.swift`

## Goal

When a new version is released, SonosBar updates itself. The user is prompted,
clicks Install, and the app replaces itself and relaunches. No visit to GitHub,
no drag-to-Applications, no re-doing the Gatekeeper right-click dance.

## Non-goals

- Delta updates. The app is a few MB; a full zip is fine.
- Privileged installs. If the bundle's directory is not user-writable we refuse
  and fall back to opening the release page. We never prompt for an admin password.
- Downgrades or channel switching (beta/stable). One channel, forward only.
- Replacing the DMG. It remains the first-install path for new users.

## Decision: no Sparkle

Sparkle is the default choice for macOS and was the initial recommendation. We are
not using it. Sparkle ships to SPM as a binary XCFramework, which must be embedded
in `Contents/Frameworks` and signed inside-out. `build-app.sh` hand-assembles the
bundle from `swift build` output, so all of that framework-embedding machinery
would be ours to write and maintain anyway.

The reason to accept that cost would be Sparkle's signature verification. It turns
out we get an identical guarantee for free: **CryptoKit implements Ed25519**
(`Curve25519.Signing`), the same primitive Sparkle uses, in the macOS SDK. Verified
empirically during the spike — a valid signature passes; a tampered manifest and an
attacker-signed manifest both fail.

So we get Sparkle's integrity model with zero dependencies and no build-system
work. This also matches the standing policy in `Package.swift`: *"We deliberately
stay vanilla… Adding deps later will be a deliberate, justified call."*

**What we give up:** delta updates (don't care), privileged install (deliberate
non-goal), and a decade of battle-testing on the swap-and-relaunch path. That last
one is the real cost, which is why it was spiked before this document was written.

## Trust model

The app is distributed **unsigned** (ad-hoc), by choice — there is no Developer ID.
Code-signing therefore contributes nothing to update integrity, so the entire
guarantee rests on the Ed25519 chain:

1. A private key exists only as a GitHub Actions secret. The matching **public**
   key is compiled into `Info.plist` as `SBUpdatePublicKey`.
2. CI signs the exact bytes of `appcast.json`, producing `appcast.json.sig`.
3. The app downloads both, and verifies the signature **over the raw downloaded
   bytes before parsing any JSON**. Nothing from an unverified manifest is trusted.
4. The verified manifest contains the zip's SHA-256. The app verifies the
   downloaded zip against that hash.

Tampering with the version, the download URL, or the binary all fail closed.
An attacker who compromises the GitHub release but not the signing key cannot ship
code. An attacker who obtains the signing key can — key custody is the whole game.

Note this is strictly *stronger* than today's behavior, where the badge sends users
to a web page to download an unsigned binary by hand.

## Release artifacts

Each release publishes four files:

| Asset | Purpose |
|---|---|
| `SonosBar-X.Y.Z.dmg` | First install for new users (unchanged) |
| `SonosBar-X.Y.Z.app.zip` | **Update payload** (was previously a fallback artifact) |
| `appcast.json` + `appcast.json.sig` | Signed manifest |

Feed URL, stable across releases and requiring no commit back to the repo:

```
https://github.com/mlaplante/sonosbar/releases/latest/download/appcast.json
```

### Manifest format

```json
{
  "version": "0.6.0",
  "build": "10",
  "url": "https://github.com/mlaplante/sonosbar/releases/download/v0.6.0/SonosBar-0.6.0.app.zip",
  "sha256": "75a0522b…",
  "bundleIdentifier": "app.sonosbar.SonosBar",
  "minimumSystemVersion": "26.0",
  "releaseNotesURL": "https://github.com/mlaplante/sonosbar/releases/tag/v0.6.0",
  "pubDate": "2026-08-30T12:00:00Z"
}
```

`version` (`CFBundleShortVersionString`) is what we compare on — it tracks the git
tag. `build` is carried for display and future use.

> **Trap:** `CFBundleVersion` is currently hand-pinned at `9` and nothing in
> `release.yml` stamps it. Left alone, it would drift permanently out of sync with
> the tag. CI will stamp **both** version keys from the tag.

## Components

| File | Role |
|---|---|
| `Util/UpdateManifest.swift` | Model + strict decoder. Rejects unknown/missing fields. |
| `Util/UpdateSignature.swift` | CryptoKit Ed25519 verification over raw bytes. |
| `Util/UpdateChecker.swift` | *(rework)* Fetch + verify manifest; expose `updateAvailable`, `latestVersion`. Keeps its current shape so the footer badge survives. |
| `Util/UpdateInstaller.swift` | Download, verify, unpack, gate, swap, relaunch. |
| `UI/MenuBarRootView.swift` | Badge triggers the in-app flow instead of `NSWorkspace.open`. |
| `UI/SettingsView.swift` | "Check for Updates…" + automatic-check toggle. |
| `scripts/generate-update-keys.swift` | One-time keypair generation (run by a human). |
| `scripts/sign-update.swift` | CI-side manifest signing. Same CryptoKit code as the verifier. |
| `.github/workflows/release.yml` | Stamp versions, sign, publish the release files. |

Signer and verifier share one crypto implementation, so they cannot drift apart.

## Update flow

```
check    fetch appcast.json + .sig
         verify Ed25519 over raw bytes ────────── fail ─▶ abort, stay silent
         parse; compare version ───────────── not newer ─▶ done
prompt   show "Version X is available" in the popover
download fetch zip; verify SHA-256 ───────────── fail ─▶ abort, report in UI
unpack   ditto -x -k into a temp dir
gate     CFBundleIdentifier == app.sonosbar.SonosBar
         CFBundleShortVersionString == manifest.version ── fail ─▶ abort, report
swap     write helper script; launch detached; capped graceful shutdown, then exit(0)
         helper waits for exit → stage payload in a dot-prefixed sibling → two renames → relaunch
```

`ditto -x -k`, never `unzip` — `unzip` mangles bundle symlinks and resource forks.

## Refusal conditions

The updater declines and falls back to opening the release page when:

- The bundle path contains `AppTranslocation` — the user is running from the DMG or
  a quarantined location, so the bundle is on a read-only mount.
- The bundle's parent directory is not writable.
- `minimumSystemVersion` in the manifest exceeds the running OS.

Refusal is a normal outcome, not an error. The user still gets the badge and a
working manual path.

## Failure handling

**The point of no return is `exit(0)`, after a capped graceful shutdown.**
`NSApp.terminate` cannot be called from the installer: `install()` runs as a
MainActor task, and `.terminateLater`'s nested event loop would block that same
actor waiting for a reply that only other MainActor work can send — a self-deadlock
confirmed by an end-to-end hang and process sample, fixed by running a capped
graceful-shutdown closure and calling `exit(0)` directly instead. After `exit(0)`
the app cannot report anything — the UI is gone. Every failure past that point must
be handled by the helper script, which is why the helper, not the app, owns
recovery:

- **Wait-loop timeout (30s):** the app is evidently still alive. Do **not** touch
  the bundle. Exit without changing anything; the running app is unharmed.
- **Swap fails:** the swap is staged, not in-place. The payload is `ditto`'d into a
  sibling `.SonosBar-update-staging` directory first, and only once that copy is
  complete does the helper (1) rename the old bundle aside to
  `.SonosBar-update-backup`, then (2) rename staging onto the live path. A failure
  before step 1 — missing payload, or the staging copy itself failing — leaves the
  bundle untouched, same as the timeout case above. A failure at step 2, the only
  rename that can strand the app off-disk, restores the backup, then **`open`s it**
  so the user gets their app back, then exits non-zero. Two same-volume renames in
  place of the old mv-aside-then-ditto-in-place sequence shrink the crash window —
  the stretch where nothing exists at the live path — from however long `ditto`
  takes to copy the whole app down to the duration of a single rename: milliseconds,
  not seconds.
- **Any failure:** write a reason to
  `~/Library/Application Support/SonosBar/last-update-error.txt`. On next launch the
  app reads it, surfaces "the last update didn't complete" in the popover, and
  deletes it.

The spike's original helper restored the bundle but never relaunched, which would
have left the user with a vanished menu bar icon and no error anywhere. That is the
single most important correction this document makes.

The 30s cap is sized against the app's real quit latency on the update path: the
capped graceful-shutdown closure run via `prepareForTermination` is itself raced
against a detached `Task.sleep` that forces `exit(0)` at **5s** regardless, so 30s
is a wide margin.

Backups go to `/Applications/.SonosBar-update-backup` and staged copies to
`/Applications/.SonosBar-update-staging` — both dot-prefixed so a leftover from a
mid-flight crash is not indexed by LaunchServices or Spotlight as a second visible
app, and both on the same volume as the live bundle so every rename stays atomic.

## UI

The update prompt and progress live **inside the popover**, not in a separate
window. SonosBar is `LSUIElement`; detached windows in agent apps are a known
source of unreachable-window bugs. A card at the top of the popover shows the new
version, release notes link, an Install button, and download progress.

Settings gains "Check for Updates…" and an automatic-check toggle (default on,
once every 24h, matching current behavior).

## CI changes

1. Stamp `CFBundleShortVersionString` **and `CFBundleVersion`** into `Info.plist`
   from the tag, before building.
2. Build, package DMG and zip (already happens).
3. Compute the zip's SHA-256, write `appcast.json`.
4. `swift scripts/sign-update.swift` using `UPDATE_ED_PRIVATE_KEY` → `appcast.json.sig`.
5. Attach all four files to the release.

## Key management — one manual step

Run once, at a keyboard:

```
swift scripts/generate-update-keys.swift
```

It prints a public key (paste into `Info.plist` as `SBUpdatePublicKey`) and a private
key (paste into a GitHub Actions secret named `UPDATE_ED_PRIVATE_KEY`).

**The private key is the entire security boundary.** It must never be committed.
Losing it means future releases cannot be signed and every installed client stops
accepting updates until users manually install a build carrying a new public key.
Back it up somewhere durable.

This is the only step that cannot be automated; everything else in Phases 1 and 2
is buildable and testable without it, because the tests generate their own keypair.

## Migration

Users on 0.5.1 and earlier have no updater and must install one build by hand. To
pull them across, the current "open the releases page" badge behavior is retained
as the fallback whenever the in-app path refuses or fails. It is removed no earlier
than one release after the first self-updating build ships.

## Testing

Extends the existing `Tests/ParserTests` harness (`scripts/run-parser-tests.sh`).

| Area | Cases |
|---|---|
| Signature | valid; tampered manifest; attacker-signed; truncated sig; wrong key length |
| Manifest | well-formed; missing field; wrong types; unknown field; bad version string |
| Version compare | newer, older, equal, unequal component counts, non-numeric |
| Payload gate | id mismatch; version mismatch; no `.app` in archive; unreadable Info.plist |
| Hash | match; mismatch; truncated download |

Tests generate their own keypair inline, so they need no secret. The swap-and-
relaunch path is validated by the spike (below) rather than by unit tests, since it
requires a real bundle and a real process lifecycle.

## Spike evidence (2026-08-30)

A throwaway `SpikeBar.app` — `LSUIElement`, ad-hoc signed, hand-assembled exactly
as `build-app.sh` does — was installed to `/Applications` and updated 1.0.0 → 2.0.0
over HTTP. Results:

- Happy path completed in ~1s. The detached helper survived the parent's
  termination. `codesign --verify --deep --strict` passed on the swapped ad-hoc
  bundle. The relaunched build re-checked the feed and correctly reported
  "already current".
- Hash mismatch: refused before unpacking; app untouched.
- Attacker payload with a *correct* hash but `com.attacker.payload` as its
  identifier: refused by the gate; app untouched.
- Slow-quitting parent: helper blocked 5.3s, then swapped. No race.
- Forced swap failure: original restored, canary intact, no leftover backups.

Environment facts confirmed: `/Applications` is user-writable (no privileged path
needed) and the app is not translocated when installed normally.

## Phases

**Phase 1 — manifest + verification.** Model, decoder, Ed25519 verify, reworked
checker, key/sign scripts, full test suite. The badge still opens GitHub, so user
behavior is unchanged and this phase is safe to ship alone. Needs no keys.

**Phase 2 — installer.** Download, verify, unpack, gate, swap, relaunch, rollback,
error surfacing, popover UI. Ends with a real end-to-end test against a locally
served manifest.

**Phase 3 — CI.** Version stamping, manifest generation, signing, asset upload.
Requires the GitHub secret, so it is gated on the key-generation step.

## Residual risks

- **Login-item registration may not survive a swap.** Ad-hoc signatures differ per
  build (different cdhash), so `SMAppService.mainApp` registration could be
  invalidated and "launch at login" could silently switch off after an update.
  Mitigation: on launch, if the user's stored preference is on but
  `SMAppService.mainApp.status != .enabled`, re-register. Must be verified in Phase 2.
- **Only tested over localhost HTTP.** The real flow is HTTPS from GitHub Releases.
  `URLSession` does not set `com.apple.quarantine`, so the swapped bundle should
  launch without a Gatekeeper prompt — confirm against a real release in Phase 2.
- **Translocated state was guarded for but never exercised.** The refusal path
  should be tested by running from a mounted DMG.
- **Key custody.** A single secret protects every installed client. There is no
  revocation mechanism short of shipping a new public key by hand.
