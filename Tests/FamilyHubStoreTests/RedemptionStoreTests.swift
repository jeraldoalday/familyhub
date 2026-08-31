import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers redemptions as records the store keeps: written by identifier,
/// reported on the change feed, carried through a backup, and understood when
/// the backup predates them.
@Suite("Redemptions in the store")
struct RedemptionStoreTests {

    // MARK: Fixture

    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let household: Household
        let mary: Member
        let sam: Member
        let movieNight: Reward
    }

    private func makeFixture() async throws -> Fixture {
        let household = try Household(
            name: "The Aldays", tier: .plus, timeZone: .gmt, createdAt: clock.now
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .owner, joinedAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: clock.now
        )
        let movieNight = try Reward(
            householdID: household.id, name: "Movie night pick", cost: 25, createdAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(
                household: household,
                members: [mary, sam],
                rewards: [movieNight]
            )
        )
        return Fixture(
            store: store, household: household, mary: mary, sam: sam, movieNight: movieNight
        )
    }

    private func makeRedemption(
        in fixture: Fixture,
        state: Redemption.State = .owed
    ) throws -> Redemption {
        try Redemption(
            householdID: fixture.household.id,
            rewardID: fixture.movieNight.id,
            memberID: fixture.sam.id,
            cost: fixture.movieNight.cost,
            redeemedAt: clock.now,
            state: state
        )
    }

    // MARK: Writing

    @Test("A saved redemption comes back on the snapshot")
    func savesAndReads() async throws {
        let f = try await makeFixture()
        let redemption = try makeRedemption(in: f)

        try await f.store.save(redemption)
        let snapshot = try await f.store.snapshot(of: f.household.id)

        #expect(snapshot.redemptions == [redemption])
        #expect(snapshot.owedRedemptions.count == 1)
        #expect(snapshot.owedPoints(to: f.sam.id) == 25)
    }

    @Test("Two parents confirming the same reward converge on one record")
    func writesAreIdempotentByIdentifier() async throws {
        let f = try await makeFixture()
        let redemption = try makeRedemption(in: f)
        let given = try redemption.given(by: f.mary.id, at: clock.now)

        try await f.store.save(redemption)
        try await f.store.save(given)
        try await f.store.save(given)
        let snapshot = try await f.store.snapshot(of: f.household.id)

        #expect(snapshot.redemptions.count == 1)
        #expect(snapshot.redemptions.first?.state == .given(by: f.mary.id, at: clock.now))
        #expect(snapshot.owedRedemptions.isEmpty)
    }

    @Test("Redemptions can be written in a batch")
    func savesInABatch() async throws {
        let f = try await makeFixture()
        let batch = [
            try makeRedemption(in: f),
            try makeRedemption(in: f),
            try makeRedemption(in: f, state: .given(by: f.mary.id, at: clock.now)),
        ]

        try await f.store.save(redemptions: batch)
        let snapshot = try await f.store.snapshot(of: f.household.id)

        #expect(snapshot.redemptions.count == 3)
        #expect(snapshot.owedRedemptions.count == 2)
    }

    @Test("Erasing a household erases what it owed")
    func deletingAHouseholdTakesRedemptions() async throws {
        let f = try await makeFixture()
        try await f.store.save(try makeRedemption(in: f))

        try await f.store.deleteHousehold(f.household.id)

        #expect(await f.store.recordCount == 0)
    }

    // MARK: The change feed

    @Test("Saving a redemption reports itself as a redemption")
    func publishesAChange() async throws {
        let f = try await makeFixture()
        let redemption = try makeRedemption(in: f)
        let stream = await f.store.changes(for: f.household.id)

        let collector = Task {
            var seen: [HouseholdChange] = []
            for await change in stream {
                seen.append(change)
                if seen.count == 1 { break }
            }
            return seen
        }
        try await f.store.save(redemption)
        let changes = await collector.value

        #expect(changes.first?.entity == .redemption)
        #expect(changes.first?.recordID == redemption.id.rawValue)
        #expect(changes.first?.operation == .upserted)
    }

    @Test("A redemption wakes the rewards screen and nothing else")
    func changeFilters() {
        let change = HouseholdChange(
            householdID: Identifier<Household>(), entity: .redemption, recordID: UUID()
        )

        #expect(change.affectsRewards)
        #expect(!change.affectsAgenda)
        #expect(!change.affectsBalances)
        #expect(!change.affectsMealPlan)
        #expect(!change.affectsCalendar)
    }

    @Test("The rewards filter wakes for everything that reward screen shows")
    func rewardsFilterCoversTheScreen() {
        let householdID = Identifier<Household>()
        func change(_ entity: HouseholdChange.Entity) -> HouseholdChange {
            HouseholdChange(householdID: householdID, entity: entity, recordID: UUID())
        }

        #expect(change(.reward).affectsRewards)
        #expect(change(.ledgerEntry).affectsRewards)
        #expect(change(.completion).affectsRewards)
        #expect(change(.member).affectsRewards)
        #expect(change(.household).affectsRewards)
        #expect(!change(.shoppingItem).affectsRewards)
        #expect(!change(.plannedMeal).affectsRewards)
        #expect(!change(.coverRequest).affectsRewards)
    }

    // MARK: Backups

    @Test("A backup carries what the household still owes")
    func archiveRoundTripsRedemptions() async throws {
        let f = try await makeFixture()
        let owed = try makeRedemption(in: f)
        let given = try makeRedemption(in: f).given(by: f.mary.id, at: clock.now)
        try await f.store.save(redemptions: [owed, given])

        let archive = try await f.store.archive(f.household.id, exportedAt: clock.now)
        let restored = try HouseholdArchive.decoded(from: try archive.encoded())

        #expect(restored.schemaVersion == 5)
        #expect(Set(restored.snapshot.redemptions) == Set([owed, given]))
        #expect(restored.snapshot.owedRedemptions.map(\.id) == [owed.id])
    }

    @Test("Restoring a backup puts the promises back on the queue")
    func restoreWritesRedemptions() async throws {
        let f = try await makeFixture()
        try await f.store.save(try makeRedemption(in: f))
        let archive = try await f.store.archive(f.household.id, exportedAt: clock.now)

        let fresh = InMemoryHouseholdStore()
        try await fresh.restore(archive)
        let snapshot = try await fresh.snapshot(of: f.household.id)

        #expect(snapshot.redemptions.count == 1)
        #expect(snapshot.owedPoints(to: f.sam.id) == 25)
    }

    @Test("A backup from before redemptions existed restores as owing nothing")
    func migratesFromSchemaFour() async throws {
        let f = try await makeFixture()
        // A version 4 household is not one whose rewards were never redeemed —
        // it is one whose redemptions were settled, or not, out in the world
        // where the app could not see them. Inventing records from the ledger
        // would tell the family it owes films they watched in February.
        try await f.store.append(
            LedgerEntry.spent(on: f.movieNight, by: f.sam.id, at: clock.advanced(byDays: -20).now)
        )
        let old = HouseholdArchive(
            snapshot: try await f.store.snapshot(of: f.household.id),
            exportedAt: clock.now,
            schemaVersion: 4
        )

        let restored = try HouseholdArchive.decoded(from: try old.encoded())

        #expect(restored.schemaVersion == FamilyHubStore.schemaVersion)
        #expect(restored.snapshot.redemptions.isEmpty)
        #expect(restored.snapshot.ledgerEntries.count == 1)
    }

    @Test("A backup claiming a schema this build has never heard of is refused")
    func refusesANewerArchive() async throws {
        let f = try await makeFixture()
        let future = HouseholdArchive(
            snapshot: try await f.store.snapshot(of: f.household.id),
            exportedAt: clock.now,
            schemaVersion: FamilyHubStore.schemaVersion + 1
        )

        #expect(
            throws: ArchiveError.fromANewerBuild(
                found: FamilyHubStore.schemaVersion + 1,
                supported: FamilyHubStore.schemaVersion
            )
        ) {
            try HouseholdArchive.decoded(from: try future.encoded())
        }
    }
}
