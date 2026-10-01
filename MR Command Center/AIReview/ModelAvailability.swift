import Foundation
import FoundationModels

/// Whether the on-device model can run, with a user-facing explanation when it can't.
nonisolated enum ModelStatus: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown(String)

    static var current: ModelStatus {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable(let other): .unknown(String(describing: other))
        }
    }

    var isAvailable: Bool { self == .available }

    var title: String {
        switch self {
        case .available: "On-device model ready"
        case .deviceNotEligible: "This Mac can't run Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is turned off"
        case .modelNotReady: "The on-device model isn't ready yet"
        case .unknown: "The on-device model is unavailable"
        }
    }

    var explanation: String {
        switch self {
        case .available:
            "Reviews run entirely on this Mac. Code never leaves the machine."
        case .deviceNotEligible:
            "AI review needs a Mac with Apple silicon that supports Apple Intelligence. Everything else in the app still works."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri, then come back. Everything else in the app still works."
        case .modelNotReady:
            "The model is still downloading or being prepared. Try again in a few minutes."
        case .unknown(let reason):
            "The model reported: \(reason)."
        }
    }
}
