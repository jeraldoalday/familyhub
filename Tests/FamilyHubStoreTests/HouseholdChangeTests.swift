import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

@Suite("Change feed")
struct HouseholdChangeTests {

    // MARK: Fixture

    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let household: Household
        let parent: Member
        let chore: Chore
    }

    private func makeFixture() async throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: clock.now
        )
        let parent = try Member(
            householdID: household.id, name: "Jerald", role: .owner, joinedAt: clock.now
        )
        let chore = try Chore(
            householdID: household.id,
            title: "Feed the cat",
            startDate: clock.today,
            recurrence: .daily,
            createdBy: parent.id,
            createdAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(
                household: household, members: [parent], chores: [chore]
            )
        )
        return Fixture(store: store, household: household, parent: parent, chore: chore)
    }

    /// Collects the next `count` changes, failing rather than hanging if the
    /// writes never arrive.
    private func collect(
        _ count: Int,
        from stream: AsyncStream<HouseholdChange>,
        whileDoing work: @escaping @Sendable () async throws -> Void
    ) async throws -> [HouseholdChange] {
        let collector = Task {
            var collected: [HouseholdChange] = []
            for await change in stream {
                collected.append(change)
                if collected.count >= count { break }
            }
            return collected
        }
        try await work()
        return await collector.value
    }

    // MARK: Delivery

    @Test("A write reaches an open subscriber")
    func writesAreObserved() async throws {
        let f = try await makeFixture()
        let stream = await f.store.changes(for: f.household.id)

        let changes = try await collect(1, from: stream) {
            try await f.store.save(f.chore.retitled(to: "Feed the cat twice"))
        }

        #expect(changes.count == 1)
        #expect(changes.first?.entity == .chore)
        #expect(changes.first?.operation == .upserted)
        #expect(changes.first?.recordID == f.chore.id.rawValue)
        #expect(changes.first?.householdID == f.household.id)
    }

    @Test("Every kind of record reports its own writes")
    func everyEntityIsReported() async throws {
        let f = try await makeFixture()
        let stream = await f.store.changes(for: f.household.id)

        let reward = try Reward(
            householdID: f.household.id, name: "Movie night", cost: 50, createdAt: clock.now
        )
        let list = try ShoppingList(
            householdID: f.household.id, name: "Groceries",
            createdBy: f.parent.id, createdAt: clock.now
        )
        let item = try ShoppingItem(
            listID: list.id, householdID: f.household.id, name: "Milk",
            addedBy: f.parent.id, addedAt: clock.now
        )
        let completion = ChoreCompletion(
            householdID: f.household.id,
            choreID: f.chore.id,
            occurrenceDay: clock.today,
            completedBy: f.parent.id,
            completedAt: clock.now,
            pointsAwarded: 10,
            calendar: .testDefault
        )

        let changes = try await collect(5, from: stream) {
            try await f.store.save(completion)
            try await f.store.append(.earned(completion))
            try await f.store.save(reward)
            try await f.store.save(list)
            try await f.store.save(item)
        }

        #expect(
            changes.map(\.entity) == [
                .completion, .ledgerEntry, .reward, .shoppingList, .shoppingItem,
            ]
        )
    }

    @Test("Another household's writes do not wake this subscriber")
    func otherHouseholdsAreIgnored() async throws {
        // A device belonging to a user in two families must not rebuild one
        // family's home screen because the other's shopping list moved.
        let f = try await makeFixture()
        let other = try Household(name: "Flat 3B", timeZone: .gmt, createdAt: clock.now)
        try await f.store.save(other)

        let stream = await f.store.changes(for: f.household.id)
        let changes = try await collect(1, from: stream) {
            let stranger = try Member(
                householdID: other.id, name: "Robin", role: .owner, joinedAt: self.clock.now
            )
            try await f.store.save(stranger)
            try await f.store.save(f.parent.renamed(to: "Jerald A"))
        }

        #expect(changes.count == 1)
        #expect(changes.first?.entity == .member)
        #expect(changes.first?.recordID == f.parent.id.rawValue)
    }

    // MARK: Deletion

    @Test("Deleting a chore reports the chore and its completions")
    func deletingAChoreReportsItsCompletions() async throws {
        // A completion that vanishes with its chore is a row that disappears
        // from the history screen. A subscriber that never heard about it goes
        // on rendering it.
        let f = try await makeFixture()
        let completion = ChoreCompletion(
            householdID: f.household.id,
            choreID: f.chore.id,
            occurrenceDay: clock.today,
            completedBy: f.parent.id,
            completedAt: clock.now,
            pointsAwarded: 10,
            calendar: .testDefault
        )
        try await f.store.save(completion)

        let stream = await f.store.changes(for: f.household.id)
        let changes = try await collect(2, from: stream) {
            try await f.store.deleteChore(f.chore.id)
        }

        #expect(changes.allSatisfy { $0.operation == .deleted })
        #expect(Set(changes.map(\.entity)) == [.chore, .completion])
    }

    @Test("Deleting a record that was never there says nothing")
    func deletingNothingIsSilent() async throws {
        let f = try await makeFixture()
        let stream = await f.store.changes(for: f.household.id)

        let changes = try await collect(1, from: stream) {
            try await f.store.deleteChore(Identifier<Chore>())
            try await f.store.deleteShoppingItem(Identifier<ShoppingItem>())
            try await f.store.save(f.parent.renamed(to: "Jerald A"))
        }

        #expect(changes.map(\.entity) == [.member])
    }

    @Test("Erasing a household reports once and closes the stream")
    func deletingAHouseholdEndsTheStream() async throws {
        // One notification rather than one per orphaned record: a subscriber's
        // only reaction is to reload, and there is nothing left to reload.
        let f = try await makeFixture()
        let stream = await f.store.changes(for: f.household.id)

        let collector = Task {
            var collected: [HouseholdChange] = []
            for await change in stream { collected.append(change) }
            return collected
        }
        try await f.store.deleteHousehold(f.household.id)
        let changes = await collector.value

        #expect(changes.count == 1)
        #expect(changes.first?.entity == .household)
        #expect(changes.first?.operation == .deleted)
        #expect(await f.store.openChangeFeeds == 0)
    }

    // MARK: Subscriptions

    @Test("Two subscribers both hear the same write")
    func subscribersAreIndependent() async throws {
        let f = try await makeFixture()
        let first = await f.store.changes(for: f.household.id)
        let second = await f.store.changes(for: f.household.id)
        #expect(await f.store.openChangeFeeds == 2)

        let firstHeard = Task { await first.first { _ in true } }
        let secondHeard = Task { await second.first { _ in true } }

        // Each stream buffers from the moment it is created, so the write does
        // not have to race the consumers into their loops.
        try await f.store.save(f.parent.renamed(to: "Jerald A"))

        #expect(await firstHeard.value?.entity == .member)
        #expect(await secondHeard.value?.entity == .member)
    }

    @Test("A finished subscription is released")
    func cancelledSubscriptionsAreReleased() async throws {
        // A view that has gone away must not leave a continuation behind for
        // the lifetime of the store.
        let f = try await makeFixture()
        do {
            let stream = await f.store.changes(for: f.household.id)
            let task = Task {
                for await _ in stream { break }
            }
            try await f.store.save(f.parent.renamed(to: "Jerald A"))
            await task.value
        }

        // Termination hops back onto the actor, so give it a turn to land.
        for _ in 0..<100 where await f.store.openChangeFeeds > 0 {
            await Task.yield()
        }
        #expect(await f.store.openChangeFeeds == 0)
    }

    // MARK: Classification

    @Test("Changes say whether they could move the agenda or a balance")
    func changesClassifyThemselves() {
        let householdID = Identifier<Household>()
        func change(_ entity: HouseholdChange.Entity) -> HouseholdChange {
            HouseholdChange(householdID: householdID, entity: entity, recordID: UUID())
        }

        #expect(change(.chore).affectsAgenda)
        #expect(change(.completion).affectsAgenda)
        #expect(!change(.shoppingItem).affectsAgenda)
        #expect(!change(.reward).affectsAgenda)

        #expect(change(.ledgerEntry).affectsBalances)
        #expect(change(.completion).affectsBalances)
        #expect(!change(.chore).affectsBalances)
    }

    // MARK: Snapshot stream

    @Test("The snapshot stream delivers current state before anything changes")
    func snapshotStreamStartsWithTheCurrentState() async throws {
        // A view built on this should have data on its first frame, without a
        // loading state that exists only for that frame.
        let f = try await makeFixture()
        let stream = await f.store.snapshots(of: f.household.id)

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.chores.count == 1)
        #expect(first?.members.count == 1)
    }

    @Test("The snapshot stream re-delivers after a write")
    func snapshotStreamFollowsWrites() async throws {
        let f = try await makeFixture()
        let stream = await f.store.snapshots(of: f.household.id)

        let collector = Task {
            var seen: [Int] = []
            for await snapshot in stream {
                seen.append(snapshot.members.count)
                if seen.count == 2 { break }
            }
            return seen
        }

        // Subscription and first read have both already happened, so this write
        // cannot slip through the gap.
        let sibling = try Member(
            householdID: f.household.id, name: "Sam", role: .child, joinedAt: clock.now
        )
        try await f.store.save(sibling)

        #expect(await collector.value == [1, 2])
    }

    @Test("A filtered snapshot stream sleeps through irrelevant changes")
    func snapshotStreamRespectsItsFilter() async throws {
        let f = try await makeFixture()
        let stream = await f.store.snapshots(of: f.household.id, where: \.affectsAgenda)

        let collector = Task {
            var seen: [Int] = []
            for await snapshot in stream {
                seen.append(snapshot.chores.count)
                if seen.count == 2 { break }
            }
            return seen
        }

        let list = try ShoppingList(
            householdID: f.household.id, name: "Groceries",
            createdBy: f.parent.id, createdAt: clock.now
        )
        // Ignored by the filter.
        try await f.store.save(list)
        // Not ignored.
        let second = try Chore(
            householdID: f.household.id,
            title: "Bins",
            startDate: clock.today,
            recurrence: .daily,
            createdBy: f.parent.id,
            createdAt: clock.now
        )
        try await f.store.save(second)

        #expect(await collector.value == [1, 2])
    }

    @Test("Watching a household that does not exist ends immediately")
    func snapshotStreamOfNothingFinishes() async throws {
        let f = try await makeFixture()
        let stream = await f.store.snapshots(of: Identifier<Household>())

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}
