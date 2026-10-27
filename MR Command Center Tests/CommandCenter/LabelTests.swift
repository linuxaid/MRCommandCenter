import Foundation
import SwiftData
import Synchronization
import Testing
@testable import MR_Command_Center

/// Adding and removing an MR's labels from the project's existing ones (#27).
@MainActor
struct LabelTests {
    private func loaded() async throws -> (AppModel, SpyGitLabClient, TrackedMR) {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        return (app, spy, mr)
    }

    @Test func pickerListsTheProjectsLabelsWithTheMRsOwnFirst() async throws {
        let (app, _, mr) = try await loaded()
        let editor = LabelEditor(mrKey: mr.key, service: app.commandCenter)
        await editor.load()

        #expect(editor.phase == .loaded)
        #expect(editor.available.map(\.name) == MockGitLabData.projectLabels.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
        #expect(Array(editor.visible.prefix(2)).map(\.name).sorted() == ["backend", "payments"], "Applied labels come first")
        #expect(editor.title == "Labels for payments/api!412")
    }

    @Test func searchIgnoresCase() async throws {
        let (app, _, mr) = try await loaded()
        let editor = LabelEditor(mrKey: mr.key, service: app.commandCenter)
        await editor.load()
        editor.query = "  BLOCK "
        #expect(editor.visible.map(\.name) == ["blocked"])
    }

    @Test func togglingAddsThenRemoves() async throws {
        let (app, spy, mr) = try await loaded()
        let editor = LabelEditor(mrKey: mr.key, service: app.commandCenter)
        await editor.load()

        await editor.toggle("blocked")
        #expect(mr.labels.contains("blocked"))
        #expect(mr.labelStyles["blocked"]?.color == "#C92A2A", "New label keeps its project color")
        #expect(editor.error == nil)

        await editor.toggle("blocked")
        #expect(!mr.labels.contains("blocked"))
        #expect(mr.labels.contains("backend"), "Other labels are untouched")
        #expect(spy.count("updateLabels") == 2)
        let events = try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>()).map(\.message)
        #expect(events.contains("You added the label “blocked”"))
        #expect(events.contains("You removed the label “blocked”"))
    }

    @Test func removingFromTheBrief() async throws {
        let (app, _, mr) = try await loaded()
        let error = await app.commandCenter.setLabel("payments", on: mr, applied: false)
        #expect(error == nil)
        #expect(mr.labels == ["backend"])
    }

    @Test func failuresAreExplained() async throws {
        let (app, spy, mr) = try await loaded()
        spy.edit { $0.labelFailure = .forbidden }
        let editor = LabelEditor(mrKey: mr.key, service: app.commandCenter)
        await editor.load()
        guard case .failed(let message) = editor.phase else {
            Issue.record("Expected a failure"); return
        }
        #expect(message.contains("api scope"))

        let error = await app.commandCenter.setLabel("blocked", on: mr, applied: true)
        #expect(error?.contains("api scope") == true)
        #expect(!mr.labels.contains("blocked"))
    }

    @Test func projectLabelsAreFetchedOncePerProject() async throws {
        let (app, spy, mr) = try await loaded()
        _ = try await app.commandCenter.projectLabels(for: mr)
        _ = try await app.commandCenter.projectLabels(for: mr)
        #expect(spy.count("projectLabels") == 1)
    }

    @Test func editLabelsOpensThePicker() async throws {
        let (app, _, mr) = try await loaded()
        app.commandCenter.editLabels(mr)
        #expect(app.commandCenter.labelEditorKey == mr.key)
    }

    @Test func requestAsksGitLabForCommaSeparatedNames() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        let body = UpdateLabelsRequest(addLabels: "a,b", removeLabels: nil)
        #expect(String(decoding: try encoder.encode(body), as: UTF8.self) == #"{"add_labels":"a,b"}"#)
    }
}
