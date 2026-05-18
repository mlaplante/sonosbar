//
//  Debouncer.swift
//  SonosBar
//
//  Coalesces high-frequency calls (volume slider drags, scroll events)
//  into one trailing-edge invocation. Sonos rate-limits aggressively
//  when you flood it with SetVolume — Menu Bar Controller's reviews
//  document them hitting this and having to throttle.
//
//  Behaviour: while events keep arriving, the action is deferred. Once
//  `interval` passes without a new event, the most recent payload fires.
//
//  Usage:
//      let d = Debouncer<Int>(interval: .milliseconds(120))
//      await d.submit(newVolume) { v in
//          try? await transport.setVolume(v, on: player)
//      }
//

import Foundation

actor Debouncer<Payload: Sendable> {

    private let interval: Duration
    private var pendingPayload: Payload?
    private var firingTask: Task<Void, Never>?

    init(interval: Duration) {
        self.interval = interval
    }

    /// Stash the latest payload and schedule a fire. If a fire is already
    /// scheduled it stays — only the payload it operates on changes.
    func submit(_ payload: Payload, action: @escaping @Sendable (Payload) async -> Void) {
        pendingPayload = payload
        if firingTask == nil {
            // Capture interval before the detached Task — reading it
            // from inside the Task would require hopping back onto the
            // actor and produces a needless await.
            let interval = self.interval
            firingTask = Task { [weak self] in
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.fire(action: action)
            }
        }
    }

    private func fire(action: @Sendable (Payload) async -> Void) async {
        let payload = pendingPayload
        pendingPayload = nil
        firingTask = nil
        if let payload {
            await action(payload)
        }
    }

    /// Cancel any pending fire without invoking the action.
    func cancel() {
        firingTask?.cancel()
        firingTask = nil
        pendingPayload = nil
    }
}
