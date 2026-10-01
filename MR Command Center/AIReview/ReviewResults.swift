import Foundation

// Domain results of an AI review. These are what the app stores and shows; the
// `@Generable` types the model fills in live in `ModelOutputs.swift` and are converted here.

nonisolated enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
    case low, medium, high

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

nonisolated enum CriteriaMatch: String, Codable, Sendable, CaseIterable {
    case yes, partially, no, unclear
}

nonisolated enum Confidence: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

nonisolated enum VerdictStatus: String, Codable, Sendable, CaseIterable {
    case looksGood, needsHumanReview, likelyProblem
}

nonisolated struct ConcernResult: Codable, Sendable, Equatable {
    var lineHint: String
    var severity: Severity
    var explanation: String
}

nonisolated struct FileReviewResult: Codable, Sendable, Equatable {
    var summary: String
    var meetsCriteria: CriteriaMatch
    var concerns: [ConcernResult]
    var confidence: Confidence

    /// Combines the results of a file reviewed in several parts (split by hunk).
    static func merged(_ parts: [FileReviewResult]) -> FileReviewResult? {
        guard let first = parts.first else { return nil }
        guard parts.count > 1 else { return first }
        var seen = Set<String>()
        let concerns = parts.flatMap(\.concerns).filter { seen.insert($0.lineHint + "|" + $0.explanation).inserted }
        let confidenceOrder = Confidence.allCases
        let lowest = parts.map(\.confidence).min { confidenceOrder.firstIndex(of: $0)! < confidenceOrder.firstIndex(of: $1)! } ?? .low
        // The weakest criteria answer wins: any "no" beats "partially" beats "unclear" beats "yes".
        let criteriaOrder: [CriteriaMatch] = [.no, .partially, .unclear, .yes]
        let criteria = parts.map(\.meetsCriteria).min { criteriaOrder.firstIndex(of: $0)! < criteriaOrder.firstIndex(of: $1)! } ?? .unclear
        return FileReviewResult(
            summary: parts.enumerated().map { "Part \($0 + 1): \($1.summary)" }.joined(separator: " "),
            meetsCriteria: criteria,
            concerns: concerns,
            confidence: lowest
        )
    }
}

nonisolated struct VerdictResult: Codable, Sendable, Equatable {
    var status: VerdictStatus
    var criteriaCoverage: String
    var topConcerns: [String]
    var rationale: String
}

/// Why a file (or the merge step) couldn't be reviewed. Mapped from Foundation Models errors
/// so one bad file never fails the whole review.
nonisolated enum ReviewFailure: Error, Codable, Sendable, Equatable {
    case contextSizeExceeded
    case guardrailViolation
    case unsupportedLanguage
    case refusal
    case rateLimited
    case timeout
    case modelUnavailable
    case decodingFailure
    case other(String)

    var title: String {
        switch self {
        case .contextSizeExceeded: "Too large for the model's context"
        case .guardrailViolation: "Blocked by safety guardrails"
        case .unsupportedLanguage: "Unsupported language"
        case .refusal: "The model declined"
        case .rateLimited: "Rate limited"
        case .timeout: "Timed out"
        case .modelUnavailable: "Model unavailable"
        case .decodingFailure: "Couldn't parse the model's output"
        case .other: "Error"
        }
    }

    var message: String {
        if case .other(let detail) = self { return detail }
        return title
    }
}

/// One logged tool call (when tools are enabled).
nonisolated struct ToolCallLog: Codable, Sendable, Equatable {
    var tool: String
    var arguments: String
    var resultSummary: String
    var succeeded: Bool
}

/// Everything recorded for one model call, for the inspector and evaluation.
nonisolated struct ModelCallRecord: Codable, Sendable, Equatable {
    var instructions: String
    var prompt: String
    var transcript: String
    var rawOutput: String
    var inputTokens: Int?
    var outputTokens: Int?
    var latency: TimeInterval
    var toolCalls: [ToolCallLog] = []
}
