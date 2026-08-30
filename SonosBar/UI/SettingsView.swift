//
//  SettingsView.swift
//  SonosBar
//
//  The Settings scene. Reachable via Cmd+, when the menu bar popover
//  is open, or via the Apple menu's Settings item that SwiftUI
//  automatically adds even for LSUIElement apps.
//
//  Kept intentionally tiny in v1 — three toggles. More elaborate
//  preferences (hotkey rebinding, default zone, per-event notifications)
//  can land in a future version without rearchitecting this view.
//

import SwiftUI

struct SettingsView: View {

    @Environment(SonosCoordinator.self) private var coordinator
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        // @Bindable lets us bind directly to @Observable properties on
        // the settings store. This is the SwiftUI 5+ replacement for
        // @ObservedObject bindings.
        @Bindable var settings = coordinator.settings

        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                Toggle("Show track title in menu bar", isOn: $settings.showTitleInMenuBar)
                    .toggleStyle(.switch)
                Toggle("Remember last selected zone", isOn: $settings.rememberLastZone)
                    .toggleStyle(.switch)
            }

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

            Section("Global shortcuts") {
                Text("⌘⌥⌃ P — Play / Pause")
                Text("⌘⌥⌃ ←/→ — Previous / Next")
                Text("⌘⌥⌃ ↑/↓ — Volume up / down")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Section("About") {
                Text("SonosBar \(updates.currentVersion)")
                    .font(.callout)
                Text("Sonos is a trademark of Sonos Inc. SonosBar is an independent project not affiliated with Sonos.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 380)
    }
}
