import Foundation
import Testing
@testable import MR_Command_Center

struct ADFAndCriteriaTests {
    private func issue(_ name: String) throws -> JiraIssue {
        try HTTPClient.decode(JiraIssue.self, from: Fixture.data(name), decoder: .jira)
    }

    @Test func rendersADFStructure() throws {
        let description = try #require(try issue("jira_issue_cloud").fields["description"]?.plainText)
        #expect(description.contains("Merchants miss webhooks during **short** outages."))
        #expect(description.contains("### Acceptance Criteria"))
        #expect(description.contains("- Retries 5xx up to 5 times"))
        #expect(description.contains("- Honors `Retry-After`"))
    }

    @Test func rendersTaskListsTablesAndNestedLists() {
        let doc: JSONValue = .object(["type": .string("doc"), "content": .array([
            .object(["type": .string("orderedList"), "content": .array([
                .object(["type": .string("listItem"), "content": .array([
                    .object(["type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string("First")])])]),
                    .object(["type": .string("bulletList"), "content": .array([
                        .object(["type": .string("listItem"), "content": .array([
                            .object(["type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string("Nested")])])]),
                        ])]),
                    ])]),
                ])]),
            ])]),
            .object(["type": .string("table"), "content": .array([
                .object(["type": .string("tableRow"), "content": .array([
                    .object(["type": .string("tableHeader"), "content": .array([.object(["type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string("Given")])])])])]),
                    .object(["type": .string("tableHeader"), "content": .array([.object(["type": .string("paragraph"), "content": .array([.object(["type": .string("text"), "text": .string("Then")])])])])]),
                ])]),
            ])]),
            .object(["type": .string("paragraph"), "content": .array([
                .object(["type": .string("mention"), "attrs": .object(["text": .string("@Dana")])]),
                .object(["type": .string("text"), "text": .string(" please check")]),
            ])]),
        ])])
        let text = ADFRenderer.render(doc)
        #expect(text.contains("1. First"))
        #expect(text.contains("  - Nested"))
        #expect(text.contains("| Given | Then |"))
        #expect(text.contains("@Dana please check"))
    }

    @Test func prefersTheCriteriaFieldAndRendersChecklists() throws {
        let details = JiraIssueDetails(issue: try issue("jira_issue_cloud"), acceptanceCriteriaFieldID: "customfield_10050", priorityFieldID: "")
        #expect(details.acceptanceCriteriaSource == .customField)
        #expect(details.acceptanceCriteria == "- [x] Retries 5xx with backoff\n- [ ] 429 honors Retry-After")
        #expect(details.summary == "Retry failed webhook deliveries")
        #expect(details.status == "In Review")
        #expect(details.statusCategory == "indeterminate")
        #expect(details.issueType == "Story")
        #expect(details.assignee == "Priya Natarajan")
        #expect(details.priority == "High" && details.hasPriority)
        #expect(details.fixVersions == ["2.4.0"])
    }

    @Test func fallsBackToTheDescriptionSection() throws {
        let details = JiraIssueDetails(issue: try issue("jira_issue_cloud"), acceptanceCriteriaFieldID: "", priorityFieldID: "")
        #expect(details.acceptanceCriteriaSource == .description)
        #expect(details.acceptanceCriteria == "- Retries 5xx up to 5 times\n- Honors `Retry-After`", "Stops at the next heading")
    }

    @Test func handlesDataCenterPlainTextAndCustomPriority() throws {
        let issue = try issue("jira_issue_datacenter")
        let details = JiraIssueDetails(issue: issue, acceptanceCriteriaFieldID: "customfield_10050", priorityFieldID: "")
        #expect(details.acceptanceCriteriaSource == .description, "Empty/missing criteria field falls back to the description")
        #expect(details.acceptanceCriteria?.contains("* Export finishes within 90 minutes") == true)
        #expect(details.acceptanceCriteria?.contains("runbook") == false)
        #expect(!details.hasPriority)
        #expect(details.assignee == nil)

        let custom = JiraIssueDetails(issue: issue, acceptanceCriteriaFieldID: "", priorityFieldID: "customfield_10500")
        #expect(custom.priority == "P2" && custom.hasPriority)
    }

    @Test(arguments: [
        ("## Acceptance Criteria\n- a\n- b\n## Next\nx", "- a\n- b"),
        ("h3. Acceptance criteria\n* a\nh3. Notes", "* a"),
        ("*Acceptance Criteria*\n1. a\n2. b", "1. a\n2. b"),
        ("Intro\nAC:\n- only this", "- only this"),
        ("**Definition of Done**\n- shipped", "- shipped"),
    ])
    func extractsCriteriaFromDescriptions(text: String, expected: String) {
        #expect(AcceptanceCriteriaExtractor.fromDescription(text) == expected)
    }

    @Test func noCriteriaHeadingMeansNone() {
        #expect(AcceptanceCriteriaExtractor.fromDescription("Just a description that mentions acceptance criteria inline.") == nil)
    }

    @Test(arguments: [("High", true), ("None", false), ("unprioritized", false), ("", false), ("P3", true)])
    func priorityPlaceholders(value: String, isSet: Bool) {
        var issue = JiraIssue(key: "X-1", fields: ["priority": .object(["name": .string(value)])])
        _ = issue
        issue = JiraIssue(key: "X-1", fields: ["priority": .object(["name": .string(value)]), "summary": .string("s")])
        #expect(JiraIssueDetails(issue: issue, acceptanceCriteriaFieldID: "", priorityFieldID: "").hasPriority == isSet)
    }

    @Test func decodesFieldList() throws {
        let fields = try HTTPClient.decode([JiraField].self, from: Fixture.data("jira_fields"), decoder: .jira)
        #expect(fields.map(\.id) == ["summary", "customfield_10050", "customfield_10500"])
        #expect(fields[1].custom == true)
    }

    @Test func issueRequestUsesTheRightPathAndFields() async throws {
        let transport = StubTransport([.response(status: 200, body: try Fixture.data("jira_issue_cloud"))])
        let client = LiveJiraClient(baseURL: URL(string: "https://acme.atlassian.net")!, auth: .cloudBasic(email: "a@b.c", token: "t"), transport: transport)
        _ = try await client.issue(key: "PAY-142", fields: JiraIssueDetails.requestedFields(acceptanceCriteriaFieldID: "customfield_10050", priorityFieldID: ""))
        let url = try #require(transport.requests.first?.url)
        #expect(url.path() == "/rest/api/3/issue/PAY-142")
        let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "fields" }?.value
        #expect(fields == "summary,status,issuetype,assignee,priority,fixVersions,description,customfield_10050")
    }
}

struct JiraServiceTests {
    private func setUp() async -> (AppModel, SpyJiraClient) {
        let jira = SpyJiraClient()
        let app = AppModel.testing(jira: jira)
        await app.refresh(.automatic)
        return (app, jira)
    }

    private func mr(_ app: AppModel, _ iid: Int) throws -> TrackedMR {
        try #require(app.mergeRequests.reviewerMergeRequests.first { $0.iid == iid })
    }

    @Test func refreshFillsIssueStateOnMRs() async throws {
        let (app, _) = await setUp()
        let pay142 = try mr(app, 412)
        #expect(pay142.jiraLookup == .found)
        #expect(pay142.jiraStatus == "In Review")
        #expect(pay142.jiraPassing == true)
        #expect(pay142.jiraPriority == "High")

        #expect(try mr(app, 415).jiraHasPriority == false)
        #expect(try mr(app, 1873).jiraPassing == false)
        #expect(try mr(app, 1884).jiraLookup == .notFound)
        #expect(try mr(app, 77).jiraLookup == nil, "No key, nothing to look up")
        #expect(app.jira.details(for: "PAY-142")?.acceptanceCriteria?.contains("429 responses honor Retry-After") == true)
    }

    @Test func passingIssuesArentRefetchedAutomaticallyButManualAlwaysRefetches() async throws {
        let (app, jira) = await setUp()
        #expect(jira.fetchCount("PAY-142") == 1)
        #expect(jira.fetchCount("SHOP-88") == 1)

        await app.refresh(.automatic)
        #expect(jira.fetchCount("PAY-142") == 1, "In Review is passing: not refetched")
        #expect(jira.fetchCount("SHOP-88") == 2, "In Progress isn't passing: refetched")

        // The ticket gets reopened; a manual refresh notices.
        jira.edit { state in
            var issue = state.issues["PAY-142"]!
            var fields = issue.fields
            fields["status"] = .object(["name": .string("In Progress")])
            issue = JiraIssue(key: issue.key, fields: fields)
            state.issues["PAY-142"] = issue
        }
        await app.refresh(.manual)
        #expect(jira.fetchCount("PAY-142") == 2)
        #expect(try mr(app, 412).jiraPassing == false)

        await app.refreshDetails(for: try mr(app, 412))
        #expect(jira.fetchCount("PAY-142") == 3, "Refresh This MR always refetches")
    }

    @Test func fetchFailuresKeepTheLastGoodDetails() async throws {
        let (app, jira) = await setUp()
        jira.edit { $0.failure = .offline }
        await app.refresh(.manual)
        let pay142 = try mr(app, 412)
        #expect(pay142.jiraLookup == .found)
        #expect(pay142.jiraError != nil)
        #expect(app.jira.details(for: "PAY-142")?.summary == "Retry failed webhook deliveries")
    }

    @Test func notConfiguredLeavesChecksPending() async throws {
        let app = AppModel.testing()
        await app.refresh(.automatic)
        let pay142 = try mr(app, 412)
        #expect(pay142.jiraLookup == .notConfigured)
        #expect(StaticChecks.jira(MRCheckInput(pay142)).outcome == .pending)
        #expect(StaticChecks.priority(MRCheckInput(pay142)).outcome == .pending)
    }

    @Test func checksAndChipsReflectJira() async throws {
        let (app, _) = await setUp()
        func outcome(_ iid: Int, _ id: CheckID) throws -> CheckOutcome? {
            app.staticChecks.report(for: try mr(app, iid)).result(id)?.outcome
        }
        #expect(try outcome(412, .jira) == .pass)
        #expect(try outcome(412, .priority) == .pass)
        #expect(try outcome(1873, .jira) == .warning)
        #expect(try outcome(415, .priority) == .warning)
        #expect(try outcome(420, .priority) == .warning, "\"None\" is a placeholder")
        #expect(try outcome(1884, .jira) == .fail)
        #expect(try outcome(1884, .priority) == .notApplicable)
        #expect(try outcome(77, .priority) == .notApplicable)

        #expect(MRStatusLine.jiraItem(for: try mr(app, 412)).title == "PAY-142 · In Review")
        #expect(MRStatusLine.jiraItem(for: try mr(app, 412)).tone == .positive)
        #expect(MRStatusLine.jiraItem(for: try mr(app, 1884)).title == "SHOP-95 · not found")
    }

    @Test func previewShowsExtractionAndSuggestsFields() async {
        let (app, _) = await setUp()
        let preview = await app.jira.preview(key: "pay-142")
        #expect(preview.error == nil)
        #expect(preview.details?.acceptanceCriteriaSource == .customField)
        #expect(preview.suggestedFields.map(\.id) == [MockJiraData.acceptanceCriteriaField])
        let missing = await app.jira.preview(key: "NOPE-1")
        #expect(missing.error?.contains("wasn't found") == true)
    }

    @Test func cachePolicy() {
        #expect(CachePolicy.shouldFetchJira(previouslyPassed: nil, trigger: .automatic))
        #expect(CachePolicy.shouldFetchJira(previouslyPassed: false, trigger: .automatic))
        #expect(!CachePolicy.shouldFetchJira(previouslyPassed: true, trigger: .automatic))
        #expect(CachePolicy.shouldFetchJira(previouslyPassed: true, trigger: .manual))
    }
}

struct StoryInReviewTests {
    @Test func storyAndCriteriaReachTheModelAndTheRun() async throws {
        let model = FakeReviewModel()
        let app = AppModel.testing(model: model, jira: SpyJiraClient())
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.reviewerMergeRequests.first { $0.iid == 412 })
        app.aiReview.start(mr)
        await app.aiReview.wait(for: mr.key)

        let prompt = try #require(model.fileCalls.first?.prompt)
        #expect(prompt.contains("Story PAY-142: Retry failed webhook deliveries"))
        #expect(prompt.contains("Story description: Merchants miss webhooks"))
        #expect(prompt.contains("429 responses honor Retry-After and are retried"))
        #expect(prompt.contains("Judge whether this file's change does what the story and criteria ask."))
        #expect(model.verdictCalls.first?.prompt.contains("Acceptance criteria:") == true)

        let run = try #require(app.aiReview.latestRun(for: mr.key))
        #expect(run.usedAcceptanceCriteria)
        #expect(run.storyKey == "PAY-142")
    }

    @Test func storyWithoutCriteriaAndMissingIssuesAreExplained() async throws {
        let model = FakeReviewModel()
        let app = AppModel.testing(model: model, jira: SpyJiraClient())
        await app.refresh(.automatic)
        let pay150 = try #require(app.mergeRequests.reviewerMergeRequests.first { $0.iid == 415 })
        #expect(PromptBuilder.contextBlock(app.aiReview.storyContext(for: pay150)).contains("none listed, so judge meetsCriteria against the story description"))
        let shop95 = try #require(app.mergeRequests.reviewerMergeRequests.first { $0.iid == 1884 })
        #expect(PromptBuilder.contextBlock(app.aiReview.storyContext(for: shop95)).contains("the Jira issue wasn't found"))
        let noKey = try #require(app.mergeRequests.reviewerMergeRequests.first { $0.iid == 77 })
        #expect(PromptBuilder.contextBlock(app.aiReview.storyContext(for: noKey)).contains("no Jira key in the branch name"))
    }

    @Test func evalCasesSnapshotTheStory() async throws {
        let app = AppModel.testing(jira: SpyJiraClient())
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.reviewerMergeRequests.first { $0.iid == 80 })
        let evalCase = try await app.evaluation.saveCase(for: mr, expectedVerdict: .likelyProblem, expectedConcerns: [], notes: "")
        #expect(evalCase.jiraSummary == "Rotate staging database credentials via Vault")
        #expect(evalCase.acceptanceCriteria?.contains("No credentials are stored in Terraform files") == true)
        #expect(evalCase.context.hasAcceptanceCriteria)
    }
}
