//
//  SonosBarApp.swift
//  SonosBar
//
//  Entry point. The coordinator, now-playing bridge, and global hotkey
//  manager live at app scope so their lifetimes span the entire session.
//

import SwiftUI
import AppKit

@main
struct SonosBarApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = SonosCoordinator()
    @State private var nowPlaying = NowPlayingBridge()
    @State private var hotkeys = GlobalHotkeyManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environment(coordinator)
                .task {
                    appDelegate.coordinator = coordinator
                    appDelegate.nowPlaying = nowPlaying
                    appDelegate.hotkeys = hotkeys

                    nowPlaying.attach(to: coordinator)

                    // Wire global hotkeys to the coordinator.
                    hotkeys.install { action in
                        Task { @MainActor in
                            switch action {
                            case .playPause:    await coordinator.togglePlayPause()
                            case .nextTrack:    await coordinator.next()
                            case .previousTrack: await coordinator.previous()
                            case .volumeUp:     coordinator.nudgeVolume(by: +5)
                            case .volumeDown:   coordinator.nudgeVolume(by: -5)
                            }
                        }
                    }

                    await coordinator.bootstrap()
                }
        } label: {
            MenuBarLabel()
                .environment(coordinator)
        }
        .menuBarExtraStyle(.window)

        // Settings scene — accessible via Cmd+, from the popover or via
        // the standard Settings menu item that SwiftUI exposes for
        // agent apps.
        Settings {
            SettingsView()
                .environment(coordinator)
        }
    }
}

private struct MenuBarLabel: View {

    @Environment(SonosCoordinator.self) private var coordinator

    var body: some View {
        Image(systemName: symbolName)
            .renderingMode(.template)
            .accessibilityLabel("SonosBar")
    }

    private var symbolName: String {
        if coordinator.players.isEmpty {
            return "hifispeaker.2"
        }
        let isPlaying = (coordinator.selectedGroup
            .flatMap { coordinator.playback[$0.id]?.state } ?? .stopped).isActive
        return isPlaying ? "hifispeaker.2.fill" : "hifispeaker.2"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    var coordinator: SonosCoordinator?
    var nowPlaying: NowPlayingBridge?
    var hotkeys: GlobalHotkeyManager?

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying?.detach()
        hotkeys?.uninstall()
        guard let coordinator else { return }
        let group = DispatchGroup()
        group.enter()
        Task { @MainActor in
            await coordinator.shutdown()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 2)
    }
}
