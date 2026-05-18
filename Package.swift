// swift-tools-version: 6.0
// SonosBar — a menu bar controller for Sonos on macOS Tahoe (26+).
//
// This is a Swift Package Manager executable. Open Package.swift in Xcode 26
// to get a full IDE experience; build from the command line with `swift build`.
//
// Why SPM instead of an .xcodeproj?
//   * .xcodeproj files contain machine-generated UUIDs and are painful to
//     hand-edit reliably. SPM manifests are plain Swift.
//   * Xcode 26 opens Package.swift as a first-class project.
//   * Signing, notarization, and .dmg packaging happen in scripts (see
//     scripts/ in later chunks), not inside Xcode's project settings.

import PackageDescription

let package = Package(
    name: "SonosBar",
    platforms: [
        // Tahoe-only by design. MenuBarExtra has existed since macOS 13, but
        // .glassEffect, the new MenuBarExtra materials, App Intents niceties,
        // and the @Observable macro are all cleanest on 26+.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "SonosBar", targets: ["SonosBar"])
    ],
    dependencies: [
        // No external dependencies in chunk 1. We deliberately stay vanilla:
        // Foundation, SwiftUI, Network.framework, and AppKit interop are
        // enough to ship this app. Adding deps later (e.g. for SOAP XML or
        // global hotkeys) will be a deliberate, justified call.
    ],
    targets: [
        .executableTarget(
            name: "SonosBar",
            path: "SonosBar",
            exclude: [
                "Resources/Info.plist",
                "Resources/SonosBar.entitlements"
            ],
            resources: [
                .process("Resources/Assets.xcassets")
            ],
            swiftSettings: [
                // Strict concurrency catches data races before they ship.
                // Sonos work is fundamentally concurrent (discovery, event
                // subscriptions, transport state), so we want this on from day 1.
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("AccessLevelOnImport")
            ],
            linkerSettings: [
                // MediaPlayer needed for MPNowPlayingInfoCenter (chunk 7).
                // Carbon is needed for RegisterEventHotKey (chunk 10);
                // it's still the only API on macOS that can claim a
                // global keystroke (vs. only observing it).
                .linkedFramework("MediaPlayer"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
