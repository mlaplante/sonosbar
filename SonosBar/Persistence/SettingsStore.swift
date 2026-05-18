//
//  SettingsStore.swift
//  SonosBar
//
//  Persists user preferences and last-seen state across launches.
//
//  Two distinct concerns colocated here:
//    1. User-tweakable preferences (launch at login, show title in
//       menu bar, hotkey config). Stored under stable keys.
//    2. Operational cache (last-selected group ID, last-known speaker
//       IPs for discovery fallback). Also stable keys but treated as
//       "soft" — corruption or staleness just degrades, never fails.
//
//  Backed by UserDefaults because the data is small (<1KB) and writes
//  are infrequent. Anything larger would warrant SwiftData or a real
//  file, but for "did the user enable launch at login" UserDefaults is
//  the canonical choice.
//

import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {

    // MARK: - Preferences

    private static let defaults = UserDefaults.standard

    /// Whether SonosBar starts at login. The actual SMAppService toggle
    /// happens in LaunchAtLogin; this property mirrors the desired
    /// state so the UI can bind to it.
    var launchAtLogin: Bool {
        didSet {
            Self.defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            LaunchAtLogin.set(enabled: launchAtLogin)
        }
    }

    /// Show the current track title next to the menu bar icon.
    /// Many users find this cluttered; off by default.
    var showTitleInMenuBar: Bool {
        didSet {
            Self.defaults.set(showTitleInMenuBar, forKey: Key.showTitleInMenuBar)
        }
    }

    /// Restore the previously-selected zone group on launch.
    var rememberLastZone: Bool {
        didSet {
            Self.defaults.set(rememberLastZone, forKey: Key.rememberLastZone)
        }
    }

    // MARK: - Operational cache

    /// Last selected group ID, used to restore selection on next launch.
    var lastSelectedGroupID: String? {
        didSet {
            if let id = lastSelectedGroupID {
                Self.defaults.set(id, forKey: Key.lastSelectedGroupID)
            } else {
                Self.defaults.removeObject(forKey: Key.lastSelectedGroupID)
            }
        }
    }

    /// Cache of speaker UUID → host IP. Used by discovery as a fallback
    /// when SSDP fails (e.g. flaky multicast on a busy WiFi network).
    /// We can directly poll these IPs to confirm they're still valid
    /// Sonos devices.
    private(set) var lastKnownHosts: [String: String]

    func recordHost(uuid: String, host: String) {
        lastKnownHosts[uuid] = host
        Self.defaults.set(lastKnownHosts, forKey: Key.lastKnownHosts)
    }

    func forgetHost(uuid: String) {
        lastKnownHosts.removeValue(forKey: uuid)
        Self.defaults.set(lastKnownHosts, forKey: Key.lastKnownHosts)
    }

    /// Set of favorite URIs the user has pinned to the top of the
    /// Favorites tab. Persisted so pins survive relaunches. We key on
    /// the URI (not title) because titles can drift if a service
    /// renames a station.
    private(set) var pinnedFavoriteURIs: Set<String>

    func togglePinned(favoriteURI uri: String) {
        if pinnedFavoriteURIs.contains(uri) {
            pinnedFavoriteURIs.remove(uri)
        } else {
            pinnedFavoriteURIs.insert(uri)
        }
        Self.defaults.set(Array(pinnedFavoriteURIs), forKey: Key.pinnedFavoriteURIs)
    }

    func isPinned(favoriteURI uri: String) -> Bool {
        pinnedFavoriteURIs.contains(uri)
    }

    // MARK: - Init

    init() {
        // Read existing values with sensible defaults.
        self.launchAtLogin       = Self.defaults.bool(forKey: Key.launchAtLogin)
        self.showTitleInMenuBar  = Self.defaults.bool(forKey: Key.showTitleInMenuBar)
        // rememberLastZone defaults to true (the helpful behaviour).
        self.rememberLastZone    = (Self.defaults.object(forKey: Key.rememberLastZone) as? Bool) ?? true
        self.lastSelectedGroupID = Self.defaults.string(forKey: Key.lastSelectedGroupID)
        self.lastKnownHosts      = (Self.defaults.dictionary(forKey: Key.lastKnownHosts) as? [String: String]) ?? [:]
        let pinnedArray = (Self.defaults.array(forKey: Key.pinnedFavoriteURIs) as? [String]) ?? []
        self.pinnedFavoriteURIs  = Set(pinnedArray)
    }

    private enum Key {
        static let launchAtLogin       = "settings.launchAtLogin"
        static let showTitleInMenuBar  = "settings.showTitleInMenuBar"
        static let rememberLastZone    = "settings.rememberLastZone"
        static let lastSelectedGroupID = "cache.lastSelectedGroupID"
        static let lastKnownHosts      = "cache.lastKnownHosts"
        static let pinnedFavoriteURIs  = "settings.pinnedFavoriteURIs"
    }
}
