//
//  LaunchAtLogin.swift
//  SonosBar
//
//  SMAppService.mainApp is the post-deprecation way to register an app
//  to launch at login. The older SMLoginItemSetEnabled and helper-bundle
//  dance are both deprecated as of macOS 13.
//
//  We register the main app itself (not a separate helper) because
//  SonosBar is already an LSUIElement agent — there's no Dock icon to
//  hide on relaunch, which was the original reason to use a helper.
//
//  Caveat: SMAppService can throw "operation not permitted" if the app
//  isn't signed (or is only ad-hoc signed) and isn't in /Applications.
//  We catch that and surface a hint via Log; the user sees the toggle
//  flip back to off and can re-try after moving the app.
//

import Foundation
import ServiceManagement

enum LaunchAtLogin {

    /// Current status — useful to reconcile UI state after a launch
    /// without trusting the persisted preference.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggle launch-at-login. Failures are logged, not thrown — the
    /// settings UI just observes isEnabled afterwards.
    static func set(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    Log.app.info("Registered SonosBar for launch at login")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    Log.app.info("Unregistered SonosBar from launch at login")
                }
            }
        } catch {
            Log.app.error("LaunchAtLogin toggle failed: \(error.localizedDescription). Is the app in /Applications and signed?")
        }
    }
}
