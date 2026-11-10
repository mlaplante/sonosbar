//
//  ConnectivityMonitor.swift
//  SonosBar
//
//  Tells the coordinator when the world under it may have changed:
//    * the Mac woke from sleep (GENA subscriptions may have lapsed, and
//      renewal timers all fire at once into a network that isn't up yet);
//    * the network path changed (Wi-Fi switch, Ethernet plugged in, new
//      DHCP lease) — the callback address the speakers hold may be dead.
//
//  Triggers are debounced and only delivered once the path is satisfied,
//  so a wake that lands before Wi-Fi reassociates is held until the
//  network is actually usable instead of being wasted on a dead link.
//

import AppKit
import Foundation
import Network

@MainActor
final class ConnectivityMonitor {

    enum Trigger: Sendable {
        case wake
        case networkChange

        /// A wake must force a full resubscribe; a path change only needs one
        /// if our address moved. Merging keeps the stronger of the two.
        func merged(with other: Trigger?) -> Trigger {
            (self == .wake || other == .wake) ? .wake : .networkChange
        }
    }

    private let settleDelay: Duration
    private let pathMonitor = NWPathMonitor()
    private var wakeObserver: (any NSObjectProtocol)?
    private var handler: (@MainActor (Trigger) -> Void)?

    private var pathSatisfied = false
    private var sawInitialPath = false
    private var pendingTrigger: Trigger?
    private var settleTask: Task<Void, Never>?

    init(settleDelay: Duration = .seconds(3)) {
        self.settleDelay = settleDelay
    }

    func start(handler: @escaping @MainActor (Trigger) -> Void) {
        stop()
        self.handler = handler

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main,
            using: Self.makeWakeHandler(self)
        )
        pathMonitor.pathUpdateHandler = Self.makePathHandler(self)
        pathMonitor.start(queue: DispatchQueue(label: "app.sonosbar.path-monitor", qos: .utility))
    }

    func stop() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        pathMonitor.pathUpdateHandler = nil
        settleTask?.cancel()
        settleTask = nil
        pendingTrigger = nil
        handler = nil
    }

    // MARK: - Callback factories
    //
    // Formed in nonisolated context on purpose: a closure literal written
    // inside this @MainActor class inherits main-actor isolation, and
    // NWPathMonitor invokes its handler on our private queue — the runtime
    // isolation check would trap. These hop to the main actor explicitly.

    private nonisolated static func makeWakeHandler(
        _ monitor: ConnectivityMonitor
    ) -> @Sendable (Notification) -> Void {
        { [weak monitor] _ in
            Task { @MainActor in monitor?.noteWake() }
        }
    }

    private nonisolated static func makePathHandler(
        _ monitor: ConnectivityMonitor
    ) -> @Sendable (NWPath) -> Void {
        { [weak monitor] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in monitor?.notePath(satisfied: satisfied) }
        }
    }

    // MARK: - Debounce

    private func noteWake() {
        Log.app.info("Mac woke from sleep")
        enqueue(.wake)
    }

    private func notePath(satisfied: Bool) {
        pathSatisfied = satisfied
        // NWPathMonitor reports the current path immediately on start;
        // bootstrap already handles that state, so only later changes count.
        guard sawInitialPath else {
            sawInitialPath = true
            return
        }
        Log.app.info("Network path changed (satisfied: \(satisfied))")
        enqueue(.networkChange)
    }

    private func enqueue(_ trigger: Trigger) {
        pendingTrigger = trigger.merged(with: pendingTrigger)
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self, settleDelay] in
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled else { return }
            self?.deliverIfReady()
        }
    }

    private func deliverIfReady() {
        // Not satisfied yet: keep the pending trigger. The path update that
        // brings the network back re-enters enqueue() and delivers it.
        guard pathSatisfied, let trigger = pendingTrigger else { return }
        pendingTrigger = nil
        handler?(trigger)
    }
}
