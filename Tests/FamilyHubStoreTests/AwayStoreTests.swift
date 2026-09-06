import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers what the store owes the away feature: trips survive a write and a
/// read, they wake the screens that show chores, they go when the household
/// goes, and they travel in a backup.
@Suite("Away periods in the store")
struct AwayStoreTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 9)

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let household: Household
        let mary: Member
        let sam: Member
    }

    private func makeFixture() async throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: clock.now
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .adult, joinedAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(household: household, members: [mary, sam])
        )
        return Fixture(store: store, household: household, mary: mary, sam: sam)
    }

    private func trip(
        _ f: Fixture,
        members: Set<Identifier<Member>> = [],
        reason: String? = "Spain"
    ) throws -> AwayPeriod {
        try AwayPeriod(
            householdID: f.household.id,
            firstDay: clock.today,
            lastDay: clock.day(offsetFromToday: 6),
            memberIDs: members,
            reason: reason,
            createdBy: f.mary.id,
            createdAt: clock.now,
            calendar: calendar
        )
    }

    // MARK: Writing and reading

    @Test("A saved trip comes back in the snapshot")
    func tripRoundTrips() async throws {
        let f = try await makeFixture()
        let holiday = try trip(f)

        try await f.store.save(holiday)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.awayPeriods == [holiday])
        #expect(snapshot.isAway(f.sam.id, on: clock.today))
        #expect(snapshot.awayPeriods.first?.reason?.value == "Spain")
    }

    @Test("Two phones recording the same holiday converge on one trip")
    func writingByIdentifierConverges() async throws {
        let f = try await makeFixture()
        let holiday = try trip(f)
        try await f.store.save(holiday)

        try await f.store.save(
            try holiday.rescheduled(lastDay: clock.day(offsetFromToday: 9), calendar: calendar))
        try await f.store.save(
            try holiday.rescheduled(lastDay: clock.day(offsetFromToday: 9), calendar: calendar))

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.awayPeriods.count == 1)
        #expect(snapshot.awayPeriods.first?.lastDay == clock.day(offsetFromToday: 9))
    }

    @Test("Trips belong to their own household")
    func tripsAreScopedToTheirHousehold() async throws {
        let f = try await makeFixture()
        let other = try Household(name: "Flat 3B", timeZone: .gmt, createdAt: clock.now)
        try await f.store.save(other)
        try await f.store.save(try trip(f))

        #expect(try await f.store.snapshot(of: other.id).awayPeriods.isEmpty)
    }

    // MARK: The change feed

    @Test("Saving a trip wakes the screens that show chores, and only those")
    func tripChangeAffectsTheAgenda() async throws {
        let f = try await makeFixture()
        let feed = await f.store.changes(for: f.household.id)
        var iterator = feed.makeAsyncIterator()

        let holiday = try trip(f)
        try await f.store.save(holiday)

        let change = try #require(await iterator.next())
        #expect(change.entity == .awayPeriod)
        #expect(change.recordID == holiday.id.rawValue)
        #expect(change.operation == .upserted)
        // A trip decides whose list a chore is on and whether anybody is here
        // to do it, which is exactly a change to what the agenda shows.
        #expect(change.affectsAgenda)
        #expect(!change.affectsBalances)
        #expect(!change.affectsRewards)
        #expect(!change.affectsCalendar)
        #expect(!change.affectsMealPlan)
    }

    @Test("Cancelling a trip is a change like any other")
    func cancellingPublishesAChange() async throws {
        let f = try await makeFixture()
        let holiday = try trip(f)
        try await f.store.save(holiday)

        let feed = await f.store.changes(for: f.household.id)
        var iterator = feed.makeAsyncIterator()
        try await f.store.save(holiday.cancelled(at: clock.now))

        let change = try #require(await iterator.next())
        #expect(change.entity == .awayPeriod)
        #expect(change.operation == .upserted)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(!snapshot.isAway(f.sam.id, on: clock.today))
    }

    // MARK: Deleting

    @Test("Erasing a household erases its trips")
    func deletingAHouseholdClearsItsTrips() async throws {
        let f = try await makeFixture()
        try await f.store.save(try trip(f))

        try await f.store.deleteHousehold(f.household.id)

        #expect(await f.store.recordCount == 0)
    }

    // MARK: Backup

    @Test("A backup carries the trips and restores them")
    func archiveCarriesTrips() async throws {
        let f = try await makeFixture()
        let halfTerm = try trip(f, members: [f.sam.id], reason: "Nan's")
        try await f.store.save(halfTerm)

        let archive = try await f.store.archive(f.household.id, exportedAt: clock.now)
        #expect(archive.schemaVersion == FamilyHubStore.schemaVersion)

        let reread = try HouseholdArchive.decoded(from: try archive.encoded())
        let fresh = InMemoryHouseholdStore()
        try await fresh.restore(reread)

        let restored = try await fresh.snapshot(of: f.household.id)
        #expect(restored.awayPeriods == [halfTerm])
        #expect(restored.isAway(f.sam.id, on: clock.today))
        #expect(!restored.isAway(f.mary.id, on: clock.today))
    }

    @Test("A backup from before the feature restores as a household with no trips")
    func olderArchivesRestoreWithoutTrips() async throws {
        let f = try await makeFixture()
        try await f.store.save(try trip(f))

        // Version 5 is the last schema that had no away periods. A household
        // from then has weeks where every chore was missed at once, and
        // inventing a holiday from that shape would rewrite its history.
        let older = HouseholdArchive(
            snapshot: HouseholdSnapshot(
                household: f.household, members: [f.mary, f.sam]
            ),
            exportedAt: clock.now,
            schemaVersion: 5
        )
        let migrated = try HouseholdArchive.decoded(from: try older.encoded())

        #expect(migrated.schemaVersion == FamilyHubStore.schemaVersion)
        #expect(migrated.snapshot.awayPeriods.isEmpty)
    }
}
