import Foundation

nonisolated enum JiraDeployment: String, CaseIterable, Codable, Sendable, Identifiable {
    case cloud
    case dataCenter

    var id: Self { self }

    var displayName: String {
        switch self {
        case .cloud: "Jira Cloud"
        case .dataCenter: "Data Center / Server"
        }
    }
}

/// How requests authenticate. Cloud uses email + API token as Basic auth;
/// Data Center uses a Personal Access Token as Bearer.
nonisolated enum JiraAuth: Sendable {
    case cloudBasic(email: String, token: String)
    case dataCenterBearer(token: String)

    var authorizationHeader: String {
        switch self {
        case .cloudBasic(let email, let token):
            "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
        case .dataCenterBearer(let token):
            "Bearer " + token
        }
    }

    /// Cloud has v3 (ADF rich text); Data Center only has v2 (plain/wiki text).
    var apiPath: String {
        switch self {
        case .cloudBasic: "/rest/api/3"
        case .dataCenterBearer: "/rest/api/2"
        }
    }
}
