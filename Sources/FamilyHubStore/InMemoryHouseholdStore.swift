import FamilyHubCore
import Foundation

/// A complete ``HouseholdStore`` that keeps everything in memory.
///
/// Not a stub. It implements the full contract, which makes it useful in three
/// places at once: unit tests get a real store with no disk or container to set
/// up, SwiftUI previews get a populated household that renders instantly, and
/// the app's own onboarding can run against it so a family can try the whole
/// product before deciding to keep any of it.
///
/// An actor rather than a lock, so concurrent writes from a sync task and a
/// user tap serialise without either side reasoning about it.
public actor InMemoryHouseholdStore: HouseholdStore {

    private var householdsByID: [Identifier<Household>: Household] = [:]
    private var membersByID: [Identifier<Member>: Member] = [:]
    private var choresByID: [Identifier<Chore>: Chore] = [:]
    private var completionsByID: [Identifier<ChoreCompletion>: ChoreCompletion] = [:]
    private var ledgerEntriesByID: [Identifier<LedgerEntry>: LedgerEntry] = [:]
    private var rewardsByID: [Identifier<Reward>: Reward] = [:]
    private var shoppingListsByID: [Identifier<ShoppingList>: ShoppingList] = [:]
    private var shoppingItemsByID: [Identifier<ShoppingItem>: ShoppingItem] = [:]

    /// Creates an empty store.
    public init() {}

    /// Creates a store already holding a snapshot, for previews and tests.
    public init(seed: HouseholdSnapshot) {
        householdsByID[seed.household.id] = seed.household
        for member in seed.members { membersByID[member.id] = member }
        for chore in seed.chores { choresByID[chore.id] = chore }
        for completion in seed.completions { completionsByID[completion.id] = completion }
        for entry in seed.ledgerEntries { ledgerEntriesByID[entry.id] = entry }
        for reward in seed.rewards { rewardsByID[reward.id] = reward }
        for list in seed.shoppingLists { shoppingListsByID[list.id] = list }
        for item in seed.shoppingItems { shoppingItemsByID[item.id] = item }
    }

    // MARK: Reading

    public func snapshot(of householdID: Identifier<Household>) throws -> HouseholdSnapshot {
        guard let household = householdsByID[householdID] else {
            throw DomainError.notFound(entity: "Household", id: householdID.description)
        }
        return HouseholdSnapshot(
            household: household,
            members: membersByID.values.filter { $0.householdID == householdID },
            chores: choresByID.values.filter { $0.householdID == householdID },
            completions: completionsByID.values.filter { $0.householdID == householdID },
            ledgerEntries: ledgerEntriesByID.values.filter { $0.householdID == householdID },
            rewards: rewardsByID.values.filter { $0.householdID == householdID },
            shoppingLists: shoppingListsByID.values.filter { $0.householdID == householdID },
            shoppingItems: shoppingItemsByID.values.filter { $0.householdID == householdID }
        )
    }

    public func households() -> [Household] {
        householdsByID.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Writing

    public func save(_ household: Household) {
        householdsByID[household.id] = household
    }

    public func save(_ member: Member) {
        membersByID[member.id] = member
    }

    public func save(_ chore: Chore) {
        choresByID[chore.id] = chore
    }

    public func save(_ completion: ChoreCompletion) {
        completionsByID[completion.id] = completion
    }

    public func append(_ entry: LedgerEntry) {
        // Keyed by identifier rather than appended blindly, so a sync that
        // redelivers an entry converges instead of double-counting it.
        ledgerEntriesByID[entry.id] = entry
    }

    public func save(_ reward: Reward) {
        rewardsByID[reward.id] = reward
    }

    public func save(_ list: ShoppingList) {
        shoppingListsByID[list.id] = list
    }

    public func save(_ item: ShoppingItem) {
        shoppingItemsByID[item.id] = item
    }

    // MARK: Deleting

    public func deleteChore(_ id: Identifier<Chore>) {
        choresByID[id] = nil
        // Completions are removed alongside, because a completion pointing at
        // a chore that no longer exists cannot render a row and would sit in
        // the ledger's history as an unexplainable entry.
        for (key, completion) in completionsByID where completion.choreID == id {
            completionsByID[key] = nil
        }
    }

    public func deleteShoppingItem(_ id: Identifier<ShoppingItem>) {
        shoppingItemsByID[id] = nil
    }

    public func deleteHousehold(_ id: Identifier<Household>) {
        householdsByID[id] = nil
        membersByID = membersByID.filter { $0.value.householdID != id }
        choresByID = choresByID.filter { $0.value.householdID != id }
        completionsByID = completionsByID.filter { $0.value.householdID != id }
        ledgerEntriesByID = ledgerEntriesByID.filter { $0.value.householdID != id }
        rewardsByID = rewardsByID.filter { $0.value.householdID != id }
        shoppingListsByID = shoppingListsByID.filter { $0.value.householdID != id }
        shoppingItemsByID = shoppingItemsByID.filter { $0.value.householdID != id }
    }

    // MARK: Introspection

    /// The number of records held, for tests that assert a write did or did not
    /// land without reaching into private state.
    public var recordCount: Int {
        householdsByID.count + membersByID.count + choresByID.count + completionsByID.count
            + ledgerEntriesByID.count + rewardsByID.count + shoppingListsByID.count + shoppingItemsByID.count
    }
}
