//
//  ReconnectPolicy.swift
//  SonosBar
//
//  Pure decision logic for recovering event subscriptions after the Mac
//  sleeps, roams networks, or a speaker stops answering renewals. Kept
//  free of I/O so the parser-test harness can pin the rules down.
//

import Foundation

enum ReconnectPolicy {

    /// Delay before re-subscribe attempt `attempt` (0-based) after a GENA
    /// renewal failed: 5s, 10s, 20s, 40s, then every 60s until it works or
    /// the subscription is torn down. A menu bar app runs for days, so
    /// giving up after one try (the old behaviour) left the UI frozen
    /// until relaunch.
    static func resubscribeDelay(attempt: Int) -> Duration {
        let capped = min(max(attempt, 0), 4)
        return .seconds(min(5 * (1 << capped), 60))
    }

    /// Whether every subscription must be torn down and re-created.
    ///
    /// - force: the Mac just woke (subscriptions may have lapsed while
    ///   asleep) or the user hit Re-scan.
    /// - The callback address the speakers were given no longer matches the
    ///   address they'd reach us at now (Wi-Fi switch, new DHCP lease):
    ///   renewals would keep "succeeding" while every NOTIFY goes to a dead
    ///   address.
    /// - Nothing is subscribed at all (e.g. launched before the network was up).
    ///
    /// Returns false when we can't currently determine our address: tearing
    /// down live subscriptions without being able to re-create them only
    /// makes things worse.
    static func needsResubscribe(
        force: Bool,
        previousCallbackHost: String?,
        currentCallbackHost: String?,
        hasLiveSubscriptions: Bool
    ) -> Bool {
        guard currentCallbackHost != nil else { return false }
        if force || !hasLiveSubscriptions { return true }
        return previousCallbackHost != currentCallbackHost
    }
}
