import Foundation
import SwiftData
import Testing
@testable import MR_Command_Center

/// Issue #38: one dad joke a day at the top of the main window, from the on-device model.
@MainActor
struct DadJokeTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func date(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private let modelJoke = "Why did the fake model cross the road? To get to the other test."

    @Test func aRefreshWritesTodaysJokeOnce() async throws {
        let model = FakeReviewModel()
        let app = AppModel.testing(model: model)
        let before = app.dadJoke.joke()
        #expect(!before.isFromModel, "A built-in joke shows until the model's arrives")
        #expect(DadJokeService.fallbackJokes.contains(before.text))

        await app.refresh(.automatic)
        await app.dadJoke.waitForJoke()
        #expect(app.dadJoke.joke() == DadJoke(text: modelJoke, isFromModel: true))
        #expect(model.jokeCalls.count == 1)

        await app.refresh(.automatic)
        await app.dadJoke.waitForJoke()
        #expect(model.jokeCalls.count == 1, "Same day, same joke")
    }

    @Test func aRefreshDoesntWaitForTheJoke() async throws {
        let model = FakeReviewModel()
        // The model takes far longer than a refresh; the refresh returns with a built-in joke showing.
        model.edit { $0.jokeDelay = .seconds(60) }
        let app = AppModel.testing(model: model)
        await app.refresh(.automatic)
        #expect(!app.dadJoke.joke().isFromModel)
        #expect(!app.dadJoke.hasStoredJoke())
    }

    @Test func aNewDayBringsANewJokeThatAvoidsRecentOnes() async throws {
        let model = FakeReviewModel()
        let app = AppModel.testing(model: model)
        let service = app.dadJoke

        service.startIfNeeded(now: date(30), calendar: calendar)
        await service.waitForJoke()
        let first = service.joke(now: date(30, hour: 23), calendar: calendar)
        #expect(first.isFromModel)
        #expect(!service.joke(now: date(31), calendar: calendar).isFromModel, "Yesterday's joke isn't today's")

        model.edit { $0.joke = "  \"I'm afraid for the calendar. Its days are numbered.\"\n" }
        service.startIfNeeded(now: date(31), calendar: calendar)
        await service.waitForJoke()
        #expect(service.joke(now: date(31), calendar: calendar).text == "I'm afraid for the calendar. Its days are numbered.")
        #expect(model.jokeCalls.last?.prompt.contains(first.text) == true)
        #expect(AccountSettings.current(in: app.modelContainer.mainContext).recentDadJokes.count == 2)
    }

    @Test func aRepeatIsAskedAgainLater() async throws {
        let model = FakeReviewModel()
        let app = AppModel.testing(model: model)
        app.dadJoke.startIfNeeded(now: date(30), calendar: calendar)
        await app.dadJoke.waitForJoke()

        // Tomorrow the model repeats itself: not stored, and a built-in joke shows meanwhile.
        app.dadJoke.startIfNeeded(now: date(31), calendar: calendar)
        await app.dadJoke.waitForJoke()
        #expect(!app.dadJoke.hasStoredJoke(now: date(31), calendar: calendar))
        #expect(app.dadJoke.joke(now: date(31), calendar: calendar).text != modelJoke)

        model.edit { $0.joke = "A brand new one." }
        app.dadJoke.startIfNeeded(now: date(31), calendar: calendar)
        await app.dadJoke.waitForJoke()
        #expect(app.dadJoke.joke(now: date(31), calendar: calendar) == DadJoke(text: "A brand new one.", isFromModel: true))
    }

    @Test func aBusyModelIsAskedAgainAfterTheNextRefresh() async throws {
        let model = FakeReviewModel()
        model.edit {
            $0.joke = nil
            $0.jokeFailure = .rateLimited
        }
        let app = AppModel.testing(model: model)
        app.dadJoke.startIfNeeded(now: date(30), calendar: calendar)
        await app.dadJoke.waitForJoke()
        #expect(!app.dadJoke.hasStoredJoke(now: date(30), calendar: calendar))
        #expect(!app.dadJoke.joke(now: date(30), calendar: calendar).isFromModel)

        model.edit { $0.joke = "Finally." }
        app.dadJoke.startIfNeeded(now: date(30), calendar: calendar)
        await app.dadJoke.waitForJoke()
        #expect(model.jokeCalls.count == 2)
        #expect(app.dadJoke.joke(now: date(30), calendar: calendar) == DadJoke(text: "Finally.", isFromModel: true))
    }

    @Test func aRefusalSettlesOnABuiltInJokeForTheDay() async throws {
        let model = FakeReviewModel()
        model.edit { $0.joke = nil }
        let app = AppModel.testing(model: model)
        app.dadJoke.startIfNeeded(now: date(30), calendar: calendar)
        await app.dadJoke.waitForJoke()
        let joke = app.dadJoke.joke(now: date(30), calendar: calendar)
        #expect(!joke.isFromModel)
        #expect(DadJokeService.fallbackJokes.contains(joke.text))
        app.dadJoke.startIfNeeded(now: date(30), calendar: calendar)
        await app.dadJoke.waitForJoke()
        #expect(model.jokeCalls.count == 1)
    }

    @Test func withoutTheModelABuiltInJokeShows() async throws {
        let model = FakeReviewModel()
        let app = AppModel.testing(model: model, modelStatus: .appleIntelligenceNotEnabled)
        app.dadJoke.startIfNeeded(now: date(30), calendar: calendar)
        await app.dadJoke.waitForJoke()
        #expect(model.jokeCalls.isEmpty)
        let joke = app.dadJoke.joke(now: date(30), calendar: calendar)
        #expect(joke == DadJoke(text: DadJokeService.fallback(for: date(30), calendar: calendar), isFromModel: false))
    }

    @Test func builtInJokesSkipRecentOnes() {
        let today = DadJokeService.fallback(for: date(30), calendar: calendar)
        let other = DadJokeService.fallback(for: date(30), calendar: calendar, avoiding: [today])
        #expect(other != today)
        #expect(DadJokeService.fallback(for: date(30), calendar: calendar, avoiding: DadJokeService.fallbackJokes) == today)
    }

    @Test func fallbackJokesChangeDaily() {
        #expect(DadJokeService.fallback(for: date(30), calendar: calendar) != DadJokeService.fallback(for: date(31), calendar: calendar))
        #expect(DadJokeService.fallback(for: date(30, hour: 1), calendar: calendar) == DadJokeService.fallback(for: date(30, hour: 23), calendar: calendar))
    }

    @Test func answersAreTidiedOrRejected() {
        #expect(DadJokeService.clean("Here's a dad joke: Why? Because.", avoiding: []) == "Why? Because.")
        #expect(DadJokeService.clean("Why did it?\n\nBecause it could.", avoiding: []) == "Why did it? Because it could.")
        #expect(DadJokeService.clean("“Quoted joke.”", avoiding: []) == "Quoted joke.")
        #expect(DadJokeService.clean("Here’s a dad joke: Curly apostrophe.", avoiding: []) == "Curly apostrophe.")
        #expect(DadJokeService.clean("\"Hi,\" said Dad, \"bye.\"", avoiding: []) == "\"Hi,\" said Dad, \"bye.\"")
        #expect(DadJokeService.clean("'Cause I said so, kids'", avoiding: []) == "'Cause I said so, kids'")
        #expect(DadJokeService.clean("   ", avoiding: []) == nil)
        #expect(DadJokeService.clean(String(repeating: "a", count: 400), avoiding: []) == nil)
        #expect(DadJokeService.clean("Old joke.", avoiding: ["old JOKE."]) == nil)
    }

    /// The banner shows the setup as a headline and the punchline under it (#38 follow-up).
    @Test func jokesSplitIntoSetupAndPunchline() {
        let question = DadJoke(text: "Why do programmers prefer dark mode? Because light attracts bugs.", isFromModel: true)
        #expect(question.setup == "Why do programmers prefer dark mode?")
        #expect(question.punchline == "Because light attracts bugs.")

        let statement = DadJoke(text: "I only know 25 letters of the alphabet. I don't know y.", isFromModel: false)
        #expect(statement.setup == "I only know 25 letters of the alphabet.")
        #expect(statement.punchline == "I don't know y.")

        let longer = DadJoke(text: "Knock knock! Who's there? Interrupting cow.", isFromModel: true)
        #expect(longer.setup == "Knock knock!")
        #expect(longer.punchline == "Who's there? Interrupting cow.")

        let oneLiner = DadJoke(text: "I used to hate facial hair, but then it grew on me.", isFromModel: false)
        #expect(oneLiner.setup == oneLiner.text)
        #expect(oneLiner.punchline == nil)

        // Dots inside a word, like a version number, aren't sentence ends.
        let version = DadJoke(text: "Version 2.0 shipped on time", isFromModel: true)
        #expect(version.setup == "Version 2.0 shipped on time")
        #expect(version.punchline == nil)
    }

    @Test func splittingNeverLosesWords() {
        for text in DadJokeService.fallbackJokes {
            let joke = DadJoke(text: text, isFromModel: false)
            #expect([joke.setup, joke.punchline].compactMap { $0 }.joined(separator: " ") == text)
        }
    }

    @Test func dayKeysFollowTheLocalCalendar() {
        #expect(DadJokeService.dayKey(date(30, hour: 23), calendar: calendar) == "2026-10-30")
        #expect(DadJokeService.dayKey(date(31, hour: 0), calendar: calendar) == "2026-10-31")
    }
}
