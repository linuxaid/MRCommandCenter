import Foundation

/// Errors surfaced by the GitLab and Jira clients. Never carries response bodies,
/// which could contain code or personal data.
nonisolated enum APIError: LocalizedError, Equatable, Sendable {
    case missingBaseURL
    case invalidBaseURL(String)
    case missingToken
    case missingEmail
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case server(status: Int)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: "Enter a base URL first."
        case .invalidBaseURL(let reason): reason
        case .missingToken: "No token saved. Add one in Accounts."
        case .missingEmail: "Enter the email address for your Jira account."
        case .unauthorized: "The token was rejected (401). It may be expired or revoked."
        case .forbidden: "The token doesn't have permission for this (403). Check its scopes."
        case .notFound: "Not found (404). Check the base URL."
        case .rateLimited: "Rate limited by the server. Try again shortly."
        case .offline: "Can't reach the server. Check your network or VPN."
        case .server(let status): "The server returned an error (\(status))."
        case .decoding(let detail): "Unexpected response from the server: \(detail)"
        case .transport(let detail): detail
        }
    }

    /// True when the user needs to fix their token or credentials in Accounts.
    var needsCredentialFix: Bool {
        switch self {
        case .unauthorized, .forbidden, .missingToken, .missingEmail: true
        default: false
        }
    }
}
