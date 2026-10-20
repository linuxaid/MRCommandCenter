import Foundation
import SwiftData

/// Something that happened to a merge request between refreshes: a push, a pipeline result,
/// an approval, a reply, a merge. Feeds the Activity view and each MR's brief.
@Model
final class ActivityEvent {
    var id: UUID
    var date: Date
    var mrKey: String
    var mrReference: String
    var mrTitle: String
    var kindRaw: String
    var message: String

    init(kind: ActivityKind, message: String, mrKey: String, mrReference: String, mrTitle: String, date: Date = .now) {
        id = UUID()
        self.date = date
        self.mrKey = mrKey
        self.mrReference = mrReference
        self.mrTitle = mrTitle
        kindRaw = kind.rawValue
        self.message = message
    }

    var kind: ActivityKind { ActivityKind(rawValue: kindRaw) ?? .other }
}

nonisolated enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case appeared
    case pushed
    case pipelinePassed
    case pipelineFailed
    case approved
    case approvalRevoked
    case replied
    case threadsResolved
    case conflicts
    case conflictsCleared
    case readyToMerge
    case left
    case autoMerged
    case autoMergeWouldMerge
    case autoMergeFailed
    case other
}
