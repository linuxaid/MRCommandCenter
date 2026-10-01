import Foundation

/// Counts tokens the way the model will. The live counter asks Foundation Models;
/// tests use a deterministic estimate.
nonisolated protocol TokenCounter: Sendable {
    func count(_ text: String) async throws -> Int
    /// Tokens the response schema adds to every file review.
    func fileSchemaTokens() async throws -> Int
    func verdictSchemaTokens() async throws -> Int
}

/// Roughly 3.5 characters per token, plus per-call overhead. Used in tests and as a fallback.
nonisolated struct EstimatingTokenCounter: TokenCounter {
    var schemaTokens = 250

    func count(_ text: String) async throws -> Int { text.count * 2 / 7 + 4 }
    func fileSchemaTokens() async throws -> Int { schemaTokens }
    func verdictSchemaTokens() async throws -> Int { schemaTokens }
}

/// What the model is told about the MR as a whole.
nonisolated struct ReviewContext: Sendable, Equatable {
    var mrTitle: String
    var mrDescription: String
    var jiraKey: String?
    var jiraSummary: String?
    var acceptanceCriteria: String?
    var storyDescription: String?
    /// Why there's no story, when there isn't one (e.g. "Jira isn't connected").
    var storyUnavailableReason: String?

    var hasStory: Bool { jiraSummary != nil || hasAcceptanceCriteria }

    var hasAcceptanceCriteria: Bool {
        !(acceptanceCriteria?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// Token budget for one session.
nonisolated struct PromptBudget: Sendable, Equatable {
    var contextSize: Int
    /// Room left for the model's answer.
    var responseReserve = 900
    /// Room for tool calls and their output, when tools are enabled.
    var toolReserve = 0

    var promptTokens: Int { contextSize - responseReserve - toolReserve }
}

/// The prompt(s) for one file. More than one part when the diff doesn't fit.
nonisolated struct FilePromptPlan: Sendable, Equatable {
    var instructions: String
    var parts: [String]
    var skills: [SkillSnapshot]
    /// Tokens of instructions + schema + the largest part.
    var estimatedTokens: Int
}

nonisolated enum PromptBuilder {
    static let maxDescriptionCharacters = 600
    static let maxCriteriaCharacters = 1_500
    static let maxStoryCharacters = 800
    /// Upper bound on skill text per file, so skills can't crowd out the diff.
    static let maxSkillTokens = 600

    // MARK: Pieces

    static func instructions(base: String, skills: [SkillSnapshot]) -> String {
        guard !skills.isEmpty else { return base }
        let guidance = skills.map { "### \($0.name)\n\($0.content)" }.joined(separator: "\n\n")
        return base + "\n\nLanguage and project guidance:\n" + guidance
    }

    static func contextBlock(_ context: ReviewContext) -> String {
        var lines = ["Merge request: \(context.mrTitle)"]
        let description = context.mrDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            lines.append("Description: " + truncate(description, to: maxDescriptionCharacters))
        }
        if let key = context.jiraKey, let summary = context.jiraSummary {
            lines.append("Story \(key): \(summary)")
            if let story = context.storyDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !story.isEmpty {
                // The criteria are listed separately; keep the rest of the story short.
                let withoutCriteria = context.hasAcceptanceCriteria ? story.replacingOccurrences(of: context.acceptanceCriteria ?? "", with: "") : story
                lines.append("Story description: " + truncate(withoutCriteria.trimmingCharacters(in: .whitespacesAndNewlines), to: maxStoryCharacters))
            }
        }
        if context.hasAcceptanceCriteria, let criteria = context.acceptanceCriteria {
            lines.append("Acceptance criteria:\n" + truncate(criteria, to: maxCriteriaCharacters))
            lines.append("Judge whether this file's change does what the story and criteria ask.")
        } else if context.jiraSummary != nil {
            lines.append("Acceptance criteria: none listed, so judge meetsCriteria against the story description.")
        } else {
            let reason = context.storyUnavailableReason ?? "Jira is not connected"
            lines.append("Acceptance criteria: none available (\(reason)), so set meetsCriteria to unclear and judge correctness only.")
        }
        return lines.joined(separator: "\n")
    }

    static func flagsBlock(_ findings: [PatternFinding]) -> String? {
        guard !findings.isEmpty else { return nil }
        let lines = findings.map { "- line \($0.line): \($0.kind.label) (\($0.rule))" }
        return "Static analysis flags for this file:\n" + lines.joined(separator: "\n")
    }

    static func fileHeader(_ file: DiffFile) -> String {
        switch file.change {
        case .added: "File: \(file.path) (new file)"
        case .deleted: "File: \(file.path) (deleted)"
        case .renamed: "File: \(file.newPath) (renamed from \(file.oldPath))"
        case .modified: "File: \(file.path)"
        }
    }

    /// Hunk text with new-side line numbers so the model can cite lines.
    static func render(_ hunk: DiffHunk) -> String {
        var lines = [hunk.header]
        for line in hunk.lines {
            switch line.kind {
            case .addition: lines.append(String(format: "%5d + ", line.newNumber ?? 0) + line.text)
            case .deletion: lines.append("      - " + line.text)
            case .context: lines.append(String(format: "%5d   ", line.newNumber ?? 0) + line.text)
            case .noNewline: lines.append("      \\ " + line.text)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    // MARK: File plan

    /// Builds the prompt for one file, splitting by hunk (and splitting oversized hunks by
    /// line) so each part fits the budget.
    static func plan(
        file: DiffFile,
        context: ReviewContext,
        flags: [PatternFinding],
        skills allSkills: [SkillSnapshot],
        baseInstructions: String,
        budget: PromptBudget,
        counter: any TokenCounter
    ) async throws -> FilePromptPlan {
        let skills = try await fittingSkills(SkillMatcher.skills(for: file.path, from: allSkills), counter: counter)
        let instructions = instructions(base: baseInstructions, skills: skills)
        let fixed = try await counter.count(instructions) + counter.fileSchemaTokens()

        var header = [contextBlock(context), flagsBlock(flags), fileHeader(file)].compactMap { $0 }.joined(separator: "\n\n")
        var available = budget.promptTokens - fixed - (try await counter.count(header)) - 20
        if available < 400 {
            // Drop the description before giving up diff space.
            var trimmed = context
            trimmed.mrDescription = ""
            header = [contextBlock(trimmed), flagsBlock(flags), fileHeader(file)].compactMap { $0 }.joined(separator: "\n\n")
            available = budget.promptTokens - fixed - (try await counter.count(header)) - 20
        }
        available = max(available, 200)

        let chunks = try await chunks(for: file.hunks, available: available, counter: counter)
        let parts = chunks.enumerated().map { index, body in
            let partLabel = chunks.count > 1 ? "\nPart \(index + 1) of \(chunks.count) of this file's diff:\n" : "\nDiff:\n"
            return header + "\n" + partLabel + body
        }
        var largest = 0
        for part in parts { largest = max(largest, try await counter.count(part)) }
        return FilePromptPlan(instructions: instructions, parts: parts, skills: skills, estimatedTokens: fixed + largest)
    }

    private static func fittingSkills(_ skills: [SkillSnapshot], counter: any TokenCounter) async throws -> [SkillSnapshot] {
        var kept: [SkillSnapshot] = []
        var used = 0
        for skill in skills {
            let tokens = try await counter.count(skill.content) + 6
            guard used + tokens <= maxSkillTokens else { continue }
            used += tokens
            kept.append(skill)
        }
        return kept
    }

    /// Packs hunks greedily into chunks under `available` tokens.
    static func chunks(for hunks: [DiffHunk], available: Int, counter: any TokenCounter) async throws -> [String] {
        var pieces: [String] = []
        for hunk in hunks {
            let text = render(hunk)
            if try await counter.count(text) <= available {
                pieces.append(text)
            } else {
                pieces += try await split(hunk, available: available, counter: counter)
            }
        }

        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = current.isEmpty ? piece : current + "\n" + piece
            let fits = current.isEmpty ? true : try await counter.count(candidate) <= available
            if fits {
                current = candidate
            } else {
                chunks.append(current)
                current = piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? ["(no line changes)"] : chunks
    }

    /// Splits one oversized hunk into line ranges, each with its own header.
    private static func split(_ hunk: DiffHunk, available: Int, counter: any TokenCounter) async throws -> [String] {
        var pieces: [String] = []
        var lines: [String] = []
        let rendered = render(hunk).split(separator: "\n", omittingEmptySubsequences: false).dropFirst().map(String.init)
        for line in rendered {
            let candidate = ([hunk.header + " (continued)"] + lines + [line]).joined(separator: "\n")
            if !lines.isEmpty, try await counter.count(candidate) > available {
                pieces.append(([hunk.header + (pieces.isEmpty ? "" : " (continued)")] + lines).joined(separator: "\n"))
                lines = []
            }
            lines.append(line)
        }
        if !lines.isEmpty {
            pieces.append(([hunk.header + (pieces.isEmpty ? "" : " (continued)")] + lines).joined(separator: "\n"))
        }
        return pieces
    }

    // MARK: Merge prompt

    nonisolated struct FileSummary: Sendable {
        var path: String
        var result: FileReviewResult?
        var problem: String?
    }

    /// The verdict prompt: per-file findings (never raw diffs) plus criteria and static checks.
    static func mergePrompt(context: ReviewContext, files: [FileSummary], staticSummary: String,
                            budgetTokens: Int, counter: any TokenCounter) async throws -> String {
        func build(maxConcernSeverity: Severity) -> String {
            var sections = [contextBlock(context), "Static checks: " + staticSummary, "Per-file findings:"]
            for file in files {
                if let result = file.result {
                    var block = "- \(file.path): \(result.summary) [criteria: \(result.meetsCriteria.rawValue), confidence: \(result.confidence.rawValue)]"
                    let concerns = result.concerns.filter { $0.severity >= maxConcernSeverity }
                    for concern in concerns {
                        block += "\n    • \(concern.severity.rawValue) at \(concern.lineHint): \(concern.explanation)"
                    }
                    if concerns.isEmpty && !result.concerns.isEmpty {
                        block += "\n    • (\(result.concerns.count) lower-severity concerns omitted)"
                    }
                    sections.append(block)
                } else if let problem = file.problem {
                    sections.append("- \(file.path): not reviewed (\(problem))")
                }
            }
            return sections.joined(separator: "\n")
        }
        // Drop low, then medium concerns if the findings don't fit.
        for threshold in [Severity.low, .medium, .high] {
            let prompt = build(maxConcernSeverity: threshold)
            if try await counter.count(prompt) <= budgetTokens { return prompt }
        }
        return truncate(build(maxConcernSeverity: .high), to: budgetTokens * 3)
    }
}

extension PatternFinding.Kind {
    nonisolated var label: String {
        switch self {
        case .secret: "possible secret"
        case .debugOutput: "debug output"
        case .todo: "TODO marker"
        }
    }
}
