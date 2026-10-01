import SwiftData
import SwiftUI
import os

@main
struct MRCommandCenterApp: App {
    @State private var appModel: AppModel

    init() {
        let useMocks = LaunchMode.usesMockData
        let inMemory = useMocks || LaunchMode.isRunningTests

        var storageWarning: String?
        let container: ModelContainer
        do {
            container = try AppModelContainer.make(inMemory: inMemory)
        } catch {
            Log.persistence.error("Opening the store failed: \(error.localizedDescription, privacy: .public)")
            storageWarning = "The local database couldn't be opened, so nothing will be saved this session."
            // An in-memory container with the same schema can only fail on a programmer error.
            container = try! AppModelContainer.make(inMemory: true)
        }

        let settings = AccountSettings.current(in: container.mainContext)
        if useMocks && settings.gitLabBaseURL.isEmpty {
            settings.gitLabBaseURL = "https://gitlab.example.com"
            settings.jiraBaseURL = "https://example.atlassian.net"
            settings.jiraEmail = "reviewer@example.com"
            settings.jiraAcceptanceCriteriaFieldID = MockJiraData.acceptanceCriteriaField
            // Mock GitLab is in-memory, so posting comments is safe to try.
            settings.postCommentsEnabled = true
        }

        let model = AppModel(dependencies: useMocks ? .mock() : .live(), modelContainer: container)
        model.storageWarning = storageWarning
        _appModel = State(initialValue: model)
    }

    var body: some Scene {
        Window("MR Command Center", id: "main") {
            RootView()
        }
        .modelContainer(appModel.modelContainer)
        .environment(appModel)
        .commands {
            AppCommands(appModel: appModel)
        }

        Window("Evaluation", id: "evaluation") {
            EvaluationView()
        }
        .modelContainer(appModel.modelContainer)
        .environment(appModel)
        .keyboardShortcut("e", modifiers: [.command, .shift])

        Settings {
            SettingsView()
        }
        .modelContainer(appModel.modelContainer)
        .environment(appModel)
    }
}
