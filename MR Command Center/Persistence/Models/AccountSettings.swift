import os
import Foundation
import SwiftData

/// Non-secret connection details and preferences. One row per install.
/// Tokens live in the Keychain; this model stores only the Keychain account names.
@Model
final class AccountSettings {
    // GitLab
    var gitLabBaseURL: String = ""
    var gitLabTokenAccount: String = SecretAccount.gitLabToken
    var gitLabUserID: Int?
    var gitLabUsername: String?
    var gitLabVerifiedAt: Date?

    // Jira
    var jiraBaseURL: String = ""
    var jiraEmail: String = ""
    var jiraDeploymentRaw: String = JiraDeployment.cloud.rawValue
    var jiraTokenAccount: String = SecretAccount.jiraToken
    var jiraDisplayName: String?
    var jiraVerifiedAt: Date?
    var jiraAcceptanceCriteriaFieldID: String = ""
    /// Empty means Jira's standard Priority field.
    var jiraPriorityFieldID: String = ""
    var jiraPassingStatuses: [String] = AccountSettings.defaultPassingStatuses
    var branchKeyPattern: String = AccountSettings.defaultBranchKeyPattern

    // Refresh and checks
    var pollIntervalMinutes: Int = 5
    /// See `ActivityKeeper`.
    var keepMacActive: Bool = false
    var diffSizeLimitLines: Int = 1000
    var collapseFileDiffThresholdLines: Int = 400
    var debugPatterns: [String] = AccountSettings.defaultDebugPatterns
    var todoMarkers: [String] = AccountSettings.defaultTodoMarkers
    /// Extra path substrings that mark a file as a test (on top of the built-in rules).
    var extraTestPathPatterns: [String] = []
    var lastMergeRequestRefreshAt: Date?

    // AI review
    var aiConcurrencyLimit: Int = 1
    var aiToolsEnabled: Bool = false
    /// Greedy sampling makes runs repeatable for evaluation.
    var aiGreedySampling: Bool = true
    var aiTemperature: Double = 0.3
    var activePromptVersionID: UUID?
    /// Default skills are seeded once, so deleting them sticks.
    var didSeedDefaultSkills: Bool = false

    // Write actions and notifications
    var postCommentsEnabled: Bool = false
    /// The master switch for merge rules. Off: rules run as a dry run and only report what they'd merge.
    var autoMergeEnabled: Bool = false
    /// Merge MRs you're reviewing (not ones you opened) as soon as they're ready, without a rule.
    /// Its own opt-in: it merges for real even while merge rules are a dry run.
    var mergeReadyReviewsAutomatically: Bool = false
    /// How MRs are ordered inside each lane (`LaneOrder`); easiest first unless changed (#36).
    var laneOrderRaw: String = LaneOrder.easiestFirst.rawValue
    /// Today's dad joke (#38), the day it's for (`yyyy-MM-dd`), and recent ones not to repeat.
    var dadJokeText: String?
    var dadJokeDay: String?
    var recentDadJokes: [String] = []
    var notifyNewReviewRequests: Bool = false
    var notifyPipelineFailures: Bool = false

    init() {}

    static let defaultPassingStatuses = ["In Review", "Code Review"]
    static let defaultBranchKeyPattern = #"[A-Z][A-Z0-9]+-\d+"#
    static let defaultDebugPatterns = ["print(", "console.log", "debugger;", "dump(", "var_dump(", "fmt.Println("]
    static let defaultTodoMarkers = ["TODO", "FIXME"]

    var checkConfiguration: CheckConfiguration {
        CheckConfiguration(
            diffSizeLimit: diffSizeLimitLines,
            debugPatterns: debugPatterns,
            todoMarkers: todoMarkers,
            extraTestPathPatterns: extraTestPathPatterns
        )
    }

    var jiraDeployment: JiraDeployment {
        get { JiraDeployment(rawValue: jiraDeploymentRaw) ?? .cloud }
        set { jiraDeploymentRaw = newValue.rawValue }
    }
}

extension AccountSettings {
    /// The issue's page in Jira, or nil when no valid Jira URL is set.
    func jiraBrowseURL(for key: String) -> URL? {
        guard let base = try? BaseURL.normalize(jiraBaseURL, strippingSuffixes: BaseURL.jiraSuffixes) else { return nil }
        return base.appending(path: "browse").appending(path: key)
    }

    /// Returns the settings row, creating it on first launch.
    static func current(in context: ModelContext) -> AccountSettings {
        var descriptor = FetchDescriptor<AccountSettings>()
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let settings = AccountSettings()
        context.insert(settings)
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving initial settings failed: \(error.localizedDescription, privacy: .public)")
        }
        return settings
    }
}
