import Foundation
import Testing
@testable import MR_Command_Center

struct ConnectionTests {
    @Test func gitLabClientSendsPrivateTokenToUserEndpoint() async throws {
        let transport = StubTransport([.response(status: 200, body: try Fixture.data("gitlab_user"))])
        let client = LiveGitLabClient(baseURL: URL(string: "https://gitlab.example.com")!, token: "glpat-x", transport: transport)
        let user = try await client.currentUser()
        #expect(user.username == "jdoe")
        let request = try #require(transport.requests.first)
        #expect(request.url?.path() == "/api/v4/user")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-x")
    }

    @Test func gitLabTokenInfoReturnsNilWhenUnsupported() async throws {
        let transport = StubTransport([.response(status: 404)])
        let client = LiveGitLabClient(baseURL: URL(string: "https://gitlab.example.com")!, token: "t", transport: transport)
        #expect(try await client.tokenInfo() == nil)
    }

    @Test func jiraCloudUsesBasicAuthAndV3() async throws {
        let transport = StubTransport([.response(status: 200, body: try Fixture.data("jira_myself_cloud"))])
        let client = LiveJiraClient(
            baseURL: URL(string: "https://acme.atlassian.net")!,
            auth: .cloudBasic(email: "jane@example.com", token: "tok"),
            transport: transport
        )
        _ = try await client.myself()
        let request = try #require(transport.requests.first)
        #expect(request.url?.path() == "/rest/api/3/myself")
        let expected = "Basic " + Data("jane@example.com:tok".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
    }

    @Test func jiraDataCenterUsesBearerAndV2() async throws {
        let transport = StubTransport([.response(status: 200, body: try Fixture.data("jira_myself_datacenter"))])
        let client = LiveJiraClient(
            baseURL: URL(string: "https://jira.acme.com")!,
            auth: .dataCenterBearer(token: "pat"),
            transport: transport
        )
        _ = try await client.myself()
        let request = try #require(transport.requests.first)
        #expect(request.url?.path() == "/rest/api/2/myself")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pat")
    }

    @Test func accountsModelReportsSignedInUserAndStoresIt() async throws {
        let appModel = AppModel.preview()
        let model = AccountsModel(appModel: appModel)
        let settings = AccountSettings()
        settings.gitLabBaseURL = "https://gitlab.example.com/api/v4"

        await model.testGitLab(settings: settings)

        guard case .success(let message) = model.gitLabTest else {
            Issue.record("Expected success, got \(model.gitLabTest)")
            return
        }
        #expect(message.contains("@aj"))
        #expect(settings.gitLabUserID == 42)
    }

    @Test func accountsModelRequiresEmailForJiraCloud() async {
        let model = AccountsModel(appModel: AppModel.preview())
        let settings = AccountSettings()
        settings.jiraBaseURL = "https://acme.atlassian.net"
        settings.jiraEmail = ""
        await model.testJira(settings: settings)
        #expect(model.jiraTest == .failure(APIError.missingEmail.localizedDescription))
    }

    @Test func savingAndRemovingTokenUpdatesAppState() throws {
        let appModel = AppModel.preview(dependencies: AppDependencies(secrets: InMemorySecretStore(), clients: MockClientFactory(), isMock: true))
        let model = AccountsModel(appModel: appModel)
        let settings = AccountSettings()
        #expect(appModel.needsOnboarding)

        model.gitLabTokenDraft = "  glpat-new \n"
        model.saveGitLabToken(settings: settings)
        #expect(appModel.hasGitLabToken)
        #expect(model.gitLabTokenDraft.isEmpty)
        #expect(try appModel.dependencies.secrets.secret(for: SecretAccount.gitLabToken) == "glpat-new")

        model.removeGitLabToken(settings: settings)
        #expect(!appModel.hasGitLabToken)
    }
}
