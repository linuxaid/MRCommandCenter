import Testing
@testable import MR_Command_Center

struct JiraKeyExtractorTests {
    @Test(arguments: [
        ("feature/PAY-142-webhook-retries", "PAY-142"),
        ("PAY-142", "PAY-142"),
        ("bugfix/SHOP-91-rounding", "SHOP-91"),
        ("INFRA-12-vault-rotation", "INFRA-12"),
        ("feature/AB2-7_thing", "AB2-7"),
        ("hotfix/PAY-1-and-PAY-2", "PAY-1"),
    ])
    func extractsFirstKey(branch: String, expected: String) {
        #expect(JiraKeyExtractor.extractKey(from: branch) == expected)
    }

    @Test(arguments: ["chore/bump-aws-provider", "main", "feature/pay-142-lowercase", "A-1", ""])
    func returnsNilWithoutKey(branch: String) {
        #expect(JiraKeyExtractor.extractKey(from: branch) == nil)
    }

    @Test func usesCustomPattern() {
        #expect(JiraKeyExtractor.extractKey(from: "feature/pay-142-x", pattern: "(?i)[a-z]+-\\d+")?.uppercased() == "PAY-142")
        #expect(JiraKeyExtractor.extractKey(from: "ticket-77/fix", pattern: "ticket-\\d+") == "ticket-77")
    }

    @Test func invalidOrEmptyPatternReturnsNil() {
        #expect(JiraKeyExtractor.extractKey(from: "PAY-142", pattern: "[unclosed") == nil)
        #expect(JiraKeyExtractor.extractKey(from: "PAY-142", pattern: "") == nil)
    }
}
