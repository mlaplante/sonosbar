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

    // Discovery, subscriptions, hotkeys, and media-key handling start in
    // AppDelegate.applicationDidFinishLaunching — NOT in a .task on the
    // MenuBarExtra content view, which SwiftUI can lazily create only when
    // the popover is first opened. The app must be live before any click.
    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environment(appDelegate.coordinator)
                .environment(appDelegate.updates)
                .environment(appDelegate.installer)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.coordinator)
        }
        .menuBarExtraStyle(.window)

        // Settings scene — accessible via Cmd+, from the popover or via
        // the standard Settings menu item that SwiftUI exposes for
        // agent apps.
        Settings {
            SettingsView()
                .environment(appDelegate.coordinator)
                .environment(appDelegate.updates)
        }
    }
}

private struct MenuBarLabel: View {

    @Environment(SonosCoordinator.self) private var coordinator

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: SonosBarIcon.image(for: state))
            if let title = menuBarTitle {
                Text(title)
            }
        }
        .accessibilityLabel("SonosBar")
    }

    private var state: SonosBarIcon.State {
        if coordinator.players.isEmpty { return .offline }
        let isPlaying = (coordinator.selectedGroup
            .flatMap { coordinator.playback[$0.id]?.state } ?? .stopped).isActive
        return isPlaying ? .playing : .idle
    }

    /// Track title beside the icon, when the user opted in and something
    /// is actually playing. Trimmed hard — the menu bar is shared space.
    private var menuBarTitle: String? {
        guard coordinator.settings.showTitleInMenuBar,
              let group = coordinator.selectedGroup,
              let snapshot = coordinator.playback[group.id],
              snapshot.state.isActive,
              !snapshot.track.title.isEmpty else { return nil }
        let title = snapshot.track.title
        return title.count > 40 ? String(title.prefix(39)) + "…" : title
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

    let coordinator = SonosCoordinator()
    let nowPlaying = NowPlayingBridge()
    let hotkeys = GlobalHotkeyManager()
    let updates = UpdateChecker()
    let installer = UpdateInstaller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        nowPlaying.attach(to: coordinator)

        // Wire global hotkeys to the coordinator.
        let coordinator = self.coordinator
        hotkeys.install { action in
            Task { @MainActor in
                switch action {
                case .playPause:     await coordinator.togglePlayPause()
                case .nextTrack:     await coordinator.next()
                case .previousTrack: await coordinator.previous()
                case .volumeUp:      coordinator.nudgeVolume(by: +5)
                case .volumeDown:    coordinator.nudgeVolume(by: -5)
                }
            }
        }

        Task { await coordinator.bootstrap() }
        updates.installer = installer
        installer.prepareForTermination = { [weak self] in
            await self?.coordinator.shutdown()
        }
        updates.start()
        if let failure = installer.consumeLastUpdateError() {
            Log.app.error("Previous update did not complete: \(failure)")
        }

        // An update swaps the bundle; ad-hoc signatures differ per build,
        // which can invalidate the SMAppService login-item registration.
        // If the user wants launch-at-login but the system lost it,
        // re-register quietly.
        if coordinator.settings.launchAtLogin && !LaunchAtLogin.isEnabled {
            LaunchAtLogin.set(enabled: true)
        }
    }

    private var hasRepliedToTerminate = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        nowPlaying.detach()
        hotkeys.uninstall()

        // Blocking the main thread here (DispatchGroup.wait) can never work:
        // shutdown() is main-actor and would need the very thread we'd be
        // blocking, so the speakers were left holding live GENA subscriptions
        // to a dead callback port. .terminateLater lets shutdown() actually
        // run; a watchdog caps quit latency if a speaker hangs.
        Task { @MainActor in
            await coordinator.shutdown()
            self.replyToTerminateOnce(sender)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.replyToTerminateOnce(sender)
        }
        return .terminateLater
    }

    private func replyToTerminateOnce(_ app: NSApplication) {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        app.reply(toApplicationShouldTerminate: true)
    }
}
