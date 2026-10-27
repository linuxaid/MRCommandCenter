import Foundation
import SwiftUI
import Testing
@testable import MR_Command_Center

struct SyntaxHighlighterTests {
    /// The text of each token, with its kind, for readable expectations.
    private func lex(_ text: String, _ language: CodeLanguage, state: inout SyntaxHighlighter.State) -> [(String, SyntaxKind)] {
        let chars = Array(text)
        return SyntaxHighlighter.tokens(in: text, language: language, state: &state)
            .map { (String(chars[$0.range]), $0.kind) }
    }

    private func lex(_ text: String, _ language: CodeLanguage) -> [(String, SyntaxKind)] {
        var state = SyntaxHighlighter.State()
        return lex(text, language, state: &state)
    }

    private func kinds(_ tokens: [(String, SyntaxKind)]) -> [String: SyntaxKind] {
        Dictionary(tokens.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
    }

    @Test(arguments: [("App.swift", "Swift"), ("main.ts", "JavaScript"), ("view.TSX", "JavaScript"), ("api.py", "Python"),
                      ("Main.kt", "Java"), ("main.go", "Go"), ("lib.rs", "Rust"), ("query.sql", "SQL"),
                      ("deploy.sh", "Shell"), ("main.tf", "HCL"), ("config.yml", "YAML"), ("Dockerfile", "Shell"),
                      ("delivery.m", "C")])
    func detectsLanguages(path: String, name: String) {
        #expect(CodeLanguage.forPath(path)?.name == name)
    }

    @Test func unknownFilesAreNotHighlighted() {
        #expect(CodeLanguage.forPath("notes.txt") == nil)
        #expect(CodeLanguage.forPath("LICENSE") == nil)
    }

    @Test func swiftLine() {
        let tokens = kinds(lex(#"    @MainActor let count: Int = 42 // the answer"#, .swift))
        #expect(tokens["@MainActor"] == .attribute)
        #expect(tokens["let"] == .keyword)
        #expect(tokens["Int"] == .type)
        #expect(tokens["42"] == .number)
        #expect(tokens["// the answer"] == .comment)
        #expect(tokens["count"] == nil, "Plain identifiers stay uncolored")
    }

    @Test func stringsKeepEscapedQuotesInside() {
        let tokens = lex(#"let s = "say \"hi\"" + x"#, .swift)
        #expect(tokens.contains { $0 == (#""say \"hi\"""#, .string) })
    }

    @Test func commentMarkersInsideStringsArentComments() {
        let tokens = lex(#"let url = "https://example.com" "#, .swift)
        #expect(!tokens.contains { $0.1 == .comment })
    }

    @Test func numbersInsideIdentifiersArentNumbers() {
        #expect(!lex("let abc123 = sha256", .swift).contains { $0.1 == .number })
        #expect(lex("let x = 0x1F", .swift).contains { $0 == ("0x1F", .number) })
    }

    @Test func memberNamedLikeAKeywordIsNotAKeyword() {
        #expect(!lex("value.default", .swift).contains { $0.0 == "default" })
    }

    @Test func swiftDirectiveButPythonComment() {
        #expect(lex("#if DEBUG", .swift).first?.1 == .directive)
        #expect(lex("# just a note", .python).first?.1 == .comment)
    }

    @Test func sqlKeywordsIgnoreCase() {
        let tokens = kinds(lex("SELECT id FROM users WHERE active -- live only", .sql))
        #expect(tokens["SELECT"] == .keyword && tokens["FROM"] == .keyword && tokens["WHERE"] == .keyword)
        #expect(tokens["-- live only"] == .comment)
    }

    @Test func blockCommentCarriesAcrossLines() {
        var state = SyntaxHighlighter.State()
        #expect(lex("let a = 1 /* starts", .swift, state: &state).last?.1 == .comment)
        #expect(state.inBlockComment)
        #expect(lex("still a comment", .swift, state: &state).map(\.1) == [.comment])
        let closing = lex("ends */ let b = 2", .swift, state: &state)
        #expect(closing.first?.1 == .comment)
        #expect(closing.contains { $0 == ("let", .keyword) })
        #expect(!state.inBlockComment)
    }

    @Test func pythonTripleQuotedStringCarriesAcrossLines() {
        var state = SyntaxHighlighter.State()
        _ = lex(#"doc = """Starts here"#, .python, state: &state)
        #expect(state.openTripleQuote == #"""""#)
        #expect(lex("def not_code():", .python, state: &state).map(\.1) == [.string])
        _ = lex(#"ends""" "#, .python, state: &state)
        #expect(state.openTripleQuote == nil)
    }

    @Test func removedCommentDoesNotColorAddedLines() {
        let hunk = UnifiedDiffParser.parse("""
        @@ -1,2 +1,2 @@
        -/* old comment opens
        +let value = 1
         let other = 2
        """).first!
        let tokens = SyntaxHighlighter.highlight([hunk], language: .swift)
        let added = hunk.lines.first { $0.kind == .addition }!
        #expect(tokens[added.id]?.first?.kind == .keyword, "The added line is lexed on the new side, which has no open comment")
    }

    @Test func tabsAreMeasuredAsDisplayed() {
        let tokens = lex("\tlet x = 1", .swift)
        #expect(tokens.first?.0 == "let")
        #expect(SyntaxHighlighter.displayText("\tlet") == "    let")
    }

    @Test func attributedTextKeepsEveryCharacter() {
        let text = #"let s = "hi" // done"#
        var state = SyntaxHighlighter.State()
        let attributed = SyntaxColors.attributed(text, tokens: SyntaxHighlighter.tokens(in: text, language: .swift, state: &state))
        #expect(String(attributed.characters) == text)
    }
}
