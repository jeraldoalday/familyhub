import Foundation
import Testing

@testable import FamilyHubCore

/// Covers what a trip does to the two numbers a household argues about: the
/// week's completion rate, and whether the work was shared out evenly.
@Suite("Away in the recap")
struct AwayRecapTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        FixedDateProvider(year: year, month: month, day: day, calendar: calendar).now
    }

    /// Monday 2 March 2026, the start of the week every assertion measures.
    private var monday: Date { date(2026, 3, 2) }
    private var sunday: Date { date(2026, 3, 8) }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: monday) ?? monday
    }

    private struct Fixture {
        var snapshot: HouseholdSnapshot
        let mary: Member
        let sam: Member
        let alex: Member
        let samsChore: Chore
        let alexsChore: Chore
    }

    private func makeFixture() throws -> Fixture {
        let created = date(2026, 1, 1)
        let household = try Household(
            name: "The Aldays", timeZone: .gmt, requiresApproval: false, createdAt: created
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .adult, joinedAt: created
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: created
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen, joinedAt: created
        )
        func chore(_ title: String, for memberID: Identifier<Member>) throws -> Chore {
            try Chore(
                householdID: household.id,
                title: title,
                assignment: .member(memberID),
                points: 10,
                startDate: created,
                recurrence: .daily,
                createdBy: mary.id,
                createdAt: created
            )
        }
        let samsChore = try chore("Feed the cat", for: sam.id)
        let alexsChore = try chore("Take out the bins", for: alex.id)

        return Fixture(
            snapshot: HouseholdSnapshot(
                household: household,
                members: [mary, sam, alex],
                chores: [samsChore, alexsChore]
            ),
            mary: mary,
            sam: sam,
            alex: alex,
            samsChore: samsChore,
            alexsChore: alexsChore
        )
    }

    private func done(
        _ f: Fixture,
        _ chore: Chore,
        on when: Date,
        by memberID: Identifier<Member>
    ) -> ChoreCompletion {
        ChoreCompletion(
            householdID: f.snapshot.household.id,
            choreID: chore.id,
            occurrenceDay: when,
            completedBy: memberID,
            completedAt: when,
            approval: .notRequired,
            pointsAwarded: chore.points,
            calendar: calendar
        )
    }

    private func trip(
        _ f: Fixture,
        members: Set<Identifier<Member>> = [],
        from first: Int,
        to last: Int
    ) throws -> AwayPeriod {
        try AwayPeriod(
            householdID: f.snapshot.household.id,
            firstDay: day(first),
            lastDay: day(last),
            memberIDs: members,
            createdBy: f.mary.id,
            createdAt: date(2026, 2, 1),
            calendar: calendar
        )
    }

    // MARK: The week

    @Test("A week half spent away is not a week the household gave up on")
    func completionRateIgnoresAwayDays() throws {
        var fixture = try makeFixture()
        // Both chores done on Monday to Wednesday; the household is away from
        // Thursday to Sunday.
        fixture.snapshot.completions = (0...2).flatMap { offset in
            [
                done(fixture, fixture.samsChore, on: day(offset), by: fixture.sam.id),
                done(fixture, fixture.alexsChore, on: day(offset), by: fixture.alex.id),
            ]
        }

        let unaware = fixture.snapshot.insights.recap(from: monday, to: sunday)
        #expect(unaware.scheduled == 14)
        #expect(unaware.completed == 6)

        fixture.snapshot.awayPeriods = [try trip(fixture, from: 3, to: 6)]
        let aware = fixture.snapshot.insights.recap(from: monday, to: sunday)
        #expect(aware.scheduled == 6)
        #expect(aware.completed == 6)
        #expect(aware.completionRate == 1)
        #expect(aware.mostMissedChore == nil)
    }

    @Test("A chore done while away is still a chore the household did")
    func workDoneAwayStillCounts() throws {
        var fixture = try makeFixture()
        fixture.snapshot.completions = [
            done(fixture, fixture.samsChore, on: day(4), by: fixture.sam.id)
        ]
        fixture.snapshot.awayPeriods = [try trip(fixture, from: 3, to: 6)]

        let recap = fixture.snapshot.insights.recap(from: monday, to: sunday)
        // Three ordinary days of two chores, plus the one Sam did anyway.
        #expect(recap.scheduled == 7)
        #expect(recap.completed == 1)
    }

    @Test("Only the person who went is excused")
    func oneChildAwayLeavesTheRestScheduled() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [
            try trip(fixture, members: [fixture.sam.id], from: 0, to: 6)
        ]

        let recap = fixture.snapshot.insights.recap(from: monday, to: sunday)
        // Alex's week is untouched; Sam's has gone.
        #expect(recap.scheduled == 7)
        let sam = try #require(recap.members.first { $0.member.id == fixture.sam.id })
        let alex = try #require(recap.members.first { $0.member.id == fixture.alex.id })
        #expect(sam.assigned == 0)
        #expect(alex.assigned == 7)
    }

    // MARK: Fairness

    @Test("A child who was away did not carry a lighter share — they were not offered one")
    func fairnessIgnoresAwayDays() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [
            try trip(fixture, members: [fixture.sam.id], from: 0, to: 2)
        ]

        let balance = fixture.snapshot.insights.workloadBalance(from: monday, to: sunday)
        let sam = try #require(balance.shares.first { $0.member.id == fixture.sam.id })
        let alex = try #require(balance.shares.first { $0.member.id == fixture.alex.id })

        #expect(sam.occurrences == 4)
        #expect(alex.occurrences == 7)

        // With the whole household away for the same three days, the week is
        // level again — which is what it was.
        fixture.snapshot.awayPeriods = [try trip(fixture, from: 0, to: 2)]
        let level = fixture.snapshot.insights.workloadBalance(from: monday, to: sunday)
        let levelSam = try #require(level.shares.first { $0.member.id == fixture.sam.id })
        let levelAlex = try #require(level.shares.first { $0.member.id == fixture.alex.id })
        #expect(levelSam.occurrences == 4)
        #expect(levelAlex.occurrences == 4)
        #expect(levelSam.share == levelAlex.share)
    }

    @Test("A cancelled trip changes neither number")
    func cancelledTripsAreIgnored() throws {
        var fixture = try makeFixture()
        let called = try trip(fixture, from: 3, to: 6).cancelled(at: date(2026, 2, 20))
        fixture.snapshot.awayPeriods = [called]

        #expect(fixture.snapshot.insights.recap(from: monday, to: sunday).scheduled == 14)
    }
}
