import Foundation
import SwiftData

enum AppModelContainer {
    static let schema = Schema([
        AccountSettings.self,
        TrackedMR.self,
        DiffSnapshot.self,
        StaticCheckSnapshot.self,
        ReviewSkill.self,
        PromptVersion.self,
        AIReviewRun.self,
        FileReviewRecord.self,
        ConcernRecord.self,
        EvalCase.self,
        EvalBatch.self,
        JiraCheck.self,
        ActivityEvent.self,
        MergeRule.self,
    ])

    static func make(inMemory: Bool) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
