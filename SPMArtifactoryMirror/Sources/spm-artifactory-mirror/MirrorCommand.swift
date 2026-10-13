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
        for tool in ["swift", "unzip"] {
            guard try Shell.run(["which", tool]).succeeded else { throw MirrorError("\(tool) not found") }
        }
        let credentials = try Credentials.load(environment: environment)

        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appending(path: "spm-mirror-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let netrc = workDirectory.appending(path: "netrc")
        try credentials.writeNetrc(to: netrc, host: config.artifactoryBase.host() ?? "")

        let mirror = Mirror(
            config: config,
            client: ArtifactoryClient(config: config, authorization: credentials.basicAuthorization),
            netrc: netrc,
            workDirectory: workDirectory
        )
        try await mirror.run()
    }
}
