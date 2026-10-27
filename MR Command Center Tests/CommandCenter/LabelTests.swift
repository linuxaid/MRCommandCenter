import Foundation
import SwiftUI
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

    @Test func rowsStayPutWhileYouClick() async throws {
        let (app, _, mr) = try await loaded()
        let editor = LabelEditor(mrKey: mr.key, service: app.commandCenter)
        await editor.load()
        let before = editor.visible.map(\.name)

        await editor.toggle("blocked")
        await editor.toggle("backend")

        #expect(editor.visible.map(\.name) == before, "Adding or removing doesn't reorder the list under the pointer")
        #expect(editor.applied.contains("blocked") && !editor.applied.contains("backend"))
    }

    @Test func iOpensThePickerOnlyWhenNotTypingOrChording() {
        #expect(CommandCenter.opensLabelPicker(modifiers: [], isComposing: false))
        #expect(CommandCenter.opensLabelPicker(modifiers: .shift, isComposing: false), "Capital I works too")
        #expect(!CommandCenter.opensLabelPicker(modifiers: .command, isComposing: false))
        #expect(!CommandCenter.opensLabelPicker(modifiers: [.option, .command], isComposing: false), "⌥⌘I is the inspector")
        #expect(!CommandCenter.opensLabelPicker(modifiers: .control, isComposing: false))
        #expect(!CommandCenter.opensLabelPicker(modifiers: [], isComposing: true), "Typing in a comment box")
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
        #expect(message.contains("can't see this project's labels"))

        let error = await app.commandCenter.setLabel("blocked", on: mr, applied: true)
        #expect(error?.contains("api scope") == true)
        #expect(!mr.labels.contains("blocked"))
    }

    @Test func reopeningThePickerShowsCachedLabelsThenRefreshes() async throws {
        let (app, spy, mr) = try await loaded()
        await LabelEditor(mrKey: mr.key, service: app.commandCenter).load()
        #expect(app.commandCenter.cachedProjectLabels(for: mr)?.isEmpty == false)

        let again = LabelEditor(mrKey: mr.key, service: app.commandCenter)
        await again.load()
        #expect(spy.count("projectLabels") == 2, "Labels made in GitLab since last time show up")
        #expect(again.phase == .loaded)
    }

    @Test func returnAddsTheTopMatchButNeverRemoves() async throws {
        let (app, _, mr) = try await loaded()
        let editor = LabelEditor(mrKey: mr.key, service: app.commandCenter)
        await editor.load()

        await editor.submit()
        #expect(mr.labels.sorted() == ["backend", "payments"], "Nothing typed: Return does nothing")

        editor.query = "pay"
        await editor.submit()
        #expect(mr.labels.contains("payments"), "The only match is applied, so Return leaves it alone")

        editor.query = "bl"
        await editor.submit()
        #expect(mr.labels.contains("blocked"))
    }

    @Test func overlappingChangesDontUndoEachOther() async throws {
        let (app, spy, mr) = try await loaded()
        // Without ordering, "blocked"'s slow reply (without "bug") would land last and drop "bug".
        spy.edit { $0.labelReplyDelays["blocked"] = .milliseconds(300) }
        let center = app.commandCenter
        let first = Task { await center.setLabel("blocked", on: mr, applied: true) }
        let second = Task { await center.setLabel("bug", on: mr, applied: true) }
        _ = await (first.value, second.value)

        #expect(Set(mr.labels) == ["backend", "payments", "blocked", "bug"])
    }

    @Test func changingLabelsDoesntHideOtherChangesFromTheNextRefresh() async throws {
        let (app, spy, mr) = try await loaded()
        let pushed = String(repeating: "f", count: 40)
        spy.edit { state in
            let index = state.data.entries.firstIndex { $0.detail.iid == 412 }!
            state.data.entries[index].detail.sha = pushed
            state.data.entries[index].bumpUpdatedAt()
        }

        _ = await app.commandCenter.setLabel("blocked", on: mr, applied: true)
        #expect(mr.headSHA != pushed, "Only the labels came from the label reply")

        await app.mergeRequests.refresh(.automatic)
        let events = try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
        #expect(events.contains { $0.mrKey == mr.key && $0.kind == .pushed })
    }

    @Test(arguments: [(APIError.unauthorized, "401"), (.server(status: 422), "422"), (.server(status: 409), "409")])
    func labelErrorsTalkAboutLabels(error: APIError, code: String) {
        let message = CommandCenter.describeLabelFailure(error, changing: true)
        #expect(message.contains(code))
        #expect(!message.contains("approve") && !message.contains("merge (422)"))
    }

    @Test func readingLabelsDoesntAskForTheAPIScope() {
        #expect(!CommandCenter.describeLabelFailure(APIError.forbidden, changing: false).contains("api scope"))
    }

    @Test func closedMRSaysSo() async throws {
        let (app, _, _) = try await loaded()
        let editor = LabelEditor(mrKey: "gone!1", service: app.commandCenter)
        await editor.load()
        #expect(editor.phase == .failed(LabelEditor.closedMessage))
        await editor.toggle("bug")
        #expect(editor.error == LabelEditor.closedMessage)
    }

    @Test func editLabelsOpensThePicker() async throws {
        let (app, _, mr) = try await loaded()
        app.commandCenter.editLabels(mr)
        #expect(app.commandCenter.labelEditor?.mrKey == mr.key)
    }

    @Test func requestAsksGitLabForCommaSeparatedNames() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        let body = UpdateLabelsRequest(addLabels: "a,b", removeLabels: nil)
        #expect(String(decoding: try encoder.encode(body), as: UTF8.self) == #"{"add_labels":"a,b"}"#)
    }
}
