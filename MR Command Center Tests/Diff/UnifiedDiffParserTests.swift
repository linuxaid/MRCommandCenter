import Testing
@testable import MR_Command_Center

struct UnifiedDiffParserTests {
    @Test func numbersLinesAcrossAdditionsAndDeletions() throws {
        let hunks = UnifiedDiffParser.parse("""
        @@ -10,4 +10,5 @@ func example()
         context one
        -removed
        +added one
        +added two
         context two
        """)
        let hunk = try #require(hunks.first)
        #expect(hunks.count == 1)
        #expect((hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount) == (10, 4, 10, 5))
        #expect(hunk.section == "func example()")

        let summary = hunk.lines.map { "\($0.kind) \($0.oldNumber.map(String.init) ?? "-") \($0.newNumber.map(String.init) ?? "-") \($0.text)" }
        #expect(summary == [
            "context 10 10 context one",
            "deletion 11 - removed",
            "addition - 11 added one",
            "addition - 12 added two",
            "context 12 13 context two",
        ])
    }

    @Test func parsesMultipleHunksAndOmittedCounts() {
        let hunks = UnifiedDiffParser.parse("""
        @@ -1 +1 @@
        -a
        +b
        @@ -20,2 +20,3 @@
         x
        +y
         z
        """)
        #expect(hunks.count == 2)
        #expect(hunks[0].oldCount == 1 && hunks[0].newCount == 1)
        #expect(hunks[1].lines.map(\.newNumber) == [20, 21, 22])
        #expect(Set(hunks.flatMap(\.lines).map(\.id)).count == 5, "Line IDs are unique across hunks")
    }

    @Test func handlesNoNewlineMarker() {
        let hunk = UnifiedDiffParser.parse("@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n")[0]
        #expect(hunk.lines.map(\.kind) == [.deletion, .noNewline, .addition, .noNewline])
        #expect(hunk.lines[1].text == "No newline at end of file")
        #expect(hunk.lines[2].newNumber == 1, "Marker lines don't advance numbering")
    }

    @Test func skipsFileHeadersButKeepsDashLinesInsideHunks() {
        let hunks = UnifiedDiffParser.parse("""
        diff --git a/x.sql b/x.sql
        index 111..222 100644
        --- a/x.sql
        +++ b/x.sql
        @@ -1,2 +1,2 @@
        --- a SQL comment
        +++ looks like a header
         select 1;
        """)
        #expect(hunks.count == 1)
        #expect(hunks[0].lines.map(\.kind) == [.deletion, .addition, .context])
        #expect(hunks[0].lines[0].text == "-- a SQL comment")
        #expect(hunks[0].lines[1].text == "++ looks like a header")
    }

    @Test func treatsEmptyLinesAsBlankContextAndStripsCarriageReturns() throws {
        let hunk = try #require(UnifiedDiffParser.parse("@@ -1,3 +1,3 @@\r\n a\r\n\r\n b\r\n").first)
        #expect(hunk.lines.map(\.kind) == [.context, .context, .context])
        #expect(hunk.lines.map(\.text) == ["a", "", "b"])
        #expect(hunk.lines.map(\.newNumber) == [1, 2, 3])
    }

    @Test func newFileStartsAtLineOne() {
        let hunk = UnifiedDiffParser.parse("@@ -0,0 +1,2 @@\n+one\n+two\n")[0]
        #expect(hunk.lines.map(\.newNumber) == [1, 2])
        #expect(hunk.lines.allSatisfy { $0.oldNumber == nil })
    }

    @Test func emptyOrHeaderlessInputHasNoHunks() {
        #expect(UnifiedDiffParser.parse("").isEmpty)
        #expect(UnifiedDiffParser.parse("Binary files a/x and b/x differ\n").isEmpty)
    }
}

struct SideBySideTests {
    @Test func pairsDeletionsWithFollowingAdditions() {
        let hunk = UnifiedDiffParser.parse("""
        @@ -1,4 +1,4 @@
         keep
        -old1
        -old2
        +new1
         tail
        +extra
        """)[0]
        let rows = SideBySide.rows(for: hunk)
        let shape = rows.map { "\($0.left?.text ?? "_")|\($0.right?.text ?? "_")" }
        #expect(shape == ["keep|keep", "old1|new1", "old2|_", "tail|tail", "_|extra"])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func skipsNoNewlineMarkers() {
        let hunk = UnifiedDiffParser.parse("@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n")[0]
        #expect(SideBySide.rows(for: hunk).count == 1)
    }
}
