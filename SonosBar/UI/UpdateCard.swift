//
//  UpdateCard.swift
//  SonosBar
//
//  The in-popover update surface. Lives INSIDE the popover on purpose:
//  SonosBar is LSUIElement, and detached windows in agent apps are a
//  known source of unreachable-window bugs. Shown only when there is
//  something to say — a verified update, progress, or a failure.
//

import SwiftUI

struct UpdateCard: View {

    @Environment(UpdateChecker.self) private var updates
    @Environment(UpdateInstaller.self) private var installer

    var body: some View {
        if let manifest = updates.verifiedManifest {
            card(manifest)
        } else if installer.lastUpdateFailureNote != nil {
            lastFailureCard()
        }
    }

    /// Surfaces a helper-recorded failure from the previous launch. Shown
    /// only while there is no active update flow — a fresh verified
    /// manifest (handled above) always supersedes this stale note.
    @ViewBuilder
    private func lastFailureCard() -> some View {
        HStack {
            Text("The last update didn't complete.")
                .font(.caption2)
            Spacer()
            Button("OK") {
                installer.clearLastUpdateFailureNote()
            }
            .font(.caption2)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func card(_ manifest: UpdateManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch installer.state {
            case .idle:
                HStack {
                    Text("SonosBar \(manifest.version) is available")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Link("Notes", destination: manifest.releaseNotesURL)
                        .font(.caption2)
                    Button("Install") {
                        Task { await installer.install(manifest: manifest) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            case .working(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.caption)
                }
            case .refused(let refusal):
                // Refusal is soft: explain, and offer the manual path.
                Text(refusal.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Link("Download from GitHub", destination: manifest.releaseNotesURL)
                        .font(.caption2)
                    Button("Try Again") {
                        Task { await installer.install(manifest: manifest) }
                    }
                    .font(.caption2)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                HStack {
                    Link("Download from GitHub", destination: manifest.releaseNotesURL)
                        .font(.caption2)
                    Button("Try Again") {
                        Task { await installer.install(manifest: manifest) }
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
