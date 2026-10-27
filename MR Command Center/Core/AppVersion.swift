import Foundation

/// The app's version, which is also its release tag (`yy.m.d`, set by `scripts/claude/set-version.sh`).
nonisolated enum AppVersion {
    /// `CFBundleShortVersionString`, or nil if it's missing or blank.
    static func version(from info: [String: Any]?) -> String? {
        guard let version = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces),
              !version.isEmpty else { return nil }
        return version
    }

    static var current: String? { version(from: Bundle.main.infoDictionary) }
}
