import FamilyHubCore
import Foundation

/// Something changed in the store.
///
/// The architecture note has listed this as the one genuinely missing seam
/// since the store contract was written: reads return whole snapshots, with no
/// way to observe deltas. Without it, every screen either polls or reloads on
/// appearance, and a chore ticked off on a second device sits invisible until
/// somebody navigates away and back.
///
/// Deliberately thin. A change says *what kind of record moved and which one*,
/// not what it now contains. Carrying the new value would mean the feed and the
/// snapshot could disagree, which is precisely the class of bug that loading
/// whole snapshots was chosen to avoid — so the only correct reaction to a
/// change is to reload, and the payload exists for filtering and diagnostics
/// rather than for rendering.
public struct HouseholdChange: Sendable, Hashable {

    /// Which kind of record moved.
    public enum Entity: String, Sendable, Hashable, CaseIterable {
        case household
        case member
        case chore
        case completion
        case ledgerEntry
        case reward
        case redemption
        case shoppingList
        case shoppingItem
        case plannedMeal
        case calendarEvent
        case coverRequest
        case awayPeriod
    }

    /// What happened to it.
    public enum Operation: String, Sendable, Hashable, CaseIterable {
        /// Inserted or replaced. The two are one case because every write in
        /// this store is an idempotent upsert, and a caller that needed to tell
        /// them apart would be caching, which is the thing the snapshot model
        /// exists to make unnecessary.
        case upserted

        /// Removed permanently.
        case deleted
    }

    /// The household affected, so a subscriber watching one family is not woken
    /// by another.
    public let householdID: Identifier<Household>

    /// Which kind of record moved.
    public let entity: Entity

    /// The record's raw identifier.
    ///
    /// A bare `UUID` rather than an `Identifier<Something>`, because a single
    /// feed carries every record type in the store and a phantom parameter cannot
    /// vary across them without boxing every element. The typed identifier is
    /// recoverable — `Identifier<Chore>(change.recordID)` — when a caller
    /// already knows the entity, which it does after matching on it.
    public let recordID: UUID

    /// What happened.
    public let operation: Operation

    /// Creates a change record.
    public init(
        householdID: Identifier<Household>,
        entity: Entity,
        recordID: UUID,
        operation: Operation = .upserted
    ) {
        self.householdID = householdID
        self.entity = entity
        self.recordID = recordID
        self.operation = operation
    }

    /// Whether this change could alter what the agenda shows.
    ///
    /// Lets a home screen ignore a shopping item being ticked off in the
    /// kitchen while somebody is looking at today's chores, rather than
    /// rebuilding the whole view for it.
    /// A cover request belongs here because an accepted one moves a chore from
    /// one person's list to another's, which is precisely a change to what the
    /// agenda shows.
    /// An away period belongs here for the same reason: it decides whose list
    /// a chore is on, and whether the row says anybody is here to do it.
    public var affectsAgenda: Bool {
        switch entity {
        case .household, .member, .chore, .completion, .coverRequest, .awayPeriod: true
        case .ledgerEntry, .reward, .redemption, .shoppingList, .shoppingItem, .plannedMeal,
            .calendarEvent:
            false
        }
    }

    /// Whether this change could alter a point balance.
    ///
    /// A redemption is not on this list, and the omission is the interesting
    /// one. Redeeming and refunding both move points, but they move them by
    /// writing a ledger entry — the redemption record only says whether the
    /// reward was ever handed over, which no balance depends on. A rewards
    /// screen wants ``affectsRewards`` instead.
    public var affectsBalances: Bool {
        switch entity {
        case .ledgerEntry, .completion, .member: true
        case .household, .chore, .reward, .redemption, .shoppingList, .shoppingItem, .plannedMeal,
            .calendarEvent, .coverRequest, .awayPeriod:
            false
        }
    }

    /// Whether this change could alter what the rewards screen shows.
    ///
    /// Wider than the balance, because that screen answers three questions at
    /// once: what a member has, what they could spend it on, and what the
    /// household already owes them. A redemption changes the third without
    /// touching the first, and a parent handing over a film that the screen
    /// goes on listing as outstanding is the exact failure this feature exists
    /// to prevent.
    ///
    /// A member matters because a redemption names who it belongs to, and the
    /// household matters because its plan decides whether rewards exist at all.
    public var affectsRewards: Bool {
        switch entity {
        case .reward, .redemption, .ledgerEntry, .completion, .member, .household: true
        case .chore, .shoppingList, .shoppingItem, .plannedMeal, .calendarEvent, .coverRequest,
            .awayPeriod:
            false
        }
    }

    /// Whether this change could alter what is for dinner.
    ///
    /// A member matters here because the meal plan names cooks, and a name that
    /// has changed — or a member who has left — changes what the week grid
    /// reads. The household matters because its calendar decides where the
    /// planning week begins.
    public var affectsMealPlan: Bool {
        switch entity {
        case .plannedMeal, .member, .household: true
        case .chore, .completion, .ledgerEntry, .reward, .redemption, .shoppingList,
            .shoppingItem, .calendarEvent, .coverRequest, .awayPeriod:
            false
        }
    }

    /// Whether this change could alter what the calendar shows.
    ///
    /// A member matters because events name the people they concern, and a
    /// name that has changed — or somebody who has left — changes what a week
    /// reads and who is reported as double-booked. The household matters
    /// because its calendar decides where a week begins and what timezone four
    /// o'clock is four o'clock in.
    public var affectsCalendar: Bool {
        switch entity {
        case .calendarEvent, .member, .household: true
        case .chore, .completion, .ledgerEntry, .reward, .redemption, .shoppingList,
            .shoppingItem, .plannedMeal, .coverRequest, .awayPeriod:
            false
        }
    }
}

// MARK: - Construction from records

extension HouseholdChange {
    /// The change recording that `household` was written.
    public static func upserted(_ household: Household) -> HouseholdChange {
        HouseholdChange(
            householdID: household.id, entity: .household, recordID: household.id.rawValue
        )
    }

    /// The change recording that `member` was written.
    public static func upserted(_ member: Member) -> HouseholdChange {
        HouseholdChange(
            householdID: member.householdID, entity: .member, recordID: member.id.rawValue
        )
    }

    /// The change recording that `chore` was written.
    public static func upserted(_ chore: Chore) -> HouseholdChange {
        HouseholdChange(
            householdID: chore.householdID, entity: .chore, recordID: chore.id.rawValue
        )
    }

    /// The change recording that `completion` was written.
    public static func upserted(_ completion: ChoreCompletion) -> HouseholdChange {
        HouseholdChange(
            householdID: completion.householdID,
            entity: .completion,
            recordID: completion.id.rawValue
        )
    }

    /// The change recording that `entry` was appended.
    public static func appended(_ entry: LedgerEntry) -> HouseholdChange {
        HouseholdChange(
            householdID: entry.householdID, entity: .ledgerEntry, recordID: entry.id.rawValue
        )
    }

    /// The change recording that `reward` was written.
    public static func upserted(_ reward: Reward) -> HouseholdChange {
        HouseholdChange(
            householdID: reward.householdID, entity: .reward, recordID: reward.id.rawValue
        )
    }

    /// The change recording that `redemption` was written.
    public static func upserted(_ redemption: Redemption) -> HouseholdChange {
        HouseholdChange(
            householdID: redemption.householdID,
            entity: .redemption,
            recordID: redemption.id.rawValue
        )
    }

    /// The change recording that `list` was written.
    public static func upserted(_ list: ShoppingList) -> HouseholdChange {
        HouseholdChange(
            householdID: list.householdID, entity: .shoppingList, recordID: list.id.rawValue
        )
    }

    /// The change recording that `item` was written.
    public static func upserted(_ item: ShoppingItem) -> HouseholdChange {
        HouseholdChange(
            householdID: item.householdID, entity: .shoppingItem, recordID: item.id.rawValue
        )
    }

    /// The change recording that `meal` was written.
    public static func upserted(_ meal: PlannedMeal) -> HouseholdChange {
        HouseholdChange(
            householdID: meal.householdID, entity: .plannedMeal, recordID: meal.id.rawValue
        )
    }

    /// The change recording that `event` was written.
    public static func upserted(_ event: CalendarEvent) -> HouseholdChange {
        HouseholdChange(
            householdID: event.householdID, entity: .calendarEvent, recordID: event.id.rawValue
        )
    }

    /// The change recording that `request` was written.
    public static func upserted(_ request: CoverRequest) -> HouseholdChange {
        HouseholdChange(
            householdID: request.householdID,
            entity: .coverRequest,
            recordID: request.id.rawValue
        )
    }

    /// The change recording that `period` was written.
    public static func upserted(_ period: AwayPeriod) -> HouseholdChange {
        HouseholdChange(
            householdID: period.householdID,
            entity: .awayPeriod,
            recordID: period.id.rawValue
        )
    }

    /// The change recording that a record was removed.
    public static func deleted(
        _ entity: Entity,
        _ recordID: UUID,
        in householdID: Identifier<Household>
    ) -> HouseholdChange {
        HouseholdChange(
            householdID: householdID, entity: entity, recordID: recordID, operation: .deleted
        )
    }
}

// MARK: - Observing

extension HouseholdStore {
    /// A stream of snapshots: the household as it stands now, and again after
    /// every change to it.
    ///
    /// This is what a view model actually wants, and building it here means no
    /// screen has to write the reload-on-change loop for itself — which is the
    /// loop most likely to be written slightly differently on each screen and
    /// leave one of them stale.
    ///
    /// The call subscribes to the change feed *before* reading the first
    /// snapshot, and both have happened by the time it returns. That ordering
    /// is what makes the stream safe to build and then immediately write
    /// against: a change landing in the gap is included in the first snapshot
    /// and also delivers a second, identical one, which is a wasted render and
    /// not a missed update. Reading first would lose the write entirely, which
    /// is the failure that looks like a sync bug.
    ///
    /// The first element is already buffered when the call returns, so a view
    /// has data on its first frame without a loading state that exists only for
    /// that frame.
    ///
    /// - Parameters:
    ///   - householdID: The household to watch.
    ///   - filter: Which changes are worth a reload. Defaults to all of them; a
    ///     home screen can pass `\.affectsAgenda` to sleep through a shopping
    ///     list being edited in another room.
    /// - Returns: A stream that ends when the household is erased, or when the
    ///   store's change feed does.
    public func snapshots(
        of householdID: Identifier<Household>,
        where filter: @escaping @Sendable (HouseholdChange) -> Bool = { _ in true }
    ) async -> AsyncStream<HouseholdSnapshot> {
        let feed = await changes(for: householdID)
        // A household that never existed, or has just been erased, ends the
        // stream rather than reporting an error: there is nothing to observe,
        // and a view observing nothing should unwind rather than show an alert.
        let initial = try? await snapshot(of: householdID)

        return AsyncStream { continuation in
            guard let initial else {
                continuation.finish()
                return
            }
            continuation.yield(initial)

            let task = Task {
                for await change in feed {
                    guard filter(change) else { continue }
                    guard let updated = try? await snapshot(of: householdID) else { break }
                    continuation.yield(updated)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
