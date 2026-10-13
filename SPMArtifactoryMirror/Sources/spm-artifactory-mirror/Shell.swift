import Foundation

struct CommandResult {
    let status: Int32
    let output: String
    let errorOutput: String

    var succeeded: Bool { status == 0 }

    var combinedOutput: String {
        [output, errorOutput]
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct Shell: Sendable {
    let logger: Logger

    /// Runs a command found on PATH. Stdout and stderr are captured separately
    /// so JSON on stdout (dump-package) isn't mixed with warnings.
    func run(_ arguments: [String], environment extra: [String: String] = [:]) throws -> CommandResult {
        logger.verbose("$ " + arguments.map(Self.quoted).joined(separator: " "))
        let start = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if !extra.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        }

        let stdout = Pipe()
        process.standardOutput = stdout

        // A file rather than a second pipe, so a chatty stderr can't fill a
        // pipe buffer and stall the process while stdout is being read.
        let fileManager = FileManager.default
        let stderrURL = fileManager.temporaryDirectory.appending(path: "spm-mirror-stderr-\(UUID().uuidString)")
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? fileManager.removeItem(at: stderrURL) }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardError = stderr

        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? stderr.close()
        let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()

        let result = CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            errorOutput: String(decoding: errorData, as: UTF8.self)
        )
        logger.verbose("  exit \(result.status) after \(formatSeconds(since: start))")
        if logger.isDebug && !result.combinedOutput.isEmpty {
            logger.debug(indent(result.combinedOutput))
        }
        return result
    }

    private static func quoted(_ argument: String) -> String {
        argument.contains(where: { $0 == " " || $0 == "\"" }) ? "\"\(argument)\"" : argument
    }
}
