import os

/// Lightweight wrapper around `os.Logger` for TrackNotch.
///
/// Usage:
///   TNLog.debug("msg", category: .auth)
///   TNLog.info("[OpenAI] Cost changed", category: .provider)
///   TNLog.warn("Keychain error: \(status)", category: .auth)
///   TNLog.error("Unexpected nil", category: .display)
///
/// In Console.app, filter by subsystem `com.tracknotch.app`
/// and optionally by category (auth, display, monitor, provider, ui).
enum TNLog {
    static let subsystem = "com.tracknotch.app"

    enum Category: String {
        case auth     = "auth"
        case display  = "display"
        case monitor  = "monitor"
        case provider = "provider"
        case ui       = "ui"
    }

    private static func logger(for category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    static func debug(_ message: String, category: Category) {
        logger(for: category).debug("\(message, privacy: .public)")
    }

    static func info(_ message: String, category: Category) {
        logger(for: category).info("\(message, privacy: .public)")
    }

    static func warn(_ message: String, category: Category) {
        logger(for: category).warning("\(message, privacy: .public)")
    }

    static func error(_ message: String, category: Category) {
        logger(for: category).error("\(message, privacy: .public)")
    }
}
