import Foundation
import SwiftData

/// An open merge request you review or authored, with cached status fields.
/// Rows are kept (hidden) after the MR leaves the lists so AI runs and eval cases survive.
@Model
final class TrackedMR {
    @Attribute(.unique) var key: String
    var gitLabID: Int
    var projectID: Int
    var iid: Int
    var projectPath: String
    var webURL: String
    var title: String
    var descriptionText: String
    var authorName: String
    var authorUsername: String
    var sourceBranch: String
    var targetBranch: String
    var labels: [String]
    /// Colors by label name, JSON-encoded `[String: LabelStyle]`.
    var labelStylesData: Data?
    var isDraft: Bool
    var hasConflicts: Bool
    var detailedMergeStatus: String?
    var createdAt: Date

    /// `updated_at` from the most recent list response.
    var lastSeenUpdatedAt: Date
    /// `updated_at` that the cached details (pipeline, approvals, discussions) correspond to.
    var detailsFetchedForUpdatedAt: Date?
    var headSHA: String

    var pipelineID: Int?
    var pipelineStatusRaw: String?
    var pipelineSHA: String?
    var pipelineWebURL: String?

    var approvalsGiven: Int = 0
    var approvalsRequired: Int = 0
    var approvedBy: [String] = []
    var unresolvedDiscussions: Int = 0
    var resolvableDiscussions: Int = 0

    var jiraKey: String?

    /// Still open and in your reviewer or author list.
    var isInReviewerList: Bool = true
    /// You're a reviewer on it.
    var isReviewer: Bool = true
    /// You opened it.
    var isAuthor: Bool = false
    var approvedByUsernames: [String] = []
    /// GitLab's own "merge when pipeline succeeds" is set.
    var mergeWhenPipelineSucceeds: Bool = false
    /// Unresolved threads where someone else spoke last and you're involved
    /// (you commented in it, or it's your MR).
    var threadsAwaitingMe: Int = 0
    /// Who spoke last in the most recent thread waiting on you, and when.
    var lastReplyFrom: String?
    var lastReplyToMeAt: Date?
    /// Unresolved threads where you spoke last.
    var threadsAwaitingOthers: Int = 0
    /// When the head commit last changed (new pushes), for merge rules' quiet period.
    var headChangedAt: Date?
    /// The last time something happened to it (see `ActivityEvent`), and the last time you looked.
    var lastActivityAt: Date?
    var seenAt: Date?
    /// Merge rules: the head SHA last acted on (merged, attempted, or reported in dry run), and the last failure.
    var autoMergeHandledSHA: String?
    var autoMergeError: String?
    /// You set it aside from Your move: when, at which commit, and the reason it needed you then.
    /// Kept in the app only; GitLab never hears about it.
    var setAsideAt: Date?
    var setAsideSHA: String?
    var setAsideReason: String?
    var firstSeenAt: Date
    var lastRefreshedAt: Date?
    /// Set when the most recent detail fetch for this MR failed.
    var detailsError: String?
    /// From the detail response; `"1000+"` when GitLab stopped counting.
    var changesCount: String?
    /// `diff_refs` from the detail response, needed to anchor new diff comments.
    var baseSHA: String?
    var startSHA: String?

    /// Summary of the diff checks for the sidebar; valid when `diffCheckSHA == headSHA`.
    var diffCheckSHA: String?
    var diffCheckFailures: Int = 0
    var diffCheckWarnings: Int = 0

    /// Latest completed AI review, for the sidebar.
    var aiVerdictRaw: String?
    var aiReviewedSHA: String?
    var aiReviewedAt: Date?
    /// Open (not posted, not dismissed) AI concerns from the latest review at `aiReviewedSHA`.
    var aiOpenConcerns: Int = 0

    /// Cached from the MR's Jira issue (`JiraCheck`) for the sidebar and checks.
    var jiraLookupRaw: String?
    var jiraStatus: String?
    var jiraPassing: Bool?
    var jiraPriority: String?
    var jiraHasPriority: Bool?
    var jiraError: String?

    init(from item: GitLabMergeRequest, now: Date = .now) {
        key = item.key
        gitLabID = item.id
        projectID = item.projectId
        iid = item.iid
        projectPath = Self.projectPath(from: item)
        webURL = item.webUrl
        title = item.title
        descriptionText = item.description ?? ""
        authorName = item.author.name
        authorUsername = item.author.username
        sourceBranch = item.sourceBranch
        targetBranch = item.targetBranch
        labels = item.labels?.map(\.name) ?? []
        labelStylesData = Self.mergedStyles(existing: nil, with: item.labels ?? [])
        isDraft = item.isDraft
        hasConflicts = item.hasConflicts ?? false
        detailedMergeStatus = item.detailedMergeStatus
        createdAt = item.createdAt
        lastSeenUpdatedAt = item.updatedAt
        headSHA = item.sha ?? ""
        firstSeenAt = now
    }

    /// Adds colors from labels that carry them and keeps known colors for those that don't
    /// (the single-MR endpoint returns names only).
    static func mergedStyles(existing: Data?, with labels: [GitLabLabel]) -> Data? {
        var styles = existing.flatMap { try? JSONDecoder().decode([String: LabelStyle].self, from: $0) } ?? [:]
        for label in labels {
            if let color = label.color {
                styles[label.name] = LabelStyle(color: color, textColor: label.textColor)
            }
        }
        guard !styles.isEmpty else { return existing }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(styles)
    }

    static func makeKey(projectID: Int, iid: Int) -> String {
        "\(projectID)!\(iid)"
    }

    /// `group/project` from `references.full` (`group/project!12`), falling back to the web URL.
    static func projectPath(from item: GitLabMergeRequest) -> String {
        if let full = item.references?.full, let bang = full.lastIndex(of: "!") {
            return String(full[..<bang])
        }
        if let range = item.webUrl.range(of: "/-/merge_requests/"), let url = URL(string: String(item.webUrl[..<range.lowerBound])) {
            return url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "project \(item.projectId)"
    }
}

extension TrackedMR {
    var jiraLookup: JiraLookup? { jiraLookupRaw.flatMap(JiraLookup.init(rawValue:)) }

    var pipelineStatus: PipelineStatus? {
        pipelineStatusRaw.map { PipelineStatus(rawValue: $0) ?? .unknown }
    }

    var hasLoadedDetails: Bool { detailsFetchedForUpdatedAt != nil }

    var labelStyles: [String: LabelStyle] {
        labelStylesData.flatMap { try? JSONDecoder().decode([String: LabelStyle].self, from: $0) } ?? [:]
    }
    var approvalsMet: Bool { approvalsGiven >= approvalsRequired }
    var hasUnseenActivity: Bool {
        guard let lastActivityAt else { return false }
        return lastActivityAt > (seenAt ?? .distantPast)
    }
    var shortSHA: String { String(headSHA.prefix(8)) }

    var diffRefs: DiffRefs? {
        guard let baseSHA, let startSHA, !headSHA.isEmpty else { return nil }
        return DiffRefs(baseSHA: baseSHA, startSHA: startSHA, headSHA: headSHA)
    }
    var reference: String { "\(projectPath)!\(iid)" }

    /// Refreshes the fields present in the list response.
    func update(from item: GitLabMergeRequest) {
        if title != item.title { title = item.title }
        let description = item.description ?? ""
        if descriptionText != description { descriptionText = description }
        if webURL != item.webUrl { webURL = item.webUrl }
        if sourceBranch != item.sourceBranch { sourceBranch = item.sourceBranch }
        if targetBranch != item.targetBranch { targetBranch = item.targetBranch }
        let labels = item.labels?.map(\.name) ?? []
        if self.labels != labels { self.labels = labels }
        let styles = Self.mergedStyles(existing: labelStylesData, with: item.labels ?? [])
        if labelStylesData != styles { labelStylesData = styles }
        if isDraft != item.isDraft { isDraft = item.isDraft }
        let conflicts = item.hasConflicts ?? false
        if hasConflicts != conflicts { hasConflicts = conflicts }
        if detailedMergeStatus != item.detailedMergeStatus { detailedMergeStatus = item.detailedMergeStatus }
        if lastSeenUpdatedAt != item.updatedAt { lastSeenUpdatedAt = item.updatedAt }
        if let sha = item.sha, headSHA != sha {
            headSHA = sha
            headChangedAt = .now
        }
        let autoMerge = item.mergeWhenPipelineSucceeds ?? false
        if mergeWhenPipelineSucceeds != autoMerge { mergeWhenPipelineSucceeds = autoMerge }
        if !isInReviewerList { isInReviewerList = true }
    }

    func apply(pipeline: GitLabPipeline?) {
        pipelineID = pipeline?.id
        pipelineStatusRaw = pipeline?.pipelineStatus.rawValue
        pipelineSHA = pipeline?.sha
        pipelineWebURL = pipeline?.webUrl
    }

    func apply(approvals: GitLabApprovals) {
        approvalsGiven = approvals.given
        approvalsRequired = approvals.required
        approvedBy = approvals.approvedBy?.map(\.user.name) ?? []
        approvedByUsernames = approvals.approverUsernames
    }

    func apply(discussions: [GitLabDiscussion], me: String?) {
        unresolvedDiscussions = discussions.count(where: \.isUnresolved)
        resolvableDiscussions = discussions.count(where: \.isResolvable)
        let turns = ThreadTurns(discussions: discussions, me: me, isMyMR: isAuthor)
        threadsAwaitingMe = turns.awaitingMe
        threadsAwaitingOthers = turns.awaitingOthers
        lastReplyFrom = turns.lastReplyFrom
        lastReplyToMeAt = turns.latestReplyAt
    }
}

/// GitLab label colors as hex strings, e.g. `#428BCA`.
nonisolated struct LabelStyle: Codable, Sendable, Equatable {
    var color: String
    var textColor: String?
}

/// Whose turn it is in each unresolved thread, from your point of view.
nonisolated struct ThreadTurns: Equatable {
    var awaitingMe = 0
    var awaitingOthers = 0
    var lastReplyFrom: String?
    var latestReplyAt: Date?

    init(discussions: [GitLabDiscussion], me: String?, isMyMR: Bool) {
        guard let me else { return }
        var latestReply: Date?
        for thread in discussions where thread.isUnresolved {
            let notes = thread.userNotes
            guard let last = notes.last, let lastAuthor = last.author else { continue }
            if lastAuthor.username == me {
                awaitingOthers += 1
                continue
            }
            let involved = isMyMR || notes.contains { $0.author?.username == me }
            guard involved else { continue }
            awaitingMe += 1
            let date = last.createdAt ?? .distantPast
            if latestReply.map({ date >= $0 }) ?? true {
                latestReply = date
                lastReplyFrom = lastAuthor.name
            }
        }
        latestReplyAt = latestReply
    }
}
