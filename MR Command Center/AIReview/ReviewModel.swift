import Foundation
import FoundationModels
import Synchronization

nonisolated struct ReviewOptions: Sendable, Equatable {
    var greedy = true
    var temperature = 0.3
    var maximumResponseTokens = 800
    var toolsEnabled = false

    var generationOptions: GenerationOptions {
        greedy
            ? GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
            : GenerationOptions(temperature: temperature, maximumResponseTokens: maximumResponseTokens)
    }
}

/// The model seam: the live on-device model, or a fake in tests.
nonisolated protocol ReviewLanguageModel: Sendable {
    var identifier: String { get }
    var contextSize: Int { get }
    var tokenCounter: any TokenCounter { get }

    func reviewFile(instructions: String, prompt: String, options: ReviewOptions, tools: ReviewTools?) async throws -> (FileReviewResult, ModelCallRecord)
    func verdict(instructions: String, prompt: String, options: ReviewOptions) async throws -> (VerdictResult, ModelCallRecord)
    /// Whether an MR is simpler or harder to review than its size suggests (#36).
    func difficulty(instructions: String, prompt: String, options: ReviewOptions) async throws -> DifficultyNudge
    /// Today's dad joke, as plain text (#38).
    func dadJoke(instructions: String, prompt: String, options: ReviewOptions) async throws -> String
}

/// Apple's on-device model through Foundation Models. One fresh session per call.
nonisolated struct OnDeviceReviewModel: ReviewLanguageModel {
    var identifier: String {
        "apple.on-device.default (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))"
    }

    var contextSize: Int { SystemLanguageModel.default.contextSize }
    var tokenCounter: any TokenCounter { ModelTokenCounter() }

    func reviewFile(instructions: String, prompt: String, options: ReviewOptions, tools: ReviewTools?) async throws -> (FileReviewResult, ModelCallRecord) {
        let session = LanguageModelSession(model: .default, tools: tools?.tools ?? [], instructions: instructions)
        let start = ContinuousClock.now
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedFileFinding.self, options: options.generationOptions)
            let result = response.content.result
            var record = try await callRecord(session: session, instructions: instructions, prompt: prompt,
                                              raw: result, rawContent: response.rawContent, start: start)
            if #available(macOS 27.0, *) {
                record.inputTokens = response.usage.input.totalTokenCount
                record.outputTokens = response.usage.output.totalTokenCount
            }
            record.toolCalls = tools?.recorder.calls ?? []
            return (result, record)
        } catch {
            throw ReviewModelError(failure: ReviewFailureMapper.map(error), transcript: Self.render(session.transcript))
        }
    }

    func verdict(instructions: String, prompt: String, options: ReviewOptions) async throws -> (VerdictResult, ModelCallRecord) {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let start = ContinuousClock.now
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedVerdict.self, options: options.generationOptions)
            let result = response.content.result
            var record = try await callRecord(session: session, instructions: instructions, prompt: prompt,
                                              raw: result, rawContent: response.rawContent, start: start)
            if #available(macOS 27.0, *) {
                record.inputTokens = response.usage.input.totalTokenCount
                record.outputTokens = response.usage.output.totalTokenCount
            }
            return (result, record)
        } catch {
            throw ReviewModelError(failure: ReviewFailureMapper.map(error), transcript: Self.render(session.transcript))
        }
    }

    func difficulty(instructions: String, prompt: String, options: ReviewOptions) async throws -> DifficultyNudge {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedDifficulty.self, options: options.generationOptions)
            return response.content.result
        } catch {
            throw ReviewModelError(failure: ReviewFailureMapper.map(error), transcript: Self.render(session.transcript))
        }
    }

    func dadJoke(instructions: String, prompt: String, options: ReviewOptions) async throws -> String {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        do {
            return try await session.respond(to: prompt, options: options.generationOptions).content
        } catch {
            throw ReviewModelError(failure: ReviewFailureMapper.map(error), transcript: Self.render(session.transcript))
        }
    }

    private func callRecord<T: Encodable>(session: LanguageModelSession, instructions: String, prompt: String,
                                          raw: T, rawContent: GeneratedContent, start: ContinuousClock.Instant) async throws -> ModelCallRecord {
        let elapsed = ContinuousClock.now - start
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = (try? encoder.encode(raw)).map { String(decoding: $0, as: UTF8.self) } ?? String(describing: rawContent)
        // Token counts for macOS 26.x, where `usage` isn't available; replaced on 27.
        let transcriptTokens = try? await SystemLanguageModel.default.tokenCount(for: session.transcript)
        return ModelCallRecord(
            instructions: instructions,
            prompt: prompt,
            transcript: Self.render(session.transcript),
            rawOutput: json,
            inputTokens: transcriptTokens,
            outputTokens: nil,
            latency: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
    }

    static func render(_ transcript: Transcript) -> String {
        transcript.map { entry in
            switch entry {
            case .instructions: "── Instructions ──\n\(entry)"
            case .prompt: "── Prompt ──\n\(entry)"
            case .toolCalls: "── Tool calls ──\n\(entry)"
            case .toolOutput: "── Tool output ──\n\(entry)"
            case .response: "── Response ──\n\(entry)"
            default: "── \(entry.id) ──\n\(entry)"
            }
        }.joined(separator: "\n\n")
    }
}

/// A model failure plus whatever transcript existed when it failed.
nonisolated struct ReviewModelError: Error, Sendable {
    let failure: ReviewFailure
    let transcript: String
}

nonisolated struct ModelTokenCounter: TokenCounter {
    func count(_ text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: text)
    }

    func fileSchemaTokens() async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: GeneratedFileFinding.generationSchema)
    }

    func verdictSchemaTokens() async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: GeneratedVerdict.generationSchema)
    }
}

/// Maps Foundation Models errors (26.x `GenerationError`, 27 `LanguageModelError`) to `ReviewFailure`.
nonisolated enum ReviewFailureMapper {
    static func map(_ error: any Error) -> ReviewFailure {
        if let failure = error as? ReviewFailure { return failure }
        if let error = error as? ReviewModelError { return error.failure }
        if error is CancellationError { return .other("Cancelled") }
        // Foundation Models' ParsingError (structured output didn't match the schema) isn't public API.
        if String(describing: type(of: error)).contains("ParsingError") { return .decodingFailure }
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .contextSizeExceeded
            case .guardrailViolation: return .guardrailViolation
            case .refusal: return .refusal
            case .rateLimited: return .rateLimited
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .timeout: return .timeout
            default: return .other(error.localizedDescription)
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextSizeExceeded
            case .guardrailViolation: return .guardrailViolation
            case .refusal: return .refusal
            case .rateLimited, .concurrentRequests: return .rateLimited
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .assetsUnavailable: return .modelUnavailable
            case .decodingFailure, .unsupportedGuide: return .decodingFailure
            @unknown default: return .other(error.localizedDescription)
            }
        }
        return .other(error.localizedDescription)
    }
}

// MARK: - Tools

/// Records tool calls so the inspector can show them.
nonisolated final class ToolCallRecorder: Sendable {
    private let state = Mutex<[ToolCallLog]>([])
    var calls: [ToolCallLog] { state.withLock { $0 } }
    func record(_ log: ToolCallLog) { state.withLock { $0.append(log) } }
}

/// Tools offered to the model when the "Allow tools" setting is on.
nonisolated struct ReviewTools: Sendable {
    let tools: [any Tool]
    let recorder: ToolCallRecorder

    static func make(fetch: @escaping @Sendable (String) async throws -> String) -> ReviewTools {
        let recorder = ToolCallRecorder()
        return ReviewTools(tools: [ReadFileLinesTool(fetch: fetch, recorder: recorder)], recorder: recorder)
    }
}

/// Lets the model read lines of a file at the MR's head commit when a hunk lacks context.
nonisolated struct ReadFileLinesTool: Tool {
    let name = "readFileLines"
    let description = "Reads numbered lines from a file at the merge request's head commit. Use only when a hunk lacks the context needed to judge it."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Path of the file, as shown in the diff")
        var path: String
        @Guide(description: "First line to read, starting at 1")
        var startLine: Int
        @Guide(description: "How many lines to read", .range(1...60))
        var lineCount: Int
    }

    let fetch: @Sendable (String) async throws -> String
    let recorder: ToolCallRecorder

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        let summary = "\(arguments.path) lines \(arguments.startLine)–\(arguments.startLine + arguments.lineCount - 1)"
        do {
            let lines = try await fetch(arguments.path).split(separator: "\n", omittingEmptySubsequences: false)
            let start = max(1, arguments.startLine)
            let end = min(lines.count, start + min(arguments.lineCount, 60) - 1)
            guard start <= end else {
                recorder.record(ToolCallLog(tool: name, arguments: summary, resultSummary: "Out of range (\(lines.count) lines)", succeeded: false))
                return "The file has \(lines.count) lines."
            }
            let text = (start...end).map { String(format: "%5d  ", $0) + lines[$0 - 1] }.joined(separator: "\n")
            recorder.record(ToolCallLog(tool: name, arguments: summary, resultSummary: "Returned \(end - start + 1) lines", succeeded: true))
            return text
        } catch {
            recorder.record(ToolCallLog(tool: name, arguments: summary, resultSummary: error.localizedDescription, succeeded: false))
            return "Could not read the file: \(error.localizedDescription)"
        }
    }
}
