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

    // MARK: Observing

    /// Every change to a household, as it happens.
    ///
    /// Part of the contract rather than an optional extra. A store that cannot
    /// report its own writes leaves every screen either polling or reloading on
    /// appearance, and a chore ticked off on a second device stays invisible
    /// until somebody navigates away and back — which reads as a sync bug and
    /// is impossible to distinguish from one.
    ///
    /// The stream is scoped to one household so a subscriber watching one
    /// family is not woken by another, and it is expected to stay open until
    /// the caller stops iterating. Several callers may observe the same
    /// household at once; each gets its own stream.
    ///
    /// Most callers want ``snapshots(of:where:)`` instead, which turns this
    /// into the reload loop a view model would otherwise write for itself.
    func changes(for householdID: Identifier<Household>) async -> AsyncStream<HouseholdChange>

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

    /// Inserts or replaces a redemption.
    ///
    /// Written by identifier like everything else, which is what makes handing
    /// a reward over convergent: two parents who both confirm the same movie
    /// night from two devices produce one record with one evening on it rather
    /// than a household that owes the film twice.
    func save(_ redemption: Redemption) async throws

    /// Inserts or replaces a shopping list.
    func save(_ list: ShoppingList) async throws

    /// Inserts or replaces a shopping item.
    func save(_ item: ShoppingItem) async throws

    /// Inserts or replaces a calendar event.
    ///
    /// Written by identifier like everything else, so two parents who both
    /// move the dentist appointment converge on one appointment rather than
    /// on two.
    func save(_ event: CalendarEvent) async throws

    /// Inserts or replaces a planned meal.
    ///
    /// Written by identifier like everything else here, so a household that
    /// changes its mind about Thursday replaces Thursday rather than
    /// accumulating a history of dinners it did not have.
    func save(_ meal: PlannedMeal) async throws

    /// Inserts or replaces a cover request.
    ///
    /// Written by identifier, which is what makes answering one convergent:
    /// two siblings accepting at once produce one record with one answer
    /// rather than two arrangements the household has to reconcile.
    func save(_ request: CoverRequest) async throws

    // MARK: Deleting

    /// Permanently removes a chore and its completions.
    ///
    /// Rarely the right call — archiving preserves history and is what the UI
    /// offers — but a household must be able to erase a chore created by
    /// mistake, and privacy law requires a genuine delete to exist.
    func deleteChore(_ id: Identifier<Chore>) async throws

    /// Permanently removes a shopping item.
    func deleteShoppingItem(_ id: Identifier<ShoppingItem>) async throws

    /// Permanently removes a calendar event.
    ///
    /// Rarely the right call — cancelling keeps the entry visible and struck
    /// through, which is what the UI offers — but an event created by mistake
    /// has to be erasable, and privacy law requires a genuine delete to exist.
    func deleteEvent(_ id: Identifier<CalendarEvent>) async throws

    /// Permanently removes a planned meal.
    ///
    /// A genuine delete rather than an archive, for the same reason clearing a
    /// shopping list is one: a plan is a working document, and nobody wants to
    /// scroll past the dinner they changed their mind about in March.
    func deletePlannedMeal(_ id: Identifier<PlannedMeal>) async throws

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

    /// Saves several planned meals in one go.
    public func save(meals: [PlannedMeal]) async throws {
        for meal in meals {
            try await save(meal)
        }
    }

    /// Saves several calendar events in one go.
    public func save(events: [CalendarEvent]) async throws {
        for event in events {
            try await save(event)
        }
    }

    /// Saves several cover requests in one go.
    public func save(coverRequests: [CoverRequest]) async throws {
        for request in coverRequests {
            try await save(request)
        }
    }

    /// Saves several redemptions in one go.
    public func save(redemptions: [Redemption]) async throws {
        for redemption in redemptions {
            try await save(redemption)
        }
    }
}
