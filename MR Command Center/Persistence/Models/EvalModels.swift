import Foundation
import SwiftData

nonisolated struct ExpectedConcern: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    /// New-side line; nil means "anywhere in this file".
    var line: Int?
    var description: String
}

/// An MR frozen at one head SHA, with what a good review should say. The diff, Jira data,
/// and static flags are snapshotted so the case stays reproducible after the MR merges.
@Model
final class EvalCase {
    @Attribute(.unique) var id: UUID
    var name: String
    var mrKey: String
    var projectID: Int
    var iid: Int
    var mrReference: String
    var mrTitle: String
    var mrDescription: String
    var webURL: String
    var headSHA: String
    var expectedVerdictRaw: String
    var expectedConcernsData: Data
    /// JSON `[GitLabDiff]` at `headSHA`.
    @Attribute(.externalStorage) var diffData: Data
    var changesCount: String?
    var jiraKey: String?
    var jiraSummary: String?
    var acceptanceCriteria: String?
    var storyDescription: String?
    /// JSON `[PatternFinding]` from the static checks at `headSHA`.
    var findingsData: Data
    var staticSummary: String
    var notes: String
    var createdAt: Date

    init(mr: TrackedMR, diffs: [GitLabDiff], findings: [PatternFinding], staticSummary: String,
         expectedVerdict: VerdictStatus, expectedConcerns: [ExpectedConcern], notes: String = "") throws {
        id = UUID()
        name = "\(mr.reference) @ \(mr.shortSHA)"
        mrKey = mr.key
        projectID = mr.projectID
        iid = mr.iid
        mrReference = mr.reference
        mrTitle = mr.title
        mrDescription = mr.descriptionText
        webURL = mr.webURL
        headSHA = mr.headSHA
        expectedVerdictRaw = expectedVerdict.rawValue
        expectedConcernsData = try JSONEncoder().encode(expectedConcerns)
        diffData = try JSONEncoder().encode(diffs)
        changesCount = mr.changesCount
        jiraKey = mr.jiraKey
        findingsData = try JSONEncoder().encode(findings)
        self.staticSummary = staticSummary
        self.notes = notes
        createdAt = .now
    }

    var expectedVerdict: VerdictStatus {
        get { VerdictStatus(rawValue: expectedVerdictRaw) ?? .needsHumanReview }
        set { expectedVerdictRaw = newValue.rawValue }
    }

    var expectedConcerns: [ExpectedConcern] {
        get { (try? JSONDecoder().decode([ExpectedConcern].self, from: expectedConcernsData)) ?? [] }
        set { expectedConcernsData = (try? JSONEncoder().encode(newValue)) ?? expectedConcernsData }
    }

    var diffs: [GitLabDiff] { (try? JSONDecoder().decode([GitLabDiff].self, from: diffData)) ?? [] }
    var findings: [PatternFinding] { (try? JSONDecoder().decode([PatternFinding].self, from: findingsData)) ?? [] }
    var changedPaths: [String] { diffs.map(\.newPath) }

    var context: ReviewContext {
        ReviewContext(mrTitle: mrTitle, mrDescription: mrDescription, jiraKey: jiraKey,
                      jiraSummary: jiraSummary, acceptanceCriteria: acceptanceCriteria, storyDescription: storyDescription,
                      storyUnavailableReason: jiraSummary == nil ? "no Jira story was saved with this eval case" : nil)
    }
}

nonisolated enum BatchStatus: String, Codable, Sendable {
    case running, completed, cancelled
}

/// One run of the eval set against a prompt version.
@Model
final class EvalBatch {
    @Attribute(.unique) var id: UUID
    var promptVersionID: UUID
    var promptVersionName: String
    var modelIdentifier: String
    var startedAt: Date
    var finishedAt: Date?
    var statusRaw: String
    var caseIDs: [UUID]
    var greedy: Bool
    var notes: String = ""

    init(prompt: PromptSnapshot, modelIdentifier: String, caseIDs: [UUID], greedy: Bool) {
        id = UUID()
        promptVersionID = prompt.id
        promptVersionName = prompt.name
        self.modelIdentifier = modelIdentifier
        startedAt = .now
        statusRaw = BatchStatus.running.rawValue
        self.caseIDs = caseIDs
        self.greedy = greedy
    }

    var status: BatchStatus {
        get { BatchStatus(rawValue: statusRaw) ?? .cancelled }
        set { statusRaw = newValue.rawValue }
    }
}
