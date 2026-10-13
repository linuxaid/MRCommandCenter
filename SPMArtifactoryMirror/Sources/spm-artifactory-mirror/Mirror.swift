import Foundation

/// Walks the dependency tree by reading each Package.swift, mirrors every
/// GitHub-hosted version into the Swift local repo, then checks that the
/// package resolves through the Swift virtual repo.
actor Mirror {
    private struct Pending {
        let dependency: Dependency
        let parent: String
    }

    private struct ListedTag {
        let tag: String
        let version: Version
    }

    private struct Source {
        let tag: String
        let version: Version
        let archive: Data
    }

    let config: Config
    let client: ArtifactoryClient
    let shell: Shell
    let logger: Logger
    /// nil when running without credentials.
    let netrc: URL?
    let workDirectory: URL

    private var queue: [Pending] = []
    private var stepCount = 0
    /// "<package>|<requirement>" → tree node it resolved to.
    private var nodeForRequest: [String: String] = [:]
    /// Package versions whose manifests have been read.
    private var crawled = Set<String>()
    private var crawledRepos = Set<String>()
    private var tagCache: [String: [ListedTag]] = [:]
    private var children: [String: [String]] = [:]

    private var published: [String] = []
    private var alreadyPublished: [String] = []
    private var otherHosts: [String] = []
    private var problems: [String] = []

    init(config: Config, client: ArtifactoryClient, shell: Shell, logger: Logger, netrc: URL?, workDirectory: URL) {
        self.config = config
        self.client = client
        self.shell = shell
        self.logger = logger
        self.netrc = netrc
        self.workDirectory = workDirectory
    }

    private var rootName: String { config.packageDirectory.lastPathComponent }
    private var packagePath: String { config.packageDirectory.path }
    private var swiftVerbosity: [String] { logger.isDebug ? ["-vvv"] : [] }
    private var netrcArguments: [String] { netrc.map { ["--netrc-file", $0.path] } ?? [] }

    func run() async throws {
        logger.step("Package: \(packagePath)")
        logger.info("GitHub source zips: \(config.archiveTemplate)")
        logger.info("GitHub tag lists:   \(config.tagsTemplate)")
        if config.listOnly {
            logger.info("List only: nothing is published and the package isn't changed")
        } else {
            logger.info("Publishing to:      \(config.localRegistryURL.absoluteString)")
            logger.info("Resolving against:  \(config.virtualRegistryURL.absoluteString)")
        }

        logger.step("Reading \(rootName)/Package.swift")
        let dependencies = try Manifest.dependencies(in: config.packageDirectory, shell: shell)
        describe(dependencies)
        enqueue(dependencies, parent: rootName)
        await crawl()

        printTree()
        defer { printSummary() }
        guard !config.listOnly else { return }

        try prepareForResolve()
        try await verify()
    }

    // MARK: - Walking the tree

    private func enqueue(_ dependencies: [Dependency], parent: String) {
        queue += dependencies.map { Pending(dependency: $0, parent: parent) }
    }

    private func crawl() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            switch item.dependency.source {
            case let .github(repo):
                await processGitHub(repo, requirement: item.dependency.requirement, parent: item.parent)
            case let .git(url):
                processGit(url, requirement: item.dependency.requirement, parent: item.parent)
            case let .registry(identity):
                addEdge(from: item.parent, to: "\(identity) \(item.dependency.requirement) (registry)")
                logger.verbose("\(identity) is a registry package; Artifactory serves it as is")
            case let .path(path):
                processPath(path, identity: item.dependency.identity, parent: item.parent)
            }
        }
    }

    private func processGitHub(_ repo: GitHubRepo, requirement: Requirement, parent: String) async {
        let requestKey = "\(repo.key)|\(requirement)"
        if let node = nodeForRequest[requestKey] {
            addEdge(from: parent, to: node)
            logger.verbose("\(repo) \(requirement), needed by \(parent): already handled as \(node)")
            return
        }

        stepCount += 1
        logger.step("[\(stepCount)] \(repo)  \(requirement), needed by \(parent)")

        if requirement.isPinnedToCommit {
            let node = "\(repo) (\(requirement))"
            nodeForRequest[requestKey] = node
            addEdge(from: parent, to: node)
            problem("\(repo): \(parent) pins it to \(requirement); a registry can only serve tagged versions")
            return
        }

        // Skip the download when the version this would pick was already read.
        if let best = await listedTags(of: repo).first(where: { requirement.allows($0.version) }),
           crawled.contains("\(repo.key)@\(best.version)") {
            let node = "\(repo) \(best.version)"
            nodeForRequest[requestKey] = node
            addEdge(from: parent, to: node)
            logger.info("using \(best.version), already handled above")
            return
        }

        guard let source = await fetchSource(repo, requirement: requirement) else {
            let node = "\(repo) (\(requirement), not found)"
            nodeForRequest[requestKey] = node
            addEdge(from: parent, to: node)
            problem("\(repo): no tag satisfying \(requirement) could be downloaded")
            return
        }

        let node = "\(repo) \(source.version)"
        nodeForRequest[requestKey] = node
        addEdge(from: parent, to: node)
        crawledRepos.insert(repo.key)
        guard crawled.insert("\(repo.key)@\(source.version)").inserted else {
            logger.info("\(source.version) was already handled above")
            return
        }

        let directory = workDirectory.appending(path: "src/\(repo.identity)/\(source.version)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let packageRoot = try unpack(source.archive, into: directory)
            let dependencies = try Manifest.dependencies(in: packageRoot, shell: shell)
            describe(dependencies)
            enqueue(dependencies, parent: node)
            if !config.listOnly {
                try await publish(repo, version: source.version, packageRoot: packageRoot, directory: directory)
            }
        } catch {
            problem("\(node): \(error)")
        }
    }

    /// Picks the newest tag in tags.atom that satisfies the requirement. If
    /// none does (the feed only lists 10 tags), falls back to the lowest
    /// version the requirement allows, trying the usual tag spellings.
    private func fetchSource(_ repo: GitHubRepo, requirement: Requirement) async -> Source? {
        let listed = await listedTags(of: repo)

        var candidates: [(tag: String, version: Version, reason: String)] = []
        if let best = listed.first(where: { requirement.allows($0.version) }) {
            candidates.append((best.tag, best.version, "newest listed tag that satisfies \(requirement)"))
        } else if !listed.isEmpty {
            logger.info("none of the listed tags satisfies \(requirement)")
        }
        if let minimum = requirement.minimumVersion {
            for tag in minimum.tagCandidates where !candidates.contains(where: { $0.tag == tag }) {
                candidates.append((tag, minimum, "lowest version allowed by \(requirement)"))
            }
        }

        for candidate in candidates {
            logger.verbose("trying tag \(candidate.tag): \(candidate.reason)")
            do {
                guard let archive = try await client.downloadArchive(of: repo, tag: candidate.tag) else {
                    logger.verbose("tag \(candidate.tag) doesn't exist")
                    continue
                }
                logger.info("using \(candidate.version) (tag \(candidate.tag)): \(candidate.reason)")
                logger.info("downloaded source zip, \(formatBytes(archive.count))")
                return Source(tag: candidate.tag, version: candidate.version, archive: archive)
            } catch {
                logger.warn("downloading tag \(candidate.tag) failed: \(error)")
            }
        }
        return nil
    }

    private func listedTags(of repo: GitHubRepo) async -> [ListedTag] {
        if let cached = tagCache[repo.key] { return cached }

        var listed: [ListedTag] = []
        do {
            let tags = try await client.listedTags(of: repo)
            listed = tags
                .compactMap { tag in Version(tag).map { ListedTag(tag: tag, version: $0) } }
                .sorted { $0.version > $1.version }
            let newest = listed.first.map { ", newest \($0.version)" } ?? ""
            logger.info("tags.atom lists \(tags.count) tag(s)\(newest)")
            if logger.isVerbose && !tags.isEmpty {
                logger.verbose("tags: \(tags.joined(separator: ", "))")
            }
        } catch {
            logger.warn("couldn't read tags.atom (\(error)); falling back to the lowest allowed version")
        }
        tagCache[repo.key] = listed
        return listed
    }

    /// Non-GitHub git hosts aren't published: SwiftPM fetches them directly.
    /// Their manifests are still read so their GitHub dependencies get mirrored.
    private func processGit(_ url: String, requirement: Requirement, parent: String) {
        let requestKey = "\(url.lowercased())|\(requirement)"
        if let node = nodeForRequest[requestKey] {
            addEdge(from: parent, to: node)
            return
        }

        stepCount += 1
        logger.step("[\(stepCount)] \(url)  \(requirement), needed by \(parent)")
        logger.info("not on GitHub: SwiftPM fetches this with git directly, so it isn't published")

        let directory = workDirectory.appending(path: "git/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let noPrompt = ["GIT_TERMINAL_PROMPT": "0"]

        do {
            let ref: String
            let label: String
            switch requirement {
            case let .branch(branch):
                ref = branch
                label = "branch \(branch)"
            case .revision:
                throw MirrorError("can't read a manifest at a specific revision; its dependencies won't be mirrored")
            case .range, .exact, .latest:
                let lsRemote = try shell.run(["git", "ls-remote", "--tags", "--refs", url], environment: noPrompt)
                guard lsRemote.succeeded else {
                    throw MirrorError("git can't reach it:\n\(indent(lsRemote.combinedOutput))")
                }
                let tags = lsRemote.output.split(separator: "\n").compactMap { line -> ListedTag? in
                    guard let ref = line.split(separator: "\t").last, ref.hasPrefix("refs/tags/") else { return nil }
                    let tag = String(ref.dropFirst("refs/tags/".count))
                    return Version(tag).map { ListedTag(tag: tag, version: $0) }
                }
                guard let best = tags.filter({ requirement.allows($0.version) }).max(by: { $0.version < $1.version }) else {
                    throw MirrorError("no tag satisfies \(requirement)")
                }
                ref = best.tag
                label = best.version.description
                logger.info("using \(best.version) (tag \(best.tag)), the newest tag that satisfies \(requirement)")
            }

            let node = "\(url) \(label) (git)"
            nodeForRequest[requestKey] = node
            addEdge(from: parent, to: node)
            guard crawled.insert("\(url.lowercased())@\(ref)").inserted else { return }

            let clone = try shell.run(
                ["git", "clone", "--quiet", "--depth", "1", "--branch", ref, url, directory.path],
                environment: noPrompt
            )
            guard clone.succeeded else {
                throw MirrorError("git clone failed:\n\(indent(clone.combinedOutput))")
            }
            otherHosts.append("\(url) \(label)")
            let dependencies = try Manifest.dependencies(in: directory, shell: shell)
            describe(dependencies)
            enqueue(dependencies, parent: node)
        } catch {
            if nodeForRequest[requestKey] == nil {
                let node = "\(url) (\(requirement), unreadable)"
                nodeForRequest[requestKey] = node
                addEdge(from: parent, to: node)
            }
            problem("\(url): \(error)")
        }
    }

    private func processPath(_ path: String, identity: String, parent: String) {
        let node = "\(identity) (local path)"
        addEdge(from: parent, to: node)
        guard crawled.insert("path:\(path)").inserted else { return }

        stepCount += 1
        logger.step("[\(stepCount)] \(identity)  local package at \(path), needed by \(parent)")
        do {
            let dependencies = try Manifest.dependencies(in: URL(fileURLWithPath: path), shell: shell)
            describe(dependencies)
            enqueue(dependencies, parent: node)
        } catch {
            problem("\(identity): \(error)")
        }
    }

    // MARK: - Publishing

    private func unpack(_ archive: Data, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let extracted = directory.appending(path: "extract")
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)

        let zip = directory.appending(path: "source.zip")
        try archive.write(to: zip)
        let unzip = try shell.run(["unzip", "-q", zip.path, "-d", extracted.path])
        guard unzip.succeeded else {
            throw MirrorError("could not unzip:\n\(indent(unzip.combinedOutput))")
        }

        // GitHub zips wrap the source in one top-level folder.
        if fileManager.fileExists(atPath: extracted.appending(path: "Package.swift").path) {
            return extracted
        }
        let folders = (try? fileManager.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)) ?? []
        guard let root = folders.first(where: { fileManager.fileExists(atPath: $0.appending(path: "Package.swift").path) }) else {
            throw MirrorError("no Package.swift at this tag")
        }
        return root
    }

    private func publish(_ repo: GitHubRepo, version: Version, packageRoot: URL, directory: URL) async throws {
        let label = "\(repo.identity) \(version)"
        if await client.isPublished(repo, version: version) {
            alreadyPublished.append(label)
            logger.info("already in \(config.swiftLocal)")
            return
        }

        let metadata = directory.appending(path: "metadata.json")
        try repo.metadataJSON().write(to: metadata)
        logger.info("publishing \(label) to \(config.swiftLocal)…")

        let result = try shell.run([
            "swift", "package-registry", "publish", repo.identity, version.description,
            "--url", config.localRegistryURL.absoluteString,
            "--package-path", packageRoot.path,
            "--metadata-path", metadata.path,
            "--scratch-directory", directory.appending(path: "scratch").path,
        ] + netrcArguments + swiftVerbosity)
        guard result.succeeded else {
            var message = "publish failed:\n\(indent(result.combinedOutput))"
            if netrc == nil && result.combinedOutput.contains("401") {
                message += "\n      Artifactory wants a login to publish: set ART_USER and ART_TOKEN, or run with --login."
            }
            throw MirrorError(message)
        }
        published.append(label)
        logger.info("published")
    }

    // MARK: - Checking the result

    private func prepareForResolve() throws {
        logger.step("Pointing \(rootName) at \(config.swiftVirtual)")
        let set = try shell.run([
            "swift", "package-registry", "set", config.virtualRegistryURL.absoluteString,
            "--package-path", packagePath,
        ])
        guard set.succeeded else {
            throw MirrorError("swift package-registry set failed:\n\(indent(set.combinedOutput))")
        }
        logger.info("registry set in .swiftpm/configuration/registries.json")

        let fileManager = FileManager.default
        let resolved = config.packageDirectory.appending(path: "Package.resolved")
        if fileManager.fileExists(atPath: resolved.path) {
            let backup = config.packageDirectory.appending(path: "Package.resolved.bak")
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: resolved, to: backup)
            logger.info("moved Package.resolved to Package.resolved.bak")
        }

        let reset = try shell.run(["swift", "package", "reset", "--package-path", packagePath])
        guard reset.succeeded else {
            throw MirrorError("swift package reset failed:\n\(indent(reset.combinedOutput))")
        }
        logger.info("cleared .build so nothing stale is reused")
    }

    /// Resolves through Artifactory. If SwiftPM still needs GitHub packages the
    /// manifests didn't lead to, mirrors those and tries again.
    private func verify() async throws {
        for round in 1...config.maxRounds {
            logger.step("Checking: swift package resolve --replace-scm-with-registry (attempt \(round) of \(config.maxRounds))")
            let start = Date()
            let result = try shell.run([
                "swift", "package", "resolve",
                "--package-path", packagePath,
                "--replace-scm-with-registry",
            ] + netrcArguments + swiftVerbosity)

            if result.succeeded {
                logger.info("resolved in \(formatSeconds(since: start))")
                printResolvedPins()
                return
            }

            let missed = GitHubRepo.extract(fromLog: result.combinedOutput)
                .filter { !crawledRepos.contains($0.key) }
                .sorted()
            guard !missed.isEmpty else {
                reportStuck(resolveOutput: result.combinedOutput)
                throw MirrorError("resolve still fails and there are no new GitHub packages to publish")
            }

            logger.info("resolve failed; SwiftPM still wants \(missed.count) GitHub package(s) the manifests didn't lead to:")
            for repo in missed {
                logger.info("  \(repo)")
            }
            enqueue(
                missed.map { Dependency(identity: $0.repo, source: .github($0), requirement: .latest) },
                parent: "swift package resolve"
            )
            await crawl()
        }
        throw MirrorError("still not resolving after \(config.maxRounds) attempts")
    }

    private func printResolvedPins() {
        let url = config.packageDirectory.appending(path: "Package.resolved")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = json["pins"] as? [[String: Any]]
        else { return }

        logger.info("Package.resolved now pins \(pins.count) package(s):")
        for pin in pins {
            let identity = pin["identity"] as? String ?? "?"
            let state = pin["state"] as? [String: Any]
            let version = state?["version"] as? String ?? state?["branch"] as? String ?? "?"
            let kind = (pin["kind"] as? String) == "registry" ? "from Artifactory" : "via git: \(pin["location"] as? String ?? "?")"
            logger.info("  \(identity) \(version) (\(kind))")
        }
    }

    // MARK: - Reporting

    private func describe(_ dependencies: [Dependency]) {
        guard !dependencies.isEmpty else {
            logger.info("no dependencies")
            return
        }
        logger.info("depends on:")
        for dependency in dependencies {
            logger.info("  - \(dependency.summary)")
        }
    }

    private func addEdge(from parent: String, to child: String) {
        if !(children[parent] ?? []).contains(child) {
            children[parent, default: []].append(child)
        }
    }

    private func problem(_ message: String) {
        problems.append(message)
        logger.warn(message)
    }

    /// The tree goes to stdout so `--list-only` output can be saved or piped.
    private func printTree() {
        logger.step("Dependency tree")
        let children = self.children
        var lines = [rootName]
        var expanded = Set<String>()

        func walk(_ node: String, prefix: String, ancestors: Set<String>) {
            let nodes = children[node] ?? []
            for (index, child) in nodes.enumerated() {
                let isLast = index == nodes.count - 1
                let hasChildren = !(children[child] ?? []).isEmpty
                var line = prefix + (isLast ? "└─ " : "├─ ") + child
                if ancestors.contains(child) {
                    line += " (cycle)"
                } else if hasChildren && expanded.contains(child) {
                    line += " (see above)"
                }
                lines.append(line)
                if !ancestors.contains(child) && expanded.insert(child).inserted {
                    walk(child, prefix: prefix + (isLast ? "   " : "│  "), ancestors: ancestors.union([child]))
                }
            }
        }
        walk(rootName, prefix: "", ancestors: [rootName])
        // Written unbuffered so it lands before the summary on stderr.
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func printSummary() {
        logger.step("Summary")
        logger.info("GitHub packages found: \(crawledRepos.count) (\(crawled.count) package version(s) read)")
        if !config.listOnly {
            logger.info("Published to \(config.swiftLocal): \(published.count)")
            for label in published {
                logger.info("  + \(label)")
            }
            logger.info("Already in \(config.swiftLocal): \(alreadyPublished.count)")
            for label in alreadyPublished {
                logger.verbose("\(label)")
            }
        }
        if !otherHosts.isEmpty {
            logger.info("From other hosts (SwiftPM fetches these with git; not published):")
            for label in otherHosts {
                logger.info("  - \(label)")
            }
        }
        if problems.isEmpty {
            logger.info("Problems: none")
        } else {
            logger.warn("Problems: \(problems.count)")
            for message in problems {
                logger.info("  - \(message)")
            }
        }
    }

    private func reportStuck(resolveOutput: String) {
        let lastLines = resolveOutput.split(separator: "\n", omittingEmptySubsequences: false).suffix(40)
        logger.warn("resolve failed. Last lines of its output:")
        logger.info(indent(lastLines.joined(separator: "\n"), by: "  "))
        logger.info("""
            Common causes:
                  - A manifest pins a dependency with branch: or revision: (see Problems).
                  - A .binaryTarget(url:) downloads from a blocked host.
                  - A version failed to publish (see Problems).
                  - Two packages need versions of the same dependency that only exist outside
                    the 10 tags in tags.atom. Run again with -v to see which versions were chosen.
            """)
    }
}
