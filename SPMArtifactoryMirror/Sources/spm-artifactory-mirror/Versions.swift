struct ReleaseTag: Equatable, Sendable {
    let tag: String
    let version: String
}

enum Versions {
    /// Turns git tags into registry versions, newest first. Accepts "1.2.3",
    /// "v1.2.3" and "1.2" (published as 1.2.0), like SwiftPM does.
    static func pick(from tags: [String], max: Int, includePrereleases: Bool) -> [ReleaseTag] {
        let pattern = #/v?(\d+)\.(\d+)(?:\.(\d+))?(-[0-9A-Za-z.\-]+)?(\+[0-9A-Za-z.\-]+)?/#

        var found: [String: (key: SortKey, tag: String)] = [:]
        for tag in tags {
            guard let match = tag.wholeMatch(of: pattern) else { continue }
            let (_, majorText, minorText, patchText, prerelease, _) = match.output
            if prerelease != nil && !includePrereleases { continue }
            guard let major = Int(majorText), let minor = Int(minorText) else { continue }
            let patch = patchText.flatMap { Int($0) } ?? 0
            let suffix = prerelease.map(String.init) ?? ""
            let version = "\(major).\(minor).\(patch)\(suffix)"
            if found[version] == nil {
                found[version] = (SortKey(major: major, minor: minor, patch: patch, prerelease: suffix), tag)
            }
        }

        var releases = found
            .sorted { $0.value.key > $1.value.key }
            .map { ReleaseTag(tag: $0.value.tag, version: $0.key) }
        if max > 0 {
            releases = Array(releases.prefix(max))
        }
        return releases
    }

    private struct SortKey: Comparable {
        let major: Int
        let minor: Int
        let patch: Int
        let prerelease: String

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            // A release sorts above its own prereleases.
            (lhs.major, lhs.minor, lhs.patch, lhs.prerelease.isEmpty ? 1 : 0, lhs.prerelease)
                < (rhs.major, rhs.minor, rhs.patch, rhs.prerelease.isEmpty ? 1 : 0, rhs.prerelease)
        }
    }
}
