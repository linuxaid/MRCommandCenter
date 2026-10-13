import Foundation

struct MirrorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Config: Sendable {
    static let defaultArtifactoryBase = "https://artifactory-uat.us.bank-dns.com/artifactory"

    var artifactoryBase: URL
    var swiftVirtual: String
    var swiftLocal: String
    var vcsRemote: String
    var maxVersions: Int
    var includePrereleases: Bool
    var maxRounds: Int
    var packageDirectory: URL

    var virtualRegistryURL: URL { artifactoryBase.appending(path: "api/swift/\(swiftVirtual)") }
    var localRegistryURL: URL { artifactoryBase.appending(path: "api/swift/\(swiftLocal)") }

    static let usage = """
        Usage: spm-artifactory-mirror [options] <package-directory>

        Publishes every GitHub-hosted dependency of a Swift package (direct and
        transitive) into an Artifactory Swift local repository, fetching from
        GitHub only through an Artifactory VCS remote repository. Repeats
        `swift package resolve --replace-scm-with-registry` until it succeeds.

        Options (environment variable in brackets):
          --artifactory <url>      Artifactory base URL            [ART_BASE]
                                   default: \(defaultArtifactoryBase)
          --virtual <key>          Swift virtual repo to resolve   [SWIFT_VIRTUAL]  default: omni-swift
          --local <key>            Swift local repo to publish to  [SWIFT_LOCAL]    default: omni-swift-local
          --vcs-remote <key>       VCS remote repo for GitHub      [VCS_REMOTE]     default: omni-github-vcs
          --max-versions <n>       Newest n versions per package, 0 = all [MAX_VERSIONS] default: 0
          --include-prereleases    Also publish prerelease tags    [INCLUDE_PRERELEASES=1]
          --max-rounds <n>         Give up after n resolve rounds  [MAX_ROUNDS]     default: 15
          -h, --help               Show this help

        Credentials come from ART_USER and ART_TOKEN, or you are prompted.
        """

    static func parse(_ arguments: [String], environment env: [String: String]) throws -> Config {
        var base = env["ART_BASE"] ?? defaultArtifactoryBase
        var virtual = env["SWIFT_VIRTUAL"] ?? "omni-swift"
        var local = env["SWIFT_LOCAL"] ?? "omni-swift-local"
        var vcs = env["VCS_REMOTE"] ?? "omni-github-vcs"
        var maxVersions = env["MAX_VERSIONS"] ?? "0"
        var includePrereleases = env["INCLUDE_PRERELEASES"] == "1"
        var maxRounds = env["MAX_ROUNDS"] ?? "15"
        var packagePath: String?

        var remaining = arguments[...]
        func value(for flag: String) throws -> String {
            guard let value = remaining.popFirst() else { throw MirrorError("\(flag) needs a value") }
            return value
        }

        while let argument = remaining.popFirst() {
            switch argument {
            case "--artifactory": base = try value(for: argument)
            case "--virtual": virtual = try value(for: argument)
            case "--local": local = try value(for: argument)
            case "--vcs-remote": vcs = try value(for: argument)
            case "--max-versions": maxVersions = try value(for: argument)
            case "--include-prereleases": includePrereleases = true
            case "--max-rounds": maxRounds = try value(for: argument)
            case _ where argument.hasPrefix("-"):
                throw MirrorError("unknown option \(argument)\n\n\(usage)")
            default:
                guard packagePath == nil else { throw MirrorError("only one package directory is allowed") }
                packagePath = argument
            }
        }

        guard let packagePath else { throw MirrorError("missing package directory\n\n\(usage)") }
        let packageDirectory = URL(fileURLWithPath: packagePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: packageDirectory.appending(path: "Package.swift").path) else {
            throw MirrorError("no Package.swift in \(packageDirectory.path)")
        }
        guard let artifactoryBase = URL(string: base), artifactoryBase.host() != nil else {
            throw MirrorError("invalid Artifactory URL: \(base)")
        }
        guard let maxVersionCount = Int(maxVersions), maxVersionCount >= 0 else {
            throw MirrorError("--max-versions must be 0 or more")
        }
        guard let maxRoundCount = Int(maxRounds), maxRoundCount >= 1 else {
            throw MirrorError("--max-rounds must be 1 or more")
        }

        return Config(
            artifactoryBase: artifactoryBase,
            swiftVirtual: virtual,
            swiftLocal: local,
            vcsRemote: vcs,
            maxVersions: maxVersionCount,
            includePrereleases: includePrereleases,
            maxRounds: maxRoundCount,
            packageDirectory: packageDirectory
        )
    }
}
