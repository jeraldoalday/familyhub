import Foundation
import Testing

@testable import FamilyHubCore

/// Covers what a household being away does to the agenda: whose list a chore
/// stays on, whose it leaves, and what the row says about the day.
@Suite("Away on the agenda")
struct AwayAgendaTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        FixedDateProvider(year: year, month: month, day: day, hour: hour, calendar: calendar).now
    }

    /// 2 March 2026, a Monday.
    private var monday: Date { date(2026, 3, 2) }

    private struct Fixture {
        var snapshot: HouseholdSnapshot
        let parent: Member
        let sam: Member
        let alex: Member
        /// Sam's, every day.
        let bins: Chore
        /// Nobody's in particular, every day.
        let dishwasher: Chore
    }

    private func makeFixture() throws -> Fixture {
        let start = date(2026, 1, 1)
        let household = try Household(
            name: "The Aldays",
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: start
        )
        let parent = try Member(
            householdID: household.id, name: "Mary", role: .adult, joinedAt: start
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: start
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen, joinedAt: start
        )
        let bins = try Chore(
            householdID: household.id,
            title: "Take out the bins",
            assignment: .member(sam.id),
            startDate: date(2026, 3, 1),
            recurrence: .daily,
            createdBy: parent.id,
            createdAt: start
        )
        let dishwasher = try Chore(
            householdID: household.id,
            title: "Empty the dishwasher",
            assignment: .anyone,
            startDate: date(2026, 3, 1),
            recurrence: .daily,
            createdBy: parent.id,
            createdAt: start
        )
        return Fixture(
            snapshot: HouseholdSnapshot(
                household: household,
                members: [parent, sam, alex],
                chores: [bins, dishwasher]
            ),
            parent: parent,
            sam: sam,
            alex: alex,
            bins: bins,
            dishwasher: dishwasher
        )
    }

    private func away(
        in fixture: Fixture,
        members: Set<Identifier<Member>> = [],
        from first: Date? = nil,
        to last: Date? = nil,
        reason: String? = nil
    ) throws -> AwayPeriod {
        try AwayPeriod(
            householdID: fixture.snapshot.household.id,
            firstDay: first ?? monday,
            lastDay: last ?? date(2026, 3, 8),
            memberIDs: members,
            reason: reason,
            createdBy: fixture.parent.id,
            createdAt: date(2026, 2, 20),
            calendar: calendar
        )
    }

    // MARK: The household's own list

    @Test("A chore whose person is away stays on the household's list, marked")
    func householdStillSeesTheWork() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [try away(in: fixture, members: [fixture.sam.id])]

        let agenda = fixture.snapshot.agenda(for: monday)
        let binRow = try #require(agenda.first { $0.chore.id == fixture.bins.id })

        #expect(binRow.isAway)
        #expect(binRow.needsSomebodyElse)
        #expect(binRow.awayPeriod?.covers(fixture.sam.id) == true)
        #expect(binRow.responsible?.id == fixture.sam.id)
    }

    @Test("An open chore is only excused when the house is actually empty")
    func openChoreNeedsAnEmptyHouse() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [try away(in: fixture, members: [fixture.sam.id])]

        let withSamAway = fixture.snapshot.agenda(for: monday)
        let dishes = try #require(withSamAway.first { $0.chore.id == fixture.dishwasher.id })
        // Alex and Mary are still here, and the dishwasher is still theirs to
        // empty.
        #expect(!dishes.isAway)

        fixture.snapshot.awayPeriods = [try away(in: fixture)]
        let emptyHouse = fixture.snapshot.agenda(for: monday)
        #expect(emptyHouse.allSatisfy { $0.isAway })
    }

    @Test("A day outside the trip is an ordinary day again")
    func daysOutsideTheTripAreNormal() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [
            try away(in: fixture, members: [fixture.sam.id], from: monday, to: date(2026, 3, 4))
        ]

        #expect(fixture.snapshot.agenda(for: date(2026, 3, 4)).contains { $0.isAway })
        #expect(!fixture.snapshot.agenda(for: date(2026, 3, 5)).contains { $0.isAway })
        #expect(!fixture.snapshot.agenda(for: date(2026, 3, 1)).contains { $0.isAway })
    }

    @Test("A cancelled trip leaves the agenda exactly as it was")
    func cancellingRestoresTheDay() throws {
        var fixture = try makeFixture()
        let trip = try away(in: fixture, members: [fixture.sam.id])
        fixture.snapshot.awayPeriods = [trip.cancelled(at: date(2026, 2, 28))]

        #expect(!fixture.snapshot.agenda(for: monday).contains { $0.isAway })
        #expect(fixture.snapshot.agenda(for: monday, memberID: fixture.sam.id).count == 2)
    }

    // MARK: One person's list

    @Test("Somebody who is away is not asked for anything")
    func awayMemberHasAnEmptyList() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [try away(in: fixture, members: [fixture.sam.id])]

        // Not even the open chore, which is on everybody else's list.
        #expect(fixture.snapshot.agenda(for: monday, memberID: fixture.sam.id).isEmpty)

        let alexes = fixture.snapshot.agenda(for: monday, memberID: fixture.alex.id)
        #expect(alexes.map(\.chore.id) == [fixture.dishwasher.id])
    }

    @Test("What somebody did anyway while away stays on their list")
    func completedWorkStaysOnAnAwayList() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [try away(in: fixture, members: [fixture.sam.id])]
        fixture.snapshot.completions = [
            ChoreCompletion(
                householdID: fixture.snapshot.household.id,
                choreID: fixture.bins.id,
                occurrenceDay: monday,
                completedBy: fixture.sam.id,
                completedAt: monday,
                approval: .notRequired,
                pointsAwarded: 10,
                calendar: calendar
            )
        ]

        // He is still not being asked for the open chore, but the one he did
        // from his grandmother's is his and must not vanish the moment he
        // ticks it off.
        let his = fixture.snapshot.agenda(for: monday, memberID: fixture.sam.id)
        #expect(his.map(\.chore.id) == [fixture.bins.id])
        #expect(his[0].isDone)

        // And the household's list agrees about the same square.
        let binRow = try #require(
            fixture.snapshot.agenda(for: monday).first { $0.chore.id == fixture.bins.id }
        )
        #expect(binRow.isDone)
        #expect(binRow.isAway)
        #expect(!binRow.needsSomebodyElse)
    }

    @Test("A covered chore follows the person covering it, away and all")
    func coverMovesTheAbsence() throws {
        var fixture = try makeFixture()
        let cover = try CoverRequest(
            householdID: fixture.snapshot.household.id,
            choreID: fixture.bins.id,
            day: monday,
            requestedBy: fixture.sam.id,
            createdAt: date(2026, 3, 1),
            resolution: .accepted(by: fixture.alex.id, at: date(2026, 3, 1)),
            calendar: calendar
        )
        fixture.snapshot.coverRequests = [cover]
        // Sam is away, but Alex took the bins on and Alex is here.
        fixture.snapshot.awayPeriods = [try away(in: fixture, members: [fixture.sam.id])]

        let binRow = try #require(
            fixture.snapshot.agenda(for: monday).first { $0.chore.id == fixture.bins.id }
        )
        #expect(!binRow.isAway)
        #expect(binRow.responsible?.id == fixture.alex.id)

        // Turn it round: Alex is the one away, and the row he took on is the
        // one nobody is here for.
        fixture.snapshot.awayPeriods = [try away(in: fixture, members: [fixture.alex.id])]
        let movedRow = try #require(
            fixture.snapshot.agenda(for: monday).first { $0.chore.id == fixture.bins.id }
        )
        #expect(movedRow.isAway)
    }

    // MARK: Ordering

    @Test("Work somebody is here for comes above work nobody is")
    func liveWorkSortsAboveAbsentWork() throws {
        var fixture = try makeFixture()
        // Titled so that sorting on the title alone would put it first: an
        // ordering that ignored the trip would open the home screen on the one
        // row nobody in the house can act on.
        let sheets = try Chore(
            householdID: fixture.snapshot.household.id,
            title: "Change the sheets",
            assignment: .member(fixture.sam.id),
            startDate: date(2026, 3, 1),
            recurrence: .daily,
            createdBy: fixture.parent.id,
            createdAt: date(2026, 1, 1)
        )
        fixture.snapshot.chores.append(sheets)
        fixture.snapshot.awayPeriods = [try away(in: fixture, members: [fixture.sam.id])]

        let agenda = fixture.snapshot.agenda(for: monday)
        #expect(
            agenda.map(\.chore.id) == [fixture.dishwasher.id, sheets.id, fixture.bins.id]
        )
        #expect(agenda.map { $0.isAway } == [false, true, true])
    }

    // MARK: What the household is told

    @Test("The household can say who is away, and who is going")
    func snapshotAnswersWhoIsAway() throws {
        var fixture = try makeFixture()
        let halfTerm = try away(
            in: fixture, members: [fixture.sam.id], from: monday, to: date(2026, 3, 4),
            reason: "Nan's"
        )
        let holiday = try away(in: fixture, from: date(2026, 4, 1), to: date(2026, 4, 10))
        fixture.snapshot.awayPeriods = [holiday, halfTerm]

        #expect(fixture.snapshot.isAway(fixture.sam.id, on: monday))
        #expect(!fixture.snapshot.isAway(fixture.alex.id, on: monday))
        #expect(!fixture.snapshot.isHouseholdAway(on: monday))
        #expect(fixture.snapshot.isHouseholdAway(on: date(2026, 4, 2)))

        #expect(fixture.snapshot.membersAway(on: monday).map(\.id) == [fixture.sam.id])
        #expect(fixture.snapshot.membersAway(on: date(2026, 3, 20)).isEmpty)
        #expect(
            fixture.snapshot.membersAway(on: date(2026, 4, 2)).map(\.id)
                == [fixture.parent.id, fixture.alex.id, fixture.sam.id]
        )

        #expect(fixture.snapshot.upcomingAwayPeriods(after: monday).map(\.id) == [holiday.id])
        #expect(fixture.snapshot.upcomingAwayPeriods(after: date(2026, 5, 1)).isEmpty)

        #expect(try fixture.snapshot.requireAwayPeriod(halfTerm.id).reason?.value == "Nan's")
        #expect(throws: DomainError.self) {
            try fixture.snapshot.requireAwayPeriod(Identifier<AwayPeriod>())
        }
    }

    @Test("A trip survives the round trip through a backup")
    func awayPeriodsEncodeAndDecode() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [try away(in: fixture, members: [fixture.sam.id])]

        let encoded = try JSONEncoder().encode(fixture.snapshot)
        let decoded = try JSONDecoder().decode(HouseholdSnapshot.self, from: encoded)
        #expect(decoded.awayPeriods.map(\.id) == fixture.snapshot.awayPeriods.map(\.id))
        #expect(decoded.isAway(fixture.sam.id, on: monday))

        // A backup written before the feature existed simply has no trips.
        var older = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        older.removeValue(forKey: "awayPeriods")
        let olderData = try JSONSerialization.data(withJSONObject: older)
        #expect(
            try JSONDecoder().decode(HouseholdSnapshot.self, from: olderData).awayPeriods.isEmpty)
    }
}
