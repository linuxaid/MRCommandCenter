import Foundation
import Observation
import SwiftData
import os

/// One dad joke a day at the top of the main window (#38), written by the on-device model.
/// Kept in settings so it stays the same all day, across launches. When the model can't run
/// or gives nothing usable, a joke from a short built-in list stands in.
@Observable
final class DadJokeService {
    @ObservationIgnored private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped when a new joke is stored, so the banner updates.
    private(set) var revision = 0

    /// Jokes remembered so the model is asked not to repeat them.
    static let recentLimit = 14
    static let maxLength = 280

    init(container: ModelContainer, dependencies: AppDependencies) {
        self.container = container
        self.dependencies = dependencies
    }

    private var settings: AccountSettings { AccountSettings.current(in: context) }

    /// Today's joke, or nil until it's been written.
    func joke(now: Date = .now, calendar: Calendar = .current) -> String? {
        _ = revision
        guard settings.dadJokeDay == Self.dayKey(now, calendar: calendar) else { return nil }
        return settings.dadJokeText
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Writes today's joke in the background if there isn't one yet. Cheap to call on every refresh.
    func startIfNeeded(now: Date = .now, calendar: Calendar = .current) {
        guard task == nil, joke(now: now, calendar: calendar) == nil else { return }
        task = Task { [weak self] in
            await self?.makeJoke(for: now, calendar: calendar)
            self?.task = nil
        }
    }

    /// Waits for a joke being written (tests).
    func waitForJoke() async {
        await task?.value
    }

    private func makeJoke(for date: Date, calendar: Calendar) async {
        let recent = settings.recentDadJokes
        var text: String?
        if dependencies.modelStatus().isAvailable {
            do {
                let answer = try await dependencies.reviewModel()
                    .dadJoke(instructions: Self.instructions, prompt: Self.prompt(avoiding: recent),
                             options: ReviewOptions(greedy: false, temperature: 1.0, maximumResponseTokens: 120))
                text = Self.clean(answer, avoiding: recent)
            } catch is CancellationError {
                return
            } catch {
                Log.sync.error("The model couldn't write a dad joke: \(ReviewFailureMapper.map(error).title, privacy: .public)")
            }
        }
        store(text ?? Self.fallback(for: date, calendar: calendar), day: Self.dayKey(date, calendar: calendar))
    }

    private func store(_ joke: String, day: String) {
        let settings = settings
        settings.dadJokeText = joke
        settings.dadJokeDay = day
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
        for prefix in ["Here's a dad joke:", "Here is a dad joke:", "Here's one:", "Dad joke:"]
        where text.lowercased().hasPrefix(prefix.lowercased()) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotes = CharacterSet(charactersIn: "\"“”'")
        if let first = text.unicodeScalars.first, let last = text.unicodeScalars.last,
           quotes.contains(first), quotes.contains(last), text.count > 1 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty, text.count <= maxLength else { return nil }
        let normalized = text.lowercased()
        guard !recent.contains(where: { $0.lowercased() == normalized }) else { return nil }
        return text
    }

    /// The same joke all day, a different one the next.
    static func fallback(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = (parts.year ?? 0) * 372 + (parts.month ?? 0) * 31 + (parts.day ?? 0)
        return fallbackJokes[day % fallbackJokes.count]
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
