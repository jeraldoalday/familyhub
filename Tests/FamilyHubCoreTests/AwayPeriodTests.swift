import Foundation
import Testing

@testable import FamilyHubCore

/// Covers the record a household leaves when some or all of it is not here:
/// what it can say, who it takes out, and how the screens that judge a person
/// by their day read it back.
@Suite("Away periods")
struct AwayPeriodTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 9)

    private let householdID = Identifier<Household>()
    private let parent = Identifier<Member>()
    private let sam = Identifier<Member>()
    private let alex = Identifier<Member>()

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: clock.today) ?? clock.today
    }

    private func makePeriod(
        from first: Int = 0,
        to last: Int = 6,
        members: Set<Identifier<Member>> = [],
        reason: String? = nil,
        cancelledAt: Date? = nil
    ) throws -> AwayPeriod {
        try AwayPeriod(
            householdID: householdID,
            firstDay: day(first),
            lastDay: day(last),
            memberIDs: members,
            reason: reason,
            createdBy: parent,
            createdAt: clock.now,
            cancelledAt: cancelledAt,
            calendar: calendar
        )
    }

    // MARK: Construction

    @Test("Both ends are normalised, so two devices agree on the days")
    func normalisesBothEnds() throws {
        let period = try AwayPeriod(
            householdID: householdID,
            firstDay: day(0).addingTimeInterval(22 * 3600),
            lastDay: day(3).addingTimeInterval(6 * 3600),
            createdBy: parent,
            createdAt: clock.now,
            calendar: calendar
        )

        #expect(period.firstDay == day(0))
        #expect(period.lastDay == day(3))
        #expect(period.dayCount(calendar: calendar) == 4)
    }

    @Test("A single day away is a period of one day, not of none")
    func singleDayCountsAsOne() throws {
        let period = try makePeriod(from: 2, to: 2)
        #expect(period.dayCount(calendar: calendar) == 1)
        #expect(period.covers(day(2), calendar: calendar))
        #expect(!period.covers(day(1), calendar: calendar))
        #expect(!period.covers(day(3), calendar: calendar))
    }

    @Test("Dates the wrong way round are refused rather than swapped")
    func backwardsDatesAreRefused() {
        #expect(throws: DomainError.impossibleDateRange(reason: "it ends before it starts")) {
            try makePeriod(from: 6, to: 0)
        }
    }

    @Test("A trip longer than the limit is refused, because it is a typo")
    func absurdlyLongTripIsRefused() throws {
        // The limit itself is fine; a day past it is a mistyped year.
        #expect(throws: Never.self) { try makePeriod(from: 0, to: Limits.awayPeriodDays - 1) }
        #expect(throws: DomainError.self) { try makePeriod(from: 0, to: Limits.awayPeriodDays) }
    }

    @Test("A blank reason is no reason rather than an error")
    func blankReasonBecomesNil() throws {
        #expect(try makePeriod(reason: "  \n ").reason == nil)
        #expect(try makePeriod(reason: " Nan's ").reason?.value == "Nan's")
        #expect(throws: DomainError.tooLong(field: .awayReason, limit: Limits.notesLength)) {
            try makePeriod(reason: String(repeating: "a", count: Limits.notesLength + 1))
        }
    }

    // MARK: Who it covers

    @Test("Naming nobody means everybody")
    func emptyMemberSetMeansTheWholeHousehold() throws {
        let holiday = try makePeriod()
        #expect(holiday.isWholeHousehold)
        #expect(holiday.covers(sam))
        #expect(holiday.covers(alex))
        #expect(holiday.covers(parent))
    }

    @Test("Naming somebody leaves the rest of the household here")
    func namedMembersOnly() throws {
        let halfTerm = try makePeriod(members: [sam])
        #expect(!halfTerm.isWholeHousehold)
        #expect(halfTerm.covers(sam, on: day(1), calendar: calendar))
        #expect(!halfTerm.covers(alex, on: day(1), calendar: calendar))
    }

    @Test("A day outside the trip is not covered, however it is asked about")
    func daysOutsideAreNotCovered() throws {
        let trip = try makePeriod(from: 1, to: 3, members: [sam])
        #expect(!trip.covers(sam, on: day(0), calendar: calendar))
        #expect(trip.covers(sam, on: day(1), calendar: calendar))
        #expect(trip.covers(sam, on: day(3), calendar: calendar))
        #expect(!trip.covers(sam, on: day(4), calendar: calendar))
    }

    @Test("A cancelled trip covers nobody, on any day")
    func cancelledTripCoversNothing() throws {
        let cancelled = try makePeriod().cancelled(at: clock.now)
        #expect(!cancelled.isActive)
        #expect(!cancelled.covers(day(1), calendar: calendar))
        #expect(!cancelled.covers(sam, on: day(1), calendar: calendar))
        // Still names the people it always named — cancelling is not editing.
        #expect(cancelled.covers(sam))
        #expect(cancelled.reinstated().covers(sam, on: day(1), calendar: calendar))
    }

    // MARK: Overlap and position in time

    @Test("Overlap is inclusive at both ends")
    func overlapIsInclusive() throws {
        let trip = try makePeriod(from: 5, to: 9)
        #expect(trip.overlaps(day(0)...day(5), calendar: calendar))
        #expect(trip.overlaps(day(9)...day(20), calendar: calendar))
        #expect(trip.overlaps(day(6)...day(7), calendar: calendar))
        #expect(!trip.overlaps(day(0)...day(4), calendar: calendar))
        #expect(!trip.overlaps(day(10)...day(20), calendar: calendar))
    }

    @Test("A trip knows whether it is still to come or already over")
    func positionInTime() throws {
        let trip = try makePeriod(from: 3, to: 5)
        #expect(trip.isUpcoming(on: day(0), calendar: calendar))
        #expect(!trip.isUpcoming(on: day(3), calendar: calendar))
        #expect(!trip.hasEnded(on: day(5), calendar: calendar))
        #expect(trip.hasEnded(on: day(6), calendar: calendar))
    }

    // MARK: Naming it

    @Test("A family holiday is everyone, and a named trip lists the names")
    func namesThePeople() throws {
        let members = [
            try Member(
                id: parent, householdID: householdID, name: "Jerald", role: .owner,
                joinedAt: clock.now),
            try Member(
                id: sam, householdID: householdID, name: "Sam", role: .child,
                joinedAt: clock.now),
            try Member(
                id: alex, householdID: householdID, name: "Alex", role: .teen,
                joinedAt: clock.now),
        ]

        #expect(try makePeriod().who(among: members) == "Everyone")
        #expect(try makePeriod(members: [sam]).who(among: members) == "Sam")
        // Adults first, which is the household's usual display order.
        #expect(try makePeriod(members: [sam, alex]).who(among: members) == "Alex and Sam")
        #expect(
            try makePeriod(members: [sam, alex, parent]).who(among: members)
                == "Jerald, Alex and Sam"
        )
        // A trip naming somebody who has since been erased is not a crash.
        #expect(try makePeriod(members: [Identifier<Member>()]).who(among: members) == "Nobody")
    }

    // MARK: Editing

    @Test("Rescheduling keeps the identity and re-checks the dates")
    func reschedulingRevalidates() throws {
        let trip = try makePeriod(from: 1, to: 3, reason: "Spain")
        let moved = try trip.rescheduled(lastDay: day(8), calendar: calendar)

        #expect(moved.id == trip.id)
        #expect(moved.firstDay == day(1))
        #expect(moved.lastDay == day(8))
        #expect(moved.reason?.value == "Spain")

        #expect(throws: DomainError.self) {
            try trip.rescheduled(firstDay: day(9), calendar: calendar)
        }
    }

    @Test("A trip can change who it is about, in both directions")
    func changingWhoIsAway() throws {
        let trip = try makePeriod(members: [sam])
        #expect(trip.covering([sam, alex]).covers(alex))
        #expect(trip.covering([]).isWholeHousehold)
        #expect(try trip.withReason("Nan's").reason?.value == "Nan's")
        #expect(try trip.withReason(nil).reason == nil)
    }

    // MARK: Reading a household's trips back

    @Test("The household's trips read back in date order, cancelled ones dropped")
    func activeTripsAreOrdered() throws {
        let later = try makePeriod(from: 10, to: 12)
        let earlier = try makePeriod(from: 1, to: 2)
        let called = try makePeriod(from: 4, to: 5, cancelledAt: clock.now)

        #expect([later, earlier, called].active.map(\.id) == [earlier.id, later.id])
    }

    @Test("Overlapping trips resolve to the same one on every device")
    func overlappingTripsResolveDeterministically() throws {
        let holiday = try makePeriod(from: 0, to: 6)
        let halfTerm = try makePeriod(from: 3, to: 9, members: [sam])
        let trips = [halfTerm, holiday]

        // Both cover day 4 for Sam; the earlier start wins, either way round.
        #expect(trips.covering(sam, on: day(4), calendar: calendar)?.id == holiday.id)
        #expect(
            [holiday, halfTerm].covering(sam, on: day(4), calendar: calendar)?.id == holiday.id
        )
        // Day 8 is only the half term, and only for Sam.
        #expect(trips.covering(sam, on: day(8), calendar: calendar)?.id == halfTerm.id)
        #expect(trips.covering(alex, on: day(8), calendar: calendar) == nil)
    }

    @Test("An empty house is a different fact from everybody happening to be out")
    func householdAwayIsItsOwnQuestion() throws {
        let everyone = try makePeriod(from: 0, to: 2)
        let bothChildren = try makePeriod(from: 5, to: 7, members: [sam, alex])

        #expect([everyone, bothChildren].isHouseholdAway(on: day(1), calendar: calendar))
        #expect(![everyone, bothChildren].isHouseholdAway(on: day(6), calendar: calendar))
        #expect([bothChildren].isAway(sam, on: day(6), calendar: calendar))
    }

    @Test("The days away are expanded once, clipped to the window asked for")
    func awayDaysAreClippedToTheWindow() throws {
        let trip = try makePeriod(from: 2, to: 8, members: [sam])
        let trips = [trip]

        let inside = trips.awayDays(for: sam, in: day(0)...day(4), calendar: calendar)
        #expect(inside == Set([day(2), day(3), day(4)]))

        // Somebody the trip does not name has no days away.
        #expect(trips.awayDays(for: alex, in: day(0)...day(20), calendar: calendar).isEmpty)

        // Asking for nobody asks about the whole household, which this is not.
        #expect(trips.awayDays(for: nil, in: day(0)...day(20), calendar: calendar).isEmpty)

        let holiday = try makePeriod(from: 3, to: 4)
        #expect(
            [holiday].awayDays(for: nil, in: day(0)...day(20), calendar: calendar)
                == Set([day(3), day(4)])
        )
    }

    @Test("A cancelled trip contributes no days at all")
    func cancelledTripsContributeNothing() throws {
        let cancelled = try makePeriod(from: 0, to: 6, cancelledAt: clock.now)
        #expect([cancelled].awayDays(for: sam, in: day(0)...day(6), calendar: calendar).isEmpty)
        #expect([cancelled].live(on: day(1), calendar: calendar).isEmpty)
    }

    // MARK: Permission

    @Test("Only an adult may say who is away")
    func onlyAdultsRecordATrip() {
        #expect(Permissions.allows(.manageAwayPeriod, for: .owner))
        #expect(Permissions.allows(.manageAwayPeriod, for: .adult))
        #expect(!Permissions.allows(.manageAwayPeriod, for: .teen))
        #expect(!Permissions.allows(.manageAwayPeriod, for: .child))
        #expect(throws: DomainError.notPermitted(action: .manageAwayPeriod, role: .child)) {
            try Permissions.check(.manageAwayPeriod, for: .child)
        }
    }
}
