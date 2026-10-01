import Foundation

/// One file from `GET /projects/:id/merge_requests/:iid/diffs` (GitLab 15.7+).
/// Also the on-disk format for `DiffSnapshot`, so it's Codable both ways.
nonisolated struct GitLabDiff: Codable, Sendable, Equatable {
    var oldPath: String
    var newPath: String
    var aMode: String?
    var bMode: String?
    var diff: String
    var newFile: Bool
    var renamedFile: Bool
    var deletedFile: Bool
    /// GitLab 16.9+. Lock files, generated code, etc.
    var generatedFile: Bool?
    /// GitLab omitted the diff because it exceeds the collapse limits.
    var collapsed: Bool?
    /// GitLab omitted the diff because it exceeds the hard size limit.
    var tooLarge: Bool?
}
