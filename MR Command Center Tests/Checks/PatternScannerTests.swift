import Foundation
import Testing
@testable import MR_Command_Center

struct PatternScannerTests {
    private func scan(_ line: String, debug: [String] = AccountSettings.defaultDebugPatterns,
                      todos: [String] = AccountSettings.defaultTodoMarkers) -> [PatternFinding] {
        PatternScanner.scan(line: line, path: "a.py", number: 7, debugPatterns: debug, todoMarkers: todos)
    }

    @Test(arguments: [
        ("access_key = \"AKIAIOSFODNN7EXAMPLE\"", "AWS access key ID"),
        ("token = 'ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789'", "GitHub token"),
        ("GITLAB=glpat-abcdefghij1234567890", "GitLab token"),
        ("-----BEGIN RSA PRIVATE KEY-----", "Private key"),
        ("-----BEGIN PRIVATE KEY-----", "Private key"),
        ("password = \"hunter2hunter2\"", "Hard-coded credential"),
        ("const apiKey: \"s3cr3t-value-123\"", "Hard-coded credential"),
        ("stripe = 'sk_live_abcdefghijklmnopqrstuvwx'", "Stripe live key"),
    ])
    func detectsSecrets(line: String, rule: String) throws {
        let finding = try #require(scan(line).first { $0.kind == .secret })
        #expect(finding.rule == rule)
        #expect(finding.line == 7)
    }

    @Test func masksTheSecretValueInTheExcerpt() throws {
        let finding = try #require(scan("  access_key = \"AKIAIOSFODNN7EXAMPLE\"").first)
        #expect(!finding.excerpt.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(finding.excerpt.hasPrefix("access_key = \"AKIA"))
        #expect(finding.excerpt.contains("MPLE\""))
    }

    @Test(arguments: ["password = os.environ['DB_PASSWORD']", "token = get_token()", "secret = \"short\"", "AKIA is an AWS prefix"])
    func ignoresNonSecrets(line: String) {
        #expect(!scan(line).contains { $0.kind == .secret })
    }

    @Test(arguments: [
        ("print(f\"retrying {x}\")", true), ("    print('x')", true), ("console.log('saved')", true),
        ("fingerprint(data)", false), ("self.pprint(x)", false), ("logger.info('print( is fine')", true),
        ("debugger;", true),
    ])
    func debugOutputRespectsWordBoundaries(line: String, flagged: Bool) {
        #expect(scan(line).contains { $0.kind == .debugOutput } == flagged)
    }

    @Test(arguments: [("# TODO: retry", true), ("// FIXME later", true), ("TODOS = []", false), ("autodo()", false), ("todo lowercase", false)])
    func todoMarkersAreCaseSensitiveWholeWords(line: String, flagged: Bool) {
        #expect(scan(line).contains { $0.kind == .todo } == flagged)
    }

    @Test func customPatternsReplaceDefaults() {
        #expect(scan("puts 'x'", debug: ["puts"]).contains { $0.kind == .debugOutput })
        #expect(scan("print('x')", debug: ["puts"]).isEmpty)
        #expect(scan("// HACK: temporary", todos: ["HACK"]).contains { $0.kind == .todo })
    }

    @Test func scansOnlyAddedLinesInNonGeneratedFiles() {
        let diff = GitLabDiff(oldPath: "a.py", newPath: "a.py", diff: """
        @@ -1,3 +1,3 @@
         print("context")
        -print("removed")
        +print("added")
        """, newFile: false, renamedFile: false, deletedFile: false)
        var generated = diff
        generated.newPath = "gen.py"
        generated.oldPath = "gen.py"
        generated.generatedFile = true
        let files = [DiffFile(diff, index: 0), DiffFile(generated, index: 1)]

        let findings = PatternScanner.scan(files, debugPatterns: ["print("], todoMarkers: [])
        #expect(findings.count == 1)
        #expect(findings.first?.line == 2)
        #expect(findings.first?.path == "a.py")
    }
}

struct TestFileClassifierTests {
    @Test(arguments: [
        "tests/webhooks/test_delivery.py", "src/orders/totals.test.ts", "src/cart/Cart.spec.tsx",
        "pkg/server/handler_test.go", "MR Command Center Tests/Core/HTTPClientTests.swift",
        "app/__tests__/thing.js", "spec/models/user_spec.rb", "src/test/java/com/acme/FooTest.java",
    ])
    func recognizesTests(path: String) {
        #expect(TestFileClassifier.classify(path) == .test)
    }

    @Test(arguments: ["app/webhooks/delivery.py", "src/cart/savedCarts.ts", "Sources/App/Contest.swift", "cmd/main.go", "src/latest.ts"])
    func recognizesSource(path: String) {
        #expect(TestFileClassifier.classify(path) == .source)
    }

    @Test(arguments: ["README.md", "poetry.lock", "terraform/versions.tf", "migrations/0042.sql", "public/logo.png", "tests/fixtures/data.json"])
    func otherFilesAreNeither(path: String) {
        #expect(TestFileClassifier.classify(path) != .source)
    }

    @Test func extraPatternsMarkTests() {
        #expect(TestFileClassifier.classify("src/Fixtures/Builder.swift") == .source)
        #expect(TestFileClassifier.classify("src/Fixtures/Builder.swift", extraTestPatterns: ["fixtures/"]) == .test)
    }
}
