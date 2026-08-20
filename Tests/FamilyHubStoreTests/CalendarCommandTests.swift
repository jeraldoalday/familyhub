import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers the commands that put things on the family calendar, and in
/// particular who is allowed to put something on somebody else's day.
@Suite("Calendar commands")
struct CalendarCommandTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: clock.today) ?? clock.today
    }

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let commands: HouseholdCommands
        let household: Household
        let owner: Member
        let adult: Member
        let teen: Member
        let child: Member
    }

    private func makeFixture() async throws -> Fixture {
        let household = try Household(
            name: "The Aldays", tier: .free, timeZone: .gmt, createdAt: clock.now
        )
        let owner = try Member(
            householdID: household.id, name: "Jerald", role: .owner, joinedAt: clock.now
        )
        let adult = try Member(
            householdID: household.id, name: "Mary", role: .adult, joinedAt: clock.now
        )
        let teen = try Member(
            householdID: household.id, name: "Alex", role: .teen, joinedAt: clock.now
        )
        let child = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(
                household: household, members: [owner, adult, teen, child]
            )
        )
        return Fixture(
            store: store,
            commands: HouseholdCommands(store: store, dateProvider: clock),
            household: household,
            owner: owner,
            adult: adult,
            teen: teen,
            child: child
        )
    }

    // MARK: Scheduling

    @Test("An adult can put something on the whole household's calendar")
    func adultsCanScheduleForEveryone() async throws {
        let fixture = try await makeFixture()
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id,
            title: "Half term",
            kind: .school,
            on: day(3),
            by: fixture.adult.id
        )

        #expect(event.title.value == "Half term")
        #expect(event.startDate == day(3))
        #expect(event.isAllDay)
        #expect(event.participants == .everyone)
        #expect(event.createdBy == fixture.adult.id)

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.events.count == 1)
    }

    @Test("An event with no day named lands on today")
    func defaultsToToday() async throws {
        let fixture = try await makeFixture()
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id, title: "Dentist", by: fixture.owner.id
        )
        #expect(event.startDate == clock.today)
    }

    @Test("A recurring, timed event keeps both across a save")
    func recurringTimedEvent() async throws {
        let fixture = try await makeFixture()
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id,
            title: "Swimming",
            location: "Leisure centre",
            kind: .activity,
            on: day(1),
            timing: .at(hour: 16, lasting: 60),
            recurrence: try .weekly(on: [.tuesday]),
            participants: .members([fixture.child.id]),
            reminderMinutesBefore: 30,
            by: fixture.adult.id
        )

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        let occurrences = snapshot.familyCalendar.occurrences(from: day(0), to: day(21))
        #expect(occurrences.count == 3)
        #expect(occurrences.first?.start == day(1).addingTimeInterval(16 * 3600))
        #expect(event.location?.value == "Leisure centre")
        #expect(event.reminderMinutesBefore == 30)
    }

    // MARK: Who may schedule what

    @Test("A teen can book their own commitments")
    func teensCanScheduleForThemselves() async throws {
        let fixture = try await makeFixture()
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id,
            title: "Band practice",
            on: day(2),
            participants: .members([fixture.teen.id]),
            by: fixture.teen.id
        )
        #expect(event.participants == .members([fixture.teen.id]))
    }

    @Test("A teen cannot book their sibling in")
    func teensCannotScheduleForOthers() async throws {
        let fixture = try await makeFixture()
        await #expect(
            throws: DomainError.notPermitted(action: .manageCalendar, role: .teen)
        ) {
            try await fixture.commands.scheduleEvent(
                in: fixture.household.id,
                title: "Dentist",
                participants: .members([fixture.child.id]),
                by: fixture.teen.id
            )
        }
    }

    @Test("A teen cannot declare something for the whole household")
    func teensCannotScheduleForEveryone() async throws {
        let fixture = try await makeFixture()
        await #expect(
            throws: DomainError.notPermitted(action: .manageCalendar, role: .teen)
        ) {
            try await fixture.commands.scheduleEvent(
                in: fixture.household.id,
                title: "Half term",
                participants: .everyone,
                by: fixture.teen.id
            )
        }
    }

    @Test("A child cannot change the calendar at all")
    func childrenCannotSchedule() async throws {
        let fixture = try await makeFixture()
        await #expect(
            throws: DomainError.notPermitted(action: .manageCalendar, role: .child)
        ) {
            try await fixture.commands.scheduleEvent(
                in: fixture.household.id,
                title: "Sleepover",
                participants: .members([fixture.child.id]),
                by: fixture.child.id
            )
        }
    }

    @Test("An event cannot name somebody who has left")
    func removedMembersCannotBeNamed() async throws {
        let fixture = try await makeFixture()
        try await fixture.store.save(fixture.teen.removed(at: clock.now))

        await #expect(throws: DomainError.memberNotInHousehold(fixture.teen.id)) {
            try await fixture.commands.scheduleEvent(
                in: fixture.household.id,
                title: "Football",
                participants: .members([fixture.teen.id]),
                by: fixture.adult.id
            )
        }
    }

    @Test("The calendar is not a paid feature")
    func freeHouseholdsGetTheCalendar() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.household.tier == .free)
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id, title: "Dentist", by: fixture.owner.id
        )
        #expect(event.isActive)
    }

    // MARK: Editing

    @Test("Editing changes only what was named")
    func editingIsPartial() async throws {
        let fixture = try await makeFixture()
        let original = try await fixture.commands.scheduleEvent(
            in: fixture.household.id,
            title: "Swimming",
            notes: "Blue bag",
            location: "Pool",
            on: day(1),
            timing: .at(hour: 16, lasting: 60),
            by: fixture.adult.id
        )

        let edited = try await fixture.commands.updateEvent(
            original.id,
            in: fixture.household.id,
            by: fixture.adult.id,
            title: "Swimming lesson",
            kind: .activity
        )

        #expect(edited.title.value == "Swimming lesson")
        #expect(edited.kind == .activity)
        #expect(edited.notes?.value == "Blue bag")
        #expect(edited.location?.value == "Pool")
        #expect(edited.timing == .at(hour: 16, lasting: 60))
    }

    @Test("Clearing a field is distinguishable from leaving it alone")
    func clearingIsDistinguishable() async throws {
        let fixture = try await makeFixture()
        let original = try await fixture.commands.scheduleEvent(
            in: fixture.household.id,
            title: "Swimming",
            notes: "Blue bag",
            location: "Pool",
            reminderMinutesBefore: 30,
            by: fixture.adult.id
        )

        let cleared = try await fixture.commands.updateEvent(
            original.id,
            in: fixture.household.id,
            by: fixture.adult.id,
            notes: .some(nil),
            location: .some(nil),
            reminderMinutesBefore: .some(nil)
        )
        #expect(cleared.notes == nil)
        #expect(cleared.location == nil)
        #expect(cleared.reminderMinutesBefore == nil)
    }

    @Test("A teen cannot widen their own event into everybody's")
    func teensCannotWidenParticipants() async throws {
        let fixture = try await makeFixture()
        let mine = try await fixture.commands.scheduleEvent(
            in: fixture.household.id,
            title: "Band practice",
            participants: .members([fixture.teen.id]),
            by: fixture.teen.id
        )

        await #expect(
            throws: DomainError.notPermitted(action: .manageCalendar, role: .teen)
        ) {
            try await fixture.commands.updateEvent(
                mine.id,
                in: fixture.household.id,
                by: fixture.teen.id,
                participants: .everyone
            )
        }
    }

    @Test("A teen cannot edit an event that is not theirs")
    func teensCannotEditOthersEvents() async throws {
        let fixture = try await makeFixture()
        let theirs = try await fixture.commands.scheduleEvent(
            in: fixture.household.id,
            title: "Dentist",
            participants: .members([fixture.child.id]),
            by: fixture.adult.id
        )

        await #expect(
            throws: DomainError.notPermitted(action: .manageCalendar, role: .teen)
        ) {
            try await fixture.commands.updateEvent(
                theirs.id, in: fixture.household.id, by: fixture.teen.id, title: "Nothing"
            )
        }
    }

    @Test("Editing an event that is gone says so")
    func editingAMissingEventThrows() async throws {
        let fixture = try await makeFixture()
        await #expect(throws: DomainError.self) {
            try await fixture.commands.updateEvent(
                Identifier<CalendarEvent>(),
                in: fixture.household.id,
                by: fixture.adult.id,
                title: "Nothing"
            )
        }
    }

    @Test("An invalid edit is refused and nothing is written")
    func invalidEditsAreRefused() async throws {
        let fixture = try await makeFixture()
        let original = try await fixture.commands.scheduleEvent(
            in: fixture.household.id, title: "Swimming", by: fixture.adult.id
        )

        await #expect(throws: DomainError.blank(field: .eventTitle)) {
            try await fixture.commands.updateEvent(
                original.id, in: fixture.household.id, by: fixture.adult.id, title: "   "
            )
        }
        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.event(original.id)?.title.value == "Swimming")
    }

    // MARK: Rescheduling and skipping

    @Test("Rescheduling moves the whole series")
    func reschedulingMovesTheSeries() async throws {
        let fixture = try await makeFixture()
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id,
            title: "Swimming",
            on: day(1),
            recurrence: try .weekly(on: [.tuesday]),
            by: fixture.adult.id
        )

        let moved = try await fixture.commands.rescheduleEvent(
            event.id,
            to: day(2),
            recurrence: try .weekly(on: [.wednesday]),
            in: fixture.household.id,
            by: fixture.adult.id
        )
        #expect(moved.startDate == day(2))
        #expect(moved.recurrence.weekdays == [.wednesday])

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.familyCalendar.occurrences(on: day(1)).isEmpty)
        #expect(snapshot.familyCalendar.occurrences(on: day(2)).count == 1)
    }

    @Test("Skipping one week leaves the rest of the series alone")
    func skippingOneWeek() async throws {
        let fixture = try await makeFixture()
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id,
            title: "Swimming",
            on: day(1),
            recurrence: try .weekly(on: [.tuesday]),
            by: fixture.adult.id
        )

        try await fixture.commands.skipEvent(
            event.id, on: day(8), in: fixture.household.id, by: fixture.adult.id
        )
        var snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.familyCalendar.occurrences(on: day(8)).isEmpty)
        #expect(snapshot.familyCalendar.occurrences(on: day(15)).count == 1)

        try await fixture.commands.unskipEvent(
            event.id, on: day(8), in: fixture.household.id, by: fixture.adult.id
        )
        snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.familyCalendar.occurrences(on: day(8)).count == 1)
    }

    // MARK: Cancelling and deleting

    @Test("Cancelling takes an event off the week without erasing it")
    func cancellingKeepsTheRecord() async throws {
        let fixture = try await makeFixture()
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id, title: "Dentist", on: day(3), by: fixture.adult.id
        )

        let cancelled = try await fixture.commands.cancelEvent(
            event.id, in: fixture.household.id, by: fixture.adult.id
        )
        #expect(cancelled.cancelledAt == clock.now)

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.events.count == 1)
        #expect(snapshot.activeEvents.isEmpty)
        #expect(snapshot.familyCalendar.occurrences(on: day(3)).isEmpty)
    }

    @Test("A cancelled event can be put back")
    func reinstatingBringsItBack() async throws {
        let fixture = try await makeFixture()
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id, title: "Dentist", on: day(3), by: fixture.adult.id
        )
        try await fixture.commands.cancelEvent(
            event.id, in: fixture.household.id, by: fixture.adult.id
        )
        let back = try await fixture.commands.reinstateEvent(
            event.id, in: fixture.household.id, by: fixture.adult.id
        )
        #expect(back.isActive)

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.familyCalendar.occurrences(on: day(3)).count == 1)
    }

    @Test("Only the owner may erase an event outright")
    func deletingIsTheOwnersAlone() async throws {
        let fixture = try await makeFixture()
        let event = try await fixture.commands.scheduleEvent(
            in: fixture.household.id, title: "Dentist", by: fixture.adult.id
        )

        await #expect(
            throws: DomainError.notPermitted(action: .manageHousehold, role: .adult)
        ) {
            try await fixture.commands.deleteEvent(
                event.id, in: fixture.household.id, by: fixture.adult.id
            )
        }

        try await fixture.commands.deleteEvent(
            event.id, in: fixture.household.id, by: fixture.owner.id
        )
        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.events.isEmpty)
    }

    @Test("Erasing an event that is already gone says so rather than succeeding quietly")
    func deletingAMissingEventThrows() async throws {
        let fixture = try await makeFixture()
        await #expect(throws: DomainError.self) {
            try await fixture.commands.deleteEvent(
                Identifier<CalendarEvent>(), in: fixture.household.id, by: fixture.owner.id
            )
        }
    }
}
