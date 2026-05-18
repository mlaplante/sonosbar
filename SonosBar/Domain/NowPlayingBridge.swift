//
//  NowPlayingBridge.swift
//  SonosBar
//
//  Wires SonosBar into macOS's system-level media controls:
//    * MPRemoteCommandCenter: handlers for play/pause/next/previous so
//      the hardware media keys, Touch Bar, AirPods H1/H2 stem clicks,
//      and Control Center all route to our coordinator.
//    * MPNowPlayingInfoCenter: tells the OS what's currently playing
//      so the title shows in Control Center, the lock screen mirror,
//      and any future Live Activity-equivalent for the Mac.
//
//  The trick with MPRemoteCommandCenter on macOS is that it only
//  activates when our process is the "now playing" app — which the OS
//  picks based on who most recently published valid info to
//  MPNowPlayingInfoCenter. So we publish info eagerly even when there's
//  no track playing, otherwise iTunes/Music or Spotify steals the keys.
//
//  This is the bridge between the @MainActor SonosCoordinator and the
//  AppKit/MediaPlayer APIs. It observes coordinator state and pushes
//  updates into the system.
//

import Foundation
import MediaPlayer
import AppKit

@MainActor
final class NowPlayingBridge {

    private weak var coordinator: SonosCoordinator?
    private var observationTask: Task<Void, Never>?

    /// Connect to the coordinator and start observing.
    func attach(to coordinator: SonosCoordinator) {
        self.coordinator = coordinator
        registerHandlers()
        startObserving(coordinator)
    }

    func detach() {
        observationTask?.cancel()
        observationTask = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(self)
        center.pauseCommand.removeTarget(self)
        center.togglePlayPauseCommand.removeTarget(self)
        center.nextTrackCommand.removeTarget(self)
        center.previousTrackCommand.removeTarget(self)
    }

    // MARK: - Remote command handlers

    private func registerHandlers() {
        let center = MPRemoteCommandCenter.shared()

        // Removing-then-adding ensures a fresh handler — without this,
        // re-attaching produces duplicate dispatches.
        center.playCommand.removeTarget(self)
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.coordinator?.play() }
            return .success
        }

        center.pauseCommand.removeTarget(self)
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.coordinator?.pause() }
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(self)
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.coordinator?.togglePlayPause() }
            return .success
        }

        center.nextTrackCommand.removeTarget(self)
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.coordinator?.next() }
            return .success
        }

        center.previousTrackCommand.removeTarget(self)
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.coordinator?.previous() }
            return .success
        }

        // Enable all the commands we handle. Disabled commands won't
        // surface to the system UI.
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        // Seek and stop we don't support. Make sure they're off so the
        // system doesn't try to call them.
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.stopCommand.isEnabled = false
    }

    // MARK: - Now Playing info

    /// Watches coordinator state and pushes updates to MPNowPlayingInfoCenter.
    /// We use a polled observer rather than withObservationTracking + a
    /// recursive call because the @Observable macro doesn't expose a
    /// stable "wait for any change" primitive yet — and polling every
    /// 250ms is cheaper than rebuilding observation trees per change.
    private func startObserving(_ coordinator: SonosCoordinator) {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            // Push initial state immediately so the OS knows we're the
            // active media app.
            self?.publishNowPlaying()

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.publishNowPlaying()
            }
        }
    }

    private func publishNowPlaying() {
        guard let coordinator else { return }
        let center = MPNowPlayingInfoCenter.default()

        guard let group = coordinator.selectedGroup,
              let snapshot = coordinator.playback[group.id] else {
            // Publish minimal info so we stay "the now-playing app" even
            // before discovery completes — without this, Spotify or
            // Music can grab the keys at launch.
            center.nowPlayingInfo = [
                MPMediaItemPropertyTitle: "SonosBar",
                MPNowPlayingInfoPropertyPlaybackRate: 0.0
            ]
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle]   = snapshot.track.title.isEmpty ? group.displayName : snapshot.track.title
        info[MPMediaItemPropertyArtist]  = snapshot.track.artist
        info[MPMediaItemPropertyAlbumTitle] = snapshot.track.album
        info[MPMediaItemPropertyPlaybackDuration] = snapshot.track.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.track.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.state.isActive ? 1.0 : 0.0

        center.nowPlayingInfo = info
        center.playbackState = snapshot.state.isActive ? .playing : .paused

        // Album art is fetched async and applied separately so we don't
        // block the rest of the metadata update. We cache by URL to
        // avoid re-fetching on every poll tick.
        if let artURL = snapshot.track.albumArtURL {
            fetchAndApplyArtwork(url: artURL, info: info)
        }
    }

    // MARK: - Artwork caching

    private var lastArtURL: URL?
    private var lastArtwork: MPMediaItemArtwork?

    private func fetchAndApplyArtwork(url: URL, info: [String: Any]) {
        if url == lastArtURL, let art = lastArtwork {
            updateInfo(info, with: art)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            guard let data = try? await URLSession.shared.data(from: url).0,
                  let image = NSImage(data: data) else { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                self.lastArtURL = url
                self.lastArtwork = artwork
                self.updateInfo(info, with: artwork)
            }
        }
    }

    private func updateInfo(_ info: [String: Any], with artwork: MPMediaItemArtwork) {
        var updated = info
        updated[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
    }
}
