struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Accepts "1.2.3", "v1.2.3" and "1.2" (as 1.2.0), like SwiftPM does for tags.
    /// Build metadata ("+abc") is ignored.
    init?(_ text: String) {
        let pattern = #/v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.\-]+))?(?:\+[0-9A-Za-z.\-]+)?/#
        guard let match = text.wholeMatch(of: pattern),
              let major = Int(match.output.1),
              let minor = Int(match.output.2)
        else { return nil }
        let patch = match.output.3.flatMap { Int($0) } ?? 0
        let prerelease = match.output.4.map { $0.split(separator: ".").map(String.init) } ?? []
        self.init(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// Tag names a project might have used for this version, most likely first.
    var tagCandidates: [String] {
        var tags = [description, "v\(description)"]
        if patch == 0 && prerelease.isEmpty {
            tags += ["\(major).\(minor)", "v\(major).\(minor)"]
        }
        return tags
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A release sorts above its own prereleases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

enum Requirement: Hashable, Sendable, CustomStringConvertible {
    case range(Version, Version)
    case exact(Version)
    case branch(String)
    case revision(String)
    /// No requirement known (a package found only in resolve output).
    case latest

    func allows(_ version: Version) -> Bool {
        switch self {
        case let .range(lower, upper):
            guard version >= lower && version < upper else { return false }
            return !version.isPrerelease || lower.isPrerelease || upper.isPrerelease
        case let .exact(exact):
            return version == exact
        case .latest:
            return !version.isPrerelease
        case .branch, .revision:
            return false
        }
    }

    /// The version to try when no listed tag satisfies the requirement.
    var minimumVersion: Version? {
        switch self {
        case let .range(lower, _): lower
        case let .exact(exact): exact
        case .branch, .revision, .latest: nil
        }
    }

    var isPinnedToCommit: Bool {
        switch self {
        case .branch, .revision: true
        default: false
        }
    }

    var description: String {
        switch self {
        case let .range(lower, upper): "\(lower)..<\(upper)"
        case let .exact(exact): "exactly \(exact)"
        case let .branch(branch): "branch \(branch)"
        case let .revision(revision): "revision \(revision)"
        case .latest: "newest"
        }
    }
}
