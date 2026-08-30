//
//  UpdateChecker.swift
//  SonosBar
//
//  Compares the running version against the newest GitHub release and
//  exposes `updateAvailable` for the footer badge. Checks once at launch
//  and every 24h after; failures are silent — an update hint is a
//  nicety, never worth an error surface.
//

import Foundation
import Observation

@MainActor
@Observable
final class UpdateChecker {

    private(set) var latestVersion: String?
    private(set) var releaseURL: URL?

    let currentVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    var updateAvailable: Bool {
        guard let latestVersion else { return false }
        return Self.version(latestVersion, isNewerThan: currentVersion)
    }

    private var pollTask: Task<Void, Never>?

    func start() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func check() async {
        guard let url = URL(string: "https://api.github.com/repos/mlaplante/sonosbar/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }

        latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/mlaplante/sonosbar/releases/latest")
    }

    /// Numeric dotted-component comparison; missing components count as 0.
    static func version(_ a: String, isNewerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
