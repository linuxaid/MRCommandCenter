import Foundation

nonisolated struct LiveJiraClient: JiraAPI {
    let http: HTTPClient
    let auth: JiraAuth

    init(baseURL: URL, auth: JiraAuth, transport: any HTTPTransport) {
        self.auth = auth
        http = HTTPClient(
            baseURL: baseURL,
            transport: transport,
            defaultHeaders: ["Authorization": auth.authorizationHeader, "Accept": "application/json"]
        )
    }

    func myself() async throws -> JiraUser {
        try await http.get(JiraUser.self, path: auth.apiPath + "/myself", decoder: .jira)
    }

    func issue(key: String, fields: [String]) async throws -> JiraIssue {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? key
        return try await http.get(JiraIssue.self, path: auth.apiPath + "/issue/" + encoded,
                                  query: [URLQueryItem(name: "fields", value: fields.joined(separator: ","))], decoder: .jira)
    }

    func fields() async throws -> [JiraField] {
        try await http.get([JiraField].self, path: auth.apiPath + "/field", decoder: .jira)
    }
}
