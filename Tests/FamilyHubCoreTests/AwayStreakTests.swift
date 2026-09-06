import Foundation
import Testing

@testable import FamilyHubCore

/// Covers what a trip does to a run: the days it excuses, the days it does not,
/// and the record it must not cut in half.
@Suite("Away and streaks")
struct AwayStreakTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        FixedDateProvider(year: year, month: month, day: day, calendar: calendar).now
    }

    /// 16 March 2026, a Monday, and the day every assertion measures from.
    private var today: Date { date(2026, 3, 16) }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    private let householdID = Identifier<Household>()
    private let parent = Identifier<Member>()
    private let sam = Identifier<Member>()
    private let alex = Identifier<Member>()

    private func makeChore(
        assignment: Chore.Assignment,
        title: String = "Feed the cat"
    ) throws -> Chore {
        try Chore(
            householdID: householdID,
            title: title,
            assignment: assignment,
            startDate: day(-30),
            recurrence: .daily,
            createdBy: parent,
            createdAt: day(-30)
        )
    }

    private func completion(
        of chore: Chore,
        on when: Date,
        by memberID: Identifier<Member>
    ) -> ChoreCompletion {
        ChoreCompletion(
            householdID: householdID,
            choreID: chore.id,
            occurrenceDay: when,
            completedBy: memberID,
            completedAt: when,
            approval: .notRequired,
            pointsAwarded: 10,
            calendar: calendar
        )
    }

    private func trip(
        from first: Int,
        to last: Int,
        members: Set<Identifier<Member>> = []
    ) throws -> AwayPeriod {
        try AwayPeriod(
            householdID: householdID,
            firstDay: day(first),
            lastDay: day(last),
            memberIDs: members,
            createdBy: parent,
            createdAt: day(-30),
            calendar: calendar
        )
    }

    // MARK: A chore's run

    @Test("A fortnight away joins the weeks either side of it")
    func awayDaysDoNotBreakARun() throws {
        let chore = try makeChore(assignment: .member(sam))
        // Done every day except the four the household was in Spain.
        let done = try (-10...(-1)).filter { !(-7...(-4)).contains($0) }
            .map { completion(of: chore, on: day($0), by: sam) }

        let holiday = StreakCalculator(
            chores: [chore], completions: done, engine: RecurrenceEngine(calendar: calendar),
            awayPeriods: [try trip(from: -7, to: -4)]
        )
        // Six days actually done, in one run: the four away days are stepped
        // over rather than counted, so they neither pad the number nor end it.
        #expect(holiday.streak(for: chore, asOf: day(-1)).length == 6)

        // Without the record, the same history is a household that gave up on
        // the Tuesday and started again on the Saturday.
        let unaware = StreakCalculator(
            chores: [chore], completions: done, engine: RecurrenceEngine(calendar: calendar)
        )
        #expect(unaware.streak(for: chore, asOf: day(-1)).length == 3)
    }

    @Test("A chore done anyway while away still counts")
    func doneWhileAwayStillCounts() throws {
        let chore = try makeChore(assignment: .member(sam))
        let done = try (-3...(-1)).map { completion(of: chore, on: day($0), by: sam) }

        let calculator = StreakCalculator(
            chores: [chore], completions: done, engine: RecurrenceEngine(calendar: calendar),
            awayPeriods: [try trip(from: -3, to: -1, members: [sam])]
        )
        // Being away excuses the work. It does not refuse the credit for a
        // child who did it from their grandmother's anyway.
        let streak = calculator.streak(for: chore, asOf: day(-1))
        #expect(streak.length == 3)
        #expect(streak.lastDay == day(-1))
    }

    @Test("A trip that names somebody else excuses nothing")
    func someoneElsesTripIsNotYours() throws {
        let chore = try makeChore(assignment: .member(sam))
        let done = try [-3, -1].map { completion(of: chore, on: day($0), by: sam) }

        let calculator = StreakCalculator(
            chores: [chore], completions: done, engine: RecurrenceEngine(calendar: calendar),
            awayPeriods: [try trip(from: -2, to: -2, members: [alex])]
        )
        // Sam was here on the day he missed, and Alex being at a sleepover does
        // not fix it.
        #expect(calculator.streak(for: chore, asOf: day(-1)).length == 1)
    }

    @Test("An open chore is only excused by an empty house")
    func openChoreNeedsTheWholeHouseholdAway() throws {
        let chore = try makeChore(assignment: .anyone)
        let done = try [-3, -1].map { completion(of: chore, on: day($0), by: sam) }
        let engine = RecurrenceEngine(calendar: calendar)

        let oneChildAway = StreakCalculator(
            chores: [chore], completions: done, engine: engine,
            awayPeriods: [try trip(from: -2, to: -2, members: [sam])]
        )
        #expect(oneChildAway.streak(for: chore, asOf: day(-1)).length == 1)

        let emptyHouse = StreakCalculator(
            chores: [chore], completions: done, engine: engine,
            awayPeriods: [try trip(from: -2, to: -2)]
        )
        #expect(emptyHouse.streak(for: chore, asOf: day(-1)).length == 2)
    }

    @Test("A rota excuses whoever's turn it actually was")
    func rotaResolvesWhoWasAway() throws {
        // Alternating: even positions are Sam's, odd are Alex's.
        let chore = try makeChore(assignment: .rotating([sam, alex]))
        let engine = RecurrenceEngine(calendar: calendar)
        let missed = try #require(
            chore.indexedOccurrences(in: day(-2)...day(-2), using: engine, maximum: 1).first
        )
        let whoseTurn = try #require(chore.assignee(forOccurrenceIndex: missed.index))
        let other = whoseTurn == sam ? alex : sam
        let done = try [-3, -1].map { completion(of: chore, on: day($0), by: parent) }

        let rightPerson = StreakCalculator(
            chores: [chore], completions: done, engine: engine,
            awayPeriods: [try trip(from: -2, to: -2, members: [whoseTurn])]
        )
        #expect(rightPerson.streak(for: chore, asOf: day(-1)).length == 2)

        let wrongPerson = StreakCalculator(
            chores: [chore], completions: done, engine: engine,
            awayPeriods: [try trip(from: -2, to: -2, members: [other])]
        )
        #expect(wrongPerson.streak(for: chore, asOf: day(-1)).length == 1)
    }

    @Test("A cancelled trip excuses nothing at all")
    func cancelledTripsAreNotHonoured() throws {
        let chore = try makeChore(assignment: .member(sam))
        let done = try [-3, -1].map { completion(of: chore, on: day($0), by: sam) }

        let calculator = StreakCalculator(
            chores: [chore], completions: done, engine: RecurrenceEngine(calendar: calendar),
            awayPeriods: [try trip(from: -2, to: -2, members: [sam]).cancelled(at: day(-5))]
        )
        #expect(calculator.streak(for: chore, asOf: day(-1)).length == 1)
    }

    // MARK: The record

    @Test("The longest run is not cut in two by a holiday in the middle")
    func longestRunSpansTheTrip() throws {
        let chore = try makeChore(assignment: .member(sam))
        let done = try (-20...(-1)).filter { !(-12...(-8)).contains($0) }
            .map { completion(of: chore, on: day($0), by: sam) }

        let calculator = StreakCalculator(
            chores: [chore], completions: done, engine: RecurrenceEngine(calendar: calendar),
            awayPeriods: [try trip(from: -12, to: -8)]
        )
        let best = calculator.longestStreak(for: chore, upTo: day(-1))
        #expect(best.length == 15)
        #expect(best.isLive)
    }

    // MARK: A person's run

    @Test("A person away keeps the run they had when they left")
    func memberRunSurvivesTheTrip() throws {
        let chore = try makeChore(assignment: .member(sam))
        let done = try (-10...(-6)).map { completion(of: chore, on: day($0), by: sam) }

        let calculator = StreakCalculator(
            chores: [chore], completions: done, engine: RecurrenceEngine(calendar: calendar),
            awayPeriods: [try trip(from: -5, to: -1, members: [sam])]
        )
        // Five days at his grandmother's, and the five days before them intact.
        #expect(calculator.streak(forMember: sam, asOf: day(-1)).length == 5)

        let unaware = StreakCalculator(
            chores: [chore], completions: done, engine: RecurrenceEngine(calendar: calendar)
        )
        #expect(unaware.streak(forMember: sam, asOf: day(-1)).length == 0)
    }

    // MARK: What is about to break

    @Test("Nothing is at risk on a day nobody is here")
    func nothingIsAtRiskWhileAway() throws {
        let chore = try makeChore(assignment: .member(sam))
        let done = try (-5...(-1)).map { completion(of: chore, on: day($0), by: sam) }
        let engine = RecurrenceEngine(calendar: calendar)

        let here = StreakCalculator(chores: [chore], completions: done, engine: engine)
        #expect(here.streaksAtRisk(on: today).count == 1)

        let away = StreakCalculator(
            chores: [chore], completions: done, engine: engine,
            awayPeriods: [try trip(from: 0, to: 3, members: [sam])]
        )
        #expect(away.streaksAtRisk(on: today).isEmpty)
    }
}
