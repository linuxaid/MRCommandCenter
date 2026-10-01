import Foundation

/// Everything that talks to the outside world, injected so previews, mock mode,
/// and tests can run without real tokens.
struct AppDependencies {
    let secrets: any SecretStore
    let clients: any ClientFactory
    let isMock: Bool
    /// The review model. Mock mode still uses the real on-device model when it's available.
    var reviewModel: @Sendable () -> any ReviewLanguageModel = { OnDeviceReviewModel() }
    var modelStatus: @Sendable () -> ModelStatus = { ModelStatus.current }

    static func live() -> AppDependencies {
        AppDependencies(
            secrets: KeychainSecretStore(),
            clients: LiveClientFactory(transport: URLSessionTransport()),
            isMock: false
        )
    }

    static func mock() -> AppDependencies {
        AppDependencies(
            secrets: InMemorySecretStore([
                SecretAccount.gitLabToken: "mock-gitlab-token",
                SecretAccount.jiraToken: "mock-jira-token",
            ]),
            clients: MockClientFactory(),
            isMock: true
        )
    }
}

extension AppDependencies {
    /// A GitLab client for the saved connection details, or `APIError.missingBaseURL` / `.missingToken`.
    func gitLabClient(settings: AccountSettings) throws -> any GitLabAPI {
        let baseURL = try BaseURL.normalize(settings.gitLabBaseURL, strippingSuffixes: BaseURL.gitLabSuffixes)
        guard let token = try secrets.secret(for: settings.gitLabTokenAccount), !token.isEmpty else {
            throw APIError.missingToken
        }
        return clients.gitLab(baseURL: baseURL, token: token)
    }
}

enum LaunchMode {
    /// `-UseMockData` runs the app against mock clients and an in-memory store.
    static var usesMockData: Bool {
        ProcessInfo.processInfo.arguments.contains("-UseMockData")
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
