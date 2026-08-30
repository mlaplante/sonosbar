# Security Hardening + UI Polish + Group Volume + EQ — Implementation Plan

> **For agentic workers:** implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Land all security-audit findings, the actionable UI-polish items, true group volume, and EQ (bass/treble/loudness) in SonosBar.

**Architecture:** Keep the transport-protocol boundary intact. New SOAP surface (GroupRenderingControl, RenderingControl EQ) is added to `SOAPService`, `SonosTransport`, `SOAPTransport`; coordinator state + UI follow. Security guards are written as pure statics tested by `Tests/ParserTests/main.swift`.

**Tech Stack:** Swift 6, SPM executable, SwiftUI (macOS 26), Network.framework, CryptoKit.

**Spec:** Derived from the two review reports in the originating session (security audit + UI/feature analysis).

## Global Constraints

- macOS 26+, Swift 6, strict concurrency on. No new external dependencies.
- **Build/verify environment has NO Xcode** (CLT only). `swift build` fails on `actool`. Verification paths:
  - `./scripts/run-parser-tests.sh` (compiles Transport/Util/Discovery + harness). Baseline: `80 passed, 0 failed`.
  - `swiftc -typecheck` over Transport/ Util/ Discovery/ Domain/ Persistence/ (0 errors baseline).
  - `UI/*.swift` and `App/*.swift` **cannot be compiled locally** (SwiftUI macro plugin absent). Write carefully; flag for an Xcode build.
- SOAP action/arg names below are **verified against a live device (10.0.6.63) SCPD** — do not alter them.
- Every SOAP argument value must pass through `SOAPClient.escape` (already automatic in `envelope`, except hand-built DIDL — see Task 3).

---

## Verified SOAP surface (from live SCPD)

- `GroupRenderingControl:1`: ctrl `/MediaRenderer/GroupRenderingControl/Control`, evt `/MediaRenderer/GroupRenderingControl/Event`.
  - `SetGroupVolume`(InstanceID, DesiredVolume 0..100); `GetGroupVolume`→CurrentVolume; `SetGroupMute`(InstanceID, DesiredMute); `GetGroupMute`→CurrentMute.
- `RenderingControl:1` EQ: `GetBass`→CurrentBass / `SetBass`(InstanceID, DesiredBass); `GetTreble`→CurrentTreble / `SetTreble`(InstanceID, DesiredTreble); Bass/Treble i2 **-10..10**. `GetLoudness`(InstanceID, Channel)→CurrentLoudness / `SetLoudness`(InstanceID, Channel, DesiredLoudness) boolean.

---

## COMMIT A — Security guards with harness tests (Transport/Util/Discovery)

### Task A1: EventServer connection cap + idle timeout + body slice
**Files:** Modify `SonosBar/Transport/EventServer.swift`; Test `Tests/ParserTests/main.swift`.
- Add `static let maxConnections = 64`; in `accept`, if `connections.count >= maxConnections` cancel + return before insert.
- Arm a per-connection idle deadline: after `accept`, schedule a Task that sleeps 10s and drops the wrapper if still present (connection that never completes a request).
- In `parseRequest`, when `contentLength` present, slice `body.prefix(len)` into the Event. Extract the header-field parsing into a pure `static func parseHeaders(_ headerString:) -> (sid:String?, seq:Int, contentLength:Int?)` OR keep parseRequest but add a pure `static func slicedBody(_ body: Data, contentLength: Int?) -> Data` and assert it in the harness.
- Test: assert `slicedBody(10-byte over-read, 4) == first 4 bytes`; `slicedBody(x, nil) == x`.

### Task A2: XMLNode explicit entity flag
**Files:** Modify `SonosBar/Util/XMLNode.swift`.
- In `parse(_ data:)`, set `parser.shouldResolveExternalEntities = false` and `parser.shouldProcessNamespaces = false` explicitly before `parse()`.
- No behavior change (defaults already these); documents intent. Harness already parses XML — existing tests cover regression.

### Task A3: Escape hand-built DIDL in synthesizeDIDL
**Files:** Modify `SonosBar/Transport/SOAPClient.swift` (promote `escape` to `static func escape` — drop `private`); `SonosBar/Transport/SOAPTransport.swift`.
- In `synthesizeDIDL`, wrap `title` and `uri` in `SOAPClient.escape(...)`.
- Test: assert `SOAPTransport`'s favorite path escaping — add a `parseFavorites`/synthesize round-trip assertion that a title with `<`/`&` yields escaped DIDL. Simplest: make `synthesizeDIDL` internal (`static`) and assert `SOAPTransport.synthesizeDIDL(title: "A & B <x>", uri: "u").contains("A &amp; B &lt;x&gt;")`.

### Task A4: legacyCheck html_url scheme/host allowlist
**Files:** Modify `SonosBar/Util/UpdateChecker.swift`.
- Extract a pure `static func sanitizedReleaseURL(_ raw: String?) -> URL?` returning the URL only if `scheme == "https"` and `host == "github.com"`, else nil. Use it in `legacyCheck` for `html_url` (fall back to the hard-coded releases URL as today).
- Test: assert `sanitizedReleaseURL("https://github.com/x")` non-nil; `("file:///etc/passwd")`, `("https://evil.com/x")`, `(nil)` → nil.

### Task A5: SSDP fetch restricted to private/link-local ranges
**Files:** Modify `SonosBar/Discovery/SSDPDiscovery.swift`; Test `Tests/ParserTests/main.swift`.
- Add pure `static func isPrivateOrLinkLocalIPv4(_ host: String) -> Bool` covering `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, plus `127/8` (loopback, harmless) — reject everything else and any non-dotted-quad (a hostname) for safety. IPv6: allow `fe80::/10` and unique-local `fc00::/7`? Sonos is IPv4-only in practice; reject IPv6 literal targets (return false) — discovery already tolerates nil.
- In `fetchPlayer`, after extracting `host`, `guard isPrivateOrLinkLocalIPv4(host) else { log + return nil }`.
- Test: assert 10.x/192.168.x/172.16-31.x/169.254.x true; 8.8.8.8, 172.32.x, "example.com", "" false.

**Verify Commit A:** `./scripts/run-parser-tests.sh` → all green incl. new asserts. Commit.

---

## COMMIT B — GENA NOTIFY source binding

### Task B1: Capture remote host on the event connection
**Files:** Modify `SonosBar/Transport/EventServer.swift`.
- Add `remoteHost: String?` to `EventServer.Event`.
- In `accept`, capture `conn.currentPath?.remoteEndpoint` / `conn.endpoint`; extract the host string (reuse the same normalization approach as `LocalAddress.hostToString` — strip `%scope`). Thread it through `readRequest` → `parseRequest` so the produced Event carries it. Simplest: capture in `accept`, pass as a param down the recursion, set on the Event in the dispatch closure (parseRequest stays pure; set remoteHost after it returns).

### Task B2: Verify NOTIFY source in coordinator
**Files:** Modify `SonosBar/Domain/SonosCoordinator.swift`.
- In `handleEvent`: after resolving `routing`, if `event.remoteHost` is non-nil and `players[routing.uuid]?.host` is non-nil and they differ (after normalization), `Log.events.debug` a drop and `return`. If either is nil, proceed (fail-open on unknown, to avoid blackholing legit events — log at debug).
- Normalization helper: compare with `%scope` stripped and surrounding brackets removed.

**Verify Commit B:** `swiftc -typecheck` Transport+Domain (+others) → 0 errors; parser tests green. Commit.

---

## COMMIT C — Debug-seam hardening

### Task C1: Clear the swap helper's inherited environment
**Files:** Modify `SonosBar/Util/UpdateInstaller.swift`.
- Before `try helper.run()`, set `helper.environment = [:]`. The script pins its own PATH and reads `SB_*` via `${VAR:-default}`, so an empty env makes production use the safe defaults. **Verified safe:** `test-update-helper.sh` drives the script directly with `sh` and sets SB_* itself (unaffected); `test-update-e2e.sh` sets no SB_* (unaffected).

### Task C2: Gate the two UserDefaults debug seams behind DEBUG
**Files:** Modify `Package.swift`, `SonosBar/Util/UpdateChecker.swift`, `scripts/test-update-e2e.sh`.
- `Package.swift`: add `.define("DEBUG", .when(configuration: .debug))` to the target `swiftSettings` (SwiftPM does NOT define DEBUG automatically).
- `UpdateChecker.feedURL`: wrap the `debug.updateFeedURL` override read in `#if DEBUG`. `checkSignedFeed`: wrap the `debug.updateAutoInstall` block in `#if DEBUG`.
- `test-update-e2e.sh`: change default-mode build from `./scripts/build-app.sh release` to `./scripts/build-app.sh debug` (so the DEBUG-gated seams are compiled in), and note in the prebuilt-mode comment that the prebuilt app must be a **debug** build for the auto-install seam to be honored.
- **Cannot run E2E here (launches a GUI app).** Flag for the user to run `./scripts/test-update-e2e.sh` once.

**Verify Commit C:** parser tests green (`test-update-helper.sh` too); typecheck clean. Commit.

---

## COMMIT D — Group volume + EQ transport & coordinator

### Task D1: Add SOAP services
**Files:** Modify `SonosBar/Transport/SOAPServices.swift`.
- Add cases `.groupRenderingControl`. serviceType `urn:schemas-upnp-org:service:GroupRenderingControl:1`; controlPath `/MediaRenderer/GroupRenderingControl/Control`; eventPath `/MediaRenderer/GroupRenderingControl/Event`.

### Task D2: Transport protocol + SOAPTransport methods
**Files:** Modify `SonosBar/Transport/SonosTransport.swift`, `SonosBar/Transport/SOAPTransport.swift`.
- `setGroupVolume(_ volume: Int, on coordinator:)` → `SetGroupVolume`(InstanceID 0, DesiredVolume clamp 0...100), service `.groupRenderingControl`.
- `getGroupVolume(of coordinator:)` → `GetGroupVolume` → CurrentVolume (Int).
- `setGroupMute(_:on:)` → `SetGroupMute`(InstanceID, DesiredMute 1/0).
- EQ struct `EQSettings { var bass: Int; var treble: Int; var loudness: Bool }` in TransportTypes.
- `getEQ(of:)` → parallel GetBass/GetTreble/GetLoudness(Channel Master) → EQSettings (bass/treble clamp -10...10).
- `setBass(_:on:)`, `setTreble(_:on:)` (clamp -10...10), `setLoudness(_:on:)` (Channel Master).

### Task D3: Coordinator wiring
**Files:** Modify `SonosBar/Domain/SonosCoordinator.swift`.
- `setVolume(_:)`: switch the debounced write to `transport.setGroupVolume` on the coordinator; **on SOAP fault fall back to `transport.setVolume`** (per-coordinator) so older firmware degrades to today's behavior rather than a dead slider.
- `setMute`: use `setGroupMute` with same fallback.
- Add `eq: [String: EQSettings]` keyed by group id; `var selectedEQ: EQSettings`. `loadEQ()` in `refreshSelectedGroup` (fetch alongside). Actions `setBass/setTreble/setLoudness` (optimistic + rollback on error, mirroring `apply(playMode:)`).

**Verify Commit D:** typecheck Transport+Domain+others → 0 errors; parser tests green (add EQ clamp + group-volume envelope asserts if cheap). Commit.

---

## COMMIT E — UI (NOT locally compilable — Xcode build required)

### Task E1: UpdateCard shows the real failure note
`UpdateCard.swift:32` → `Text(installer.lastUpdateFailureNote ?? "The last update didn't complete.")`.

### Task E2: Accessibility labels + scrubber traits
- Add `.accessibilityLabel(...)` to every icon-only button (transport prev/play/next, shuffle/repeat/crossfade, mute, footer rescan/settings/quit, zone/group/sleep chevrons, favorite pin).
- `ScrubberRow`: add `.accessibilityElement()`, `.accessibilityLabel("Playback position")`, `.accessibilityValue(format(displayed))`, and `.accessibilityAdjustableAction` that seeks ±15s.
- `MenuBarLabel`: make `.accessibilityLabel` dynamic (offline/idle/"playing — <zone>").

### Task E3: Transport button in-flight guard
- Add `@State private var busy = false` to `TransportRow`; wrap each action `guard !busy; busy = true; …; busy = false`; `.disabled(busy)`. (Mirrors `GroupEditRow.busyUUIDs`.)

### Task E4: Popover height ceiling + auto-collapse siblings
- Wrap `nowPlayingContent` disclosures so opening one collapses the others (single `enum ExpandedSection` @State instead of four bools), OR wrap the whole content column in `.frame(maxHeight:)` + `ScrollView`. Prefer the single-section enum (less disruptive).

### Task E5: Album-art failed state + crossfade
- Converge both AsyncImage sites on the phase API with a distinct `.failure` placeholder (e.g. `music.note` dimmed) vs loading (`ProgressView`), and add `.transition(.opacity)`/`.animation` on the image swap.

### Task E6: Footer error dismiss + reduced-motion + Dynamic Type cap
- Footer error: add a small "×" button setting `coordinator.clearLastError()` (add that method to coordinator — trivial, goes in Commit D or a follow-up; if added post-D, note it).
- Guard `withAnimation` calls with `@Environment(\.accessibilityReduceMotion)`.
- Add `.dynamicTypeSize(...(.xxLarge))` cap on the root popover `VStack`.

### Task E7: EQ + group-volume UI
- Group volume: no UI change needed beyond Commit D (existing `VolumeRow` now drives group volume). Update the `VolumeRow` help/label to "Group volume".
- EQ: add a collapsible `EQRow` in `nowPlayingContent` (bass/treble sliders -10…10, loudness toggle), same disclosure idiom as `SleepTimerRow`, bound to `coordinator.selectedEQ` + `setBass/setTreble/setLoudness`.

### Task E8: README + SettingsView copy
- README: correct the stale "no queue/grouping" limitations; add self-update, group volume, EQ. SettingsView: mention EQ if surfaced there.

**Verify Commit E:** Cannot compile locally. Self-review each view against existing idioms. Commit with a clear note that an Xcode build is required.

---

## Self-review checklist
- Group volume falls back to per-coordinator on fault (D3) — no dead slider.
- All SOAP names match the verified SCPD list (no drift).
- Security guards are pure statics with harness asserts (A1,A3,A4,A5).
- Debug-seam gating updates BOTH Package.swift and the E2E script (C2).
- UI files flagged as unverified-locally in the final report.
