//
//  MenuBarRootView.swift
//  SonosBar
//
//  The popover that opens when the user clicks the menu bar icon.
//
//  Composition:
//    [Tab bar]        — Now Playing | Favorites
//    Now Playing tab:
//      [NowPlayingCard]
//      [TransportRow]
//      [VolumeRow]    — group volume slider
//      [SpeakerList]  — collapsible: per-speaker volumes
//      [ZonePicker]
//      [SleepTimerRow]
//    Favorites tab:
//      [FavoritesList]
//    [FooterRow]
//
//  Tahoe design notes:
//    * The popover chrome already provides Liquid Glass; we don't add
//      .glassEffect to the container.
//    * Grouped sub-surfaces use .ultraThinMaterial inside a rounded rect.
//    * The aesthetic match for a menu bar utility is "controlled, quiet,
//      functional" — closer to System Settings than to a media app.
//

import SwiftUI

private enum Tab: Hashable {
    case nowPlaying
    case favorites
}

struct MenuBarRootView: View {

    @Environment(SonosCoordinator.self) private var coordinator

    @State private var tab: Tab = .nowPlaying
    @State private var isZonePickerExpanded = false
    @State private var isSpeakerListExpanded = false
    @State private var isSleepTimerExpanded = false

    var body: some View {
        VStack(spacing: 12) {
            tabBar

            if coordinator.isInitialising && coordinator.players.isEmpty {
                initialisingView
            } else if coordinator.players.isEmpty {
                noSpeakersView
            } else {
                switch tab {
                case .nowPlaying:
                    nowPlayingContent
                case .favorites:
                    favoritesContent
                }
            }

            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Now Playing", tab: .nowPlaying, symbol: "play.square")
            tabButton("Favorites", tab: .favorites, symbol: "star")
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tabButton(_ title: String, tab target: Tab, symbol: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { tab = target }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.caption.weight(tab == target ? .semibold : .regular))
            .foregroundStyle(tab == target ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if tab == target {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .padding(2)
            }
        }
    }

    // MARK: - States

    private var initialisingView: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text("Looking for Sonos speakers…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var noSpeakersView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Sonos speakers found.")
                .font(.callout)
                .fontWeight(.medium)
            Text("Make sure your Mac is on the same Wi-Fi network as your Sonos system, then try refreshing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Now Playing tab

    @ViewBuilder
    private var nowPlayingContent: some View {
        if let group = coordinator.selectedGroup {
            NowPlayingCard(group: group)
            ScrubberRow(group: group)
            TransportRow()
            VolumeRow()
            SpeakerList(group: group, isExpanded: $isSpeakerListExpanded)
            ZonePicker(isExpanded: $isZonePickerExpanded)
            SleepTimerRow(isExpanded: $isSleepTimerExpanded)
        } else {
            noSpeakersView
        }
    }

    // MARK: - Favorites tab

    private var favoritesContent: some View {
        FavoritesList()
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            if let error = coordinator.lastError {
                Text(error.description)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button {
                    Task { await coordinator.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Re-scan for speakers")

                Spacer()

                SettingsLink {
                    Label("Settings…", systemImage: "gear")
                        .labelStyle(.titleOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: [.command])

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .labelStyle(.titleOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}

// MARK: - Now Playing card

private struct NowPlayingCard: View {

    @Environment(SonosCoordinator.self) private var coordinator
    let group: ZoneGroup

    private var snapshot: PlaybackSnapshot {
        coordinator.playback[group.id] ?? PlaybackSnapshot()
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.track.title.isEmpty ? "Nothing playing" : snapshot.track.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !snapshot.track.artist.isEmpty {
                    Text(snapshot.track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !snapshot.track.album.isEmpty {
                    Text(snapshot.track.album)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = snapshot.track.albumArtURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    artworkPlaceholder
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            artworkPlaceholder
                .frame(width: 56, height: 56)
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
    }
}

// MARK: - Scrubber

/// Thin progress bar showing position/duration with click-to-seek.
/// Position advances locally on a 1 Hz timer while playing so the bar
/// feels alive without spamming the speaker with GetPositionInfo polls.
/// Click anywhere along the track to seek; we issue a Seek then refresh
/// the snapshot so the canonical position takes over.
private struct ScrubberRow: View {

    @Environment(SonosCoordinator.self) private var coordinator
    let group: ZoneGroup

    @State private var localPosition: TimeInterval = 0
    @State private var lastSnapshotPosition: TimeInterval = -1
    @State private var dragPreview: TimeInterval?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var snapshot: PlaybackSnapshot {
        coordinator.playback[group.id] ?? PlaybackSnapshot()
    }

    private var duration: TimeInterval { snapshot.track.duration }
    private var isPlaying: Bool { snapshot.state.isActive }
    private var isSeekable: Bool { duration > 0 }

    var body: some View {
        if isSeekable {
            VStack(spacing: 2) {
                GeometryReader { geo in
                    let displayed = dragPreview ?? localPosition
                    let progress = duration > 0 ? min(max(displayed / duration, 0), 1) : 0
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(.tint)
                            .frame(width: geo.size.width * progress)
                    }
                    .frame(height: 4)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                                dragPreview = ratio * duration
                            }
                            .onEnded { value in
                                let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                                let target = Int((ratio * duration).rounded())
                                dragPreview = nil
                                localPosition = TimeInterval(target)
                                Task { await coordinator.seek(toSeconds: target) }
                            }
                    )
                }
                .frame(height: 6)

                HStack {
                    Text(format(dragPreview ?? localPosition))
                    Spacer()
                    Text(format(duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .onAppear {
                localPosition = snapshot.track.position
                lastSnapshotPosition = snapshot.track.position
            }
            .onReceive(timer) { _ in
                // If the speaker just told us a new position (via a
                // refresh), snap to it; otherwise advance locally.
                if snapshot.track.position != lastSnapshotPosition {
                    localPosition = snapshot.track.position
                    lastSnapshotPosition = snapshot.track.position
                } else if isPlaying && dragPreview == nil {
                    localPosition = min(localPosition + 1, duration)
                }
            }
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Transport controls

private struct TransportRow: View {

    @Environment(SonosCoordinator.self) private var coordinator

    private var isPlaying: Bool {
        (coordinator.selectedGroup.flatMap { coordinator.playback[$0.id]?.state } ?? .stopped).isActive
    }

    var body: some View {
        HStack(spacing: 24) {
            Spacer()
            transportButton(systemImage: "backward.fill") {
                Task { await coordinator.previous() }
            }
            transportButton(systemImage: isPlaying ? "pause.fill" : "play.fill", size: 22) {
                Task { await coordinator.togglePlayPause() }
            }
            transportButton(systemImage: "forward.fill") {
                Task { await coordinator.next() }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func transportButton(systemImage: String, size: CGFloat = 18, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Volume row

private struct VolumeRow: View {

    @Environment(SonosCoordinator.self) private var coordinator

    private var volume: VolumeSnapshot {
        coordinator.selectedGroup.flatMap { coordinator.volumes[$0.id] } ?? VolumeSnapshot()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await coordinator.setMute(!volume.muted) }
            } label: {
                Image(systemName: volume.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(volume.muted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { Double(volume.volume) },
                    set: { newValue in
                        coordinator.setVolume(Int(newValue.rounded()))
                    }
                ),
                in: 0...100,
                step: 1
            )
            .controlSize(.small)

            Text("\(volume.volume)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

// MARK: - Per-speaker volume list (chunk 10)

private struct SpeakerList: View {

    @Environment(SonosCoordinator.self) private var coordinator
    let group: ZoneGroup
    @Binding var isExpanded: Bool

    var body: some View {
        // Only show the disclosure if the group has more than one member —
        // a solo speaker is already controlled by the main volume slider.
        if group.members.count > 1 {
            VStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "hifispeaker")
                            .foregroundStyle(.secondary)
                        Text("Speakers in group")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 6) {
                        ForEach(group.members, id: \.uuid) { member in
                            memberRow(member)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func memberRow(_ member: ZoneGroupMember) -> some View {
        let snap = coordinator.memberVolumes[member.uuid] ?? VolumeSnapshot()
        HStack(spacing: 6) {
            Text(member.zoneName)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)
            Slider(
                value: Binding(
                    get: { Double(snap.volume) },
                    set: { newValue in
                        coordinator.setMemberVolume(Int(newValue.rounded()), on: member)
                    }
                ),
                in: 0...100,
                step: 1
            )
            .controlSize(.mini)
            Text("\(snap.volume)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)
        }
    }
}

// MARK: - Zone picker

private struct ZonePicker: View {

    @Environment(SonosCoordinator.self) private var coordinator
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "hifispeaker.2.fill")
                        .foregroundStyle(.secondary)
                    Text(coordinator.selectedGroup?.displayName ?? "No zone")
                        .font(.callout)
                    Spacer()
                    if coordinator.groups.count > 1 {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(coordinator.groups.count <= 1)

            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(coordinator.groups, id: \.id) { group in
                        zoneRow(group: group)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func zoneRow(group: ZoneGroup) -> some View {
        Button {
            coordinator.select(group: group)
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded = false }
        } label: {
            HStack {
                Image(systemName: group.id == coordinator.selectedGroupID ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(group.id == coordinator.selectedGroupID ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                Text(group.displayName)
                    .font(.callout)
                Spacer()
                if group.members.count > 1 {
                    Text("\(group.members.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sleep timer

private struct SleepTimerRow: View {

    @Environment(SonosCoordinator.self) private var coordinator
    @Binding var isExpanded: Bool

    private let presets = [15, 30, 45, 60, 90, 120]

    var body: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: timerActive ? "moon.fill" : "moon")
                        .foregroundStyle(timerActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(timerLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(presets, id: \.self) { mins in
                            presetButton(minutes: mins)
                        }
                    }
                    if timerActive {
                        Button {
                            Task { await coordinator.clearSleepTimer() }
                        } label: {
                            Text("Cancel timer")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var timerActive: Bool { coordinator.sleepTimerRemaining > 0 }

    private var timerLabel: String {
        if !timerActive { return "Sleep timer" }
        let remaining = coordinator.sleepTimerRemaining
        let m = remaining / 60
        let s = remaining % 60
        if m > 0 {
            return "Stops in \(m)m \(s)s"
        }
        return "Stops in \(s)s"
    }

    private func presetButton(minutes: Int) -> some View {
        Button {
            Task { await coordinator.setSleepTimer(minutes: minutes) }
        } label: {
            Text("\(minutes)m")
                .font(.caption2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Favorites tab

private struct FavoritesList: View {

    @Environment(SonosCoordinator.self) private var coordinator
    @State private var search = ""

    private var filtered: [SonosFavorite] {
        if search.isEmpty { return coordinator.favorites }
        return coordinator.favorites.filter {
            $0.title.localizedCaseInsensitiveContains(search)
        }
    }

    private var pinned: [SonosFavorite] {
        filtered.filter { coordinator.settings.isPinned(favoriteURI: $0.uri) }
    }

    private var unpinned: [SonosFavorite] {
        filtered.filter { !coordinator.settings.isPinned(favoriteURI: $0.uri) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if coordinator.favoritesLoading && coordinator.favorites.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if coordinator.favorites.isEmpty {
                Text("No favorites in your Sonos system.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("Search favorites", text: $search)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                ScrollView {
                    VStack(spacing: 4) {
                        if !pinned.isEmpty {
                            ForEach(pinned) { fav in
                                FavoriteRow(favorite: fav)
                            }
                            if !unpinned.isEmpty {
                                Divider()
                                    .padding(.vertical, 2)
                            }
                        }
                        ForEach(unpinned) { fav in
                            FavoriteRow(favorite: fav)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }
}

private struct FavoriteRow: View {

    @Environment(SonosCoordinator.self) private var coordinator
    @State private var hovering = false
    let favorite: SonosFavorite

    private var isPinned: Bool {
        coordinator.settings.isPinned(favoriteURI: favorite.uri)
    }

    var body: some View {
        Button {
            Task { await coordinator.play(favorite: favorite) }
        } label: {
            HStack(spacing: 8) {
                if let art = favorite.albumArtURL {
                    AsyncImage(url: art) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        artPlaceholder
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    artPlaceholder.frame(width: 32, height: 32)
                }

                Text(favorite.title)
                    .font(.callout)
                    .lineLimit(1)

                Spacer()

                // Pin button: always visible when pinned (so the user
                // can find the unpin affordance), hover-revealed when
                // unpinned (to keep the unpinned list visually quiet).
                if isPinned || hovering {
                    Button {
                        coordinator.settings.togglePinned(favoriteURI: favorite.uri)
                    } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .foregroundStyle(isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "Unpin" : "Pin to top")
                }

                Image(systemName: "play.circle")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "star")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }
}
