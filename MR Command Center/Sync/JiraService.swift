import Foundation
import Observation
import SwiftData
import os

/// Fetches Jira issues for MRs' branch keys, applying the passing-status cache rule.
@Observable
final class JiraService {
    private(set) var revision = 0
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let dependencies: AppDependencies
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer, dependencies: AppDependencies) {
        self.container = container
        self.dependencies = dependencies
    }

    private var settings: AccountSettings { AccountSettings.current(in: context) }

    /// A client for the saved Jira details, or the reason it can't be built.
    func client() throws -> any JiraAPI {
        let settings = settings
        let baseURL = try BaseURL.normalize(settings.jiraBaseURL, strippingSuffixes: BaseURL.jiraSuffixes)
        guard let token = try dependencies.secrets.secret(for: settings.jiraTokenAccount), !token.isEmpty else {
            throw APIError.missingToken
        }
        let auth: JiraAuth
        switch settings.jiraDeployment {
        case .cloud:
            let email = settings.jiraEmail.trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty else { throw APIError.missingEmail }
            auth = .cloudBasic(email: email, token: token)
        case .dataCenter:
            auth = .dataCenterBearer(token: token)
        }
        return dependencies.clients.jira(baseURL: baseURL, auth: auth)
    }

    var isConfigured: Bool { (try? client()) != nil }

    func check(for key: String) -> JiraCheck? {
        _ = revision
        var descriptor = FetchDescriptor<JiraCheck>(predicate: #Predicate { $0.issueKey == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func details(for key: String?) -> JiraIssueDetails? {
        key.flatMap { check(for: $0)?.details }
    }

    /// Fetches the issues for these MRs. Automatic refreshes skip issues already in a
    /// passing status; manual ones refetch everything.
    func refresh(for mrs: [TrackedMR], trigger: RefreshTrigger) async {
        let keys = Set(mrs.compactMap(\.jiraKey))
        guard let client = try? client() else {
            for mr in mrs where mr.jiraKey != nil { setLookup(.notConfigured, on: mr) }
            return
        }
        for key in keys.sorted() {
            let existing = check(for: key)
            if CachePolicy.shouldFetchJira(previouslyPassed: existing?.passed, trigger: trigger) {
                await fetch(key, client: client)
            }
            for mr in mrs where mr.jiraKey == key { apply(check(for: key), to: mr) }
        }
        save()
    }

    /// "Refresh This MR": always refetches the MR's issue.
    func refresh(_ mr: TrackedMR) async {
        await refresh(for: [mr], trigger: .manual)
    }

    private func fetch(_ key: String, client: any JiraAPI) async {
        let settings = settings
        let fields = JiraIssueDetails.requestedFields(acceptanceCriteriaFieldID: settings.jiraAcceptanceCriteriaFieldID,
                                                      priorityFieldID: settings.jiraPriorityFieldID)
        let check = self.check(for: key) ?? {
            let new = JiraCheck(issueKey: key)
            context.insert(new)
            return new
        }()
        do {
            let issue = try await client.issue(key: key, fields: fields)
            let details = JiraIssueDetails(issue: issue, acceptanceCriteriaFieldID: settings.jiraAcceptanceCriteriaFieldID,
                                           priorityFieldID: settings.jiraPriorityFieldID)
            check.apply(details, passingStatuses: settings.jiraPassingStatuses)
        } catch APIError.notFound {
            check.notFound = true
            check.detailsData = nil
            check.passed = false
            check.lastError = nil
            check.lastCheckedAt = .now
        } catch {
            // Keep the last good details; just note the failure.
            check.lastError = error.localizedDescription
            check.lastCheckedAt = .now
            Log.sync.error("Jira fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        revision += 1
    }

    private func apply(_ check: JiraCheck?, to mr: TrackedMR) {
        guard let check else { return }
        if check.notFound {
            setLookup(.notFound, on: mr)
            mr.jiraStatus = nil
            mr.jiraPassing = nil
            mr.jiraPriority = nil
        } else if let details = check.details {
            setLookup(.found, on: mr)
            mr.jiraStatus = details.status
            mr.jiraPassing = check.passed
            mr.jiraPriority = details.hasPriority ? details.priority : nil
            mr.jiraHasPriority = details.hasPriority
        } else if check.lastError != nil {
            setLookup(.failed, on: mr)
        }
        mr.jiraError = check.lastError
    }

    private func setLookup(_ lookup: JiraLookup, on mr: TrackedMR) {
        if mr.jiraLookupRaw != lookup.rawValue { mr.jiraLookupRaw = lookup.rawValue }
    }

    // MARK: Setup preview

    struct Preview: Equatable {
        var details: JiraIssueDetails?
        var error: String?
        var suggestedFields: [JiraField]
    }

    /// Fetches one issue with the current settings and suggests field IDs, for checking
    /// the setup in Settings.
    func preview(key: String) async -> Preview {
        let settings = settings
        do {
            let client = try client()
            let fields = JiraIssueDetails.requestedFields(acceptanceCriteriaFieldID: settings.jiraAcceptanceCriteriaFieldID,
                                                          priorityFieldID: settings.jiraPriorityFieldID)
            async let issue = client.issue(key: key.trimmingCharacters(in: .whitespaces).uppercased(), fields: fields)
            let suggestions = ((try? await client.fields()) ?? []).filter { field in
                let name = field.name.lowercased()
                return field.custom == true && (name.contains("acceptance") || name.contains("criteria") || name.contains("priority") || name.contains("definition of done"))
            }
            let details = JiraIssueDetails(issue: try await issue, acceptanceCriteriaFieldID: settings.jiraAcceptanceCriteriaFieldID,
                                           priorityFieldID: settings.jiraPriorityFieldID)
            return Preview(details: details, error: nil, suggestedFields: suggestions)
        } catch APIError.notFound {
            return Preview(details: nil, error: "\(key) wasn't found, or the token can't see it.", suggestedFields: [])
        } catch {
            return Preview(details: nil, error: error.localizedDescription, suggestedFields: [])
        }
    }

    private func save() {
        do { try context.save() } catch {
            Log.persistence.error("Saving Jira data failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
