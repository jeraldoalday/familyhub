import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

@Suite("Demo household")
struct DemoHouseholdTests {

    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    @Test("Builds a populated household")
    func buildsPopulatedHousehold() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        #expect(snapshot.activeMembers.count == 4)
        #expect(snapshot.activeChores.count == 6)
        #expect(!snapshot.rewards.isEmpty)
        #expect(!snapshot.shoppingItems.isEmpty)
        #expect(!snapshot.ledgerEntries.isEmpty)
    }

    @Test("Is deterministic")
    func isDeterministic() throws {
        // App Store screenshots have to reproduce across locales and device
        // sizes, and a preview that reshuffles on every rebuild is one nobody
        // trusts. Identifiers are fresh each build; the shape must not be.
        let first = try DemoHousehold.snapshot(asOf: clock)
        let second = try DemoHousehold.snapshot(asOf: clock)

        #expect(first.activeMembers.map(\.name.value) == second.activeMembers.map(\.name.value))
        #expect(first.completions.count == second.completions.count)
        #expect(first.ledgerEntries.count == second.ledgerEntries.count)
        #expect(
            first.ledger.balance(for: first.activeMembers[0].id)
                == second.ledger.balance(for: second.activeMembers[0].id)
        )
    }

    @Test("Today's agenda has work on it")
    func todayHasWork() throws {
        // A demo that opens on an empty list shows none of the product.
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        #expect(!snapshot.agenda(for: clock.today).isEmpty)
    }

    @Test("The review queue is not empty")
    func reviewQueueIsPopulated() throws {
        // The approvals screen is the one most people never find on their own.
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        #expect(snapshot.reviewQueue.count == 1)
    }

    @Test("Balances are positive but short of the priciest reward")
    func balancesLeaveSomethingToAimAt() throws {
        // A demo where everything is affordable shows no goal, and one where
        // nothing is affordable shows no payoff.
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let balances = snapshot.activeMembers.map { snapshot.ledger.balance(for: $0.id) }
        let mostExpensive = try #require(snapshot.rewards.map(\.cost).max())

        #expect(balances.contains { $0 > 0 })
        #expect(balances.allSatisfy { $0 < mostExpensive })
    }

    @Test("The shopping list has both bought and outstanding items")
    func shoppingListIsMidTrip() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let list = try #require(snapshot.shoppingLists.first { $0.isDefault })
        let items = snapshot.items(on: list.id)
        #expect(!items.pending.isEmpty)
        #expect(!items.purchased.isEmpty)
    }

    @Test("The rotating chore alternates between the children")
    func rotationIsVisible() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let bins = try #require(
            snapshot.chores.first { $0.title.value == "Take out the bins" }
        )
        guard case .rotating(let ids) = bins.assignment else {
            Issue.record("Expected the bins chore to rotate")
            return
        }
        #expect(ids.count == 2)
        #expect(bins.assignee(forOccurrenceIndex: 0) != bins.assignee(forOccurrenceIndex: 1))
    }

    @Test("Seeds a store that reads back identically")
    func seedsAStore() async throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let store = InMemoryHouseholdStore(seed: snapshot)
        let reloaded = try await store.snapshot(of: snapshot.household.id)

        #expect(reloaded.members.count == snapshot.members.count)
        #expect(reloaded.chores.count == snapshot.chores.count)
        #expect(reloaded.completions.count == snapshot.completions.count)
        #expect(reloaded.shoppingItems.count == snapshot.shoppingItems.count)
    }

    @Test("Commands run against the demo household")
    func commandsWorkOnDemoData() async throws {
        // The guided tour drives the real command layer, so the demo has to
        // survive being used rather than only being looked at.
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let store = InMemoryHouseholdStore(seed: snapshot)
        let commands = HouseholdCommands(store: store, dateProvider: clock)

        let parent = try #require(snapshot.activeMembers.first { $0.role == .owner })
        let pending = try #require(snapshot.reviewQueue.first)

        try await commands.approveCompletion(
            pending.id, in: snapshot.household.id, by: parent.id
        )

        let after = try await store.snapshot(of: snapshot.household.id)
        #expect(after.reviewQueue.isEmpty)
        #expect(after.ledger.balance(for: pending.completedBy) > 0)
    }
}
