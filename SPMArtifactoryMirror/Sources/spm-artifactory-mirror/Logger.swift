import Foundation

/// Progress goes to stderr so `--list-only` output on stdout can be piped.
struct Logger: Sendable {
    enum Level: Int, Comparable, Sendable {
        case normal, verbose, debug

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let level: Level

    var isVerbose: Bool { level >= .verbose }
    var isDebug: Bool { level >= .debug }

    /// A new stage or package.
    func step(_ message: String) { write("==> \(message)") }

    /// Detail under the current step.
    func info(_ message: String) { write("    \(message)") }

    func warn(_ message: String) { write("    ! \(message)") }

    /// Shown with -v: downloads, commands, decisions.
    func verbose(_ message: String) {
        if isVerbose { write("    · \(message)") }
    }

    /// Shown with -vvv: full command output.
    func debug(_ message: String) {
        if isDebug { write(message) }
    }

    private func write(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

func indent(_ text: String, by prefix: String = "      ") -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { prefix + $0 }
        .joined(separator: "\n")
}

func formatBytes(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

func formatSeconds(since start: Date) -> String {
    String(format: "%.1fs", Date().timeIntervalSince(start))
}
