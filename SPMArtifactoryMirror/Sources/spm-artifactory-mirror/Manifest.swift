import Foundation

struct Dependency: Sendable {
    enum Source: Sendable {
        case github(GitHubRepo)
        /// A git host other than GitHub. SwiftPM fetches these directly.
        case git(String)
        case registry(String)
        case path(String)
    }

    let identity: String
    let source: Source
    let requirement: Requirement

    var summary: String {
        switch source {
        case let .github(repo): "\(repo) \(requirement)"
        case let .git(url): "\(url) \(requirement) (git)"
        case let .registry(id): "\(id) \(requirement) (registry)"
        case let .path(path): "\(identity) at \(path) (local path)"
        }
    }
}

enum Manifest {
    /// Reads a package's direct dependencies with `swift package dump-package`,
    /// which evaluates Package.swift without fetching anything.
    static func dependencies(in directory: URL, shell: Shell) throws -> [Dependency] {
        let result = try shell.run(["swift", "package", "dump-package", "--package-path", directory.path])
        guard result.succeeded else {
            throw MirrorError("could not read Package.swift:\n\(indent(result.combinedOutput))")
        }
        return try parse(Data(result.output.utf8))
    }

    static func parse(_ json: Data) throws -> [Dependency] {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let entries = root["dependencies"] as? [[String: Any]]
        else {
            throw MirrorError("unexpected dump-package output")
        }
        return entries.compactMap(parseDependency)
    }

    private static func parseDependency(_ entry: [String: Any]) -> Dependency? {
        if let sourceControl = (entry["sourceControl"] as? [[String: Any]])?.first,
           let url = remoteURL(sourceControl["location"]) {
            let source: Dependency.Source = GitHubRepo(urlString: url).map { .github($0) } ?? .git(url)
            return Dependency(
                identity: sourceControl["identity"] as? String ?? url,
                source: source,
                requirement: parseRequirement(sourceControl["requirement"]) ?? .latest
            )
        }
        if let registry = (entry["registry"] as? [[String: Any]])?.first,
           let identity = registry["identity"] as? String {
            return Dependency(
                identity: identity,
                source: .registry(identity),
                requirement: parseRequirement(registry["requirement"]) ?? .latest
            )
        }
        if let fileSystem = (entry["fileSystem"] as? [[String: Any]])?.first,
           let path = fileSystem["path"] as? String {
            return Dependency(
                identity: fileSystem["identity"] as? String ?? path,
                source: .path(path),
                requirement: .latest
            )
        }
        return nil
    }

    /// Newer toolchains write `{"remote": [{"urlString": ...}]}`, older ones `{"remote": [...]}`.
    private static func remoteURL(_ location: Any?) -> String? {
        guard let location = location as? [String: Any],
              let remote = (location["remote"] as? [Any])?.first
        else { return nil }
        if let url = remote as? String { return url }
        return (remote as? [String: Any])?["urlString"] as? String
    }

    private static func parseRequirement(_ value: Any?) -> Requirement? {
        guard let requirement = value as? [String: Any] else { return nil }
        if let range = (requirement["range"] as? [[String: Any]])?.first,
           let lower = (range["lowerBound"] as? String).flatMap({ Version($0) }),
           let upper = (range["upperBound"] as? String).flatMap({ Version($0) }) {
            return .range(lower, upper)
        }
        if let exact = (requirement["exact"] as? [String])?.first.flatMap({ Version($0) }) {
            return .exact(exact)
        }
        if let branch = (requirement["branch"] as? [String])?.first {
            return .branch(branch)
        }
        if let revision = (requirement["revision"] as? [String])?.first {
            return .revision(revision)
        }
        return nil
    }
}
