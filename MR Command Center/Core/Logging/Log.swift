import Foundation
import os

/// Central loggers. Never log tokens, diff content, or prompt text; mark identifiers `.private`.
nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.weinnotes.MRCommandCenter"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
