import Foundation
import Testing
@testable import MR_Command_Center

/// The brief's Jira card (#25): real issue details instead of an unexplained "warnings" count.
@MainActor
struct JiraSummaryTests {
    private func loaded(jira: Bool = true) async -> AppModel {
        let app = AppModel.testing(jira: jira ? SpyJiraClient() : nil)
        await app.refresh(.automatic)
        return app
    }

    private func summary(_ app: AppModel, _ iid: Int) throws -> JiraSummary {
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == iid })
        return JiraSummary.make(for: mr, details: app.jira.details(for: mr.jiraKey))
    }

    private func value(_ summary: JiraSummary, _ label: String) -> JiraSummary.Row? {
        summary.rows.first { $0.label == label }
    }

    @Test func showsTheIssuesKeyFields() async throws {
        let pay142 = try summary(await loaded(), 412)
        #expect(pay142.state == .found)
        #expect(pay142.key == "PAY-142")
        #expect(pay142.title == "Retry failed webhook deliveries")
        #expect(pay142.rows.map(\.label) == ["Status", "Type", "Priority", "Fix version", "Assignee"])
        #expect(value(pay142, "Status")?.value == "In Review")
        #expect(value(pay142, "Status")?.tone == .positive, "In Review is a passing status")
        #expect(value(pay142, "Type")?.value == "Story")
        #expect(value(pay142, "Priority")?.value == "High")
        #expect(value(pay142, "Fix version")?.value == "2.4.0")
        #expect(value(pay142, "Assignee")?.value == "Priya Natarajan")
    }

    @Test func descriptionAndCriteriaCanBeExpanded() async throws {
        let pay142 = try summary(await loaded(), 412)
        #expect(pay142.hasStory)
        #expect(pay142.description?.contains("Merchants miss webhooks") == true)
    }

    @Test func missingPriorityIsCalledOut() async throws {
        let app = await loaded()
        let noPriority = try #require(app.mergeRequests.trackedMergeRequests.compactMap { mr -> JiraSummary? in
            let summary = JiraSummary.make(for: mr, details: app.jira.details(for: mr.jiraKey))
            return summary.rows.contains { $0.label == "Priority" && $0.value == "Not set" } ? summary : nil
        }.first)
        #expect(noPriority.rows.first { $0.label == "Priority" }?.tone == .warning)
    }

    @Test func noFixVersionsSaysNone() {
        var details = JiraIssueDetails(issue: MockJiraData.issues["PAY-142"]!, acceptanceCriteriaFieldID: "", priorityFieldID: "")
        details.fixVersions = []
        details.assignee = nil
        let summary = JiraSummary.found(details, passing: false)
        #expect(summary.rows.first { $0.label == "Fix version" }?.value == "None")
        #expect(summary.rows.first { $0.label == "Assignee" }?.value == "Unassigned")
        #expect(summary.rows.first { $0.label == "Status" }?.tone == .normal)
    }

    @Test func severalFixVersionsAreListed() {
        var details = JiraIssueDetails(issue: MockJiraData.issues["PAY-142"]!, acceptanceCriteriaFieldID: "", priorityFieldID: "")
        details.fixVersions = ["2.4.0", "2.5.0"]
        let summary = JiraSummary.found(details, passing: true)
        #expect(summary.rows.first { $0.label == "Fix versions" }?.value == "2.4.0, 2.5.0")
    }

    @Test func branchWithoutAKey() async throws {
        let terraform = try summary(await loaded(), 77)
        #expect(terraform.state == .noKey(branch: "chore/bump-aws-provider"))
        #expect(terraform.rows.isEmpty)
    }

    @Test func jiraNotConnected() async throws {
        let pay142 = try summary(await loaded(jira: false), 412)
        #expect(pay142.state == .notConnected)
        #expect(pay142.key == "PAY-142")
    }

    @Test func issueNotFound() async throws {
        let shop95 = try summary(await loaded(), 1884)
        #expect(shop95.state == .notFound)
    }
}
