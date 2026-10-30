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

    @Test func aRefreshWritesTodaysJokeOnce() async throws {
        let model = FakeReviewModel()
        let app = AppModel.testing(model: model)
        #expect(app.dadJoke.joke() == nil)

        await app.refresh(.automatic)
        await app.dadJoke.waitForJoke()
        #expect(app.dadJoke.joke() == "Why did the fake model cross the road? To get to the other test.")
        #expect(model.jokeCalls.count == 1)

        await app.refresh(.automatic)
        await app.dadJoke.waitForJoke()
        #expect(model.jokeCalls.count == 1, "Same day, same joke")
    }

    @Test func aNewDayBringsANewJokeThatAvoidsRecentOnes() async throws {
        let model = FakeReviewModel()
        let app = AppModel.testing(model: model)
        let service = app.dadJoke

        service.startIfNeeded(now: date(30), calendar: calendar)
        await service.waitForJoke()
        let first = try #require(service.joke(now: date(30, hour: 23), calendar: calendar))
        #expect(service.joke(now: date(31), calendar: calendar) == nil, "Yesterday's joke isn't today's")

        model.edit { $0.joke = "  \"I'm afraid for the calendar. Its days are numbered.\"\n" }
        service.startIfNeeded(now: date(31), calendar: calendar)
        await service.waitForJoke()
        #expect(service.joke(now: date(31), calendar: calendar) == "I'm afraid for the calendar. Its days are numbered.")
        #expect(model.jokeCalls.last?.prompt.contains(first) == true)
        #expect(AccountSettings.current(in: app.modelContainer.mainContext).recentDadJokes.count == 2)
    }

    @Test func withoutTheModelABuiltInJokeStandsIn() async throws {
        let app = AppModel.testing(modelStatus: .appleIntelligenceNotEnabled)
        app.dadJoke.startIfNeeded(now: date(30), calendar: calendar)
        await app.dadJoke.waitForJoke()
        let joke = try #require(app.dadJoke.joke(now: date(30), calendar: calendar))
        #expect(DadJokeService.fallbackJokes.contains(joke))
        #expect(joke == DadJokeService.fallback(for: date(30), calendar: calendar))

        let model = FakeReviewModel()
        model.edit { $0.joke = nil }
        let failing = AppModel.testing(model: model)
        failing.dadJoke.startIfNeeded(now: date(30), calendar: calendar)
        await failing.dadJoke.waitForJoke()
        #expect(failing.dadJoke.joke(now: date(30), calendar: calendar).map(DadJokeService.fallbackJokes.contains) == true)
    }

    @Test func fallbackJokesChangeDaily() {
        #expect(DadJokeService.fallback(for: date(30), calendar: calendar) != DadJokeService.fallback(for: date(31), calendar: calendar))
        #expect(DadJokeService.fallback(for: date(30, hour: 1), calendar: calendar) == DadJokeService.fallback(for: date(30, hour: 23), calendar: calendar))
    }

    @Test func answersAreTidiedOrRejected() {
        #expect(DadJokeService.clean("Here's a dad joke: Why? Because.", avoiding: []) == "Why? Because.")
        #expect(DadJokeService.clean("Why did it?\n\nBecause it could.", avoiding: []) == "Why did it? Because it could.")
        #expect(DadJokeService.clean("“Quoted joke.”", avoiding: []) == "Quoted joke.")
        #expect(DadJokeService.clean("   ", avoiding: []) == nil)
        #expect(DadJokeService.clean(String(repeating: "a", count: 400), avoiding: []) == nil)
        #expect(DadJokeService.clean("Old joke.", avoiding: ["old JOKE."]) == nil)
    }

    @Test func dayKeysFollowTheLocalCalendar() {
        #expect(DadJokeService.dayKey(date(30, hour: 23), calendar: calendar) == "2026-10-30")
        #expect(DadJokeService.dayKey(date(31, hour: 0), calendar: calendar) == "2026-10-31")
    }
}
