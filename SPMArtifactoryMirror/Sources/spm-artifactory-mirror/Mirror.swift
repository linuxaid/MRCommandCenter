import Foundation

/// Resolves the package against the Swift virtual repo, publishes whatever
/// GitHub packages SwiftPM couldn't find there, and repeats. Each round
/// uncovers the next layer of transitive dependencies.
struct Mirror {
    let config: Config
    let client: ArtifactoryClient
    let netrc: URL
    let workDirectory: URL

    private var packagePath: String { config.packageDirectory.path }

    func run() async throws {
        log("Package:  \(packagePath)")
        log("Registry: \(config.virtualRegistryURL.absoluteString)")
        log("Publish:  \(config.localRegistryURL.absoluteString)")
        try prepare()

        var seen = Set<GitHubRepo>()
        for round in 1...config.maxRounds {
            log("Round \(round): resolving")
            let result = try Shell.run([
                "swift", "package", "resolve",
                "--package-path", packagePath,
                "--replace-scm-with-registry",
                "--netrc-file", netrc.path,
            ])
            if result.succeeded {
                log("Resolved. Every dependency is now available from \(config.swiftVirtual).")
                return
            }

            let found = GitHubRepo.extract(fromLog: result.output)
            let new = found.subtracting(seen).sorted()
            guard !new.isEmpty else {
                reportStuck(resolveOutput: result.output)
                throw MirrorError("resolve still fails and there are no new GitHub packages to publish")
            }

            for repo in new {
                await mirror(repo)
            }
            seen.formUnion(found)
        }
        throw MirrorError("gave up after \(config.maxRounds) rounds")
    }

    private func prepare() throws {
        let set = try Shell.run([
            "swift", "package-registry", "set", config.virtualRegistryURL.absoluteString,
            "--package-path", packagePath,
        ])
        guard set.succeeded else {
            throw MirrorError("swift package-registry set failed:\n\(indent(set.output))")
        }

        let fileManager = FileManager.default
        let resolved = config.packageDirectory.appending(path: "Package.resolved")
        if fileManager.fileExists(atPath: resolved.path) {
            let backup = config.packageDirectory.appending(path: "Package.resolved.bak")
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: resolved, to: backup)
            log("Moved existing Package.resolved to Package.resolved.bak")
        }

        let reset = try Shell.run(["swift", "package", "reset", "--package-path", packagePath])
        guard reset.succeeded else {
            throw MirrorError("swift package reset failed:\n\(indent(reset.output))")
        }
    }

    private func mirror(_ repo: GitHubRepo) async {
        log("Mirroring github.com/\(repo.owner)/\(repo.repo) as \(repo.identity)")

        let tags: [String]
        do {
            tags = try await client.listTags(owner: repo.owner, repo: repo.repo)
        } catch {
            log("  could not list tags through \(config.vcsRemote), skipping: \(error)")
            return
        }

        let releases = Versions.pick(from: tags, max: config.maxVersions, includePrereleases: config.includePrereleases)
        guard !releases.isEmpty else {
            log("  no version tags found (a registry can only serve tagged versions), skipping")
            return
        }

        for release in releases {
            if await client.versionExists(scope: repo.scope, name: repo.name, version: release.version) {
                log("  \(release.version): already published")
                continue
            }
            do {
                try await publish(repo, release)
                log("  \(release.version): published")
            } catch {
                log("  \(release.version): \(error)")
            }
        }
    }

    private func publish(_ repo: GitHubRepo, _ release: ReleaseTag) async throws {
        let fileManager = FileManager.default
        let directory = workDirectory.appending(path: "src/\(repo.identity)/\(release.version)")
        let extracted = directory.appending(path: "extract")
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let zip = directory.appending(path: "source.zip")
        try await client.downloadTag(owner: repo.owner, repo: repo.repo, tag: release.tag).write(to: zip)

        let unzip = try Shell.run(["unzip", "-q", zip.path, "-d", extracted.path])
        guard unzip.succeeded else { throw MirrorError("could not unzip, skipping") }

        guard let packageRoot = findPackageRoot(in: extracted) else {
            throw MirrorError("no Package.swift at this tag, skipping")
        }

        let metadata = directory.appending(path: "metadata.json")
        try repo.metadataJSON().write(to: metadata)

        let result = try Shell.run([
            "swift", "package-registry", "publish", repo.identity, release.version,
            "--url", config.localRegistryURL.absoluteString,
            "--package-path", packageRoot.path,
            "--metadata-path", metadata.path,
            "--scratch-directory", directory.appending(path: "scratch").path,
            "--netrc-file", netrc.path,
        ])
        guard result.succeeded else {
            throw MirrorError("publish failed:\n\(indent(result.output))")
        }
    }

    /// GitHub zips wrap the source in a single top-level folder.
    private func findPackageRoot(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appending(path: "Package.swift").path) {
            return directory
        }
        let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.first { fileManager.fileExists(atPath: $0.appending(path: "Package.swift").path) }
    }

    private func reportStuck(resolveOutput: String) {
        let lastLines = resolveOutput.split(separator: "\n", omittingEmptySubsequences: false).suffix(40)
        log("Last resolve output:")
        FileHandle.standardError.write(Data((lastLines.joined(separator: "\n") + "\n").utf8))
        FileHandle.standardError.write(Data("""

            Common causes:
              - A manifest pins a dependency with branch: or revision: instead of a version.
              - A .binaryTarget(url:) downloads from a blocked host.
              - A dependency is hosted somewhere other than GitHub.
              - A required version failed to publish (see above), or --max-versions excluded it.

            """.utf8))
    }
}
