import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The JSON written by "Export…". Versioned so analysis scripts (or an Evaluations test
/// target) can rely on its shape.
nonisolated struct ExportBundle: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = ExportBundle.currentSchemaVersion
    var exportedAt: Date
    var app = "MR Command Center"
    /// False when prompts, transcripts, and diffs (which contain code) were left out.
    var includesContent: Bool
    var promptVersions: [PromptExport]
    var skills: [SkillExport]
    var evalCases: [EvalCaseExport]
    var batches: [BatchExport]
    var runs: [RunExport]

    struct PromptExport: Codable, Sendable {
        var id: UUID
        var name: String
        var fileInstructions: String
        var mergeInstructions: String
        var notes: String
        var createdAt: Date
    }

    struct SkillExport: Codable, Sendable {
        var name: String
        var version: Int
        var appliesTo: [String]
        var content: String
        var isEnabled: Bool
    }

    struct EvalCaseExport: Codable, Sendable {
        var id: UUID
        var name: String
        var mrReference: String
        var headSHA: String
        var expectedVerdict: String
        var expectedConcerns: [ExpectedConcern]
        var notes: String
        var createdAt: Date
        var staticSummary: String
        var diffs: [GitLabDiff]?
        var findings: [PatternFinding]?
    }

    struct BatchExport: Codable, Sendable {
        var id: UUID
        var promptVersionID: UUID
        var promptVersionName: String
        var modelIdentifier: String
        var startedAt: Date
        var finishedAt: Date?
        var status: String
        var greedy: Bool
        var caseIDs: [UUID]
        var metrics: BatchMetrics
    }

    struct ConcernExport: Codable, Sendable {
        var lineHint: String
        var severity: String
        var explanation: String
        var feedback: String
        var note: String
        var postedToGitLab: Bool
        var dismissed: Bool
    }

    struct FileExport: Codable, Sendable {
        var path: String
        var status: String
        var skipReason: String?
        var failure: String?
        var summary: String?
        var meetsCriteria: String?
        var confidence: String?
        var parts: Int
        var skills: [String]
        var staticFlags: [String]
        var inputTokens: Int
        var outputTokens: Int
        var latency: TimeInterval
        var concerns: [ConcernExport]
        var calls: [ModelCallRecord]?
    }

    struct RunExport: Codable, Sendable {
        var id: UUID
        var mrKey: String
        var mrTitle: String
        var headSHA: String
        var promptVersionID: UUID
        var promptVersionName: String
        var modelIdentifier: String
        var status: String
        var startedAt: Date
        var finishedAt: Date?
        var latency: TimeInterval?
        var inputTokens: Int
        var outputTokens: Int
        var verdict: String?
        var criteriaCoverage: String?
        var topConcerns: [String]
        var rationale: String?
        var verdictFailure: String?
        var verdictFeedback: String
        var verdictNote: String
        var skillsUsed: [String]
        var usedAcceptanceCriteria: Bool
        var toolsEnabled: Bool
        var summaryPostedToGitLab: Bool
        var evalCaseID: UUID?
        var evalBatchID: UUID?
        var files: [FileExport]
        var mergeCall: ModelCallRecord?
    }
}

enum ExportService {
    static func makeBundle(context: ModelContext, evaluation: EvalService, includeContent: Bool) -> ExportBundle {
        let prompts = (try? context.fetch(FetchDescriptor<PromptVersion>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let skills = (try? context.fetch(FetchDescriptor<ReviewSkill>(sortBy: [SortDescriptor(\.name)]))) ?? []
        let runs = (try? context.fetch(FetchDescriptor<AIReviewRun>(sortBy: [SortDescriptor(\.startedAt)]))) ?? []

        return ExportBundle(
            exportedAt: .now,
            includesContent: includeContent,
            promptVersions: prompts.map {
                .init(id: $0.id, name: $0.name, fileInstructions: $0.fileInstructions, mergeInstructions: $0.mergeInstructions,
                      notes: $0.notes, createdAt: $0.createdAt)
            },
            skills: skills.map { .init(name: $0.name, version: $0.version, appliesTo: $0.appliesTo, content: $0.content, isEnabled: $0.isEnabled) },
            evalCases: evaluation.cases.map {
                .init(id: $0.id, name: $0.name, mrReference: $0.mrReference, headSHA: $0.headSHA,
                      expectedVerdict: $0.expectedVerdictRaw, expectedConcerns: $0.expectedConcerns, notes: $0.notes,
                      createdAt: $0.createdAt, staticSummary: $0.staticSummary,
                      diffs: includeContent ? $0.diffs : nil, findings: includeContent ? $0.findings : nil)
            },
            batches: evaluation.batches.map {
                .init(id: $0.id, promptVersionID: $0.promptVersionID, promptVersionName: $0.promptVersionName,
                      modelIdentifier: $0.modelIdentifier, startedAt: $0.startedAt, finishedAt: $0.finishedAt,
                      status: $0.statusRaw, greedy: $0.greedy, caseIDs: $0.caseIDs, metrics: evaluation.metrics(for: $0))
            },
            runs: runs.map { run(for: $0, includeContent: includeContent) }
        )
    }

    private static func run(for run: AIReviewRun, includeContent: Bool) -> ExportBundle.RunExport {
        ExportBundle.RunExport(
            id: run.id, mrKey: run.mrKey, mrTitle: run.mrTitle, headSHA: run.headSHA,
            promptVersionID: run.promptVersionID, promptVersionName: run.promptVersionName,
            modelIdentifier: run.modelIdentifier, status: run.statusRaw, startedAt: run.startedAt, finishedAt: run.finishedAt,
            latency: run.latency, inputTokens: run.totalInputTokens, outputTokens: run.totalOutputTokens,
            verdict: run.verdictStatusRaw, criteriaCoverage: run.criteriaCoverage, topConcerns: run.topConcerns,
            rationale: run.rationale, verdictFailure: run.verdictFailure,
            verdictFeedback: run.verdictFeedbackRaw, verdictNote: run.verdictNote,
            skillsUsed: run.skillsUsed, usedAcceptanceCriteria: run.usedAcceptanceCriteria, toolsEnabled: run.toolsEnabled,
            summaryPostedToGitLab: run.summaryPostedAt != nil, evalCaseID: run.evalCaseID, evalBatchID: run.evalBatchID,
            files: run.orderedFiles.map { file in
                ExportBundle.FileExport(
                    path: file.path, status: file.statusRaw, skipReason: file.skipReason, failure: file.failure?.message,
                    summary: file.summary, meetsCriteria: file.meetsCriteriaRaw, confidence: file.confidenceRaw,
                    parts: file.partCount, skills: file.skillsUsed, staticFlags: file.staticFlags,
                    inputTokens: file.inputTokens, outputTokens: file.outputTokens, latency: file.latency,
                    concerns: file.orderedConcerns.map {
                        .init(lineHint: $0.lineHint, severity: $0.severityRaw, explanation: $0.explanation,
                              feedback: $0.feedbackRaw, note: $0.note, postedToGitLab: $0.postedAt != nil, dismissed: $0.dismissedAt != nil)
                    },
                    calls: includeContent ? file.calls : nil
                )
            },
            mergeCall: includeContent ? run.mergeCall : nil
        )
    }

    static func encode(_ bundle: ExportBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }
}

nonisolated struct JSONExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
