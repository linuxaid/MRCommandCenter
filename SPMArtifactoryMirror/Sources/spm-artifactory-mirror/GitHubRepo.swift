import Foundation

struct GitHubRepo: Hashable, Comparable, Sendable, CustomStringConvertible {
    let owner: String
    let repo: String

    init(owner: String, repo: String) {
        var repo = repo
        while repo.hasSuffix(".") || repo.hasSuffix("/") { repo.removeLast() }
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        self.owner = owner
        self.repo = repo
    }

    /// Parses https, ssh and scp-style GitHub URLs. Returns nil for other hosts.
    init?(urlString: String) {
        let pattern = #/(?:https?://|ssh://git@|git@)(?:www\.)?github\.com[/:]([A-Za-z0-9_.\-]+)/([A-Za-z0-9_.\-]+?)(?:\.git)?/?/#
        guard let match = urlString.wholeMatch(of: pattern) else { return nil }
        self.init(owner: String(match.output.1), repo: String(match.output.2))
    }

    var url: String { "https://github.com/\(owner)/\(repo)" }
    var description: String { "\(owner)/\(repo)" }

    /// GitHub names are case-insensitive, so two spellings are one package.
    var key: String { description.lowercased() }

    /// Registry identities allow [A-Za-z0-9-] in the scope and [A-Za-z0-9_-] in the name.
    var scope: String { Self.sanitize(owner, keeping: "-", replacement: "-") }
    var name: String { Self.sanitize(repo, keeping: "_-", replacement: "_") }
    var identity: String { "\(scope).\(name)" }

    /// Metadata sent with each publish. The repository URLs let Artifactory map
    /// a manifest's GitHub URL to this registry package.
    func metadataJSON() throws -> Data {
        struct Metadata: Encodable {
            let repositoryURLs: [String]
            let description: String
        }
        let metadata = Metadata(
            repositoryURLs: [url, url + ".git", "git@github.com:\(owner)/\(repo).git"],
            description: "Mirrored from \(url)"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(metadata)
    }

    /// GitHub repositories mentioned in SwiftPM output, such as failed git fetches.
    static func extract(fromLog log: String) -> Set<GitHubRepo> {
        let https = #/https://github\.com/([A-Za-z0-9_.\-]+)/([A-Za-z0-9_.\-]+)/#
        let ssh = #/git@github\.com:([A-Za-z0-9_.\-]+)/([A-Za-z0-9_.\-]+)/#

        var repos = Set<GitHubRepo>()
        for match in log.matches(of: https) {
            repos.insert(GitHubRepo(owner: String(match.output.1), repo: String(match.output.2)))
        }
        for match in log.matches(of: ssh) {
            repos.insert(GitHubRepo(owner: String(match.output.1), repo: String(match.output.2)))
        }
        return repos.filter { !$0.repo.isEmpty }
    }

    static func < (lhs: GitHubRepo, rhs: GitHubRepo) -> Bool {
        lhs.key < rhs.key
    }

    private static func sanitize(_ text: String, keeping allowed: String, replacement: Character) -> String {
        String(text.map { character in
            let isAlphanumeric = character.isASCII && (character.isLetter || character.isNumber)
            return isAlphanumeric || allowed.contains(character) ? character : replacement
        })
    }
}

enum TagsFeed {
    /// Tag names from a GitHub tags.atom feed, newest first. GitHub lists
    /// only the 10 most recent tags.
    static func tags(fromAtom xml: String) -> [String] {
        let link = #/releases/tag/([^"<>\s]+)"/#
        var tags: [String] = []
        for match in xml.matches(of: link) {
            let raw = String(match.output.1).replacingOccurrences(of: "&amp;", with: "&")
            let tag = raw.removingPercentEncoding ?? raw
            if !tags.contains(tag) {
                tags.append(tag)
            }
        }
        return tags
    }
}
