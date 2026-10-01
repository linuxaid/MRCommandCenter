import Foundation
import SwiftData

/// Diff-based check results for one MR at one head SHA. Recomputed when the SHA or the
/// check settings (fingerprint) change. Metadata checks aren't stored; they're derived
/// live from `TrackedMR`.
@Model
final class StaticCheckSnapshot {
    @Attribute(.unique) var id: String
    var mrKey: String
    var headSHA: String
    var configurationFingerprint: String
    /// JSON-encoded `[CheckResult]`.
    var resultsData: Data
    var computedAt: Date

    init(mrKey: String, headSHA: String, fingerprint: String, results: [CheckResult], computedAt: Date = .now) throws {
        id = "\(mrKey)@\(headSHA)"
        self.mrKey = mrKey
        self.headSHA = headSHA
        configurationFingerprint = fingerprint
        resultsData = try JSONEncoder().encode(results)
        self.computedAt = computedAt
    }

    func results() throws -> [CheckResult] {
        try JSONDecoder().decode([CheckResult].self, from: resultsData)
    }
}
