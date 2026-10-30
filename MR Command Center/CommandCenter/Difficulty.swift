import Foundation

/// A kind of file that needs a careful read even when the change is small.
nonisolated enum RiskKind: String, Codable, Sendable, CaseIterable, Comparable {
    case migration, ci, build, security, infra

    var phrase: String {
        switch self {
        case .migration: "touches a DB migration"
        case .ci: "touches CI config"
        case .build: "touches build files"
        case .security: "touches security or auth code"
        case .infra: "touches infrastructure"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// The risky kind a path belongs to, if any.
    static func of(_ path: String) -> RiskKind? {
        let lower = path.lowercased()
        let components = lower.split(separator: "/").map(String.init)
        let name = components.last ?? lower
        let directories = components.dropLast()
        let ext = (name as NSString).pathExtension

        if ext == "sql" || directories.contains(where: { ["migrations", "migration", "migrate"].contains($0) }) {
            return .migration
        }
        if name == ".gitlab-ci.yml" || name == "jenkinsfile" || name == ".travis.yml" || name == "azure-pipelines.yml"
            || name == "bitrise.yml" || lower.hasPrefix(".github/workflows/") || lower.hasPrefix(".gitlab-ci/")
            || directories.contains(".circleci") {
            return .ci
        }
        if ["package.swift", "package.json", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
            "pom.xml", "podfile", "cartfile", "makefile", "cmakelists.txt", "gemfile", "cargo.toml", "go.mod",
            "requirements.txt", "pyproject.toml", "setup.py"].contains(name)
            || ["pbxproj", "xcconfig", "csproj", "entitlements"].contains(ext) {
            return .build
        }
        if name.hasPrefix("dockerfile") || name.hasPrefix("docker-compose") || ["tf", "tfvars", "hcl"].contains(ext)
            || directories.contains(where: { ["terraform", "k8s", "kubernetes", "helm", "ansible", "infra", "infrastructure"].contains($0) }) {
            return .infra
        }
        let securityWords = ["security", "crypto", "permission", "password", "oauth", "keychain", "secret", "credential", "login"]
        if components.contains(where: { component in
            (component.contains("auth") && !component.contains("author"))
                || securityWords.contains(where: component.contains)
        }) {
            return .security
        }
        return nil
    }
}

/// What the diff says about how hard an MR is to review, worked out once per head commit.
/// Thread counts change without a push, so they're applied when scoring, not stored here.
nonisolated struct DiffFacts: Codable, Sendable, Equatable {
    /// Added plus removed lines, not counting generated and lock files.
    var linesChanged: Int
    var fileCount: Int
    var topLevelFolders: Int
    var riskKinds: [RiskKind]
    var changesSource: Bool
    var changesTests: Bool
    /// Only docs, comment lines, renames, or deleted files.
    var isSkimOnly: Bool
    /// Generated and lock files left out of the counts.
    var skippedFiles: Int

    static let lockFileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "package.resolved", "podfile.lock", "gemfile.lock",
        "cargo.lock", "composer.lock", "poetry.lock", "pipfile.lock", "go.sum", "npm-shrinkwrap.json", "flake.lock",
    ]

    static func isLockFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return lockFileNames.contains(name) || (name as NSString).pathExtension == "lock"
    }

    init(linesChanged: Int, fileCount: Int, topLevelFolders: Int = 1, riskKinds: [RiskKind] = [],
         changesSource: Bool = false, changesTests: Bool = false, isSkimOnly: Bool = false, skippedFiles: Int = 0) {
        self.linesChanged = linesChanged
        self.fileCount = fileCount
        self.topLevelFolders = topLevelFolders
        self.riskKinds = riskKinds
        self.changesSource = changesSource
        self.changesTests = changesTests
        self.isSkimOnly = isSkimOnly
        self.skippedFiles = skippedFiles
    }

    init(_ diff: MRDiff, extraTestPatterns: [String] = []) {
        let counted = diff.files.filter { !$0.isGenerated && !Self.isLockFile($0.path) }
        linesChanged = counted.reduce(0) { $0 + $1.additions + $1.deletions }
        // When GitLab stopped sending files, its own count is closer to the truth.
        let reported = diff.changesCount.flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "+"))) } ?? 0
        let skipped = diff.files.count - counted.count
        fileCount = diff.isOverflow ? max(counted.count, reported - skipped) : counted.count
        topLevelFolders = Set(counted.map { path in
            let parts = path.path.split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : ""
        }).count
        riskKinds = Set(counted.compactMap { RiskKind.of($0.path) }).sorted()
        let kinds = counted.map { TestFileClassifier.classify($0.path, extraTestPatterns: extraTestPatterns) }
        changesSource = kinds.contains(.source)
        changesTests = kinds.contains(.test)
        isSkimOnly = !diff.isOverflow && counted.allSatisfy(Self.isSkimWork)
        skippedFiles = skipped
    }

    static let docExtensions: Set<String> = ["md", "markdown", "txt", "rst", "adoc"]

    /// Docs, a deleted file, a pure rename, or a change to comment and blank lines only.
    static func isSkimWork(_ file: DiffFile) -> Bool {
        if file.change == .deleted { return true }
        if file.change == .renamed && file.additions + file.deletions == 0 && file.unavailable != .tooLarge { return true }
        let lower = file.path.lowercased()
        let directories = lower.split(separator: "/").dropLast()
        if docExtensions.contains((lower as NSString).pathExtension) || directories.contains(where: { $0 == "docs" || $0 == "doc" }) {
            return true
        }
        guard file.unavailable == nil else { return false }
        let changed = file.hunks.lazy.flatMap(\.lines).filter { $0.kind == .addition || $0.kind == .deletion }
        return !changed.isEmpty && changed.allSatisfy { isCommentOrBlank($0.text) }
    }

    static func isCommentOrBlank(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return true }
        if ["//", "/*", "*", "<!--", "--", "\"\"\""].contains(where: text.hasPrefix) { return true }
        // `#` comments, but not `#if`, `#include` or `#[derive]`.
        return text == "#" || text.hasPrefix("# ") || text.hasPrefix("##")
    }
}

/// The on-device model's read of an MR, which moves the rules' score by at most one.
nonisolated enum DifficultyFeel: String, Codable, Sendable {
    case simpler, aboutRight, harder

    var delta: Int {
        switch self {
        case .simpler: -1
        case .aboutRight: 0
        case .harder: 1
        }
    }

    var phrase: String {
        switch self {
        case .simpler: "simpler than it looks"
        case .aboutRight: "about right"
        case .harder: "harder than it looks"
        }
    }
}

nonisolated struct DifficultyNudge: Codable, Sendable, Equatable {
    var feel: DifficultyFeel
    var reason: String
}

/// How hard an MR is to review, from 1 (super easy) to 10 ("OH GEEZ"), and why.
nonisolated struct Difficulty: Equatable, Sendable {
    /// The rules' score alone.
    let ruleScore: Int
    /// The rules' score after the model's nudge.
    let score: Int
    let reasons: [String]
    let nudge: DifficultyNudge?

    static let range = 1...10

    /// Fixed for now (issue #36); to be tuned after a week of real MRs.
    enum Weights {
        /// Lines below this add nothing; `maxLinePoints` are reached at `linesForMax`.
        static let quietLines = 20
        static let linesForMax = 1_000
        static let maxLinePoints = 4.0
        static let filesForMax = 20
        static let maxFilePoints = 2.0
        static let pointsPerExtraFolder = 0.5
        static let maxFolderPoints = 1.0
        static let pointsPerRiskKind = 1.0
        static let maxRiskPoints = 2.0
        static let testsBonus = -1.0
        static let pointsPerOpenThread = 0.25
        static let pointsPerResolvedThread = 0.1
        static let maxThreadPoints = 1.0
        static let skimCap = 2
    }

    init(facts: DiffFacts, openThreads: Int, threads: Int, nudge: DifficultyNudge? = nil) {
        var points = 0.0
        var reasons: [String] = []

        let lines = facts.linesChanged
        if lines >= Weights.quietLines {
            let ratio = log(Double(lines) / Double(Weights.quietLines)) / log(Double(Weights.linesForMax) / Double(Weights.quietLines))
            points += min(Weights.maxLinePoints, Weights.maxLinePoints * ratio)
        }
        if facts.fileCount > 1 {
            points += min(Weights.maxFilePoints, Weights.maxFilePoints * log(Double(facts.fileCount)) / log(Double(Weights.filesForMax)))
        }
        let lineWord = lines == 1 ? "line" : "lines"
        let fileWord = facts.fileCount == 1 ? "file" : "files"
        reasons.append("\(lines.formatted()) \(lineWord) in \(facts.fileCount.formatted()) \(fileWord)")

        if facts.topLevelFolders > 1 {
            points += min(Weights.maxFolderPoints, Double(facts.topLevelFolders - 1) * Weights.pointsPerExtraFolder)
            reasons.append("spans \(facts.topLevelFolders) top-level folders")
        }
        if !facts.riskKinds.isEmpty {
            points += min(Weights.maxRiskPoints, Double(facts.riskKinds.count) * Weights.pointsPerRiskKind)
            reasons.append(contentsOf: facts.riskKinds.map(\.phrase))
        }
        if facts.changesSource {
            if facts.changesTests {
                points += Weights.testsBonus
                reasons.append("tests changed too")
            } else {
                reasons.append("no tests changed")
            }
        }
        let open = max(0, openThreads)
        let resolved = max(0, threads - open)
        if open + resolved > 0 {
            points += min(Weights.maxThreadPoints,
                          Double(open) * Weights.pointsPerOpenThread + Double(resolved) * Weights.pointsPerResolvedThread)
            if open > 0 { reasons.append(open == 1 ? "1 open thread" : "\(open) open threads") }
        }
        if facts.skippedFiles > 0 {
            reasons.append(facts.skippedFiles == 1 ? "1 generated or lock file not counted"
                                                   : "\(facts.skippedFiles) generated or lock files not counted")
        }

        // 0 points is a 1, 10 points (every signal at its maximum) is a 10.
        var ruleScore = Self.clamp(1 + Int((max(0, points) * 0.9).rounded()))
        if facts.isSkimOnly {
            ruleScore = min(ruleScore, Weights.skimCap)
            reasons.append("only docs, comments, renames, or deletions")
        }
        var score = Self.clamp(ruleScore + (nudge?.feel.delta ?? 0))
        if facts.isSkimOnly { score = min(score, Weights.skimCap) }
        if let nudge {
            reasons.append("Apple model: \(nudge.feel.phrase)" + (nudge.reason.isEmpty ? "" : ". \(nudge.reason)"))
        }

        self.ruleScore = ruleScore
        self.score = score
        self.reasons = reasons
        self.nudge = nudge
    }

    static func clamp(_ value: Int) -> Int { min(range.upperBound, max(range.lowerBound, value)) }

    /// The word for the hover text; the badge shows the number only.
    var word: String {
        switch score {
        case ...3: "Easy"
        case 4...6: "Medium"
        default: "Hard"
        }
    }

    /// "Difficulty 4 of 10 (Medium): 612 lines in 9 files · touches a DB migration".
    var explanation: String {
        "Difficulty \(score) of 10 (\(word)): " + reasons.joined(separator: " · ")
    }

    /// Green at 1 through amber to red at 10, as a hue for `Color(hue:…)`.
    var hue: Double { Self.hue(for: score) }

    static func hue(for score: Int) -> Double {
        let position = Double(clamp(score) - range.lowerBound) / Double(range.upperBound - range.lowerBound)
        return (1 - position) / 3
    }
}

/// How MRs are ordered inside each lane.
enum LaneOrder: String, CaseIterable, Identifiable {
    /// Lowest difficulty first; MRs not scored yet go last, newest first.
    case easiestFirst
    /// The order from before scores existed: most recently updated first.
    case newestFirst

    var id: Self { self }

    var title: String {
        switch self {
        case .easiestFirst: "Easiest First"
        case .newestFirst: "Recently Updated First"
        }
    }

    /// `mrs` arrive newest first; ties keep that order.
    func sorted(_ mrs: [TrackedMR]) -> [TrackedMR] {
        guard self == .easiestFirst else { return mrs }
        let scores = mrs.map { $0.difficulty?.score ?? Int.max }
        return mrs.indices.sorted { scores[$0] != scores[$1] ? scores[$0] < scores[$1] : $0 < $1 }.map { mrs[$0] }
    }
}

/// The prompt that asks the on-device model whether an MR is harder or simpler than its size suggests.
nonisolated enum DifficultyPrompt {
    static let maxFiles = 25
    static let sampleLinesPerFile = 4
    static let maxLineLength = 120

    static let instructions = QuoteSafety.encodeInstructions("""
    You judge how hard a merge request is to review, compared with what its size suggests. \
    You get the title and a short summary of each changed file: its path, how it changed, line counts, \
    and a few of its changed lines. Answer simpler when the change is mostly mechanical or repetitive \
    (renames, formatting, generated-looking code, config values). Answer harder when it changes tricky logic, \
    concurrency, data handling, or behavior that is easy to get subtly wrong. Otherwise answer about right. \
    Give one short sentence of reason.
    """)

    static func prompt(title: String, diff: MRDiff, ruleScore: Int) -> String {
        var lines = ["Title: \(title)", "Size-based difficulty: \(ruleScore) of 10", "Files:"]
        for file in diff.files.prefix(maxFiles) where !file.isGenerated && !DiffFacts.isLockFile(file.path) {
            lines.append("- \(file.path) (\(file.change), +\(file.additions) -\(file.deletions))")
            let samples = file.hunks.lazy.flatMap(\.lines)
                .filter { ($0.kind == .addition || $0.kind == .deletion) && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                .prefix(sampleLinesPerFile)
            for line in samples {
                let marker = line.kind == .addition ? "+" : "-"
                lines.append("    \(marker) \(line.text.trimmingCharacters(in: .whitespaces).prefix(maxLineLength))")
            }
        }
        if diff.files.count > maxFiles {
            lines.append("…and \(diff.files.count - maxFiles) more files")
        }
        return QuoteSafety.encode(lines.joined(separator: "\n"))
    }
}
