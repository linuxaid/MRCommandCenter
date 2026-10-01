import Foundation

nonisolated struct GitLabUser: Decodable, Sendable, Equatable, Hashable {
    let id: Int
    let username: String
    let name: String
    var avatarUrl: String?
    var webUrl: String?
}

/// `GET /personal_access_tokens/self` (GitLab 15.5+). Used to show granted scopes.
nonisolated struct GitLabTokenInfo: Decodable, Sendable, Equatable {
    let name: String
    let scopes: [String]
    var active: Bool?
    var expiresAt: Date?
}
