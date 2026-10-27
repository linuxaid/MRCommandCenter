import SwiftUI

/// Menu bar commands and keyboard shortcuts.
struct AppCommands: Commands {
    let appModel: AppModel

    private var store: MergeRequestStore { appModel.mergeRequests }
    private var center: CommandCenter { appModel.commandCenter }

    var body: some Commands {
        CommandMenu("Merge Request") {
            Button("Refresh") {
                Task { await appModel.refresh(.manual) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isRefreshing || appModel.needsOnboarding)

            Divider()

            Button("Next Merge Request") { center.selectNext() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(store.trackedMergeRequests.isEmpty)
            Button("Previous Merge Request") { center.selectPrevious() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(store.trackedMergeRequests.isEmpty)

            Divider()

            Button("Open in GitLab") { store.openSelectedInBrowser() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(store.browserURL == nil)

            Button(appModel.isReviewing ? "Back to Briefing" : "Review Here") {
                if appModel.isReviewing {
                    appModel.isReviewing = false
                } else if let mr = store.selected {
                    appModel.review(mr)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(store.selected == nil)

            Button("Approve or Revoke Approval") {
                guard let mr = store.selected, !mr.isAuthor else { return }
                let iApproved = store.username.map { mr.approvedByUsernames.contains($0) } ?? false
                Task { iApproved ? await center.revokeApproval(mr) : await center.approve(mr) }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(store.selected == nil || store.selected?.isAuthor == true)

            // No key equivalent: a bare "I" menu shortcut would swallow typing. I works in the list and review.
            Button("Labels… (I)") {
                guard let mr = store.selected else { return }
                center.editLabels(mr)
            }
            .disabled(store.selected == nil)

            Button("Merge…") {
                guard let mr = store.selected else { return }
                center.requestMerge(mr)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(store.selected == nil || store.selected?.isDraft == true)

            Divider()

            Button("Run AI Review") {
                guard let mr = store.selected else { return }
                appModel.detailTab = .aiReview
                appModel.review(mr)
                appModel.aiReview.start(mr)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.selected == nil || !appModel.aiReview.modelStatus.isAvailable)

            Divider()

            Button("New Merge Rule…") {
                center.addRule(like: store.selected)
                appModel.isReviewing = false
                center.destination = .rules
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Briefing") {
                appModel.isReviewing = false
                center.destination = .briefing
            }
                .keyboardShortcut("0", modifiers: .command)
            Button("Activity") {
                appModel.isReviewing = false
                center.destination = .activity
            }
            Button("Merge Rules") {
                appModel.isReviewing = false
                center.destination = .rules
            }
            Divider()
            ForEach(Array(DetailTab.allCases.enumerated()), id: \.element) { index, tab in
                Button("Review: \(tab.title)") { appModel.detailTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button(appModel.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                appModel.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
