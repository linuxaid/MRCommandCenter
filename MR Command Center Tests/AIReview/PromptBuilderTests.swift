import Foundation
import Testing
@testable import MR_Command_Center

struct PromptBuilderTests {
    let counter = EstimatingTokenCounter()
    let context = ReviewContext(mrTitle: "Retry webhooks", mrDescription: "Adds retries.", jiraKey: "PAY-142")

    private func file(_ iid: Int = 412, _ index: Int = 0) -> DiffFile {
        let entry = MockGitLabData.sample.entries.first { $0.detail.iid == iid }!
        return DiffFile(entry.diffs[index], index: index)
    }

    @Test func contextSaysWhenThereAreNoAcceptanceCriteria() {
        let block = PromptBuilder.contextBlock(context)
        #expect(block.contains("Merge request: Retry webhooks"))
        #expect(block.contains("Acceptance criteria: none available"))
        var withCriteria = context
        withCriteria.acceptanceCriteria = "Retries 5xx up to 5 times."
        #expect(PromptBuilder.contextBlock(withCriteria).contains("Acceptance criteria:\nRetries 5xx"))
    }

    @Test func rendersNewLineNumbersForAddedAndContextLines() throws {
        let hunk = try #require(file().hunks.last)
        let rendered = PromptBuilder.render(hunk)
        let todoLine = try #require(rendered.split(separator: "\n").first { $0.contains("# TODO") })
        #expect(todoLine.hasPrefix("   40 + "))
        #expect(rendered.contains("      -         response = self._client.post("))
        #expect(rendered.hasPrefix("@@ -24,18 +26,30 @@"))
    }

    @Test func smallFileFitsInOnePartWithFlagsAndSkills() async throws {
        let python = SkillSnapshot(id: UUID(), name: "Python", version: 2, appliesTo: ["*.py"], content: "- Check None handling.")
        let swift = SkillSnapshot(id: UUID(), name: "Swift", version: 1, appliesTo: ["*.swift"], content: "- Force unwraps.")
        let flag = PatternFinding(kind: .debugOutput, path: "app/webhooks/delivery.py", line: 42, rule: "print(", excerpt: "print(x)")
        let plan = try await PromptBuilder.plan(file: file(), context: context, flags: [flag], skills: [python, swift],
                                                baseInstructions: "Base.", budget: PromptBudget(contextSize: 8192), counter: counter)
        #expect(plan.parts.count == 1)
        #expect(plan.skills.map(\.name) == ["Python"])
        #expect(plan.instructions.contains("### Python\n- Check None handling."))
        #expect(!plan.instructions.contains("Force unwraps"))
        #expect(plan.parts[0].contains("line 42: debug output (print()"))
        #expect(plan.parts[0].contains("File: app/webhooks/delivery.py"))
    }

    @Test func largeFileIsSplitIntoPartsThatEachFit() async throws {
        let large = file(415, 0)
        let budget = PromptBudget(contextSize: 3000)
        let plan = try await PromptBuilder.plan(file: large, context: context, flags: [], skills: [],
                                                baseInstructions: "Base.", budget: budget, counter: counter)
        #expect(plan.parts.count > 1)
        for part in plan.parts {
            #expect(try await counter.count(part) <= budget.promptTokens)
        }
        #expect(plan.parts[0].contains("Part 1 of \(plan.parts.count)"))
        // Every added line made it into some part.
        let joined = plan.parts.joined()
        #expect(joined.contains("match_rule_0(") && joined.contains("match_rule_61("))
    }

    @Test func skillsRespectTheTokenCap() async throws {
        let long = SkillSnapshot(id: UUID(), name: "Huge", version: 1, appliesTo: ["*"], content: String(repeating: "x ", count: 4000))
        let short = SkillSnapshot(id: UUID(), name: "Short", version: 1, appliesTo: ["*"], content: "- Short.")
        let plan = try await PromptBuilder.plan(file: file(), context: context, flags: [], skills: [long, short],
                                                baseInstructions: "Base.", budget: PromptBudget(contextSize: 8192), counter: counter)
        #expect(plan.skills.map(\.name) == ["Short"])
    }

    @Test func mergePromptUsesFindingsNotDiffsAndShrinksToFit() async throws {
        let concerns = (0..<20).map { ConcernResult(lineHint: "\($0)", severity: $0 == 0 ? .high : .low, explanation: String(repeating: "detail ", count: 20)) }
        let files = [
            PromptBuilder.FileSummary(path: "a.py", result: FileReviewResult(summary: "Adds retries", meetsCriteria: .unclear, concerns: concerns, confidence: .medium)),
            PromptBuilder.FileSummary(path: "b.png", problem: "skipped: Binary file"),
        ]
        let full = try await PromptBuilder.mergePrompt(context: context, files: files, staticSummary: "all passing", budgetTokens: 10_000, counter: counter)
        #expect(full.contains("• low at 1:"))
        #expect(full.contains("b.png: not reviewed (skipped: Binary file)"))
        #expect(!full.contains("@@"))

        let tight = try await PromptBuilder.mergePrompt(context: context, files: files, staticSummary: "all passing", budgetTokens: 400, counter: counter)
        #expect(tight.contains("• high at 0:"))
        #expect(!tight.contains("• low at 1:"))
    }

    @Test func mergesSplitFileResults() throws {
        let a = FileReviewResult(summary: "A", meetsCriteria: .yes, concerns: [.init(lineHint: "1", severity: .low, explanation: "x")], confidence: .high)
        let b = FileReviewResult(summary: "B", meetsCriteria: .partially, concerns: [.init(lineHint: "1", severity: .low, explanation: "x"),
                                                                                      .init(lineHint: "9", severity: .high, explanation: "y")], confidence: .low)
        let merged = try #require(FileReviewResult.merged([a, b]))
        #expect(merged.concerns.count == 2, "Duplicate concerns are dropped")
        #expect(merged.confidence == .low)
        #expect(merged.meetsCriteria == .partially)
        #expect(merged.summary == "Part 1: A Part 2: B")
    }
}

struct SkillTests {
    @Test(arguments: [
        ("app/x.py", "*.py", true), ("app/x.PY", "*.py", true), ("app/x.pyc", "*.py", false),
        ("src/a/b/c.ts", "src/**/*.ts", true), ("lib/c.ts", "src/**/*.ts", false),
        ("migrations/0042.sql", "migrations/*", true), ("anything/at/all", "*", true), ("x.py", "", false),
    ])
    func globMatching(path: String, pattern: String, expected: Bool) {
        #expect(SkillMatcher.matches(path, pattern: pattern) == expected)
    }

    @Test func parsesAndRendersSkillFiles() throws {
        let text = """
        ---
        name: Python
        applies_to: "*.py, *.pyi"
        ---
        - Check None handling.
        """
        let parsed = try SkillFile.parse(text)
        #expect(parsed == SkillFile.Parsed(name: "Python", appliesTo: ["*.py", "*.pyi"], content: "- Check None handling."))
        let rendered = SkillFile.render(name: parsed.name, appliesTo: parsed.appliesTo, content: parsed.content)
        #expect(try SkillFile.parse(rendered) == parsed)
    }

    @Test func plainMarkdownUsesTheFilenameAndAppliesEverywhere() throws {
        let parsed = try SkillFile.parse("- Be careful with money.\n", fallbackName: "Payments")
        #expect(parsed.name == "Payments")
        #expect(parsed.appliesTo == ["*"])
        #expect(throws: SkillFile.ParseError.missingName) { try SkillFile.parse("text") }
        #expect(throws: SkillFile.ParseError.emptyContent) { try SkillFile.parse("---\nname: X\n---\n  ") }
    }

    @Test func updatingASkillBumpsItsVersionOnlyOnChange() {
        let skill = ReviewSkill(name: "Go", appliesTo: ["*.go"], content: "- a")
        skill.update(name: "Go", appliesTo: ["*.go"], content: "- a")
        #expect(skill.version == 1)
        skill.update(name: "Go", appliesTo: ["*.go"], content: "- b")
        #expect(skill.version == 2)
        #expect(skill.snapshot.label == "Go v2")
    }
}
