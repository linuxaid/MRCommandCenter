import Foundation

/// One of the four things standing between an MR and a merge.
struct ReadinessStep: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case pipeline, approvals, threads, mergeable

        var shortTitle: String {
            switch self {
            case .pipeline: "CI"
            case .approvals: "Approvals"
            case .threads: "Threads"
            case .mergeable: "Mergeable"
            }
        }

        var systemImage: String {
            switch self {
            case .pipeline: "gearshape.2"
            case .approvals: "checkmark.seal"
            case .threads: "bubble.left.and.bubble.right"
            case .mergeable: "arrow.triangle.merge"
            }
        }
    }

    enum State: Equatable {
        /// Satisfied.
        case done
        /// Not yet, but nothing is wrong (running, waiting for people).
        case waiting
        /// Something is broken and someone has to fix it.
        case blocked
        /// Not loaded yet.
        case unknown
    }

    let kind: Kind
    let state: State
    /// Short status for the rail's tooltip and the brief, e.g. "1 of 2".
    let summary: String

    var id: Kind { kind }
}

/// How close an MR is to merging. Pure; computed from cached `TrackedMR` fields.
struct Readiness: Equatable {
    let steps: [ReadinessStep]
    let isDraft: Bool
    /// GitLab's `detailed_merge_status`, which knows project settings we don't.
    let gitLabStatus: String?

    init(_ mr: TrackedMR) {
        isDraft = mr.isDraft
        gitLabStatus = mr.detailedMergeStatus
        steps = [Self.pipeline(mr), Self.approvals(mr), Self.threads(mr), Self.mergeable(mr)]
    }

    func step(_ kind: ReadinessStep.Kind) -> ReadinessStep {
        // `steps` always holds every kind, in `Kind.allCases` order.
        steps.first { $0.kind == kind }!
    }

    var doneCount: Int { steps.count { $0.state == .done } }

    /// GitLab statuses that mean "can't merge yet", whatever our own steps say.
    static let blockingGitLabStatuses: Set<String> = [
        "not_approved", "ci_must_pass", "ci_still_running", "discussions_not_resolved", "draft_status",
        "conflict", "need_rebase", "blocked_status", "requested_changes", "jira_association_missing",
        "external_status_checks", "not_open", "merge_request_blocked", "commits_status", "approvals_syncing",
    ]

    /// Everything is green. Open threads only count when GitLab hasn't already said it's mergeable
    /// (projects can allow merging with open threads).
    var isReady: Bool {
        guard !isDraft else { return false }
        if let gitLabStatus, Self.blockingGitLabStatuses.contains(gitLabStatus) { return false }
        let threadsOK = step(.threads).state == .done || gitLabStatus == "mergeable"
        return step(.pipeline).state == .done && step(.approvals).state == .done
            && step(.mergeable).state == .done && threadsOK
    }

    static func pipeline(_ mr: TrackedMR) -> ReadinessStep {
        guard mr.hasLoadedDetails || mr.pipelineStatusRaw != nil else {
            return ReadinessStep(kind: .pipeline, state: .unknown, summary: "Loading")
        }
        if let sha = mr.pipelineSHA, !mr.headSHA.isEmpty, sha != mr.headSHA, mr.pipelineStatus?.isActive != true {
            return ReadinessStep(kind: .pipeline, state: .waiting, summary: "Ran on an older commit")
        }
        let (state, summary): (ReadinessStep.State, String) = switch mr.pipelineStatus {
        case nil: mr.detailedMergeStatus == "ci_must_pass" ? (.blocked, "No pipeline, but one is required") : (.done, "No pipeline")
        case .success: (.done, "Passed")
        case .skipped: (.done, "Skipped")
        case .failed: (.blocked, "Failed")
        case .canceled: (.blocked, "Canceled")
        case .running: (.waiting, "Running")
        case .created, .waitingForResource, .preparing, .pending, .scheduled: (.waiting, "Pending")
        case .manual: (.waiting, "Waiting on a manual job")
        case .unknown: (.unknown, "Unknown status")
        }
        return ReadinessStep(kind: .pipeline, state: state, summary: summary)
    }

    static func approvals(_ mr: TrackedMR) -> ReadinessStep {
        guard mr.hasLoadedDetails else { return ReadinessStep(kind: .approvals, state: .unknown, summary: "Loading") }
        if mr.approvalsRequired == 0 {
            let summary = mr.approvalsGiven == 0 ? "None required" : "\(mr.approvalsGiven) given, none required"
            return ReadinessStep(kind: .approvals, state: .done, summary: summary)
        }
        let summary = "\(mr.approvalsGiven) of \(mr.approvalsRequired)"
        return ReadinessStep(kind: .approvals, state: mr.approvalsMet ? .done : .waiting, summary: summary)
    }

    static func threads(_ mr: TrackedMR) -> ReadinessStep {
        guard mr.hasLoadedDetails else { return ReadinessStep(kind: .threads, state: .unknown, summary: "Loading") }
        let open = mr.unresolvedDiscussions
        if open == 0 {
            return ReadinessStep(kind: .threads, state: .done, summary: mr.resolvableDiscussions == 0 ? "None" : "All resolved")
        }
        return ReadinessStep(kind: .threads, state: .waiting, summary: "\(open) open")
    }

    static func mergeable(_ mr: TrackedMR) -> ReadinessStep {
        if mr.hasConflicts || mr.detailedMergeStatus == "conflict" {
            return ReadinessStep(kind: .mergeable, state: .blocked, summary: "Conflicts with \(mr.targetBranch)")
        }
        switch mr.detailedMergeStatus {
        case "need_rebase":
            return ReadinessStep(kind: .mergeable, state: .blocked, summary: "Needs a rebase onto \(mr.targetBranch)")
        case "blocked_status", "merge_request_blocked":
            return ReadinessStep(kind: .mergeable, state: .blocked, summary: "Blocked by another merge request")
        case "requested_changes":
            return ReadinessStep(kind: .mergeable, state: .blocked, summary: "A reviewer requested changes")
        case "checking", "unchecked", "approvals_syncing":
            return ReadinessStep(kind: .mergeable, state: .waiting, summary: "GitLab is checking")
        default:
            return ReadinessStep(kind: .mergeable, state: .done, summary: "No conflicts")
        }
    }
}
