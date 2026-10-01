import Foundation

/// Facts about one eval case and the run that reviewed it, as plain values so metrics are
/// pure and testable.
nonisolated struct EvalCaseFacts: Sendable, Equatable {
    let id: UUID
    let expectedVerdict: VerdictStatus
    let expectedConcerns: [ExpectedConcern]
}

nonisolated struct EvalRunFacts: Sendable, Equatable {
    struct Concern: Sendable, Equatable {
        let path: String
        let line: Int?
        let feedback: Feedback
    }

    let caseID: UUID
    let verdict: VerdictStatus?
    let concerns: [Concern]
    let latency: TimeInterval?
    let tokens: Int
    let failedFiles: Int
    let runFailed: Bool
}

nonisolated struct BatchMetrics: Codable, Sendable, Equatable {
    var cases = 0
    var runsWithVerdict = 0
    var verdictMatches = 0
    var helpful = 0
    var wrong = 0
    var unrated = 0
    var expectedConcerns = 0
    var expectedFound = 0
    var averageLatency: TimeInterval?
    var averageTokens: Double?
    var errors = 0

    /// Of the cases that produced a verdict, how many matched the expected one.
    var verdictAgreement: Double? {
        runsWithVerdict == 0 ? nil : Double(verdictMatches) / Double(runsWithVerdict)
    }

    /// Of the expected concerns, how many the model raised (same file, and within 3 lines
    /// when both sides give a line).
    var expectedRecall: Double? {
        expectedConcerns == 0 ? nil : Double(expectedFound) / Double(expectedConcerns)
    }

    var precision: Double? {
        helpful + wrong == 0 ? nil : Double(helpful) / Double(helpful + wrong)
    }
}

nonisolated enum EvalMetrics {
    static let lineTolerance = 3

    static func matches(_ expected: ExpectedConcern, _ concern: EvalRunFacts.Concern) -> Bool {
        guard expected.path == concern.path else { return false }
        guard let expectedLine = expected.line, let line = concern.line else { return true }
        return abs(expectedLine - line) <= lineTolerance
    }

    static func compute(cases: [EvalCaseFacts], runs: [EvalRunFacts]) -> BatchMetrics {
        var metrics = BatchMetrics(cases: cases.count)
        let runsByCase = Dictionary(runs.map { ($0.caseID, $0) }, uniquingKeysWith: { _, latest in latest })
        var latencies: [TimeInterval] = []
        var tokens: [Int] = []

        for testCase in cases {
            guard let run = runsByCase[testCase.id] else { continue }
            if run.runFailed { metrics.errors += 1 }
            metrics.errors += run.failedFiles
            if let verdict = run.verdict {
                metrics.runsWithVerdict += 1
                if verdict == testCase.expectedVerdict { metrics.verdictMatches += 1 }
            }
            for concern in run.concerns {
                switch concern.feedback {
                case .helpful: metrics.helpful += 1
                case .wrong: metrics.wrong += 1
                case .none: metrics.unrated += 1
                }
            }
            metrics.expectedConcerns += testCase.expectedConcerns.count
            metrics.expectedFound += testCase.expectedConcerns.count { expected in
                run.concerns.contains { matches(expected, $0) }
            }
            if let latency = run.latency { latencies.append(latency) }
            tokens.append(run.tokens)
        }
        metrics.averageLatency = latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
        metrics.averageTokens = tokens.isEmpty ? nil : Double(tokens.reduce(0, +)) / Double(tokens.count)
        return metrics
    }
}

extension AIReviewRun {
    var evalFacts: EvalRunFacts? {
        guard let caseID = evalCaseID else { return nil }
        return EvalRunFacts(
            caseID: caseID,
            verdict: verdictStatus,
            concerns: orderedFiles.flatMap { file in
                file.orderedConcerns.map { EvalRunFacts.Concern(path: file.path, line: $0.lineNumber, feedback: $0.feedback) }
            },
            latency: latency,
            tokens: totalInputTokens + totalOutputTokens,
            failedFiles: files.count { $0.status == .failed },
            runFailed: status == .failed
        )
    }
}

extension EvalCase {
    var facts: EvalCaseFacts {
        EvalCaseFacts(id: id, expectedVerdict: expectedVerdict, expectedConcerns: expectedConcerns)
    }
}
