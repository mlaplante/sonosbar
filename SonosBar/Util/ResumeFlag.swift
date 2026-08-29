//
//  ResumeFlag.swift
//  SonosBar
//
//  Thread-safe once-only flag for resuming a continuation from multiple
//  state-change paths in a callback-based API (NWConnection/NWListener
//  state handlers can fire .ready and later .failed for the same
//  attempt; a continuation must resume exactly once).
//
//  Shared by EventServer, EventSubscription, and LocalAddress — one
//  definition instead of three identical private copies.
//

import Foundation

final class ResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// Returns true exactly once; every later call returns false.
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
