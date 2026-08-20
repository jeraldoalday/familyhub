import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Streaks")
struct StreakTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    private let householdID = Identifier<Household>()
    private let parent = Identifier<Member>()
    private let sam = Identifier<Member>()
    private let alex = Identifier<Member>()

    /// 2 March 2026 is a Monday, which every weekly assertion below relies on.
    private let start = FixedDateProvider(year: 2026, month: 3, day: 2, calendar: .testDefault).now

    private var engine: RecurrenceEngine { RecurrenceEngine(calendar: calendar) }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: start) ?? start
    }

    private func makeChore(
        title: String = "Feed the cat",
        assignment: Chore.Assignment = .anyone,
        recurrence: RecurrenceRule = .daily,
        startOffset: Int = 0,
        archivedAt: Date? = nil
    ) throws -> Chore {
        try Chore(
            householdID: householdID,
            title: title,
            assignment: assignment,
            startDate: day(startOffset),
            recurrence: recurrence,
            archivedAt: archivedAt,
            createdBy: parent,
            createdAt: start
        )
    }

    private func completion(
        of chore: Chore,
        on offset: Int,
        by memberID: Identifier<Member>? = nil,
        approval: ChoreCompletion.Approval = .notRequired
    ) -> ChoreCompletion {
        ChoreCompletion(
            householdID: householdID,
            choreID: chore.id,
            occurrenceDay: day(offset),
            completedBy: memberID ?? sam,
            completedAt: day(offset).addingTimeInterval(60 * 60 * 18),
            approval: approval,
            pointsAwarded: 10,
            calendar: calendar
        )
    }

    private func calculator(
        chores: [Chore],
        completions: [ChoreCompletion]
    ) -> StreakCalculator {
        StreakCalculator(chores: chores, completions: completions, engine: engine)
    }

    // MARK: Chore streaks

    @Test("Consecutive completions build a streak")
    func consecutiveCompletionsCount() throws {
        let chore = try makeChore()
        let done = (0...3).map { completion(of: chore, on: $0) }
        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(3))

        #expect(streak.length == 4)
        #expect(streak.lastDay == day(3))
        #expect(streak.isLive)
        #expect(streak.isNoteworthy)
    }

    @Test("A missed day ends the streak at the miss")
    func missedDayBreaksStreak() throws {
        let chore = try makeChore()
        // Days 0, 1, 3, 4 done — day 2 missed.
        let done = [0, 1, 3, 4].map { completion(of: chore, on: $0) }
        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(4))

        #expect(streak.length == 2)
        #expect(streak.lastDay == day(4))
    }

    @Test("A chore due today but not yet done keeps yesterday's streak alive")
    func todayInProgressDoesNotBreakStreak() throws {
        // The single most important case here. A chore due this evening has not
        // been failed at breakfast, and a home screen that resets the number at
        // midnight is wrong for most of the day every day.
        let chore = try makeChore()
        let done = (0...2).map { completion(of: chore, on: $0) }
        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(3))

        #expect(streak.length == 3)
        #expect(streak.isLive)
        #expect(streak.lastDay == day(2))
    }

    @Test("Yesterday missed means no streak, even with today still open")
    func yesterdayMissedIsBroken() throws {
        let chore = try makeChore()
        let done = (0...1).map { completion(of: chore, on: $0) }
        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(3))

        #expect(streak.length == 0)
        #expect(!streak.isLive)
        #expect(streak == .none)
    }

    @Test("A weekly chore counts weeks, not days")
    func weeklyChoreCountsOccurrences() throws {
        // The gaps between Mondays are not misses. Counting occurrences rather
        // than calendar days is what makes a weekly streak mean anything.
        let chore = try makeChore(recurrence: try RecurrenceRule.weekly(on: [.monday]))
        let done = [0, 7, 14].map { completion(of: chore, on: $0) }
        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(14))

        #expect(streak.length == 3)
        #expect(streak.lastDay == day(14))
    }

    @Test("A skipped day is not a miss")
    func skippedDayDoesNotBreakStreak() throws {
        // Skipping is the family saying 'not this week'. Punishing them for
        // taking the holiday they told the app about would be perverse.
        let chore = try makeChore().skipping(day(2), calendar: calendar)
        let done = [0, 1, 3].map { completion(of: chore, on: $0) }
        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(3))

        #expect(streak.length == 3)
    }

    @Test("A chore with no occurrences has no streak")
    func noOccurrencesMeansNoStreak() throws {
        let chore = try makeChore(recurrence: .once, startOffset: 30)
        let streak = calculator(chores: [chore], completions: [])
            .streak(for: chore, asOf: start)

        #expect(streak == .none)
    }

    @Test("An archived chore is dropped from the calculator entirely")
    func archivedChoresAreExcluded() throws {
        let chore = try makeChore(archivedAt: day(5))
        let done = (0...4).map { completion(of: chore, on: $0) }
        let calculator = calculator(chores: [chore], completions: done)

        #expect(calculator.streak(for: chore, asOf: day(4)) == .none)
        #expect(calculator.streaksAtRisk(on: day(4)).isEmpty)
    }

    @Test("A one-off completion is not called a streak")
    func singleCompletionIsNotNoteworthy() throws {
        let chore = try makeChore()
        let streak = calculator(chores: [chore], completions: [completion(of: chore, on: 0)])
            .streak(for: chore, asOf: day(0))

        #expect(streak.length == 1)
        #expect(!streak.isNoteworthy)
    }

    @Test("Duplicate records of one occurrence do not count twice")
    func syncedDuplicatesCountOnce() throws {
        // Two devices offline at once record the same day. The streak must not
        // read that as two days.
        let chore = try makeChore()
        let done = [completion(of: chore, on: 0), completion(of: chore, on: 0)]
        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(0))

        #expect(streak.length == 1)
    }

    // MARK: Longest streak

    @Test("The longest streak survives a break")
    func longestStreakOutlivesTheCurrentOne() throws {
        let chore = try makeChore()
        // A run of four, a miss, then a run of two.
        let done = [0, 1, 2, 3, 5, 6].map { completion(of: chore, on: $0) }
        let calculator = calculator(chores: [chore], completions: done)

        let longest = calculator.longestStreak(for: chore, upTo: day(6))
        #expect(longest.length == 4)
        #expect(longest.lastDay == day(3))
        #expect(!longest.isLive)

        #expect(calculator.streak(for: chore, asOf: day(6)).length == 2)
    }

    @Test("A record that is also the current run is reported as live")
    func longestStreakCanBeTheCurrentOne() throws {
        let chore = try makeChore()
        let done = (0...3).map { completion(of: chore, on: $0) }
        let longest = calculator(chores: [chore], completions: done)
            .longestStreak(for: chore, upTo: day(3))

        #expect(longest.length == 4)
        #expect(longest.isLive)
    }

    @Test("A chore nobody has ever finished has no record, live or otherwise")
    func longestStreakOfNothingIsNotLive() throws {
        let chore = try makeChore()
        let longest = calculator(chores: [chore], completions: [])
            .longestStreak(for: chore, upTo: day(6))

        #expect(longest.length == 0)
        #expect(longest.lastDay == nil)
        // The arithmetic inside `longestStreak` compares the best run against
        // the current one, and zero is trivially equal to zero — so the only
        // thing stopping a record nobody has set from describing itself as
        // still going is the normalisation in `Streak.init`. This is the test
        // that stops that guard being removed as dead defensiveness.
        #expect(!longest.isLive)
        #expect(longest == .none)
        #expect(!longest.isNoteworthy)
    }

    @Test("A record broken today is not live even though it was this morning")
    func longestStreakBrokenIsNotLive() throws {
        let chore = try makeChore()
        // Three days done, then two missed.
        let done = (0...2).map { completion(of: chore, on: $0) }
        let longest = calculator(chores: [chore], completions: done)
            .longestStreak(for: chore, upTo: day(5))

        #expect(longest.length == 3)
        #expect(!longest.isLive)
    }

    // MARK: Member streaks

    @Test("A member's streak counts days they finished everything assigned")
    func memberStreakCountsCompleteDays() throws {
        let bins = try makeChore(title: "Bins", assignment: .member(sam))
        let dishes = try makeChore(title: "Dishes", assignment: .member(sam))
        let done =
            (0...2).map { completion(of: bins, on: $0) }
            + (0...2).map { completion(of: dishes, on: $0) }

        let streak = calculator(chores: [bins, dishes], completions: done)
            .streak(forMember: sam, asOf: day(2))
        #expect(streak.length == 3)
        #expect(streak.lastDay == day(2))
    }

    @Test("One chore left undone loses the whole day")
    func partialDayBreaksMemberStreak() throws {
        let bins = try makeChore(title: "Bins", assignment: .member(sam))
        let dishes = try makeChore(title: "Dishes", assignment: .member(sam))
        // Day 1's dishes were never done.
        let done =
            (0...2).map { completion(of: bins, on: $0) }
            + [0, 2].map { completion(of: dishes, on: $0) }

        let streak = calculator(chores: [bins, dishes], completions: done)
            .streak(forMember: sam, asOf: day(2))
        #expect(streak.length == 1)
    }

    @Test("A day with nothing assigned neither extends nor breaks a run")
    func emptyDaysAreNeutral() throws {
        // A chore only on Mondays and Wednesdays. Tuesday asks nothing of the
        // child, and a streak that resets over the school holidays teaches
        // them the number is arbitrary.
        let chore = try makeChore(
            assignment: .member(sam),
            recurrence: try RecurrenceRule.weekly(on: [.monday, .wednesday])
        )
        let done = [0, 2].map { completion(of: chore, on: $0) }

        let streak = calculator(chores: [chore], completions: done)
            .streak(forMember: sam, asOf: day(3))
        #expect(streak.length == 2)
    }

    @Test("An open chore is nobody's personal miss")
    func unassignedChoresDoNotCountAgainstAMember() throws {
        let open = try makeChore(title: "Empty the dishwasher", assignment: .anyone)
        let mine = try makeChore(title: "Bins", assignment: .member(sam))
        let done = (0...2).map { completion(of: mine, on: $0) }

        let streak = calculator(chores: [open, mine], completions: done)
            .streak(forMember: sam, asOf: day(2))
        #expect(streak.length == 3)
    }

    @Test("A rotating chore counts only on the turns that are actually yours")
    func rotationOnlyCountsYourTurns() throws {
        let chore = try makeChore(assignment: .rotating([sam, alex]))
        // Sam has days 0 and 2; Alex has days 1 and 3. Only Sam's are done.
        let done = [0, 2].map { completion(of: chore, on: $0) }

        let streaks = calculator(chores: [chore], completions: done)
        #expect(streaks.streak(forMember: sam, asOf: day(3)).length == 2)
        #expect(streaks.streak(forMember: alex, asOf: day(3)).length == 0)
    }

    @Test("Today's outstanding work does not break a member's run")
    func todayDoesNotBreakMemberStreak() throws {
        let chore = try makeChore(assignment: .member(sam))
        let done = (0...1).map { completion(of: chore, on: $0) }

        let streak = calculator(chores: [chore], completions: done)
            .streak(forMember: sam, asOf: day(2))
        #expect(streak.length == 2)
        #expect(streak.isLive)
    }

    // MARK: At risk

    @Test("An unfinished chore with a live streak is reported at risk")
    func atRiskReportsUnfinishedStreaks() throws {
        let chore = try makeChore()
        let done = (0...2).map { completion(of: chore, on: $0) }

        let atRisk = calculator(chores: [chore], completions: done).streaksAtRisk(on: day(3))
        #expect(atRisk.count == 1)
        #expect(atRisk.first?.chore.id == chore.id)
        #expect(atRisk.first?.streak.length == 3)
        #expect(atRisk.first?.day == day(3))
    }

    @Test("A chore already done today is not at risk")
    func completedChoresAreNotAtRisk() throws {
        let chore = try makeChore()
        let done = (0...3).map { completion(of: chore, on: $0) }

        #expect(calculator(chores: [chore], completions: done).streaksAtRisk(on: day(3)).isEmpty)
    }

    @Test("A run too short to matter is not worth a notification")
    func shortRunsAreNotReported() throws {
        let chore = try makeChore()
        let done = [completion(of: chore, on: 0)]

        #expect(calculator(chores: [chore], completions: done).streaksAtRisk(on: day(1)).isEmpty)
    }

    @Test("At-risk chores are ordered by how much is at stake")
    func atRiskIsOrderedByStreakLength() throws {
        let long = try makeChore(title: "Feed the cat")
        let short = try makeChore(title: "Water the plants")
        let done =
            (0...5).map { completion(of: long, on: $0) }
            + (4...5).map { completion(of: short, on: $0) }

        let atRisk = calculator(chores: [long, short], completions: done).streaksAtRisk(on: day(6))
        #expect(atRisk.map(\.chore.id) == [long.id, short.id])
        #expect(atRisk.map(\.streak.length) == [6, 2])
    }

    @Test("Filtering by member keeps the open chores anyone could save")
    func atRiskFilteredByMemberIncludesOpenChores() throws {
        let mine = try makeChore(title: "Bins", assignment: .member(sam))
        let theirs = try makeChore(title: "Homework", assignment: .member(alex))
        let open = try makeChore(title: "Dishwasher", assignment: .anyone)
        let done =
            (0...2).map { completion(of: mine, on: $0) }
            + (0...2).map { completion(of: theirs, on: $0) }
            + (0...2).map { completion(of: open, on: $0) }

        let atRisk = calculator(chores: [mine, theirs, open], completions: done)
            .streaksAtRisk(on: day(3), for: sam)
        #expect(Set(atRisk.map(\.chore.id)) == [mine.id, open.id])
    }

    // MARK: Snapshot integration

    @Test("A snapshot exposes streaks over its own data")
    func snapshotExposesStreaks() throws {
        let household = try Household(
            name: "The Aldays", timeZone: .gmt, createdAt: start
        )
        let chore = try Chore(
            householdID: household.id,
            title: "Feed the cat",
            startDate: start,
            recurrence: .daily,
            createdBy: parent,
            createdAt: start
        )
        let snapshot = HouseholdSnapshot(
            household: household,
            chores: [chore],
            completions: (0...2).map { completion(of: chore, on: $0) }
        )

        #expect(snapshot.streaks.streak(for: chore, asOf: day(2)).length == 3)
    }

    // MARK: Approval states

    @Test("Work waiting on a parent still holds the streak up")
    func pendingCompletionsCount() throws {
        let chore = try makeChore()
        let done = [
            completion(of: chore, on: 0),
            completion(of: chore, on: 1, approval: .pending),
            completion(of: chore, on: 2, approval: .pending),
        ]

        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(2))

        // A child who did the work should not watch their run break because
        // nobody has opened the app to approve it yet.
        #expect(streak.length == 3)
    }

    @Test("A completion sent back breaks the streak")
    func rejectedCompletionBreaksStreak() throws {
        let chore = try makeChore()
        let done = [
            completion(of: chore, on: 0),
            completion(of: chore, on: 1),
            completion(
                of: chore,
                on: 2,
                approval: .rejected(by: parent, at: day(2), reason: "Not actually done")
            ),
        ]

        // Measured the next day, so day 2 has settled. Measured on day 2 it
        // would still be in play — a chore sent back this morning can be
        // redone this evening, and the run is not lost until midnight.
        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(3))

        #expect(streak.length == 0)
        #expect(!streak.isLive)
    }

    @Test("Redoing a rejected day restores the run")
    func redoneDayCountsAgain() throws {
        let chore = try makeChore()
        let rejected = completion(
            of: chore,
            on: 2,
            approval: .rejected(by: parent, at: day(2), reason: nil)
        )
        // The redo is recorded later than the rejection, which is exactly the
        // case deduplication would collapse the wrong way if it ran first.
        let redone = ChoreCompletion(
            householdID: householdID,
            choreID: chore.id,
            occurrenceDay: day(2),
            completedBy: sam,
            completedAt: day(2).addingTimeInterval(60 * 60 * 20),
            approval: .approved(by: parent, at: day(2)),
            pointsAwarded: 10,
            calendar: calendar
        )
        let done = [
            completion(of: chore, on: 0),
            completion(of: chore, on: 1),
            rejected,
            redone,
        ]

        let streak = calculator(chores: [chore], completions: done)
            .streak(for: chore, asOf: day(2))

        #expect(streak.length == 3)
        #expect(streak.lastDay == day(2))
    }

    @Test("A rejected day does not complete a member's day")
    func rejectedCompletionBreaksMemberStreak() throws {
        let chore = try makeChore(assignment: .member(sam))
        let done = [
            completion(of: chore, on: 0),
            completion(
                of: chore,
                on: 1,
                approval: .rejected(by: parent, at: day(1), reason: nil)
            ),
        ]

        let streak = calculator(chores: [chore], completions: done)
            .streak(forMember: sam, asOf: day(2))

        #expect(streak.length == 0)
    }

    // MARK: The zero-length invariant

    @Test("A run of nothing is never live, however it is constructed")
    func zeroLengthIsNeverLive() {
        #expect(!Streak(length: 0, lastDay: nil, isLive: true).isLive)
        #expect(Streak(length: 0, lastDay: nil, isLive: true) == .none)
        // Negative lengths cannot arise from the calculator, but a decoded
        // record or a future caller could hand one over, and a run of minus
        // three days on a child's home screen is not a number to ship.
        #expect(Streak(length: -3, lastDay: nil, isLive: true).length == 0)
        #expect(!Streak(length: -3, lastDay: nil, isLive: true).isLive)
    }
}
