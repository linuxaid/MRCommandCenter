import Foundation

/// The MR facts the metadata checks need, as a value so checks are pure and testable.
nonisolated struct MRCheckInput: Sendable, Equatable {
    var headSHA: String
    var hasLoadedDetails: Bool
    var pipelineStatus: PipelineStatus?
    var pipelineSHA: String?
    var approvalsGiven: Int
    var approvalsRequired: Int
    var hasConflicts: Bool
    var isDraft: Bool
    var unresolvedDiscussions: Int
    var jiraKey: String?
    var jiraLookup: JiraLookup?
    var jiraStatus: String?
    var jiraPassing: Bool?
    var jiraPriority: String?
    var jiraHasPriority: Bool?
    var jiraError: String?
}

extension MRCheckInput {
    init(_ mr: TrackedMR) {
        self.init(
            headSHA: mr.headSHA, hasLoadedDetails: mr.hasLoadedDetails,
            pipelineStatus: mr.pipelineStatus, pipelineSHA: mr.pipelineSHA,
            approvalsGiven: mr.approvalsGiven, approvalsRequired: mr.approvalsRequired,
            hasConflicts: mr.hasConflicts, isDraft: mr.isDraft,
            unresolvedDiscussions: mr.unresolvedDiscussions, jiraKey: mr.jiraKey,
            jiraLookup: mr.jiraLookup, jiraStatus: mr.jiraStatus, jiraPassing: mr.jiraPassing,
            jiraPriority: mr.jiraPriority, jiraHasPriority: mr.jiraHasPriority, jiraError: mr.jiraError
        )
    }
}

/// Zero-cost checks run before the model. Metadata checks use cached MR fields and are
/// recomputed whenever those change; diff checks are computed once per head SHA.
nonisolated enum StaticChecks {
    // MARK: Metadata checks

    static func metadataChecks(_ mr: MRCheckInput) -> [CheckResult] {
        [pipeline(mr), jira(mr), priority(mr), approvals(mr), conflicts(mr), draft(mr), discussions(mr)]
    }

    static func pipeline(_ mr: MRCheckInput) -> CheckResult {
        let title = "Pipeline passed on head commit"
        guard mr.hasLoadedDetails else {
            return CheckResult(id: .pipeline, outcome: .pending, title: title, detail: "Loading pipeline status…")
        }
        guard let status = mr.pipelineStatus else {
            return CheckResult(id: .pipeline, outcome: .warning, title: title, detail: "No pipeline has run for this merge request.")
        }
        let onHead = mr.pipelineSHA == nil || mr.pipelineSHA == mr.headSHA
        switch status {
        case .success where onHead:
            return CheckResult(id: .pipeline, outcome: .pass, title: title, detail: "Passed on \(mr.headSHA.prefix(8)).")
        case .success:
            return CheckResult(id: .pipeline, outcome: .warning, title: title,
                               detail: "Passed on \(mr.pipelineSHA?.prefix(8) ?? "an older commit"), not the head commit \(mr.headSHA.prefix(8)).")
        case .failed:
            return CheckResult(id: .pipeline, outcome: .fail, title: title, detail: "The pipeline failed.")
        case _ where status.isActive:
            return CheckResult(id: .pipeline, outcome: .pending, title: title, detail: "The pipeline is still running.")
        case .manual:
            return CheckResult(id: .pipeline, outcome: .warning, title: title, detail: "The pipeline is waiting on a manual job.")
        default:
            return CheckResult(id: .pipeline, outcome: .warning, title: title, detail: "The pipeline is \(status.rawValue).")
        }
    }

    static func jira(_ mr: MRCheckInput) -> CheckResult {
        let title = "Jira issue in a passing status"
        guard let key = mr.jiraKey else {
            return CheckResult(id: .jira, outcome: .warning, title: title, detail: "No Jira key found in the branch name.")
        }
        switch mr.jiraLookup {
        case nil:
            return CheckResult(id: .jira, outcome: .pending, title: title, detail: "\(key): checking Jira…")
        case .notConfigured:
            return CheckResult(id: .jira, outcome: .pending, title: title, detail: "\(key): status not checked (Jira isn't connected).")
        case .notFound:
            return CheckResult(id: .jira, outcome: .fail, title: title, detail: "\(key) wasn't found in Jira, or the token can't see it.")
        case .failed:
            return CheckResult(id: .jira, outcome: .warning, title: title, detail: "\(key): couldn't check Jira (\(mr.jiraError ?? "unknown error")).")
        case .found:
            let status = mr.jiraStatus ?? "unknown"
            return mr.jiraPassing == true
                ? CheckResult(id: .jira, outcome: .pass, title: title, detail: "\(key) is \(status).")
                : CheckResult(id: .jira, outcome: .warning, title: title, detail: "\(key) is \(status), not a passing status.")
        }
    }

    /// Passes when the issue has a priority that isn't a placeholder like "None".
    static func priority(_ mr: MRCheckInput) -> CheckResult {
        let title = "Jira priority set"
        guard let key = mr.jiraKey else {
            return CheckResult(id: .priority, outcome: .notApplicable, title: title, detail: "No Jira issue.")
        }
        switch mr.jiraLookup {
        case .found:
            return mr.jiraHasPriority == true
                ? CheckResult(id: .priority, outcome: .pass, title: title, detail: "\(key) priority: \(mr.jiraPriority ?? "set").")
                : CheckResult(id: .priority, outcome: .warning, title: title, detail: "\(key) has no priority set.")
        case .notFound:
            return CheckResult(id: .priority, outcome: .notApplicable, title: title, detail: "Issue not found.")
        case nil, .notConfigured, .failed:
            return CheckResult(id: .priority, outcome: .pending, title: title, detail: "\(key): not checked yet.")
        }
    }

    static func approvals(_ mr: MRCheckInput) -> CheckResult {
        let title = "Required approvals met"
        guard mr.hasLoadedDetails else {
            return CheckResult(id: .approvals, outcome: .pending, title: title, detail: "Loading approvals…")
        }
        if mr.approvalsRequired == 0 {
            return CheckResult(id: .approvals, outcome: .pass, title: title, detail: "No approvals required (\(mr.approvalsGiven) given).")
        }
        let missing = mr.approvalsRequired - mr.approvalsGiven
        return missing <= 0
            ? CheckResult(id: .approvals, outcome: .pass, title: title, detail: "\(mr.approvalsGiven) of \(mr.approvalsRequired) approvals.")
            : CheckResult(id: .approvals, outcome: .warning, title: title,
                          detail: "\(mr.approvalsGiven) of \(mr.approvalsRequired) approvals; needs \(missing) more.")
    }

    static func conflicts(_ mr: MRCheckInput) -> CheckResult {
        mr.hasConflicts
            ? CheckResult(id: .conflicts, outcome: .fail, title: "No merge conflicts", detail: "The branch has merge conflicts with the target.")
            : CheckResult(id: .conflicts, outcome: .pass, title: "No merge conflicts", detail: "No conflicts.")
    }

    static func draft(_ mr: MRCheckInput) -> CheckResult {
        mr.isDraft
            ? CheckResult(id: .draft, outcome: .warning, title: "Not a draft", detail: "Marked as draft.")
            : CheckResult(id: .draft, outcome: .pass, title: "Not a draft", detail: "Ready for review.")
    }

    static func discussions(_ mr: MRCheckInput) -> CheckResult {
        let count = mr.unresolvedDiscussions
        return count == 0
            ? CheckResult(id: .discussions, outcome: .pass, title: "Discussions resolved", detail: "No unresolved threads.")
            : CheckResult(id: .discussions, outcome: .warning, title: "Discussions resolved",
                          detail: "\(count) unresolved \(count == 1 ? "thread" : "threads").")
    }

    // MARK: Diff checks

    static func diffChecks(_ diff: MRDiff, configuration: CheckConfiguration) -> [CheckResult] {
        let findings = PatternScanner.scan(diff.files, debugPatterns: configuration.debugPatterns, todoMarkers: configuration.todoMarkers)
        return [
            diffSize(diff, limit: configuration.diffSizeLimit),
            tests(diff, extraPatterns: configuration.extraTestPathPatterns),
            patternCheck(.secrets, kind: .secret, findings: findings, outcome: .fail,
                         title: "No likely secrets", noun: "possible secret"),
            patternCheck(.debugOutput, kind: .debugOutput, findings: findings, outcome: .warning,
                         title: "No debug output", noun: "debug statement"),
            patternCheck(.todos, kind: .todo, findings: findings, outcome: .warning,
                         title: "No new TODO or FIXME", noun: "marker"),
        ]
    }

    /// Placeholders shown until the diff for the head SHA has been analyzed.
    static func pendingDiffChecks(reason: String = "Analyzing the diff…") -> [CheckResult] {
        [
            CheckResult(id: .diffSize, outcome: .pending, title: "Diff size within limit", detail: reason),
            CheckResult(id: .tests, outcome: .pending, title: "Tests changed with source", detail: reason),
            CheckResult(id: .secrets, outcome: .pending, title: "No likely secrets", detail: reason),
            CheckResult(id: .debugOutput, outcome: .pending, title: "No debug output", detail: reason),
            CheckResult(id: .todos, outcome: .pending, title: "No new TODO or FIXME", detail: reason),
        ]
    }

    static func diffSize(_ diff: MRDiff, limit: Int) -> CheckResult {
        let title = "Diff size within limit"
        let counted = diff.files.filter { !$0.isGenerated }
        let lines = counted.reduce(0) { $0 + $1.additions + $1.deletions }
        if diff.isOverflow {
            return CheckResult(id: .diffSize, outcome: .warning, title: title,
                               detail: "GitLab limited the diff (\(diff.changesCount ?? "many") files changed), so it's over any limit.")
        }
        return lines <= limit
            ? CheckResult(id: .diffSize, outcome: .pass, title: title, detail: "\(lines) changed lines (limit \(limit)).")
            : CheckResult(id: .diffSize, outcome: .warning, title: title, detail: "\(lines) changed lines, over the \(limit)-line limit.")
    }

    static func tests(_ diff: MRDiff, extraPatterns: [String]) -> CheckResult {
        let title = "Tests changed with source"
        let kinds = diff.files.filter { !$0.isGenerated }.map { TestFileClassifier.classify($0.path, extraTestPatterns: extraPatterns) }
        let sources = kinds.count { $0 == .source }
        let tests = kinds.count { $0 == .test }
        if sources == 0 {
            return CheckResult(id: .tests, outcome: .notApplicable, title: title, detail: "No source files changed.")
        }
        return tests > 0
            ? CheckResult(id: .tests, outcome: .pass, title: title, detail: "\(sources) source and \(tests) test files changed.")
            : CheckResult(id: .tests, outcome: .warning, title: title,
                          detail: "\(sources) source \(sources == 1 ? "file" : "files") changed without any test changes.")
    }

    static func patternCheck(_ id: CheckID, kind: PatternFinding.Kind, findings: [PatternFinding], outcome: CheckOutcome,
                             title: String, noun: String) -> CheckResult {
        let matches = findings.filter { $0.kind == kind }
        guard !matches.isEmpty else {
            return CheckResult(id: id, outcome: .pass, title: title, detail: "None found in added lines.")
        }
        let files = Set(matches.map(\.path)).count
        return CheckResult(id: id, outcome: outcome, title: title,
                           detail: "\(matches.count) \(noun)\(matches.count == 1 ? "" : "s") in \(files) \(files == 1 ? "file" : "files").",
                           findings: matches)
    }
}
