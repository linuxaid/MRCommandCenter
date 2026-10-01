import Foundation
import SwiftData

nonisolated enum RunStatus: String, Codable, Sendable {
    case running, completed, cancelled, failed
}

nonisolated enum FileReviewStatus: String, Codable, Sendable {
    case reviewed, skipped, failed
}

nonisolated enum Feedback: String, Codable, Sendable, CaseIterable {
    case none, helpful, wrong
}

/// One AI review of an MR at a head SHA with a prompt version. Copies the MR identity
/// so the run survives the MR leaving the list.
@Model
final class AIReviewRun {
    @Attribute(.unique) var id: UUID
    var mrKey: String
    var projectID: Int
    var iid: Int
    var mrTitle: String
    var headSHA: String
    var promptVersionID: UUID
    var promptVersionName: String
    var modelIdentifier: String
    var statusRaw: String
    var startedAt: Date
    var finishedAt: Date?
    var errorMessage: String?

    var verdictStatusRaw: String?
    var criteriaCoverage: String?
    var topConcerns: [String] = []
    var rationale: String?
    var verdictFailure: String?
    /// The merge session's call record (JSON `ModelCallRecord`).
    var mergeCallData: Data?

    var usedAcceptanceCriteria: Bool = false
    /// The Jira story the review compared against, if any.
    var storyKey: String?
    var storyNote: String?
    var toolsEnabled: Bool = false
    var skillsUsed: [String] = []
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0

    // Phase 6 evaluation fields.
    var verdictFeedbackRaw: String = Feedback.none.rawValue
    var verdictNote: String = ""
    var evalCaseID: UUID?
    var evalBatchID: UUID?

    /// The summary thread posted to the MR from this run, if any.
    var summaryDiscussionID: String?
    var summaryPostedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \FileReviewRecord.run)
    var files: [FileReviewRecord] = []

    convenience init(mr: TrackedMR, prompt: PromptSnapshot, modelIdentifier: String, startedAt: Date = .now) {
        self.init(mrKey: mr.key, projectID: mr.projectID, iid: mr.iid, mrTitle: mr.title, headSHA: mr.headSHA,
                  prompt: prompt, modelIdentifier: modelIdentifier, startedAt: startedAt)
    }

    init(mrKey: String, projectID: Int, iid: Int, mrTitle: String, headSHA: String,
         prompt: PromptSnapshot, modelIdentifier: String, startedAt: Date = .now) {
        id = UUID()
        self.mrKey = mrKey
        self.projectID = projectID
        self.iid = iid
        self.mrTitle = mrTitle
        self.headSHA = headSHA
        promptVersionID = prompt.id
        promptVersionName = prompt.name
        self.modelIdentifier = modelIdentifier
        statusRaw = RunStatus.running.rawValue
        self.startedAt = startedAt
    }

    var status: RunStatus {
        get { RunStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var verdictStatus: VerdictStatus? { verdictStatusRaw.flatMap(VerdictStatus.init(rawValue:)) }
    var latency: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
    var orderedFiles: [FileReviewRecord] { files.sorted { $0.order < $1.order } }

    var mergeCall: ModelCallRecord? {
        mergeCallData.flatMap { try? JSONDecoder().decode(ModelCallRecord.self, from: $0) }
    }

    var verdictFeedback: Feedback {
        get { Feedback(rawValue: verdictFeedbackRaw) ?? .none }
        set { verdictFeedbackRaw = newValue.rawValue }
    }
}

/// The review of one file within a run (the spec's `FileFinding`).
@Model
final class FileReviewRecord {
    @Attribute(.unique) var id: UUID
    var run: AIReviewRun?
    var order: Int
    var path: String
    var statusRaw: String
    var skipReason: String?
    var failureRaw: Data?

    var summary: String?
    var meetsCriteriaRaw: String?
    var confidenceRaw: String?
    var partCount: Int = 1
    var skillsUsed: [String] = []
    var staticFlags: [String] = []

    /// JSON `[ModelCallRecord]`, one per part: exact instructions, prompt, transcript, tokens.
    @Attribute(.externalStorage) var callsData: Data?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var latency: TimeInterval = 0

    @Relationship(deleteRule: .cascade, inverse: \ConcernRecord.file)
    var concerns: [ConcernRecord] = []

    init(order: Int, path: String, status: FileReviewStatus) {
        id = UUID()
        self.order = order
        self.path = path
        statusRaw = status.rawValue
    }

    var status: FileReviewStatus { FileReviewStatus(rawValue: statusRaw) ?? .failed }
    var meetsCriteria: CriteriaMatch? { meetsCriteriaRaw.flatMap(CriteriaMatch.init(rawValue:)) }
    var confidence: Confidence? { confidenceRaw.flatMap(Confidence.init(rawValue:)) }
    var orderedConcerns: [ConcernRecord] { concerns.sorted { $0.order < $1.order } }

    var failure: ReviewFailure? {
        failureRaw.flatMap { try? JSONDecoder().decode(ReviewFailure.self, from: $0) }
    }

    var calls: [ModelCallRecord] {
        callsData.flatMap { try? JSONDecoder().decode([ModelCallRecord].self, from: $0) } ?? []
    }
}

/// One concern, separate so each can get feedback (phase 6).
@Model
final class ConcernRecord {
    @Attribute(.unique) var id: UUID
    var file: FileReviewRecord?
    var order: Int
    var lineHint: String
    var severityRaw: String
    var explanation: String
    var feedbackRaw: String = Feedback.none.rawValue
    var note: String = ""
    /// Set once the concern has been posted to GitLab as a diff comment.
    var postedDiscussionID: String?
    var postedAt: Date?
    /// Hidden by the reviewer as not worth acting on. Dismissed concerns don't count as open.
    var dismissedAt: Date?

    /// Not posted to GitLab and not dismissed.
    var isOpen: Bool { postedAt == nil && dismissedAt == nil }

    init(order: Int, concern: ConcernResult) {
        id = UUID()
        self.order = order
        lineHint = concern.lineHint
        severityRaw = concern.severity.rawValue
        explanation = concern.explanation
    }

    var severity: Severity { Severity(rawValue: severityRaw) ?? .medium }

    var feedback: Feedback {
        get { Feedback(rawValue: feedbackRaw) ?? .none }
        set { feedbackRaw = newValue.rawValue }
    }

    /// The first number in the line hint, used to jump to the diff.
    var lineNumber: Int? {
        lineHint.firstMatch(of: /\d+/).flatMap { Int($0.output) }
    }
}
