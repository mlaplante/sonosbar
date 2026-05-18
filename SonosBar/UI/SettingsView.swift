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

    @State private var probeResult: String = ""
    @State private var probeRunning = false

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

            Section("Global shortcuts") {
                Text("⌘⌥⌃ P — Play / Pause")
                Text("⌘⌥⌃ ←/→ — Previous / Next")
                Text("⌘⌥⌃ ↑/↓ — Volume up / down")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Section("Diagnostics") {
                HStack {
                    Button {
                        Task {
                            probeRunning = true
                            probeResult = await coordinator.probeMusicServices()
                            probeRunning = false
                        }
                    } label: {
                        if probeRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Probe music services")
                        }
                    }
                    .disabled(probeRunning)

                    if !probeResult.isEmpty {
                        Button("Copy") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(probeResult, forType: .string)
                        }
                    }
                }
                if !probeResult.isEmpty {
                    ScrollView {
                        Text(probeResult)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: 200)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Section("About") {
                Text("SonosBar 0.1.0")
                    .font(.callout)
                Text("Sonos is a trademark of Sonos Inc. SonosBar is an independent project not affiliated with Sonos.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }
}
