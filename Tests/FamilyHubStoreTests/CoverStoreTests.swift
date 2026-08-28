import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers what the store owes the cover feature: requests survive a write and a
/// read, they wake the screens that show chores, they go when the chore they
/// are about goes, and they travel in a backup.
@Suite("Cover requests in the store")
struct CoverStoreTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 9)

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let household: Household
        let sam: Member
        let alex: Member
        let bins: Chore
    }

    private func makeFixture() async throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child,
            avatar: Avatar(color: .amber), joinedAt: clock.now
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen,
            avatar: Avatar(color: .teal), joinedAt: clock.now
        )
        let bins = try Chore(
            householdID: household.id,
            title: "Take out the bins",
            assignment: .member(sam.id),
            points: 15,
            startDate: clock.today,
            recurrence: .daily,
            createdBy: sam.id,
            createdAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(
                household: household, members: [sam, alex], chores: [bins]
            )
        )
        return Fixture(store: store, household: household, sam: sam, alex: alex, bins: bins)
    }

    private func request(_ f: Fixture, day: Date? = nil) throws -> CoverRequest {
        try CoverRequest(
            householdID: f.household.id,
            choreID: f.bins.id,
            day: day ?? clock.today,
            requestedBy: f.sam.id,
            note: "At football until seven",
            createdAt: clock.now,
            calendar: calendar
        )
    }

    // MARK: Writing and reading

    @Test("A saved request comes back in the snapshot")
    func requestRoundTrips() async throws {
        let f = try await makeFixture()
        let asked = try request(f)

        try await f.store.save(asked)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.coverRequests == [asked])
        #expect(snapshot.coverRequests.first?.note?.value == "At football until seven")
    }

    @Test("Answering a request replaces it rather than adding a second one")
    func answeringConverges() async throws {
        // Written by identifier like everything else here, which is what makes
        // a sync retry converge instead of leaving the household with two
        // arrangements to reconcile.
        let f = try await makeFixture()
        let asked = try request(f)
        try await f.store.save(asked)

        try await f.store.save(asked.accepted(by: f.alex.id, at: clock.now))
        try await f.store.save(asked.accepted(by: f.alex.id, at: clock.now))

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.coverRequests.count == 1)
        #expect(snapshot.coverRequests.first?.resolution.coveringMemberID == f.alex.id)
    }

    @Test("Requests belong to their own household")
    func requestsAreScopedToTheirHousehold() async throws {
        let f = try await makeFixture()
        let other = try Household(name: "Flat 3B", timeZone: .gmt, createdAt: clock.now)
        try await f.store.save(other)
        try await f.store.save(try request(f))

        let theirs = try await f.store.snapshot(of: other.id)
        #expect(theirs.coverRequests.isEmpty)
    }

    // MARK: The change feed

    @Test("Saving a request wakes the screens that show chores")
    func requestChangeAffectsTheAgenda() async throws {
        let f = try await makeFixture()
        let feed = await f.store.changes(for: f.household.id)
        var iterator = feed.makeAsyncIterator()

        let asked = try request(f)
        try await f.store.save(asked)

        let change = try #require(await iterator.next())
        #expect(change.entity == .coverRequest)
        #expect(change.recordID == asked.id.rawValue)
        #expect(change.operation == .upserted)
        // An accepted cover moves a chore from one list to another, which is
        // exactly a change to what the agenda shows.
        #expect(change.affectsAgenda)
        #expect(!change.affectsBalances)
        #expect(!change.affectsCalendar)
        #expect(!change.affectsMealPlan)
    }

    // MARK: Deleting

    @Test("Deleting a chore takes its cover requests with it")
    func deletingAChoreClearsItsRequests() async throws {
        // A question about a chore that no longer exists cannot be answered
        // and cannot render a row, so leaving it behind would put a permanent
        // unanswerable ask on somebody's list.
        let f = try await makeFixture()
        try await f.store.save(try request(f))

        try await f.store.deleteChore(f.bins.id)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.coverRequests.isEmpty)
        #expect(snapshot.chores.isEmpty)
    }

    @Test("Deleting a chore reports the requests that went with it")
    func deletingAChoreReportsItsRequests() async throws {
        let f = try await makeFixture()
        let asked = try request(f)
        try await f.store.save(asked)

        let feed = await f.store.changes(for: f.household.id)
        var iterator = feed.makeAsyncIterator()
        try await f.store.deleteChore(f.bins.id)

        let first = try #require(await iterator.next())
        #expect(first.entity == .coverRequest)
        #expect(first.recordID == asked.id.rawValue)
        #expect(first.operation == .deleted)
    }

    @Test("Erasing a household erases its requests")
    func deletingAHouseholdClearsItsRequests() async throws {
        let f = try await makeFixture()
        try await f.store.save(try request(f))

        try await f.store.deleteHousehold(f.household.id)

        #expect(await f.store.recordCount == 0)
    }

    // MARK: Backup

    @Test("A backup carries the requests and restores them")
    func archiveCarriesRequests() async throws {
        let f = try await makeFixture()
        let accepted = try request(f).accepted(by: f.alex.id, at: clock.now)
        try await f.store.save(accepted)

        let archive = try await f.store.archive(f.household.id, exportedAt: clock.now)
        let reread = try HouseholdArchive.decoded(from: try archive.encoded())
        let fresh = InMemoryHouseholdStore()
        try await fresh.restore(reread)

        let restored = try await fresh.snapshot(of: f.household.id)
        #expect(restored.coverRequests == [accepted])
        #expect(restored.cover(for: accepted.occurrenceKey) == f.alex.id)
    }
}
