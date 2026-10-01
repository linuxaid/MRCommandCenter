import Foundation

nonisolated struct MockJiraClient: JiraAPI {
    var user = JiraUser(accountId: "mock-account", displayName: "A.J. Reviewer", emailAddress: "reviewer@example.com")
    var failure: APIError?
    var issues: [String: JiraIssue] = MockJiraData.issues

    func myself() async throws -> JiraUser {
        if let failure { throw failure }
        return user
    }

    func issue(key: String, fields: [String]) async throws -> JiraIssue {
        if let failure { throw failure }
        guard let issue = issues[key] else { throw APIError.notFound }
        return issue
    }

    func fields() async throws -> [JiraField] {
        if let failure { throw failure }
        return MockJiraData.fieldList
    }
}

/// Sample stories for the mock MRs. Several criteria disagree with the mock code on
/// purpose (429 handling, credentials in Terraform, idempotency key expiry) so the AI
/// review has something real to catch. SHOP-95 is missing (404), PAY-150 has no priority.
nonisolated enum MockJiraData {
    static let acceptanceCriteriaField = "customfield_10050"

    static let fieldList: [JiraField] = [
        JiraField(id: "summary", name: "Summary", custom: false),
        JiraField(id: "priority", name: "Priority", custom: false),
        JiraField(id: "fixVersions", name: "Fix versions", custom: false),
        JiraField(id: acceptanceCriteriaField, name: "Acceptance Criteria", custom: true),
        JiraField(id: "customfield_10020", name: "Sprint", custom: true),
    ]

    static let issues: [String: JiraIssue] = [
        "PAY-142": issue("PAY-142", "Retry failed webhook deliveries", status: ("In Review", "indeterminate"), type: "Story",
                         assignee: "Priya Natarajan", priority: "High", versions: ["2.4.0"],
                         description: doc([paragraph("Merchants miss webhooks when their endpoint has a brief outage. Retry deliveries so short outages don't lose events.")]),
                         criteria: doc([bullets([
                             "Retries 5xx responses and network errors with exponential backoff, up to 5 attempts",
                             "429 responses honor Retry-After and are retried",
                             "Permanent 4xx failures are not retried",
                             "The final outcome of every delivery is logged",
                         ])])),
        "SHOP-88": issue("SHOP-88", "Save carts for later", status: ("In Progress", "indeterminate"), type: "Story",
                         assignee: "Marco Bianchi", priority: "Medium", versions: ["2.5.0"],
                         description: doc([
                             paragraph("Shoppers want to come back to a cart later."),
                             heading("Acceptance Criteria", level: 3),
                             bullets([
                                 "Shoppers can save the current cart with a name",
                                 "Saved carts can be restored from checkout",
                                 "If saving fails, the shopper sees an error message",
                             ]),
                             heading("Notes", level: 3),
                             paragraph("Design is in Figma."),
                         ]), criteria: nil),
        "PAY-150": issue("PAY-150", "Refactor ledger reconciliation", status: ("In Progress", "indeterminate"), type: "Task",
                         assignee: nil, priority: nil, versions: [],
                         description: doc([paragraph("Split reconciliation into matching rules so each rule can be tested on its own.")]), criteria: nil),
        "SHOP-91": issue("SHOP-91", "Order totals are off by a cent", status: ("Code Review", "indeterminate"), type: "Bug",
                         assignee: "Lena Fischer", priority: "High", versions: ["2.4.1"],
                         description: doc([paragraph("Totals sometimes differ from the payment provider by one minor unit.")]),
                         criteria: doc([bullets([
                             "Line totals and the order total round to the currency's minor units (JPY 0, KWD 3, others 2)",
                             "Tax is calculated on the rounded subtotal",
                         ])])),
        "INFRA-12": issue("INFRA-12", "Rotate staging database credentials via Vault", status: ("In Review", "indeterminate"), type: "Task",
                          assignee: "Dana Okafor", priority: "Highest", versions: [],
                          description: doc([paragraph("Move staging DB credentials to Vault so they can be rotated.")]),
                          criteria: doc([bullets([
                              "No credentials are stored in Terraform files",
                              "Staging database credentials are read from Vault",
                          ])])),
        "PAY-160": issue("PAY-160", "Idempotent refunds", status: ("In Review", "indeterminate"), type: "Story",
                         assignee: "Sam Lee", priority: "None", versions: ["2.4.0"],
                         description: doc([
                             paragraph("Clients retry refund calls on timeouts, which can refund twice."),
                             heading("Acceptance criteria", level: 2),
                             bullets([
                                 "Repeating a refund request with the same Idempotency-Key returns the original refund",
                                 "Idempotency keys expire after 24 hours",
                             ]),
                         ]), criteria: nil),
    ]

    // MARK: ADF builders

    private static func issue(_ key: String, _ summary: String, status: (String, String), type: String, assignee: String?,
                              priority: String?, versions: [String], description: JSONValue, criteria: JSONValue?) -> JiraIssue {
        var fields: [String: JSONValue] = [
            "summary": .string(summary),
            "status": .object(["name": .string(status.0), "statusCategory": .object(["key": .string(status.1)])]),
            "issuetype": .object(["name": .string(type)]),
            "assignee": assignee.map { .object(["displayName": .string($0)]) } ?? .null,
            "priority": priority.map { .object(["name": .string($0)]) } ?? .null,
            "fixVersions": .array(versions.map { .object(["name": .string($0)]) }),
            "description": description,
        ]
        fields[acceptanceCriteriaField] = criteria ?? .null
        return JiraIssue(key: key, fields: fields)
    }

    private static func doc(_ content: [JSONValue]) -> JSONValue {
        .object(["type": .string("doc"), "version": .number(1), "content": .array(content)])
    }

    private static func paragraph(_ text: String) -> JSONValue {
        .object(["type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private static func heading(_ text: String, level: Int) -> JSONValue {
        .object(["type": .string("heading"), "attrs": .object(["level": .number(Double(level))]),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private static func bullets(_ items: [String]) -> JSONValue {
        .object(["type": .string("bulletList"), "content": .array(items.map { .object(["type": .string("listItem"), "content": .array([paragraph($0)])]) })])
    }
}
