import Foundation
import Observation
import SwiftData
import os

/// Today's joke and where it came from.
struct DadJoke: Equatable {
    let text: String
    /// False for a built-in joke standing in for the model's.
    let isFromModel: Bool
}

/// One dad joke a day at the top of the main window (#38), written by the on-device model.
/// Kept in settings so it stays the same all day, across launches. Until the model's joke
/// arrives, or when the model refuses, a joke from a short built-in list stands in. A model
/// that's busy or not ready is asked again after the next refresh.
@Observable
final class DadJokeService {
    @ObservationIgnored private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped when a new joke is stored, so the banner updates.
    private(set) var revision = 0

    /// Jokes remembered so neither the model nor the built-in list repeats them.
    static let recentLimit = 14
    static let maxLength = 280

    init(container: ModelContainer, dependencies: AppDependencies) {
        self.container = container
        self.dependencies = dependencies
    }

    private var settings: AccountSettings { AccountSettings.current(in: context) }

    /// Today's joke: the one stored for today, or a built-in one until it's been written.
    func joke(now: Date = .now, calendar: Calendar = .current) -> DadJoke {
        _ = revision
        let settings = settings
        if let text = settings.dadJokeText, settings.dadJokeDay == Self.dayKey(now, calendar: calendar) {
            return DadJoke(text: text, isFromModel: !settings.dadJokeIsFallback)
        }
        return DadJoke(text: Self.fallback(for: now, calendar: calendar, avoiding: settings.recentDadJokes), isFromModel: false)
    }

    /// Whether a joke has been settled for today (the model's, or a built-in one after it refused).
    func hasStoredJoke(now: Date = .now, calendar: Calendar = .current) -> Bool {
        let settings = settings
        return settings.dadJokeText != nil && settings.dadJokeDay == Self.dayKey(now, calendar: calendar)
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Asks the model for today's joke in the background if it hasn't written one yet. Cheap
    /// to call on every refresh; does nothing while the model can't run.
    func startIfNeeded(now: Date = .now, calendar: Calendar = .current) {
        guard task == nil, !hasStoredJoke(now: now, calendar: calendar), dependencies.modelStatus().isAvailable else { return }
        task = Task { [weak self] in
            await self?.makeJoke(for: now, calendar: calendar)
            self?.task = nil
        }
    }

    /// Waits for a joke being written. The difficulty nudges wait on it, so the two never ask
    /// the model at once.
    func waitForJoke() async {
        await task?.value
    }

    private func makeJoke(for date: Date, calendar: Calendar) async {
        let recent = settings.recentDadJokes
        let day = Self.dayKey(date, calendar: calendar)
        do {
            let answer = try await dependencies.reviewModel()
                .dadJoke(instructions: Self.instructions, prompt: Self.prompt(avoiding: recent),
                         options: ReviewOptions(greedy: false, temperature: 1.0, maximumResponseTokens: 120))
            if let text = Self.clean(answer, avoiding: recent) {
                store(text, day: day, isFallback: false)
            } else {
                // Empty, too long, or a repeat: asked again after the next refresh.
                Log.sync.info("The model's dad joke wasn't usable; trying again later")
            }
        } catch is CancellationError {
            return
        } catch {
            let failure = ReviewFailureMapper.map(error)
            Log.sync.error("The model couldn't write a dad joke: \(failure.title, privacy: .public)")
            // A refusal or guardrail won't change with retries: settle on a built-in joke for today.
            guard !DifficultyService.isTemporary(failure) else { return }
            store(Self.fallback(for: date, calendar: calendar, avoiding: recent), day: day, isFallback: true)
        }
    }

    private func store(_ joke: String, day: String, isFallback: Bool) {
        let settings = settings
        settings.dadJokeText = joke
        settings.dadJokeDay = day
        settings.dadJokeIsFallback = isFallback
        settings.recentDadJokes = Array((settings.recentDadJokes.filter { $0 != joke } + [joke]).suffix(Self.recentLimit))
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving the dad joke failed: \(error.localizedDescription, privacy: .public)")
        }
        revision += 1
    }

    static let instructions = """
    You write one short, clean, family-friendly dad joke: a pun-based setup and punchline, \
    two sentences at most. Reply with the joke only, no introduction and no explanation.
    """

    static func prompt(avoiding recent: [String]) -> String {
        guard !recent.isEmpty else { return "Tell me today's dad joke." }
        return "Tell me today's dad joke. Don't reuse any of these:\n" + recent.map { "- \($0)" }.joined(separator: "\n")
    }

    /// The model's answer, tidied, or nil when it's empty, too long, or a repeat.
    static func clean(_ answer: String, avoiding recent: [String]) -> String? {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Here's a dad joke:", "Here is a dad joke:", "Here's one:", "Dad joke:"] {
            for variant in [prefix, prefix.replacingOccurrences(of: "'", with: "’")]
            where text.lowercased().hasPrefix(variant.lowercased()) {
                text = String(text.dropFirst(variant.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Outer quotes around the whole joke, but not dialogue like "Hi," said Dad, "bye."
        let quotes = CharacterSet(charactersIn: "\"“”")
        if text.count > 1, text.unicodeScalars.filter(quotes.contains).count == 2,
           let first = text.unicodeScalars.first, let last = text.unicodeScalars.last,
           quotes.contains(first), quotes.contains(last) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty, text.count <= maxLength else { return nil }
        let normalized = text.lowercased()
        guard !recent.contains(where: { $0.lowercased() == normalized }) else { return nil }
        return text
    }

    /// The same joke all day, a different one the next, skipping recent jokes while it can.
    static func fallback(for date: Date, calendar: Calendar = .current, avoiding recent: [String] = []) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = (parts.year ?? 0) * 372 + (parts.month ?? 0) * 31 + (parts.day ?? 0)
        let start = day % fallbackJokes.count
        let order = fallbackJokes[start...] + fallbackJokes[..<start]
        return order.first { !recent.contains($0) } ?? fallbackJokes[start]
    }

    static let fallbackJokes = [
        "I told my computer I needed a break, and it said no problem, it would go to sleep.",
        "Why do programmers prefer dark mode? Because light attracts bugs.",
        "I only know 25 letters of the alphabet. I don't know y.",
        "Why did the merge request go to therapy? It had too many unresolved issues.",
        "I'm reading a book about anti-gravity. It's impossible to put down.",
        "Why don't skeletons fight each other? They don't have the guts.",
        "What do you call a fake noodle? An impasta.",
        "Why did the developer go broke? They used up all their cache.",
        "I used to hate facial hair, but then it grew on me.",
        "Why did the scarecrow win an award? It was outstanding in its field.",
        "How does a pipeline say goodbye? It waves its artifacts.",
        "What do you call a fish wearing a bowtie? Sofishticated.",
        "Why was the branch so calm? It had already been rebased.",
        "I would tell you a UDP joke, but you might not get it.",
    ]
}
