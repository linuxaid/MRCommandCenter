import Foundation

/// `GET /myself`. Cloud returns `accountId`; Data Center returns `name`/`key`.
nonisolated struct JiraUser: Decodable, Sendable, Equatable {
    var accountId: String?
    var name: String?
    let displayName: String
    var emailAddress: String?
}
