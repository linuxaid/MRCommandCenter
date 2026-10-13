import Foundation

struct CommandResult {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
}

enum Shell {
    /// Runs a command found on PATH, with stdout and stderr combined.
    static func run(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("==> \(message)\n".utf8))
}

func indent(_ text: String, by prefix: String = "      ") -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { prefix + $0 }
        .joined(separator: "\n")
}
