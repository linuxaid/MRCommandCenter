import Foundation
import Observation
import SwiftData

/// Drafts and posts the AI summary thread for an MR. One instance, so the preview can be
/// opened from the AI Review tab or the Changes strip.
@Observable
final class SummaryPoster {
    struct Draft: Identifiable, Equatable {
        var id: UUID { runID }
        let runID: UUID
        let mrKey: String
        let location: String
        var body: String
    }

    var draft: Draft?
    private(set) var isPosting = false
    var error: String?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let aiReview: AIReviewService
    @ObservationIgnored private let discussions: DiscussionService

    init(container: ModelContainer, aiReview: AIReviewService, discussions: DiscussionService) {
        self.container = container
        self.aiReview = aiReview
        self.discussions = discussions
    }

    var isPostingEnabled: Bool { discussions.isPostingEnabled }

    func preview(_ run: AIReviewRun, for mr: TrackedMR) {
        error = nil
        draft = Draft(runID: run.id, mrKey: mr.key, location: "\(mr.reference) · new thread on the merge request",
                      body: aiReview.summaryBody(for: run, mr: mr))
    }

    func post() async {
        guard let draft else { return }
        let context = container.mainContext
        let runID = draft.runID
        let key = draft.mrKey
        guard let run = try? context.fetch(FetchDescriptor<AIReviewRun>(predicate: #Predicate { $0.id == runID })).first,
              let mr = try? context.fetch(FetchDescriptor<TrackedMR>(predicate: #Predicate { $0.key == key })).first else { return }
        isPosting = true
        defer { isPosting = false }
        do {
            _ = try await discussions.postSummary(of: run, body: draft.body, mr: mr)
            self.draft = nil
            aiReview.updateOpenConcerns(for: mr)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
