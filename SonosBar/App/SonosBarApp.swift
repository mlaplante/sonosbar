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
        Image(nsImage: SonosBarIcon.image(for: state))
            .accessibilityLabel("SonosBar")
    }

    private var state: SonosBarIcon.State {
        if coordinator.players.isEmpty { return .offline }
        let isPlaying = (coordinator.selectedGroup
            .flatMap { coordinator.playback[$0.id]?.state } ?? .stopped).isActive
        return isPlaying ? .playing : .idle
    }
}

/// Custom menu-bar glyph: rounded speaker silhouette paired with a
/// sound-wave arc that appears only when audio is active.
///
/// Drawn into an `NSImage` marked as a template so macOS tints it
/// correctly for light/dark menu bars and dims it when the menu bar
/// is inactive. (SwiftUI `Shape` views inside a `MenuBarExtra` label
/// don't render — the menu bar wants a template NSImage.)
enum SonosBarIcon {

    enum State { case offline, idle, playing }

    static func image(for state: State) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state: state, in: rect, ctx: ctx)
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func draw(state: State, in rect: CGRect, ctx: CGContext) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.1)
        ctx.setLineCap(.round)

        let alpha: CGFloat = state == .offline ? 0.55 : 1.0
        ctx.setAlpha(alpha)

        // Speaker pill on the left
        let speakerRect = CGRect(x: 1, y: 0.5, width: 8, height: 13)
        let speakerPath = CGPath(
            roundedRect: speakerRect,
            cornerWidth: 2, cornerHeight: 2,
            transform: nil
        )
        ctx.addPath(speakerPath)
        ctx.strokePath()

        // Tweeter + woofer dots, centered in the speaker
        let cx = speakerRect.midX
        ctx.fillEllipse(in: CGRect(x: cx - 0.9, y: 9.6, width: 1.8, height: 1.8))
        ctx.fillEllipse(in: CGRect(x: cx - 1.8, y: 3.6, width: 3.6, height: 3.6))

        // Sound wave arcs (only when playing)
        if state == .playing {
            let center = CGPoint(x: 10.5, y: rect.midY)
            for r in [3.5, 6.5] as [CGFloat] {
                let arc = CGMutablePath()
                arc.addArc(
                    center: center,
                    radius: r,
                    startAngle: -.pi / 5.6,
                    endAngle: .pi / 5.6,
                    clockwise: false
                )
                ctx.addPath(arc)
                ctx.strokePath()
            }
        }
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
