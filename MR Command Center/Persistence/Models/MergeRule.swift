import Foundation
import SwiftData

/// "Merge MRs like this automatically once they're ready." Filters pick the MRs a rule
/// covers; requirements say when a covered MR is ready. GitLab's own rules still apply on top.
@Model
final class MergeRule {
    var id: UUID
    var name: String
    var isEnabled: Bool = true
    var createdAt: Date
    /// Rules are tried in this order; the first one that covers an MR owns it.
    var sortOrder: Int = 0

    // Filters. Empty means "any". Patterns are globs: `*` matches anything, including `/`.
    var projectPattern: String = ""
    var targetBranchPattern: String = ""
    var sourceBranchPattern: String = ""
    /// Every label listed must be on the MR.
    var requiredLabels: [String] = []
    /// GitLab usernames. Empty means any author.
    var authorUsernames: [String] = []
    /// Only MRs you opened.
    var onlyMine: Bool = false

    // Requirements on top of the built-in ones (not a draft, no conflicts, approvals met,
    // pipeline passed).
    var requireNoOpenThreads: Bool = true
    var requireChecksPass: Bool = false
    var requireAILooksGood: Bool = false
    /// Wait this long after the last push before merging. 0 merges as soon as it's ready.
    var quietMinutes: Int = 0
    /// 0 means no limit. Compared with GitLab's changed-file count.
    var maxChangedFiles: Int = 0

    // How to merge.
    var squash: Bool = false
    var removeSourceBranch: Bool = true

    // Bookkeeping.
    var mergeCount: Int = 0
    var lastMergedAt: Date?

    init(name: String, sortOrder: Int = 0, createdAt: Date = .now) {
        id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
