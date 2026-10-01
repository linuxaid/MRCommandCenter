import Foundation
import Testing
@testable import MR_Command_Center

struct BaseURLTests {
    @Test(arguments: [
        ("https://gitlab.example.com", "https://gitlab.example.com"),
        ("https://gitlab.example.com/", "https://gitlab.example.com"),
        ("  https://gitlab.example.com/api/v4/ ", "https://gitlab.example.com"),
        ("gitlab.example.com", "https://gitlab.example.com"),
        ("https://example.com/gitlab/api/v4", "https://example.com/gitlab"),
        ("HTTPS://gitlab.example.com:8443", "https://gitlab.example.com:8443"),
    ])
    func normalizesGitLab(input: String, expected: String) throws {
        let url = try BaseURL.normalize(input, strippingSuffixes: BaseURL.gitLabSuffixes)
        #expect(url.absoluteString == expected)
    }

    @Test func stripsJiraAPIPaths() throws {
        let v3 = try BaseURL.normalize("https://acme.atlassian.net/rest/api/3", strippingSuffixes: BaseURL.jiraSuffixes)
        let v2 = try BaseURL.normalize("https://jira.acme.com/rest/api/2/", strippingSuffixes: BaseURL.jiraSuffixes)
        #expect(v3.absoluteString == "https://acme.atlassian.net")
        #expect(v2.absoluteString == "https://jira.acme.com")
    }

    @Test func rejectsEmptyAndBadInput() {
        #expect(throws: APIError.missingBaseURL) { try BaseURL.normalize("   ") }
        #expect(throws: APIError.self) { try BaseURL.normalize("ftp://example.com") }
        #expect(throws: APIError.self) { try BaseURL.normalize("https://") }
    }
}
