import Foundation

nonisolated struct GitLabUserRef: Decodable, Sendable, Equatable, Hashable {
    let id: Int
    let username: String
    let name: String
}

/// Returned by both the MR list and the single-MR endpoint. The detail-only
/// fields (`headPipeline`, `diffRefs`) are nil in list responses.
nonisolated struct GitLabMergeRequest: Decodable, Sendable, Equatable {
    nonisolated struct References: Decodable, Sendable, Equatable {
        let full: String
    }

    nonisolated struct DiffRefs: Decodable, Sendable, Equatable {
        var baseSha: String?
        var headSha: String?
        var startSha: String?
    }

    let id: Int
    let iid: Int
    let projectId: Int
    let title: String
    var description: String?
    let state: String
    let createdAt: Date
    let updatedAt: Date
    let sourceBranch: String
    let targetBranch: String
    let author: GitLabUserRef
    var draft: Bool?
    var workInProgress: Bool?
    var labels: [GitLabLabel]?
    var sha: String?
    var hasConflicts: Bool?
    var detailedMergeStatus: String?
    var references: References?
    let webUrl: String
    var userNotesCount: Int?
    /// GitLab's own auto-merge ("merge when pipeline succeeds") is set on this MR.
    var mergeWhenPipelineSucceeds: Bool?
    var reviewers: [GitLabUserRef]?
    var headPipeline: GitLabPipeline?
    var diffRefs: DiffRefs?
    /// Detail only. A string; `"1000+"` when GitLab stopped counting.
    var changesCount: String?

    var isDraft: Bool { draft ?? workInProgress ?? false }
    var key: String { TrackedMR.makeKey(projectID: projectId, iid: iid) }
}

/// A label. The list endpoint returns objects with colors when asked
/// (`with_labels_details=true`); the single-MR endpoint returns plain names.
nonisolated struct GitLabLabel: Sendable, Equatable {
    let name: String
    var color: String?
    var textColor: String?
}

extension GitLabLabel: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name, color, textColor
    }

    nonisolated init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self.init(name: name)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            color: try container.decodeIfPresent(String.self, forKey: .color),
            textColor: try container.decodeIfPresent(String.self, forKey: .textColor)
        )
    }
}

nonisolated struct GitLabPipeline: Decodable, Sendable, Equatable {
    let id: Int
    var sha: String?
    let status: String
    var webUrl: String?

    var pipelineStatus: PipelineStatus { PipelineStatus(gitLabValue: status) }
}

nonisolated struct GitLabApprovals: Decodable, Sendable, Equatable {
    nonisolated struct Approver: Decodable, Sendable, Equatable {
        let user: GitLabUserRef
    }

    var approved: Bool?
    var approvalsRequired: Int?
    var approvalsLeft: Int?
    var approvedBy: [Approver]?

    var given: Int { approvedBy?.count ?? 0 }
    var approverUsernames: [String] { approvedBy?.map(\.user.username) ?? [] }
    var required: Int { approvalsRequired ?? 0 }
    var left: Int { approvalsLeft ?? max(0, required - given) }
}

nonisolated enum PipelineStatus: String, Codable, Sendable, CaseIterable {
    case created, waitingForResource, preparing, pending, running, scheduled
    case success, failed, canceled, skipped, manual
    case unknown

    init(gitLabValue: String) {
        switch gitLabValue {
        case "waiting_for_resource": self = .waitingForResource
        case "cancelled", "canceling": self = .canceled
        default: self = PipelineStatus(rawValue: gitLabValue) ?? .unknown
        }
    }

    /// Still running: a later poll may see a different status without `updated_at` changing.
    var isActive: Bool {
        switch self {
        case .created, .waitingForResource, .preparing, .pending, .running, .scheduled: true
        default: false
        }
    }
}

/// Body for `PUT /projects/:id/merge_requests/:iid/merge`.
nonisolated struct MergeOptions: Encodable, Sendable, Equatable {
    /// GitLab refuses the merge (409) if the head moved past this commit, so nothing
    /// the app didn't evaluate gets merged.
    var sha: String
    var squash: Bool?
    var shouldRemoveSourceBranch: Bool?
}
