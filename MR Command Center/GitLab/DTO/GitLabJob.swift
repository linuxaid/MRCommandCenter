import Foundation

/// A CI job, from a pipeline's job list.
nonisolated struct GitLabJob: Decodable, Sendable, Equatable, Identifiable {
    let id: Int
    let name: String
    var stage: String?
    let status: String
    var failureReason: String?
    var webUrl: String?
    var allowFailure: Bool?

    /// GitLab's failure reason in words, or nil when it gave none.
    var failureText: String? {
        guard let failureReason, !failureReason.isEmpty else { return nil }
        switch failureReason {
        case "script_failure": return "The job's script failed"
        case "stuck_or_timeout_failure", "job_execution_timeout": return "Timed out"
        case "runner_system_failure": return "The runner had a problem"
        case "runner_unsupported": return "The runner doesn't support this job"
        case "missing_dependency_failure": return "An artifact it needs is missing"
        case "api_failure": return "GitLab API error"
        case "scheduler_failure": return "It couldn't be scheduled"
        case "data_integrity_failure": return "GitLab data problem"
        case "unknown_failure": return "Unknown failure"
        default:
            let words = failureReason.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}
