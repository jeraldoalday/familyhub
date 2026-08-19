import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Household insights")
struct HouseholdInsightsTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday — the first day of the household's week.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    private struct Fixture {
        let household: Household
        let parent: Member
        let sam: Member
        let alex: Member
    }

    private func makeFixture() throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            firstWeekday: 2,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: clock.day(offsetFromToday: -60)
        )
        return Fixture(
            household: household,
            parent: try Member(
                householdID: household.id, name: "Jerald", role: .owner, joinedAt: clock.now
            ),
            sam: try Member(
                householdID: household.id, name: "Sam", role: .child, joinedAt: clock.now
            ),
            alex: try Member(
                householdID: household.id, name: "Alex", role: .child, joinedAt: clock.now
            )
        )
    }

    private func day(_ offset: Int) -> Date {
        clock.day(offsetFromToday: offset)
    }

    private func makeChore(
        _ f: Fixture,
        title: String,
        assignment: Chore.Assignment = .anyone,
        points: Int = 10,
        recurrence: RecurrenceRule = .daily,
        startOffset: Int = -30
    ) throws -> Chore {
        try Chore(
            householdID: f.household.id,
            title: title,
            assignment: assignment,
            points: points,
            startDate: day(startOffset),
            recurrence: recurrence,
            createdBy: f.parent.id,
            createdAt: day(startOffset)
        )
    }

    private func completion(
        _ f: Fixture,
        of chore: Chore,
        on offset: Int,
        by memberID: Identifier<Member>,
        lateByDays: Int = 0
    ) -> ChoreCompletion {
        ChoreCompletion(
            householdID: f.household.id,
            choreID: chore.id,
            occurrenceDay: day(offset),
            completedBy: memberID,
            completedAt: day(offset + lateByDays).addingTimeInterval(60 * 60 * 18),
            pointsAwarded: chore.points,
            calendar: calendar
        )
    }

    private func snapshot(
        _ f: Fixture,
        chores: [Chore],
        completions: [ChoreCompletion] = [],
        ledgerEntries: [LedgerEntry] = []
    ) -> HouseholdSnapshot {
        HouseholdSnapshot(
            household: f.household,
            members: [f.parent, f.sam, f.alex],
            chores: chores,
            completions: completions,
            ledgerEntries: ledgerEntries
        )
    }

    // MARK: Recap totals

    @Test("The recap counts what was due and what got done")
    func recapCountsScheduledAndCompleted() throws {
        let f = try makeFixture()
        let chore = try makeChore(f, title: "Feed the cat")
        // Monday to Thursday is four days; three of them were done.
        let completions = [0, 1, 2].map { completion(f, of: chore, on: $0, by: f.sam.id) }
        let insights = snapshot(f, chores: [chore], completions: completions).insights

        let recap = insights.recap(from: day(0), to: day(3))
        #expect(recap.scheduled == 4)
        #expect(recap.completed == 3)
        #expect(recap.completionRate == 0.75)
        #expect(!recap.isQuiet)
    }

    @Test("A week that asked nothing scores full marks, not zero")
    func quietWeekIsNotAFailure() throws {
        // Showing a family 0% for a week they were away is both wrong and
        // demoralising, and it is the number a naive ratio produces.
        let f = try makeFixture()
        let recap = snapshot(f, chores: []).insights.recap(from: day(0), to: day(6))

        #expect(recap.scheduled == 0)
        #expect(recap.completionRate == 1)
        #expect(recap.isQuiet)
    }

    @Test("Punctuality is measured against the day the work was due")
    func punctualityCountsOnTimeCompletions() throws {
        let f = try makeFixture()
        let chore = try makeChore(f, title: "Bins")
        let completions = [
            completion(f, of: chore, on: 0, by: f.sam.id),
            completion(f, of: chore, on: 1, by: f.sam.id, lateByDays: 2),
            completion(f, of: chore, on: 2, by: f.sam.id),
        ]
        let recap = snapshot(f, chores: [chore], completions: completions).insights
            .recap(from: day(0), to: day(2))

        #expect(recap.completed == 3)
        #expect(recap.onTime == 2)
        #expect(abs(recap.punctualityRate - 2.0 / 3.0) < 0.0001)
    }

    @Test("The week runs from the household's own first weekday")
    func weeklyRecapUsesTheHouseholdWeek() throws {
        // The fixture starts its week on Monday, and 2 March 2026 is a Monday,
        // so a recap taken on the Wednesday covers three days rather than seven.
        let f = try makeFixture()
        let chore = try makeChore(f, title: "Feed the cat")
        let recap = snapshot(f, chores: [chore]).insights
            .weeklyRecap(forWeekContaining: day(2))

        #expect(recap.range.lowerBound == day(0))
        #expect(recap.range.upperBound == day(2))
        #expect(recap.scheduled == 3)
    }

    @Test("A mid-week recap does not count the rest of the week as missed")
    func weeklyRecapStopsAtToday() throws {
        // Counting Friday's chores as missed on Tuesday would make every
        // mid-week recap read like a disaster.
        let f = try makeFixture()
        let chore = try makeChore(f, title: "Feed the cat")
        let completions = [0, 1].map { completion(f, of: chore, on: $0, by: f.sam.id) }
        let recap = snapshot(f, chores: [chore], completions: completions).insights
            .weeklyRecap(forWeekContaining: day(1))

        #expect(recap.completionRate == 1)
    }

    @Test("Points earned in the period are totalled")
    func recapTotalsPoints() throws {
        let f = try makeFixture()
        let entries = [
            LedgerEntry(
                householdID: f.household.id, memberID: f.sam.id, amount: 30,
                source: .adjustment(by: f.parent.id), occurredAt: day(1)
            ),
            LedgerEntry(
                householdID: f.household.id, memberID: f.alex.id, amount: 20,
                source: .adjustment(by: f.parent.id), occurredAt: day(2)
            ),
            // Spending is not earning, and a week's recap that nets them out
            // would tell a child who saved up that they did less work.
            LedgerEntry(
                householdID: f.household.id, memberID: f.sam.id, amount: -25,
                source: .adjustment(by: f.parent.id), occurredAt: day(2)
            ),
            // Outside the range entirely.
            LedgerEntry(
                householdID: f.household.id, memberID: f.sam.id, amount: 100,
                source: .adjustment(by: f.parent.id), occurredAt: day(9)
            ),
        ]
        let recap = snapshot(f, chores: [], ledgerEntries: entries).insights
            .recap(from: day(0), to: day(3))

        #expect(recap.pointsEarned == 50)
    }

    // MARK: Superlatives

    @Test("The busiest day is the one with the most work due")
    func busiestDayIsReported() throws {
        let f = try makeFixture()
        let daily = try makeChore(f, title: "Feed the cat")
        let wednesdays = try makeChore(
            f,
            title: "Bins",
            recurrence: try RecurrenceRule.weekly(on: [.wednesday])
        )
        let recap = snapshot(f, chores: [daily, wednesdays]).insights
            .recap(from: day(0), to: day(6))

        #expect(recap.busiestDay == day(2))
    }

    @Test("The most-missed chore is named")
    func mostMissedChoreIsReported() throws {
        // Nearly always a chore that wants rescheduling rather than a family
        // that wants nagging, which is why it is worth surfacing at all.
        let f = try makeFixture()
        let kept = try makeChore(f, title: "Feed the cat")
        let neglected = try makeChore(f, title: "Water the plants")
        let completions = (0...3).map { completion(f, of: kept, on: $0, by: f.sam.id) }

        let recap = snapshot(f, chores: [kept, neglected], completions: completions).insights
            .recap(from: day(0), to: day(3))
        #expect(recap.mostMissedChore?.id == neglected.id)
    }

    @Test("Nothing missed means nothing to name")
    func nothingMissedNamesNoChore() throws {
        let f = try makeFixture()
        let chore = try makeChore(f, title: "Feed the cat")
        let completions = (0...2).map { completion(f, of: chore, on: $0, by: f.sam.id) }
        let recap = snapshot(f, chores: [chore], completions: completions).insights
            .recap(from: day(0), to: day(2))

        #expect(recap.mostMissedChore == nil)
    }

    // MARK: Member summaries

    @Test("Each member's own work is summarised separately")
    func memberSummariesSplitTheWork() throws {
        let f = try makeFixture()
        let samsChore = try makeChore(f, title: "Bins", assignment: .member(f.sam.id))
        let alexsChore = try makeChore(f, title: "Dishes", assignment: .member(f.alex.id))
        let completions =
            (0...2).map { completion(f, of: samsChore, on: $0, by: f.sam.id) }
            + [completion(f, of: alexsChore, on: 0, by: f.alex.id)]

        let recap = snapshot(f, chores: [samsChore, alexsChore], completions: completions).insights
            .recap(from: day(0), to: day(2))

        let sam = try #require(recap.members.first { $0.member.id == f.sam.id })
        #expect(sam.assigned == 3)
        #expect(sam.completed == 3)
        #expect(sam.completionRate == 1)

        let alex = try #require(recap.members.first { $0.member.id == f.alex.id })
        #expect(alex.assigned == 3)
        #expect(alex.completed == 1)
    }

    @Test("Somebody covering for somebody else still counts as done")
    func coveringCountsAsCompleted() throws {
        // The recap is about the household keeping up, not about blame. It
        // records who ticked it off separately for anyone who wants that.
        let f = try makeFixture()
        let chore = try makeChore(f, title: "Bins", assignment: .member(f.sam.id))
        let completions = [completion(f, of: chore, on: 0, by: f.parent.id)]

        let recap = snapshot(f, chores: [chore], completions: completions).insights
            .recap(from: day(0), to: day(0))
        let sam = try #require(recap.members.first { $0.member.id == f.sam.id })
        let parent = try #require(recap.members.first { $0.member.id == f.parent.id })

        #expect(sam.completed == 1)
        #expect(sam.completedByThem == 0)
        #expect(parent.completedByThem == 1)
    }

    @Test("A member with nothing assigned is not marked down for it")
    func noWorkMeansNoPenalty() throws {
        let f = try makeFixture()
        let chore = try makeChore(f, title: "Bins", assignment: .member(f.sam.id))
        let recap = snapshot(f, chores: [chore]).insights.recap(from: day(0), to: day(0))

        let alex = try #require(recap.members.first { $0.member.id == f.alex.id })
        #expect(alex.assigned == 0)
        #expect(alex.completionRate == 1)
    }

    // MARK: Workload balance

    @Test("An even split is reported as balanced")
    func evenSplitIsBalanced() throws {
        let f = try makeFixture()
        let chores = [
            try makeChore(f, title: "Bins", assignment: .member(f.parent.id), points: 10),
            try makeChore(f, title: "Dishes", assignment: .member(f.sam.id), points: 10),
            try makeChore(f, title: "Hoovering", assignment: .member(f.alex.id), points: 10),
        ]
        let balance = snapshot(f, chores: chores).insights
            .workloadBalance(from: day(0), to: day(6))

        #expect(balance.isBalanced)
        #expect(balance.carryingMost == nil)
        #expect(balance.shares.count == 3)
        #expect(balance.shares.allSatisfy { abs($0.share - 1.0 / 3.0) < 0.0001 })
    }

    @Test("One person carrying everything is named")
    func lopsidedSplitNamesTheMemberCarryingIt() throws {
        let f = try makeFixture()
        let chores = [
            try makeChore(f, title: "Bins", assignment: .member(f.sam.id), points: 10),
            try makeChore(f, title: "Dishes", assignment: .member(f.sam.id), points: 10),
            try makeChore(f, title: "Hoovering", assignment: .member(f.sam.id), points: 10),
        ]
        let balance = snapshot(f, chores: chores).insights
            .workloadBalance(from: day(0), to: day(6))

        #expect(!balance.isBalanced)
        #expect(balance.carryingMost?.id == f.sam.id)
        #expect(balance.shares.first?.share == 1)
        #expect(abs((balance.shares.first?.deviation ?? 0) - 2.0 / 3.0) < 0.0001)
    }

    @Test("Share is weighted by points, not by chore count")
    func shareIsWeightedByPoints() throws {
        // Emptying a bin and cleaning a bathroom are both 'one chore', and
        // nobody involved thinks they are the same job. The household has
        // already priced them.
        let f = try makeFixture()
        let chores = [
            try makeChore(f, title: "Bins", assignment: .member(f.sam.id), points: 5),
            try makeChore(
                f, title: "Clean the bathroom", assignment: .member(f.alex.id),
                points: 45),
        ]
        let balance = snapshot(f, chores: chores).insights
            .workloadBalance(from: day(0), to: day(0))

        let sam = try #require(balance.shares.first { $0.member.id == f.sam.id })
        let alex = try #require(balance.shares.first { $0.member.id == f.alex.id })
        #expect(sam.share == 0.1)
        #expect(alex.share == 0.9)
        #expect(balance.shares.map(\.member.id).first == f.alex.id)
    }

    @Test("Somebody carrying nothing still appears on the board")
    func memberWithNoWorkIsStillListed() throws {
        // The most important row on a fairness screen, and the easiest one to
        // drop by filtering on what people were assigned.
        let f = try makeFixture()
        let chore = try makeChore(f, title: "Bins", assignment: .member(f.sam.id))
        let balance = snapshot(f, chores: [chore]).insights
            .workloadBalance(from: day(0), to: day(0))

        let alex = try #require(balance.shares.first { $0.member.id == f.alex.id })
        #expect(alex.points == 0)
        #expect(alex.share == 0)
        #expect(alex.deviation < 0)
    }

    @Test("Open chores are reported separately rather than guessed at")
    func openChoresAreNotDividedUp() throws {
        // Guessing who 'would have' done an unclaimed chore is the sort of
        // invented number that makes a fairness screen untrustworthy.
        let f = try makeFixture()
        let open = try makeChore(f, title: "Empty the dishwasher", assignment: .anyone)
        let mine = try makeChore(f, title: "Bins", assignment: .member(f.sam.id))
        let balance = snapshot(f, chores: [open, mine]).insights
            .workloadBalance(from: day(0), to: day(2))

        #expect(balance.unassignedOccurrences == 3)
        #expect(balance.shares.reduce(0) { $0 + $1.occurrences } == 3)
    }

    @Test("A rotating chore divides across the rota")
    func rotationSplitsEvenly() throws {
        let f = try makeFixture()
        let chore = try makeChore(
            f, title: "Bins", assignment: .rotating([f.sam.id, f.alex.id]), points: 10
        )
        let balance = snapshot(f, chores: [chore]).insights
            .workloadBalance(from: day(0), to: day(3))

        let sam = try #require(balance.shares.first { $0.member.id == f.sam.id })
        let alex = try #require(balance.shares.first { $0.member.id == f.alex.id })
        #expect(sam.occurrences == 2)
        #expect(alex.occurrences == 2)
        #expect(sam.share == alex.share)
    }

    @Test("A household with no assigned work is not flagged as unfair")
    func noAssignedWorkIsBalanced() throws {
        let f = try makeFixture()
        let open = try makeChore(f, title: "Empty the dishwasher", assignment: .anyone)
        let balance = snapshot(f, chores: [open]).insights
            .workloadBalance(from: day(0), to: day(2))

        #expect(balance.isBalanced)
        #expect(balance.widestGap == 0)
    }
}
