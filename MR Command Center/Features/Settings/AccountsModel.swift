import Foundation
import Observation

enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case warning(String)
    case failure(String)
}

/// Token drafts and connection tests for the Accounts screen.
@Observable
final class AccountsModel {
    var gitLabTokenDraft = ""
    var jiraTokenDraft = ""
    private(set) var gitLabTest: ConnectionTestState = .idle
    private(set) var jiraTest: ConnectionTestState = .idle
    var tokenError: String?

    private let appModel: AppModel
    private var secrets: any SecretStore { appModel.dependencies.secrets }
    private var clients: any ClientFactory { appModel.dependencies.clients }

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    var hasGitLabToken: Bool { appModel.hasGitLabToken }
    var hasJiraToken: Bool { appModel.hasJiraToken }

    // MARK: Tokens

    func saveGitLabToken(settings: AccountSettings) {
        if save(gitLabTokenDraft, account: settings.gitLabTokenAccount) {
            gitLabTokenDraft = ""
            gitLabTest = .idle
        }
    }

    func removeGitLabToken(settings: AccountSettings) {
        remove(account: settings.gitLabTokenAccount)
        settings.gitLabUserID = nil
        settings.gitLabUsername = nil
        settings.gitLabVerifiedAt = nil
        gitLabTest = .idle
    }

    func saveJiraToken(settings: AccountSettings) {
        if save(jiraTokenDraft, account: settings.jiraTokenAccount) {
            jiraTokenDraft = ""
            jiraTest = .idle
        }
    }

    func removeJiraToken(settings: AccountSettings) {
        remove(account: settings.jiraTokenAccount)
        settings.jiraDisplayName = nil
        settings.jiraVerifiedAt = nil
        jiraTest = .idle
    }

    private func save(_ draft: String, account: String) -> Bool {
        let token = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        do {
            try secrets.setSecret(token, for: account)
            tokenError = nil
            appModel.refreshTokenState()
            return true
        } catch {
            tokenError = error.localizedDescription
            return false
        }
    }

    private func remove(account: String) {
        do {
            try secrets.removeSecret(for: account)
            tokenError = nil
        } catch {
            tokenError = error.localizedDescription
        }
        appModel.refreshTokenState()
    }

    /// Prefers an unsaved draft so a token can be tested before saving it.
    private func token(draft: String, account: String) throws -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let saved = try secrets.secret(for: account), !saved.isEmpty else {
            throw APIError.missingToken
        }
        return saved
    }

    // MARK: Connection tests

    func testGitLab(settings: AccountSettings) async {
        gitLabTest = .testing
        do {
            let baseURL = try BaseURL.normalize(settings.gitLabBaseURL, strippingSuffixes: BaseURL.gitLabSuffixes)
            let client = clients.gitLab(baseURL: baseURL, token: try token(draft: gitLabTokenDraft, account: settings.gitLabTokenAccount))
            let user = try await client.currentUser()
            let tokenInfo = try? await client.tokenInfo()

            settings.gitLabUserID = user.id
            settings.gitLabUsername = user.username
            settings.gitLabVerifiedAt = .now

            let signedIn = "Signed in as @\(user.username) (\(user.name))"
            if let scopes = tokenInfo?.scopes {
                let list = scopes.sorted().joined(separator: ", ")
                if !GitLabScopes.hasReadAccess(scopes) {
                    gitLabTest = .warning("\(signedIn), but the token lacks read_api. Scopes: \(list)")
                } else if settings.postCommentsEnabled && !scopes.contains(GitLabScopes.commentPosting) {
                    gitLabTest = .warning("\(signedIn), but posting comments needs the api scope. Scopes: \(list)")
                } else {
                    gitLabTest = .success("\(signedIn). Scopes: \(list)")
                }
            } else {
                gitLabTest = .success(signedIn)
            }
        } catch {
            gitLabTest = .failure(error.localizedDescription)
        }
    }

    func testJira(settings: AccountSettings) async {
        jiraTest = .testing
        do {
            let baseURL = try BaseURL.normalize(settings.jiraBaseURL, strippingSuffixes: BaseURL.jiraSuffixes)
            let token = try token(draft: jiraTokenDraft, account: settings.jiraTokenAccount)
            let auth: JiraAuth
            switch settings.jiraDeployment {
            case .cloud:
                let email = settings.jiraEmail.trimmingCharacters(in: .whitespaces)
                guard !email.isEmpty else { throw APIError.missingEmail }
                auth = .cloudBasic(email: email, token: token)
            case .dataCenter:
                auth = .dataCenterBearer(token: token)
            }
            let user = try await clients.jira(baseURL: baseURL, auth: auth).myself()
            settings.jiraDisplayName = user.displayName
            settings.jiraVerifiedAt = .now
            let detail = user.emailAddress.map { " (\($0))" } ?? ""
            jiraTest = .success("Signed in as \(user.displayName)\(detail)")
        } catch {
            jiraTest = .failure(error.localizedDescription)
        }
    }
}
