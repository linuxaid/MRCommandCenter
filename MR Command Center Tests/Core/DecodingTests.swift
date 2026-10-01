import Foundation
import Testing
@testable import MR_Command_Center

struct DecodingTests {
    @Test func decodesGitLabUser() throws {
        let user = try HTTPClient.decode(GitLabUser.self, from: Fixture.data("gitlab_user"), decoder: .gitLab)
        #expect(user == GitLabUser(
            id: 1234, username: "jdoe", name: "Jane Doe",
            avatarUrl: "https://gitlab.example.com/uploads/-/system/user/avatar/1234/avatar.png",
            webUrl: "https://gitlab.example.com/jdoe"
        ))
    }

    @Test func decodesGitLabTokenInfoWithDateOnlyExpiry() throws {
        let info = try HTTPClient.decode(GitLabTokenInfo.self, from: Fixture.data("gitlab_token_self"), decoder: .gitLab)
        #expect(info.scopes == ["read_api"])
        #expect(info.active == true)
        #expect(info.expiresAt != nil)
    }

    @Test func decodesJiraCloudMyself() throws {
        let user = try HTTPClient.decode(JiraUser.self, from: Fixture.data("jira_myself_cloud"), decoder: .jira)
        #expect(user.accountId == "5b10a2844c20165700ede21g")
        #expect(user.displayName == "Jane Doe")
    }

    @Test func decodesJiraDataCenterMyself() throws {
        let user = try HTTPClient.decode(JiraUser.self, from: Fixture.data("jira_myself_datacenter"), decoder: .jira)
        #expect(user.accountId == nil)
        #expect(user.name == "jdoe")
    }

    @Test(arguments: ["2026-09-30T08:15:03.112Z", "2026-09-30T08:15:03Z", "2026-09-30T08:15:03.112+0000", "2026-09-30"])
    func parsesDateFormats(value: String) {
        #expect(FlexibleISO8601.parse(value) != nil)
    }
}
