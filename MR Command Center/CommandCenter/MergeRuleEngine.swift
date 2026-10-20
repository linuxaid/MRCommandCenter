import Foundation

/// Decides which merge rule covers an MR and whether that rule would merge it now. Pure.
enum MergeRuleEngine {
    struct Context {
        var me: String?
        var isLive: Bool
        var now: Date = .now
    }

    /// The first enabled rule (by sort order) whose filters cover the MR, with its verdict.
    static func status(for mr: TrackedMR, rules: [MergeRule], context: Context) -> RuleStatus? {
        guard let rule = rules.filter(\.isEnabled).sorted(by: { $0.sortOrder < $1.sortOrder }).first(where: { covers($0, mr, me: context.me) }) else {
            return nil
        }
        return RuleStatus(ruleID: rule.id, ruleName: rule.name, unmet: unmet(rule, mr, now: context.now), isLive: context.isLive)
    }

    /// Filters only: project, branches, labels, author.
    static func covers(_ rule: MergeRule, _ mr: TrackedMR, me: String?) -> Bool {
        guard glob(rule.projectPattern, matches: mr.projectPath),
              glob(rule.targetBranchPattern, matches: mr.targetBranch),
              glob(rule.sourceBranchPattern, matches: mr.sourceBranch) else { return false }
        let labels = Set(mr.labels.map { $0.lowercased() })
        guard rule.requiredLabels.allSatisfy({ labels.contains($0.lowercased()) }) else { return false }
        if rule.onlyMine && !mr.isAuthor { return false }
        let authors = rule.authorUsernames.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased() }
            .filter { !$0.isEmpty }
        if !authors.isEmpty && !authors.contains(mr.authorUsername.lowercased()) { return false }
        return true
    }

    /// The requirements this MR doesn't meet yet, phrased to follow "Will merge once…". Empty means "merge it".
    static func unmet(_ rule: MergeRule, _ mr: TrackedMR, now: Date = .now) -> [String] {
        let readiness = Readiness(mr)
        var unmet: [String] = []
        if !mr.hasLoadedDetails { return ["its details have loaded"] }
        if mr.isDraft { unmet.append("it's no longer a draft") }
        if mr.pipelineStatus != .success || mr.pipelineSHA != mr.headSHA {
            unmet.append("the pipeline passes on the latest commit")
        }
        if !mr.approvalsMet { unmet.append("it has \(mr.approvalsRequired) \(mr.approvalsRequired == 1 ? "approval" : "approvals")") }
        let mergeable = readiness.step(.mergeable)
        if mergeable.state == .waiting { unmet.append("GitLab finishes checking it") }
        if mergeable.state == .blocked { unmet.append("\(mergeable.summary.lowercasedFirst) is fixed") }
        if rule.requireNoOpenThreads && mr.unresolvedDiscussions > 0 { unmet.append("all threads are resolved") }
        if let status = mr.detailedMergeStatus, Readiness.blockingGitLabStatuses.contains(status),
           !["ci_must_pass", "ci_still_running", "not_approved", "discussions_not_resolved", "draft_status", "conflict"].contains(status) {
            unmet.append("GitLab allows it (\(status.replacingOccurrences(of: "_", with: " ")))")
        }
        if rule.requireChecksPass {
            let checks = MRStatusLine.checksItem(for: mr)
            if checks.tone == .negative || checks.tone == .pending { unmet.append("static checks pass") }
        }
        if rule.requireAILooksGood {
            if mr.aiVerdictRaw != VerdictStatus.looksGood.rawValue || mr.aiReviewedSHA != mr.headSHA {
                unmet.append("the AI review says it looks good")
            }
        }
        if rule.maxChangedFiles > 0 {
            if let count = mr.changesCount.flatMap(Int.init) {
                if count > rule.maxChangedFiles { unmet.append("it changes \(rule.maxChangedFiles) files or fewer") }
            } else {
                unmet.append("its size is known to be \(rule.maxChangedFiles) files or fewer")
            }
        }
        if rule.quietMinutes > 0 {
            let lastPush = mr.headChangedAt ?? mr.createdAt
            let readyAt = lastPush.addingTimeInterval(TimeInterval(rule.quietMinutes * 60))
            if readyAt > now {
                unmet.append("no one has pushed for \(rule.quietMinutes) min (at \(readyAt.formatted(date: .omitted, time: .shortened)))")
            }
        }
        return unmet
    }

    /// Case-insensitive glob where `*` matches any run of characters (including `/`) and `?` one.
    /// An empty pattern matches everything. Several patterns can be separated by commas.
    static func glob(_ pattern: String, matches value: String) -> Bool {
        let alternatives = pattern.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !alternatives.isEmpty else { return true }
        let target = Array(value.lowercased())
        return alternatives.contains { globMatch(Array($0.lowercased()), target) }
    }

    private static func globMatch(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0
        var star: Int?
        var mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1; t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; mark = t; p += 1
            } else if let star {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
