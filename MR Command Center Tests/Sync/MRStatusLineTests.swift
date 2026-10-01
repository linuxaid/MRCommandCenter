import Foundation
import Testing
@testable import MR_Command_Center

struct MRStatusLineTests {
    private func makeMR() throws -> TrackedMR {
        let item = MockGitLabData.sample.entries[0].listItem
        return TrackedMR(from: item)
    }

    @Test func showsLoadingBeforeDetails() throws {
        let mr = try makeMR()
        let items = MRStatusLine.items(for: mr)
        #expect(items.first { $0.id == "pipeline" }?.title == "Loading")
        #expect(!items.contains { $0.id == "approvals" })
    }

    @Test func everyItemHasTextIconAndAccessibilityLabel() throws {
        let mr = try makeMR()
        mr.detailsFetchedForUpdatedAt = mr.lastSeenUpdatedAt
        mr.pipelineStatusRaw = PipelineStatus.failed.rawValue
        mr.hasConflicts = true
        mr.isDraft = true
        mr.unresolvedDiscussions = 1
        mr.approvalsRequired = 2

        for item in MRStatusLine.items(for: mr) {
            #expect(!item.title.isEmpty)
            #expect(!item.systemImage.isEmpty)
            #expect(!item.accessibilityLabel.isEmpty)
        }
        let ids = MRStatusLine.items(for: mr).map(\.id)
        #expect(ids == ["checks", "pipeline", "approvals", "conflicts", "draft", "threads", "jira", "ai"])
    }

    @Test func approvalsMetVersusPending() throws {
        let mr = try makeMR()
        mr.detailsFetchedForUpdatedAt = mr.lastSeenUpdatedAt
        mr.approvalsGiven = 1
        mr.approvalsRequired = 2
        #expect(MRStatusLine.approvalsItem(for: mr)?.tone == .warning)
        #expect(MRStatusLine.approvalsItem(for: mr)?.accessibilityLabel == "1 of 2 required approvals")
        mr.approvalsGiven = 2
        #expect(MRStatusLine.approvalsItem(for: mr)?.tone == .positive)
    }

    @Test func noJiraKeyIsExplicit() throws {
        let mr = try makeMR()
        mr.jiraKey = nil
        #expect(MRStatusLine.jiraItem(for: mr).title == "No Jira key")
        mr.jiraKey = "PAY-142"
        #expect(MRStatusLine.jiraItem(for: mr).title == "PAY-142")
    }

    @Test func pipelineNoneAfterDetailsLoaded() throws {
        let mr = try makeMR()
        mr.detailsFetchedForUpdatedAt = mr.lastSeenUpdatedAt
        #expect(MRStatusLine.pipelineItem(for: mr).title == "No pipeline")
    }
}

struct LabelStyleTests {
    @Test func keepsColorsWhenDetailReturnsPlainNames() throws {
        let list = MockGitLabData.sample.entries[0].listItem
        let mr = TrackedMR(from: list)
        #expect(mr.labels == ["backend", "payments"])
        #expect(mr.labelStyles["backend"]?.color == "#6699CC")

        var detail = list
        detail.labels = [GitLabLabel(name: "backend"), GitLabLabel(name: "urgent")]
        mr.update(from: detail)

        #expect(mr.labels == ["backend", "urgent"])
        #expect(mr.labelStyles["backend"]?.color == "#6699CC", "Color survives a names-only update")
        #expect(mr.labelStyles["urgent"] == nil)
    }

    @Test func updatesChangedColors() {
        var item = MockGitLabData.sample.entries[0].listItem
        let mr = TrackedMR(from: item)
        item.labels = [GitLabLabel(name: "backend", color: "#000000", textColor: "#FFFFFF")]
        mr.update(from: item)
        #expect(mr.labelStyles["backend"]?.color == "#000000")
    }

    @Test func noColorsMeansNoStyleData() {
        var item = MockGitLabData.sample.entries[0].listItem
        item.labels = [GitLabLabel(name: "plain")]
        #expect(TrackedMR(from: item).labelStylesData == nil)
    }
}
