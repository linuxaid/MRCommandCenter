import SwiftUI

/// Menu bar commands and keyboard shortcuts for the MR list.
struct AppCommands: Commands {
    let appModel: AppModel

    private var store: MergeRequestStore { appModel.mergeRequests }

    var body: some Commands {
        CommandMenu("Merge Request") {
            Button("Refresh") {
                Task { await appModel.refresh(.manual) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing || appModel.needsOnboarding)

            Divider()

            Button("Next Merge Request") { store.selectNext() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(store.mergeRequests.isEmpty)
            Button("Previous Merge Request") { store.selectPrevious() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(store.mergeRequests.isEmpty)

            Divider()

            Button("Open in Browser") { store.openSelectedInBrowser() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store.selected == nil)

            Button("Run AI Review") {
                guard let mr = store.selected else { return }
                appModel.detailTab = .aiReview
                appModel.aiReview.start(mr)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.selected == nil || !appModel.aiReview.modelStatus.isAvailable)
        }

        CommandGroup(after: .sidebar) {
            ForEach(Array(DetailTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) { appModel.detailTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Toggle("Show Draft Merge Requests", isOn: Binding(
                get: { store.showsDrafts },
                set: { store.setShowsDrafts($0) }
            ))
            Divider()
            Button(appModel.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                appModel.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
