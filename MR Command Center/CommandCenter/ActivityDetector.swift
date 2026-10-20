import Foundation

/// The fields of an MR worth reporting changes in.
struct MRSnapshot: Equatable {
    var hasLoadedDetails: Bool
    var headSHA: String
    var pipelineStatus: PipelineStatus?
    var approvers: Set<String>
    var approverNames: [String: String]
    var hasConflicts: Bool
    var unresolvedThreads: Int
    var threadsAwaitingMe: Int
    var lastReplyFrom: String?
    var isReady: Bool

    init(_ mr: TrackedMR) {
        hasLoadedDetails = mr.hasLoadedDetails
        headSHA = mr.headSHA
        pipelineStatus = mr.pipelineStatus
        approvers = Set(mr.approvedByUsernames)
        approverNames = Dictionary(zip(mr.approvedByUsernames, mr.approvedBy), uniquingKeysWith: { first, _ in first })
        hasConflicts = mr.hasConflicts
        unresolvedThreads = mr.unresolvedDiscussions
        threadsAwaitingMe = mr.threadsAwaitingMe
        lastReplyFrom = mr.lastReplyFrom
        isReady = Readiness(mr).isReady
    }
}

/// Turns before/after snapshots into activity lines. Pure.
enum ActivityDetector {
    struct Change: Equatable {
        let kind: ActivityKind
        let message: String
    }

    static func changes(from old: MRSnapshot, to new: MRSnapshot) -> [Change] {
        // Before details load there's nothing meaningful to compare.
        guard old.hasLoadedDetails, new.hasLoadedDetails else { return [] }
        var changes: [Change] = []
        if old.headSHA != new.headSHA, !new.headSHA.isEmpty {
            changes.append(Change(kind: .pushed, message: "New commits pushed (\(new.headSHA.prefix(8)))"))
        }
        if old.pipelineStatus != new.pipelineStatus {
            switch new.pipelineStatus {
            case .success: changes.append(Change(kind: .pipelinePassed, message: "Pipeline passed"))
            case .failed: changes.append(Change(kind: .pipelineFailed, message: "Pipeline failed"))
            default: break
            }
        }
        for username in new.approvers.subtracting(old.approvers).sorted() {
            let name = new.approverNames[username] ?? username
            changes.append(Change(kind: .approved, message: "Approved by \(name)"))
        }
        for username in old.approvers.subtracting(new.approvers).sorted() {
            let name = old.approverNames[username] ?? username
            changes.append(Change(kind: .approvalRevoked, message: "\(name) removed their approval"))
        }
        if new.threadsAwaitingMe > old.threadsAwaitingMe {
            let who = new.lastReplyFrom ?? "Someone"
            changes.append(Change(kind: .replied, message: "\(who) replied and is waiting on you"))
        }
        if old.unresolvedThreads > 0, new.unresolvedThreads == 0 {
            changes.append(Change(kind: .threadsResolved, message: "All threads resolved"))
        }
        if !old.hasConflicts, new.hasConflicts {
            changes.append(Change(kind: .conflicts, message: "Merge conflicts appeared"))
        } else if old.hasConflicts, !new.hasConflicts {
            changes.append(Change(kind: .conflictsCleared, message: "Conflicts resolved"))
        }
        if !old.isReady, new.isReady {
            changes.append(Change(kind: .readyToMerge, message: "Ready to merge"))
        }
        return changes
    }
}
