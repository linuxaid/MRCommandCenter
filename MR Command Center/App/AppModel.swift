import Foundation
import Observation
import SwiftData

/// App-wide UI state shared by the main window, commands, and Settings.
@Observable
final class AppModel {
    let dependencies: AppDependencies
    let modelContainer: ModelContainer
    let mergeRequests: MergeRequestStore
    let diffs: DiffService
    let discussions: DiscussionService
    let staticChecks: StaticCheckService
    let aiReview: AIReviewService
    let summaryPoster: SummaryPoster
    let evaluation: EvalService
    let jira: JiraService
    let commandCenter: CommandCenter

    private(set) var hasGitLabToken = false
    private(set) var hasJiraToken = false
    var isInspectorPresented = false
    var detailTab: DetailTab = .changes
    /// Set to jump the Changes tab to a file and line (e.g. from a check finding).
    var diffNavigation: DiffNavigation?
    /// What the inspector shows: a file review record, or a run's merge step.
    var inspection: Inspection?
    /// Set when the on-disk store couldn't open and the app fell back to memory.
    var storageWarning: String?

    init(dependencies: AppDependencies, modelContainer: ModelContainer) {
        self.dependencies = dependencies
        self.modelContainer = modelContainer
        mergeRequests = MergeRequestStore(container: modelContainer, dependencies: dependencies)
        diffs = DiffService(container: modelContainer, dependencies: dependencies)
        discussions = DiscussionService(container: modelContainer, dependencies: dependencies)
        staticChecks = StaticCheckService(container: modelContainer, diffs: diffs)
        jira = JiraService(container: modelContainer, dependencies: dependencies)
        aiReview = AIReviewService(container: modelContainer, dependencies: dependencies, diffs: diffs, staticChecks: staticChecks, jira: jira)
        summaryPoster = SummaryPoster(container: modelContainer, aiReview: aiReview, discussions: discussions)
        evaluation = EvalService(container: modelContainer, dependencies: dependencies, diffs: diffs,
                                 staticChecks: staticChecks, aiReview: aiReview)
        commandCenter = CommandCenter(container: modelContainer, dependencies: dependencies, store: mergeRequests)
        refreshTokenState()
    }

    var needsOnboarding: Bool { !hasGitLabToken }

    /// Review mode: the selected MR fills the window, brief on the left and its changes on the right.
    var isReviewing = false

    func review(_ mr: TrackedMR) {
        mergeRequests.selectedKey = mr.key
        isReviewing = true
    }

    /// Refreshes the MR list, runs static checks for any new head SHAs, then lets merge rules act.
    func refresh(_ trigger: RefreshTrigger) async {
        await mergeRequests.refresh(trigger)
        await jira.refresh(for: mergeRequests.trackedMergeRequests, trigger: trigger)
        await staticChecks.evaluateMissing(mergeRequests.trackedMergeRequests)
        await commandCenter.runRules()
    }

    func refreshIfStale(olderThan interval: TimeInterval) async {
        if let last = mergeRequests.lastRefreshedAt, Date.now.timeIntervalSince(last) < interval { return }
        await refresh(.automatic)
    }

    func showInDiff(mr: TrackedMR, path: String, line: Int) {
        diffNavigation = DiffNavigation(mrKey: mr.key, path: path, line: line)
        detailTab = .changes
    }

    /// "Refresh This MR": refetches it, then rechecks if its head moved.
    func refreshDetails(for mr: TrackedMR) async {
        await mergeRequests.refreshDetails(for: mr)
        await jira.refresh(mr)
        await staticChecks.evaluate(mr)
    }

    func refreshTokenState() {
        hasGitLabToken = dependencies.secrets.hasSecret(for: SecretAccount.gitLabToken)
        hasJiraToken = dependencies.secrets.hasSecret(for: SecretAccount.jiraToken)
    }

    /// For previews and tests: mock clients and an in-memory store.
    static func preview(dependencies: AppDependencies = .mock()) -> AppModel {
        // An in-memory container with the app schema can only fail on a programmer error.
        let container = try! AppModelContainer.make(inMemory: true)
        let settings = AccountSettings.current(in: container.mainContext)
        settings.gitLabBaseURL = "https://gitlab.example.com"
        return AppModel(dependencies: dependencies, modelContainer: container)
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case changes, aiReview, overview

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Details"
        case .changes: "Changes"
        case .aiReview: "AI Review"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "doc.text"
        case .changes: "plusminus"
        case .aiReview: "sparkles"
        }
    }
}

struct DiffNavigation: Equatable {
    let id = UUID()
    let mrKey: String
    let path: String
    /// New-side line number.
    let line: Int
}

enum Inspection: Equatable {
    case file(UUID)
    case merge(runID: UUID)
}
