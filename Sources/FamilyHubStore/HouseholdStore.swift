import FamilyHubCore
import Foundation

/// The persistence contract.
///
/// Deliberately coarse. Rather than a repository per entity with a query
/// language on top, the store loads a whole household as a
/// ``HouseholdSnapshot`` and accepts writes one record at a time. A household's
/// entire dataset is small enough that this is the faster option in practice,
/// and it collapses an entire category of bug: there is no query to get subtly
/// wrong on one screen and right on another, and no partial state where a view
/// has fresh chores but stale members.
///
/// Writes are single-record and idempotent by identifier, which is what a
/// local-first app needs. Every mutation is an upsert of an immutable value, so
/// replaying the same write twice — as happens when a sync retries — converges
/// rather than duplicating.
public protocol HouseholdStore: Sendable {

    // MARK: Reading

    /// Loads a household and everything belonging to it.
    ///
    /// - Throws: ``DomainError/notFound(entity:id:)`` if no such household
    ///   exists on this device.
    func snapshot(of householdID: Identifier<Household>) async throws -> HouseholdSnapshot

    /// The households present on this device. Usually one; more when a user
    /// belongs to two families.
    func households() async throws -> [Household]

    // MARK: Writing

    /// Inserts or replaces a household.
    func save(_ household: Household) async throws

    /// Inserts or replaces a member.
    func save(_ member: Member) async throws

    /// Inserts or replaces a chore.
    func save(_ chore: Chore) async throws

    /// Inserts or replaces a completion record.
    func save(_ completion: ChoreCompletion) async throws

    /// Appends a ledger entry.
    ///
    /// Named `append` rather than `save` because the ledger is the one thing
    /// here that is never updated in place — an entry that could be edited
    /// would defeat the point of deriving balances from it.
    func append(_ entry: LedgerEntry) async throws

    /// Inserts or replaces a reward.
    func save(_ reward: Reward) async throws

    /// Inserts or replaces a shopping list.
    func save(_ list: ShoppingList) async throws

    /// Inserts or replaces a shopping item.
    func save(_ item: ShoppingItem) async throws

    // MARK: Deleting

    /// Permanently removes a chore and its completions.
    ///
    /// Rarely the right call — archiving preserves history and is what the UI
    /// offers — but a household must be able to erase a chore created by
    /// mistake, and privacy law requires a genuine delete to exist.
    func deleteChore(_ id: Identifier<Chore>) async throws

    /// Permanently removes a shopping item.
    func deleteShoppingItem(_ id: Identifier<ShoppingItem>) async throws

    /// Erases a household and everything in it.
    func deleteHousehold(_ id: Identifier<Household>) async throws
}

// MARK: - Batched writes

extension HouseholdStore {
    /// Saves several members in one go.
    public func save(members: [Member]) async throws {
        for member in members {
            try await save(member)
        }
    }

    /// Saves several chores in one go.
    public func save(chores: [Chore]) async throws {
        for chore in chores {
            try await save(chore)
        }
    }

    /// Saves several shopping items in one go.
    public func save(items: [ShoppingItem]) async throws {
        for item in items {
            try await save(item)
        }
    }
}
