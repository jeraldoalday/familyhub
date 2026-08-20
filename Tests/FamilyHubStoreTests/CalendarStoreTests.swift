import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers the persistence half of the calendar: that an event survives a
/// write, that erasing a household takes its calendar with it, and that the
/// change feed says so.
@Suite("Calendar persistence")
struct CalendarStoreTests {

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
        let household: Household
        let owner: Member
        let child: Member
    }

    private func makeFixture() async throws -> Fixture {
        let household = try Household(
            name: "The Aldays", tier: .plus, timeZone: .gmt, createdAt: clock.now
        )
        let owner = try Member(
            householdID: household.id, name: "Jerald", role: .owner, joinedAt: clock.now
        )
        let child = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(household: household, members: [owner, child])
        )
        return Fixture(store: store, household: household, owner: owner, child: child)
    }

    private func makeEvent(
        _ fixture: Fixture,
        title: String = "Swimming",
        dayOffset: Int = 0,
        participants: CalendarEvent.Participants = .everyone
    ) throws -> CalendarEvent {
        try CalendarEvent(
            householdID: fixture.household.id,
            title: title,
            startDate: day(dayOffset),
            timing: .at(hour: 16, lasting: 60),
            participants: participants,
            createdBy: fixture.owner.id,
            createdAt: clock.now,
            calendar: calendar
        )
    }

    // MARK: Reading and writing

    @Test("A saved event comes back in the snapshot")
    func eventRoundTrips() async throws {
        let fixture = try await makeFixture()
        let event = try makeEvent(fixture)
        try await fixture.store.save(event)

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.events == [event])
        #expect(snapshot.event(event.id) == event)
        #expect(try snapshot.requireEvent(event.id) == event)
    }

    @Test("Writing the same event twice replaces it rather than duplicating it")
    func writesAreIdempotent() async throws {
        let fixture = try await makeFixture()
        let event = try makeEvent(fixture)
        try await fixture.store.save(event)
        try await fixture.store.save(try event.retitled(to: "Swimming lesson"))

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.events.count == 1)
        #expect(snapshot.events.first?.title.value == "Swimming lesson")
    }

    @Test("Several events save in one call")
    func batchedWrites() async throws {
        let fixture = try await makeFixture()
        let events = [
            try makeEvent(fixture, title: "Swimming"),
            try makeEvent(fixture, title: "Dentist", dayOffset: 1),
        ]
        try await fixture.store.save(events: events)

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(Set(snapshot.events.map(\.title.value)) == ["Swimming", "Dentist"])
    }

    @Test("Asking for an event that is gone says so rather than returning nothing")
    func missingEventThrows() async throws {
        let fixture = try await makeFixture()
        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(throws: DomainError.self) {
            _ = try snapshot.requireEvent(Identifier<CalendarEvent>())
        }
    }

    // MARK: Deleting

    @Test("Deleting an event removes it")
    func deleteRemovesTheEvent() async throws {
        let fixture = try await makeFixture()
        let event = try makeEvent(fixture)
        try await fixture.store.save(event)
        try await fixture.store.deleteEvent(event.id)

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.events.isEmpty)
    }

    @Test("Deleting an event that was never there is not an error")
    func deletingNothingIsHarmless() async throws {
        let fixture = try await makeFixture()
        try await fixture.store.deleteEvent(Identifier<CalendarEvent>())
        #expect(await fixture.store.recordCount == 3)
    }

    @Test("Erasing a household takes its calendar with it")
    func deletingTheHouseholdClearsTheCalendar() async throws {
        let fixture = try await makeFixture()
        try await fixture.store.save(try makeEvent(fixture))
        try await fixture.store.deleteHousehold(fixture.household.id)
        #expect(await fixture.store.recordCount == 0)
    }

    @Test("One household's calendar is invisible to another")
    func householdsAreIsolated() async throws {
        let fixture = try await makeFixture()
        let other = try Household(name: "Flat 3B", timeZone: .gmt, createdAt: clock.now)
        let otherOwner = try Member(
            householdID: other.id, name: "Robin", role: .owner, joinedAt: clock.now
        )
        try await fixture.store.save(other)
        try await fixture.store.save(otherOwner)
        try await fixture.store.save(try makeEvent(fixture))

        let snapshot = try await fixture.store.snapshot(of: other.id)
        #expect(snapshot.events.isEmpty)
    }

    // MARK: The change feed

    @Test("Saving an event tells the subscribers watching the calendar")
    func savingPublishesAChange() async throws {
        let fixture = try await makeFixture()
        let feed = await fixture.store.changes(for: fixture.household.id)
        var iterator = feed.makeAsyncIterator()

        let event = try makeEvent(fixture)
        try await fixture.store.save(event)

        let change = try #require(await iterator.next())
        #expect(change.entity == .calendarEvent)
        #expect(change.recordID == event.id.rawValue)
        #expect(change.operation == .upserted)
        #expect(change.affectsCalendar)
        #expect(!change.affectsAgenda)
        #expect(!change.affectsMealPlan)
        #expect(!change.affectsBalances)
    }

    @Test("Deleting an event tells the subscribers too")
    func deletingPublishesAChange() async throws {
        let fixture = try await makeFixture()
        let event = try makeEvent(fixture)
        try await fixture.store.save(event)

        let feed = await fixture.store.changes(for: fixture.household.id)
        var iterator = feed.makeAsyncIterator()
        try await fixture.store.deleteEvent(event.id)

        let change = try #require(await iterator.next())
        #expect(change.entity == .calendarEvent)
        #expect(change.operation == .deleted)
    }

    @Test("A member changing is a calendar change, because events name people")
    func memberChangesReachTheCalendar() {
        let change = HouseholdChange(
            householdID: Identifier<Household>(), entity: .member, recordID: UUID()
        )
        #expect(change.affectsCalendar)
    }

    @Test("A shopping item being ticked off is not a calendar change")
    func shoppingChangesDoNotReachTheCalendar() {
        let change = HouseholdChange(
            householdID: Identifier<Household>(), entity: .shoppingItem, recordID: UUID()
        )
        #expect(!change.affectsCalendar)
    }

    // MARK: Snapshot integration

    @Test("The snapshot hands back a calendar already scoped to the household")
    func snapshotBuildsTheCalendar() async throws {
        let fixture = try await makeFixture()
        try await fixture.store.save(try makeEvent(fixture, title: "Swimming"))
        try await fixture.store.save(
            try makeEvent(fixture, title: "Dentist", dayOffset: 1).cancelled(at: clock.now)
        )

        let snapshot = try await fixture.store.snapshot(of: fixture.household.id)
        #expect(snapshot.events.count == 2)
        #expect(snapshot.activeEvents.map(\.title.value) == ["Swimming"])
        #expect(
            snapshot.familyCalendar.occurrences(on: clock.today).map(\.event.title.value)
                == ["Swimming"]
        )
    }

    @Test("A snapshot written before the calendar existed decodes as one with no events")
    func olderSnapshotsDecode() throws {
        let household = try Household(name: "The Aldays", timeZone: .gmt, createdAt: clock.now)
        let encoded = try JSONEncoder().encode(HouseholdSnapshot(household: household))
        var object =
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        object.removeValue(forKey: "events")
        let trimmed = try JSONSerialization.data(withJSONObject: object)

        let restored = try JSONDecoder().decode(HouseholdSnapshot.self, from: trimmed)
        #expect(restored.events.isEmpty)
    }

    @Test("A restored archive brings the calendar back with it")
    func restoreCarriesTheCalendar() async throws {
        let fixture = try await makeFixture()
        let event = try makeEvent(fixture)
        try await fixture.store.save(event)

        let archive = try await fixture.store.archive(fixture.household.id, exportedAt: clock.now)
        let fresh = InMemoryHouseholdStore()
        try await fresh.restore(archive)

        let snapshot = try await fresh.snapshot(of: fixture.household.id)
        #expect(snapshot.events == [event])
    }
}
