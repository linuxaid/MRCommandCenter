import Foundation

@main
struct MirrorCommand {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("-h") || arguments.contains("--help") {
            print(Config.usage)
            return
        }

        let environment = ProcessInfo.processInfo.environment
        let config = try Config.parse(arguments, environment: environment)
        let logger = Logger(level: config.verbosity)
        let shell = Shell(logger: logger)
        for tool in ["swift", "unzip"] {
            guard try shell.run(["which", tool]).succeeded else { throw MirrorError("\(tool) not found") }
        }
        // Anonymous unless credentials are provided: Artifactory rejects
        // requests carrying credentials it doesn't accept.
        let credentials = config.promptForLogin
            ? try Credentials.load(environment: environment)
            : Credentials.fromEnvironment(environment)
        logger.verbose(credentials.map { "credentials: user \($0.user)" } ?? "credentials: none, running anonymously")

        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appending(path: "spm-mirror-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }
        logger.verbose("working directory: \(workDirectory.path)")

        var netrc: URL?
        if let credentials {
            let file = workDirectory.appending(path: "netrc")
            try credentials.writeNetrc(to: file, host: config.artifactoryBase.host() ?? "")
            netrc = file
        }

        let mirror = Mirror(
            config: config,
            client: ArtifactoryClient(config: config, credentials: credentials, logger: logger),
            shell: shell,
            logger: logger,
            netrc: netrc,
            workDirectory: workDirectory
        )
        try await mirror.run()
    }
}
