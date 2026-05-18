//
//  Log.swift
//  SonosBar
//
//  Thin wrapper over os.Logger so every subsystem logs with a consistent
//  bundle id and category. Using os.Logger (not print) means logs end up
//  in Console.app with proper filtering and don't slow down release builds.
//

import Foundation
import os

enum Log {
    private static let subsystem = "app.sonosbar.SonosBar"

    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let events    = Logger(subsystem: subsystem, category: "events")
    static let domain    = Logger(subsystem: subsystem, category: "domain")
    static let ui        = Logger(subsystem: subsystem, category: "ui")
    static let app       = Logger(subsystem: subsystem, category: "app")
}
