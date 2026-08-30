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
    case queue
    case favorites
}

struct MenuBarRootView: View {

    @Environment(SonosCoordinator.self) private var coordinator
    @Environment(UpdateChecker.self) private var updates

    @State private var tab: Tab = .nowPlaying

    /// Only one Now Playing disclosure is open at a time — opening one
    /// collapses the others, so a large household can't stack four expanded
    /// sections tall enough to push the popover off-screen.
    private enum NowPlayingSection { case speakers, zones, group, sleep }
    @State private var expandedSection: NowPlayingSection?

    private func sectionBinding(_ section: NowPlayingSection) -> Binding<Bool> {
        Binding(
            get: { expandedSection == section },
            set: { expandedSection = $0 ? section : nil }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            tabBar

            UpdateCard()

            if coordinator.isInitialising && coordinator.players.isEmpty {
                initialisingView
            } else if coordinator.players.isEmpty {
                noSpeakersView
            } else {
                switch tab {
                case .nowPlaying:
                    nowPlayingContent
                case .queue:
                    QueueList()
                case .favorites:
                    favoritesContent
                }
            }

            footer
        }
        .padding(14)
        .frame(width: 340)
        // Fixed-width menu-bar surface: cap Dynamic Type so the large
        // accessibility sizes don't truncate the many fixed-width value
        // frames (volume readouts, zone names) into ellipses.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Now Playing", tab: .nowPlaying, symbol: "play.square")
            tabButton("Queue", tab: .queue, symbol: "list.bullet")
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
                // New identity per zone: the scrubber keeps local @State
                // (extrapolated position) that must not survive a switch —
                // without this the old zone's position shows for up to a
                // second until the next timer tick resyncs.
                .id(group.id)
            TransportRow()
            VolumeRow()
            SpeakerList(group: group, isExpanded: sectionBinding(.speakers))
            EQRow()
            ZonePicker(isExpanded: sectionBinding(.zones))
            GroupEditRow(isExpanded: sectionBinding(.group))
            SleepTimerRow(isExpanded: sectionBinding(.sleep))
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
                HStack(alignment: .top, spacing: 6) {
                    Text(error.description)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        coordinator.clearLastError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
                }
            }

            Divider()

            HStack(spacing: 4) {
                FooterIconButton(
                    systemImage: "arrow.clockwise",
                    help: "Re-scan for speakers"
                ) {
                    Task { await coordinator.refresh() }
                }

                if updates.updateAvailable, updates.verifiedManifest == nil,
                   let url = updates.releaseURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(updates.latestVersion.map { "v\($0)" } ?? "Update")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("A newer SonosBar release is available")
                }

                Spacer()

                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FooterIconButtonStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
                .keyboardShortcut(",", modifiers: [.command])

                FooterIconButton(
                    systemImage: "power",
                    help: "Quit SonosBar"
                ) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}

// MARK: - Footer buttons

private struct FooterIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(FooterIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct FooterIconButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
                    .opacity(configuration.isPressed ? 0.9 : (hovering ? 0.55 : 0))
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
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
            // Transaction animates phase changes so new art crossfades in
            // rather than popping. A load in progress shows a spinner; a
            // genuine failure shows the plain placeholder — the two are no
            // longer indistinguishable during a track change.
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    artworkPlaceholder.overlay { ProgressView().controlSize(.small) }
                case .failure:
                    artworkPlaceholder
                @unknown default:
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
            // The scrubber is a from-scratch drag control; without these,
            // VoiceOver reads nothing and cannot seek. Expose it as an
            // adjustable value that steps ±15s.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(format(dragPreview ?? localPosition)) of \(format(duration))")
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = 15
                let target: Int
                switch direction {
                case .increment: target = Int(min(localPosition + step, duration))
                case .decrement: target = Int(max(localPosition - step, 0))
                @unknown default: return
                }
                localPosition = TimeInterval(target)
                Task { await coordinator.seek(toSeconds: target) }
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

    // Guards against overlapping SOAP calls: two fast taps could otherwise
    // dispatch Play then Pause that land out of order. Mirrors the
    // in-flight pattern GroupEditRow already uses.
    @State private var busy = false

    private var isPlaying: Bool {
        (coordinator.selectedGroup.flatMap { coordinator.playback[$0.id]?.state } ?? .stopped).isActive
    }

    var body: some View {
        HStack(spacing: 0) {
            modeButton(
                systemImage: "shuffle",
                active: coordinator.selectedPlayMode.shuffle,
                help: "Shuffle"
            ) {
                Task { await coordinator.toggleShuffle() }
            }
            Spacer()
            HStack(spacing: 24) {
                transportButton(systemImage: "backward.fill", label: "Previous track") {
                    await coordinator.previous()
                }
                transportButton(systemImage: isPlaying ? "pause.fill" : "play.fill",
                                label: isPlaying ? "Pause" : "Play", size: 22) {
                    await coordinator.togglePlayPause()
                }
                transportButton(systemImage: "forward.fill", label: "Next track") {
                    await coordinator.next()
                }
            }
            Spacer()
            HStack(spacing: 2) {
                modeButton(
                    systemImage: coordinator.selectedPlayMode.repeatMode == .one ? "repeat.1" : "repeat",
                    active: coordinator.selectedPlayMode.repeatMode != .off,
                    help: coordinator.selectedPlayMode.repeatMode == .one ? "Repeat one" : "Repeat"
                ) {
                    Task { await coordinator.cycleRepeat() }
                }
                modeButton(
                    systemImage: "arrow.triangle.2.circlepath",
                    active: coordinator.selectedCrossfade,
                    help: "Crossfade"
                ) {
                    Task { await coordinator.toggleCrossfade() }
                }
            }
        }
    }

    @ViewBuilder
    private func modeButton(systemImage: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(active ? "On" : "Off")
    }

    @ViewBuilder
    private func transportButton(systemImage: String, label: String, size: CGFloat = 18,
                                 action: @escaping () async -> Void) -> some View {
        Button {
            guard !busy else { return }
            busy = true
            Task { await action(); busy = false }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(label)
        .accessibilityLabel(label)
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
            .accessibilityLabel(volume.muted ? "Unmute group" : "Mute group")

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
            .accessibilityLabel("Group volume")

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
        if group.visibleMembers.count > 1 {
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
                        ForEach(group.visibleMembers, id: \.uuid) { member in
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
                if group.visibleMembers.count > 1 {
                    Text("\(group.visibleMembers.count)")
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

// MARK: - Queue list

private struct QueueList: View {

    @Environment(SonosCoordinator.self) private var coordinator

    private var currentIndex: Int {
        coordinator.selectedGroup.flatMap { coordinator.playback[$0.id]?.track.queueIndex } ?? 0
    }

    var body: some View {
        VStack(spacing: 8) {
            if coordinator.queueLoading && coordinator.queue.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if coordinator.queue.isEmpty {
                Text("The queue is empty. Radio stations and line-in don't use the queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(coordinator.queue) { item in
                            queueRow(item)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        // Reload whenever the tab appears or the selected zone changes.
        .task(id: coordinator.selectedGroupID) {
            await coordinator.loadQueue()
        }
    }

    @ViewBuilder
    private func queueRow(_ item: QueueItem) -> some View {
        let isCurrent = item.index == currentIndex
        Button {
            Task { await coordinator.play(queueIndex: item.index) }
        } label: {
            HStack(spacing: 8) {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                } else {
                    Text("\(item.index)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 1) {
                    // Manually enqueued or line-in items can arrive with no
                    // dc:title at all — never render a blank row.
                    Text(item.title.isEmpty ? "Track \(item.index)" : item.title)
                        .font(.callout)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                    if !item.artist.isEmpty {
                        Text(item.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Group editor

/// Join/leave controls for the selected group: every visible zone with a
/// checkmark. Checked zones are in the group (tap to remove them);
/// unchecked zones are elsewhere (tap to pull them in). The group's
/// coordinator anchors the group and can't be removed here.
private struct GroupEditRow: View {

    @Environment(SonosCoordinator.self) private var coordinator
    @Binding var isExpanded: Bool
    @State private var busyUUIDs: Set<String> = []

    private struct Candidate: Identifiable {
        let member: ZoneGroupMember
        let inSelectedGroup: Bool
        let isAnchor: Bool
        var id: String { member.uuid }
    }

    private var candidates: [Candidate] {
        guard let selected = coordinator.selectedGroup else { return [] }
        var rows = selected.visibleMembers.map {
            Candidate(member: $0, inSelectedGroup: true, isAnchor: $0.uuid == selected.coordinatorUUID)
        }
        for group in coordinator.groups where group.id != selected.id {
            rows += group.visibleMembers.map {
                Candidate(member: $0, inSelectedGroup: false, isAnchor: false)
            }
        }
        // Anchor first, then alphabetical — stable while checkmarks flip.
        return rows.sorted {
            ($0.isAnchor ? 0 : 1, $0.member.zoneName) < ($1.isAnchor ? 0 : 1, $1.member.zoneName)
        }
    }

    var body: some View {
        // With a single visible zone in the household there is nothing
        // to join or remove.
        if candidates.count > 1 {
            VStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                        Text("Edit group")
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
                    VStack(spacing: 2) {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                        HStack(spacing: 8) {
                            bulkButton("Group all") {
                                Task { await coordinator.groupAll() }
                            }
                            .disabled(candidates.allSatisfy(\.inSelectedGroup))
                            bulkButton("Ungroup all") {
                                Task { await coordinator.ungroupAll() }
                            }
                            .disabled(candidates.count(where: { $0.inSelectedGroup }) <= 1)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    }
                    .padding(.bottom, 6)
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: Candidate) -> some View {
        let uuid = candidate.member.uuid
        Button {
            guard !busyUUIDs.contains(uuid) else { return }
            busyUUIDs.insert(uuid)
            Task {
                if candidate.inSelectedGroup {
                    await coordinator.removeFromGroup(memberUUID: uuid)
                } else {
                    await coordinator.joinSelectedGroup(memberUUID: uuid)
                }
                busyUUIDs.remove(uuid)
            }
        } label: {
            HStack {
                if busyUUIDs.contains(uuid) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 16)
                } else {
                    Image(systemName: candidate.inSelectedGroup ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(candidate.inSelectedGroup ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                Text(candidate.member.zoneName)
                    .font(.callout)
                Spacer()
                if candidate.isAnchor {
                    Text("this group")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(candidate.isAnchor)
    }

    @ViewBuilder
    private func bulkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
}

// MARK: - EQ

/// Collapsible bass/treble/loudness controls. Bass/treble commit on
/// drag-release (not every step) so a drag doesn't flood the speaker with
/// SetBass/SetTreble, the same rate-limit concern the volume Debouncer
/// exists for. Loudness is a single toggle.
private struct EQRow: View {

    @Environment(SonosCoordinator.self) private var coordinator
    @State private var isExpanded = false

    private var eq: EQSettings { coordinator.selectedEQ }

    var body: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    Text("EQ")
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
            .accessibilityLabel("Equalizer")

            if isExpanded {
                VStack(spacing: 6) {
                    EQSlider(label: "Bass", value: eq.bass) { v in
                        Task { await coordinator.setBass(v) }
                    }
                    EQSlider(label: "Treble", value: eq.treble) { v in
                        Task { await coordinator.setTreble(v) }
                    }
                    Toggle("Loudness", isOn: Binding(
                        get: { eq.loudness },
                        set: { v in Task { await coordinator.setLoudness(v) } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EQSlider: View {
    let label: String
    let value: Int                 // canonical value from the coordinator
    let commit: (Int) -> Void
    @State private var preview: Double?

    var body: some View {
        let shown = preview ?? Double(value)
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 52, alignment: .leading)
            Slider(
                value: Binding(get: { shown }, set: { preview = $0 }),
                in: -10...10,
                step: 1,
                onEditingChanged: { editing in
                    if !editing, let p = preview {
                        // Keep showing the released value; clearing preview
                        // here would snap the thumb back to the stale
                        // canonical value until the optimistic write lands.
                        commit(Int(p.rounded()))
                    }
                }
            )
            .controlSize(.mini)
            .accessibilityLabel(label)
            // Canonical value settled (optimistic write or rollback): drop
            // the local preview so the slider tracks the coordinator again.
            .onChange(of: value) { _, _ in preview = nil }
            Text("\(Int(shown) > 0 ? "+" : "")\(Int(shown))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .trailing)
        }
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
                    .accessibilityLabel(isPinned ? "Unpin favorite" : "Pin favorite to top")
                }

                Image(systemName: favorite.isPlayable ? "play.circle" : "slash.circle")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(favorite.isPlayable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!favorite.isPlayable)
        .help(favorite.isPlayable ? "" : "This favorite can only be played from the Sonos app")
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
