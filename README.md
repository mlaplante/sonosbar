# SonosBar

A native macOS menu bar controller for Sonos speakers. Built for macOS Tahoe (26+).
Direct-distribution `.dmg`, not Mac App Store.

> Sonos is a trademark of Sonos Inc. SonosBar is an independent project and is
> not affiliated with, endorsed by, or sponsored by Sonos Inc.

## Features

- 🎵 **Play / Pause / Skip** — from the menu bar, via global hotkeys, or via the macOS media keys
- ⏩ **Scrub bar** — drag to seek within the current track
- 🔀 **Shuffle / repeat / crossfade** — playback mode toggles
- 🔊 **True group + per-speaker volume** — one slider scales the whole group (via GroupRenderingControl); independent sliders for stereo pairs and grouped zones
- 🎚️ **EQ** — bass, treble, and loudness per zone
- 📋 **Queue** — browse the group's queue and jump to any track
- 👥 **Grouping** — join and split speakers from the app (group all / ungroup all)
- ⭐ **Favorites** — every favorite in your Sonos system, searchable, one-click play, pin to top
- 🌙 **Sleep timer** — 15/30/45/60/90/120-minute presets
- 🏠 **Zone switching** — pick any group from the popover
- 🎛️ **Now Playing integration** — title, artist, art surface in Control Center and on the lock screen
- ⌨️ **Global hotkeys** — `⌘⌥⌃ P` play/pause, `⌘⌥⌃ ←/→` prev/next, `⌘⌥⌃ ↑/↓` volume
- 🚀 **Launch at login** — optional, via SMAppService
- ⬆️ **Signed self-update** — checks a release feed and installs Ed25519-signed updates in place

All local. No cloud account required. No data ever leaves your LAN.

## Why direct distribution and not the App Store?

The Mac App Store sandbox requires a `com.apple.developer.networking.multicast`
entitlement that Apple grants by individual application. Discovery of Sonos
speakers uses SSDP multicast (UPnP). Direct distribution lets SonosBar work
out of the box.

## Why local UPnP and not the Sonos Cloud API?

The official Control API requires a public HTTPS callback URL for events
and access tokens that expire every 24 hours. For a menu-bar controller
whose pitch is "instant control", local UPnP wins. The transport layer
is abstracted behind a protocol (`SonosTransport`) so a cloud
implementation can land in the future without touching the domain or UI.

## Requirements

- macOS Tahoe (26.0) or later
- Xcode 26
- Swift 6.0

## Build

Open `Package.swift` in Xcode and run, **or** from the command line:

```bash
./scripts/build-app.sh release          # release build → build/SonosBar.app
open build/SonosBar.app                 # launch
```

The first launch will be ad-hoc signed only; Gatekeeper will require a
right-click → Open the first time. For real release distribution, use
the signing + DMG pipeline:

```bash
./scripts/sign-and-notarize.sh "Developer ID Application: Your Name (TEAMID)"
./scripts/make-dmg.sh                   # → dist/SonosBar-0.1.0.dmg
```

See each script's header comments for prerequisites (Developer ID cert,
notary keychain profile).

## Architecture

```
SonosBar/
├── App/              # Entry point, MenuBarExtra scene, AppDelegate
├── UI/               # SwiftUI views: popover, settings
├── Domain/           # SonosCoordinator (single source of truth), NowPlayingBridge
├── Transport/        # SonosTransport protocol + SOAP/GENA implementation
├── Discovery/        # SSDP discovery, device description parsing
├── Persistence/      # SettingsStore, LaunchAtLogin
├── Util/             # XML parser, logging, debouncing, hotkeys, LAN address probe
└── Resources/        # Info.plist, entitlements, asset catalog
```

### Layering

```
┌─────────────────────────────────────────┐
│  UI (SwiftUI views)                     │   No knowledge of network/XML
├─────────────────────────────────────────┤
│  Domain (SonosCoordinator + Bridges)    │   @MainActor, @Observable
├─────────────────────────────────────────┤
│  Transport (SonosTransport protocol)    │   SOAP, GENA, async
├─────────────────────────────────────────┤
│  Discovery (SSDP)                       │   UDP multicast
└─────────────────────────────────────────┘
```

UI binds to `SonosCoordinator` only. The coordinator is the single source
of truth and the only writer of observable state. Network operations flow
through the `SonosTransport` protocol so a cloud or future-API
implementation can swap in without touching anything above it.

### Event flow

1. SSDP discovery returns a list of `DiscoveredPlayer`s.
2. One SOAP `GetZoneGroupState` call seeds the initial topology.
3. `EventServer` binds a local TCP port and starts listening for GENA `NOTIFY` callbacks.
4. `EventSubscription`s SUBSCRIBE to AVTransport + RenderingControl on every player,
   and ZoneGroupTopology on one player (one is enough — all speakers share the same view).
5. Subscriptions auto-renew at half the granted timeout.
6. On `NOTIFY`, the server routes by SID, parses the inner LastChange,
   and updates the coordinator's `@Observable` state. UI re-renders.

### Why a coordinator and not view-local state?

Multiple surfaces (popover, menu bar label, NowPlayingBridge,
future widgets) read the same state. Putting state on the view ties
lifetime to view appearance — for MenuBarExtra that's the moment the
popover opens, not app launch. Discovery and event subscriptions need
to keep running while the popover is closed.

## Known limitations

- **No queue editing** — the queue is browse-and-jump only; dropping, reordering, and saving aren't supported yet.
- **No Trueplay or speaker setup** — EQ (bass/treble/loudness) is supported, but room calibration and initial speaker configuration stay in the Sonos app.
- **No alarms** or music-service search from within the app.
- **Local-only** — controlling Sonos when away from home isn't supported.

## License

MIT. See `LICENSE`.
