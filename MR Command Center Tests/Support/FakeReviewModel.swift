import Foundation
import Synchronization
@testable import MR_Command_Center

/// Deterministic stand-in for the on-device model.
nonisolated final class FakeReviewModel: ReviewLanguageModel {
    struct Call: Sendable {
        let instructions: String
        let prompt: String
        var path: String {
            prompt.split(separator: "\n").first { $0.hasPrefix("File: ") }
                .map { String($0.dropFirst(6).split(separator: " ").first ?? "") } ?? ""
        }
    }

    struct State {
        var fileCalls: [Call] = []
        var verdictCalls: [Call] = []
        var failures: [String: ReviewFailure] = [:]
        /// Throw a context overflow for these paths when a prompt is longer than this.
        var overflowAbove: [String: Int] = [:]
        var concernsByPath: [String: [ConcernResult]] = [:]
        var inFlight = 0
        var maxInFlight = 0
        var delay: Duration = .zero
        /// Throw a parse failure for these paths on the first (greedy) attempt.
        var parseFailureOnGreedy: Set<String> = []
        var difficultyCalls: [Call] = []
        /// What `difficulty` answers; nil throws `difficultyFailure`.
        var difficultyNudge: DifficultyNudge? = DifficultyNudge(feel: .aboutRight, reason: "Fake reason.")
        var difficultyFailure: ReviewFailure = .refusal
        var jokeCalls: [Call] = []
        /// What `dadJoke` answers; nil throws a refusal.
        var joke: String? = "Why did the fake model cross the road? To get to the other test."

    }

    let identifier = "fake-model"
    let contextSize: Int
    let tokenCounter: any TokenCounter = EstimatingTokenCounter()
    let state = Mutex(State())

    init(contextSize: Int = 8192) {
        self.contextSize = contextSize
    }

    func edit(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    var fileCalls: [Call] { state.withLock { $0.fileCalls } }
    var verdictCalls: [Call] { state.withLock { $0.verdictCalls } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    var difficultyCalls: [Call] { state.withLock { $0.difficultyCalls } }
    var jokeCalls: [Call] { state.withLock { $0.jokeCalls } }

    func reviewFile(instructions: String, prompt: String, options: ReviewOptions, tools: ReviewTools?) async throws -> (FileReviewResult, ModelCallRecord) {
        let call = Call(instructions: instructions, prompt: prompt)
        let (failure, overflow, concerns, delay, parseFails) = state.withLock { state in
            state.fileCalls.append(call)
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
            return (state.failures[call.path], state.overflowAbove[call.path], state.concernsByPath[call.path], state.delay,
                    state.parseFailureOnGreedy.contains(call.path))
        }
        if parseFails && options.greedy {
            defer { state.withLock { $0.inFlight -= 1 } }
            throw ReviewModelError(failure: .decodingFailure, transcript: "truncated")
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw ReviewModelError(failure: failure, transcript: "fake transcript") }
        if let overflow, prompt.count > overflow { throw ReviewModelError(failure: .contextSizeExceeded, transcript: "") }
        let result = FileReviewResult(summary: "Reviewed \(call.path)", meetsCriteria: .unclear,
                                      concerns: concerns ?? [], confidence: .medium)
        return (result, ModelCallRecord(instructions: instructions, prompt: prompt, transcript: "t", rawOutput: "{}",
                                        inputTokens: prompt.count / 4, outputTokens: 40, latency: 0.01))
    }

    func verdict(instructions: String, prompt: String, options: ReviewOptions) async throws -> (VerdictResult, ModelCallRecord) {
        state.withLock { $0.verdictCalls.append(Call(instructions: instructions, prompt: prompt)) }
        let anyHigh = prompt.contains("• high")
        let verdict = VerdictResult(status: anyHigh ? .likelyProblem : .looksGood, criteriaCoverage: "No criteria provided.",
                                    topConcerns: anyHigh ? ["A high-severity concern"] : [], rationale: "Fake rationale.")
        return (verdict, ModelCallRecord(instructions: instructions, prompt: prompt, transcript: "t", rawOutput: "{}",
                                         inputTokens: 100, outputTokens: 30, latency: 0.01))
    }

    func difficulty(instructions: String, prompt: String, options: ReviewOptions) async throws -> DifficultyNudge {
        let (nudge, failure) = state.withLock { state in
            state.difficultyCalls.append(Call(instructions: instructions, prompt: prompt))
            return (state.difficultyNudge, state.difficultyFailure)
        }
        guard let nudge else { throw ReviewModelError(failure: failure, transcript: "") }
        return nudge
    }

    func dadJoke(instructions: String, prompt: String, options: ReviewOptions) async throws -> String {
        let joke = state.withLock { state in
            state.jokeCalls.append(Call(instructions: instructions, prompt: prompt))
            return state.joke
        }
        guard let joke else { throw ReviewModelError(failure: .refusal, transcript: "") }
        return joke
    }
}
