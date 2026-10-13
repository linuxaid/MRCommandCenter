import Foundation

struct MirrorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Config: Sendable {
    static let defaultArtifactoryBase = "https://artifactory.us.bank-dns.com/artifactory"
    static let defaultArchiveTemplate = "{artifactory}/{remote}/{owner}/{repo}/archive/refs/tags/{tag}.zip"
    static let defaultTagsTemplate = "{artifactory}/{remote}/{owner}/{repo}/tags.atom"

    var artifactoryBase: URL
    var githubRemote: String
    var archiveTemplate: String
    var tagsTemplate: String
    var swiftVirtual: String
    var swiftLocal: String
    var maxRounds: Int
    var listOnly: Bool
    var promptForLogin: Bool
    var verbosity: Logger.Level
    var packageDirectory: URL

    var virtualRegistryURL: URL { artifactoryBase.appending(path: "api/swift/\(swiftVirtual)") }
    var localRegistryURL: URL { artifactoryBase.appending(path: "api/swift/\(swiftLocal)") }

    func archiveURL(for repo: GitHubRepo, tag: String) throws -> URL {
        try fill(archiveTemplate, repo: repo, tag: tag)
    }

    func tagsFeedURL(for repo: GitHubRepo) throws -> URL {
        try fill(tagsTemplate, repo: repo, tag: nil)
    }

    private func fill(_ template: String, repo: GitHubRepo, tag: String?) throws -> URL {
        func encoded(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
        }
        var base = artifactoryBase.absoluteString
        while base.hasSuffix("/") { base.removeLast() }

        var text = template
            .replacingOccurrences(of: "{artifactory}", with: base)
            .replacingOccurrences(of: "{remote}", with: githubRemote)
            .replacingOccurrences(of: "{owner}", with: encoded(repo.owner))
            .replacingOccurrences(of: "{repo}", with: encoded(repo.repo))
        if let tag {
            text = text.replacingOccurrences(of: "{tag}", with: encoded(tag))
        }
        guard let url = URL(string: text) else { throw MirrorError("invalid URL: \(text)") }
        return url
    }

    static let usage = """
        Usage: spm-artifactory-mirror [options] <package-directory>

        Walks a Swift package's dependency tree by reading each Package.swift, downloads
        every GitHub-hosted dependency through an Artifactory remote that proxies
        github.com, and publishes it to an Artifactory Swift local repository. Finishes
        by checking that `swift package resolve --replace-scm-with-registry` succeeds.

        Options (environment variable in brackets):
          --list-only              Print the dependency tree; publish nothing, change nothing
          -v, --verbose            Show every download, command and decision
          -vvv, --debug            Also show full command output and run SwiftPM with -vvv
          --login                  Prompt for an Artifactory username and token

          --artifactory <url>      Artifactory base URL                     [ART_BASE]
                                   default: \(defaultArtifactoryBase)
          --github-remote <key>    Artifactory remote that proxies github.com [GITHUB_REMOTE] default: github
          --virtual <key>          Swift virtual repo to resolve against    [SWIFT_VIRTUAL] default: omni-swift
          --local <key>            Swift local repo to publish to           [SWIFT_LOCAL]   default: omni-swift-local
          --max-rounds <n>         Resolve attempts before giving up        [MAX_ROUNDS]    default: 5
          --archive-url <template> Source zip URL                           [ARCHIVE_URL]
                                   default: \(defaultArchiveTemplate)
          --tags-url <template>    Tag feed URL                             [TAGS_URL]
                                   default: \(defaultTagsTemplate)
          -h, --help               Show this help

        Templates can use {artifactory}, {remote}, {owner}, {repo} and {tag}.
        Runs anonymously by default. To log in to Artifactory, set ART_USER and
        ART_TOKEN, or pass --login to be prompted.
        """

    static func parse(_ arguments: [String], environment env: [String: String]) throws -> Config {
        var base = env["ART_BASE"] ?? defaultArtifactoryBase
        var githubRemote = env["GITHUB_REMOTE"] ?? "github"
        var archiveTemplate = env["ARCHIVE_URL"] ?? defaultArchiveTemplate
        var tagsTemplate = env["TAGS_URL"] ?? defaultTagsTemplate
        var virtual = env["SWIFT_VIRTUAL"] ?? "omni-swift"
        var local = env["SWIFT_LOCAL"] ?? "omni-swift-local"
        var maxRounds = env["MAX_ROUNDS"] ?? "5"
        var listOnly = false
        var promptForLogin = false
        var verbosity = Logger.Level.normal
        var packagePath: String?

        var remaining = arguments[...]
        func value(for flag: String) throws -> String {
            guard let value = remaining.popFirst() else { throw MirrorError("\(flag) needs a value") }
            return value
        }

        while let argument = remaining.popFirst() {
            switch argument {
            case "--list-only": listOnly = true
            case "--login": promptForLogin = true
            case "-v", "--verbose": verbosity = max(verbosity, .verbose)
            case "-vv", "-vvv", "--debug": verbosity = .debug
            case "--artifactory": base = try value(for: argument)
            case "--github-remote": githubRemote = try value(for: argument)
            case "--archive-url": archiveTemplate = try value(for: argument)
            case "--tags-url": tagsTemplate = try value(for: argument)
            case "--virtual": virtual = try value(for: argument)
            case "--local": local = try value(for: argument)
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
        guard archiveTemplate.contains("{tag}") else {
            throw MirrorError("--archive-url must contain {tag}")
        }
        guard let maxRoundCount = Int(maxRounds), maxRoundCount >= 1 else {
            throw MirrorError("--max-rounds must be 1 or more")
        }

        return Config(
            artifactoryBase: artifactoryBase,
            githubRemote: githubRemote,
            archiveTemplate: archiveTemplate,
            tagsTemplate: tagsTemplate,
            swiftVirtual: virtual,
            swiftLocal: local,
            maxRounds: maxRoundCount,
            listOnly: listOnly,
            promptForLogin: promptForLogin,
            verbosity: verbosity,
            packageDirectory: packageDirectory
        )
    }
}
