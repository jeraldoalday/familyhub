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
    private var redemptionsByID: [Identifier<Redemption>: Redemption] = [:]
    private var shoppingListsByID: [Identifier<ShoppingList>: ShoppingList] = [:]
    private var shoppingItemsByID: [Identifier<ShoppingItem>: ShoppingItem] = [:]
    private var plannedMealsByID: [Identifier<PlannedMeal>: PlannedMeal] = [:]
    private var eventsByID: [Identifier<CalendarEvent>: CalendarEvent] = [:]
    private var coverRequestsByID: [Identifier<CoverRequest>: CoverRequest] = [:]

    /// Open change-feed subscriptions, keyed by a token so each can be removed
    /// when its consumer stops iterating.
    private var subscribers: [UUID: Subscription] = [:]

    /// One open change feed.
    private struct Subscription {
        let householdID: Identifier<Household>
        let continuation: AsyncStream<HouseholdChange>.Continuation
    }

    /// How many unread changes a slow subscriber may accumulate.
    ///
    /// Bounded rather than unlimited, and dropping the *oldest* when full. The
    /// only correct reaction to a change is to reload the snapshot, so a
    /// subscriber that has fallen behind wants the newest notification and does
    /// not care that it missed four earlier ones — it is about to read
    /// everything anyway. An unbounded buffer would instead grow without limit
    /// behind a suspended view.
    private static let changeBufferSize = 32

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
        for redemption in seed.redemptions { redemptionsByID[redemption.id] = redemption }
        for list in seed.shoppingLists { shoppingListsByID[list.id] = list }
        for item in seed.shoppingItems { shoppingItemsByID[item.id] = item }
        for meal in seed.plannedMeals { plannedMealsByID[meal.id] = meal }
        for event in seed.events { eventsByID[event.id] = event }
        for request in seed.coverRequests { coverRequestsByID[request.id] = request }
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
            redemptions: redemptionsByID.values.filter { $0.householdID == householdID },
            shoppingLists: shoppingListsByID.values.filter { $0.householdID == householdID },
            shoppingItems: shoppingItemsByID.values.filter { $0.householdID == householdID },
            plannedMeals: plannedMealsByID.values.filter { $0.householdID == householdID },
            events: eventsByID.values.filter { $0.householdID == householdID },
            coverRequests: coverRequestsByID.values.filter { $0.householdID == householdID }
        )
    }

    public func households() -> [Household] {
        householdsByID.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Writing

    public func save(_ household: Household) {
        householdsByID[household.id] = household
        publish(.upserted(household))
    }

    public func save(_ member: Member) {
        membersByID[member.id] = member
        publish(.upserted(member))
    }

    public func save(_ chore: Chore) {
        choresByID[chore.id] = chore
        publish(.upserted(chore))
    }

    public func save(_ completion: ChoreCompletion) {
        completionsByID[completion.id] = completion
        publish(.upserted(completion))
    }

    public func append(_ entry: LedgerEntry) {
        // Keyed by identifier rather than appended blindly, so a sync that
        // redelivers an entry converges instead of double-counting it.
        ledgerEntriesByID[entry.id] = entry
        publish(.appended(entry))
    }

    public func save(_ reward: Reward) {
        rewardsByID[reward.id] = reward
        publish(.upserted(reward))
    }

    public func save(_ redemption: Redemption) {
        redemptionsByID[redemption.id] = redemption
        publish(.upserted(redemption))
    }

    public func save(_ list: ShoppingList) {
        shoppingListsByID[list.id] = list
        publish(.upserted(list))
    }

    public func save(_ item: ShoppingItem) {
        shoppingItemsByID[item.id] = item
        publish(.upserted(item))
    }

    public func save(_ meal: PlannedMeal) {
        plannedMealsByID[meal.id] = meal
        publish(.upserted(meal))
    }

    public func save(_ event: CalendarEvent) {
        eventsByID[event.id] = event
        publish(.upserted(event))
    }

    public func save(_ request: CoverRequest) {
        coverRequestsByID[request.id] = request
        publish(.upserted(request))
    }

    // MARK: Deleting

    public func deleteChore(_ id: Identifier<Chore>) {
        guard let chore = choresByID[id] else { return }
        choresByID[id] = nil
        // Completions are removed alongside, because a completion pointing at
        // a chore that no longer exists cannot render a row and would sit in
        // the ledger's history as an unexplainable entry.
        for (key, completion) in completionsByID where completion.choreID == id {
            completionsByID[key] = nil
            publish(
                .deleted(.completion, completion.id.rawValue, in: completion.householdID)
            )
        }
        // Cover requests go with them, for the same reason. An ask about a
        // chore that no longer exists cannot render a row and cannot be
        // answered, so leaving it behind would put a permanent unanswerable
        // question on somebody's list.
        for (key, request) in coverRequestsByID where request.choreID == id {
            coverRequestsByID[key] = nil
            publish(.deleted(.coverRequest, request.id.rawValue, in: request.householdID))
        }
        publish(.deleted(.chore, id.rawValue, in: chore.householdID))
    }

    public func deleteShoppingItem(_ id: Identifier<ShoppingItem>) {
        guard let item = shoppingItemsByID[id] else { return }
        shoppingItemsByID[id] = nil
        publish(.deleted(.shoppingItem, id.rawValue, in: item.householdID))
    }

    public func deleteEvent(_ id: Identifier<CalendarEvent>) {
        guard let event = eventsByID[id] else { return }
        eventsByID[id] = nil
        publish(.deleted(.calendarEvent, id.rawValue, in: event.householdID))
    }

    public func deletePlannedMeal(_ id: Identifier<PlannedMeal>) {
        guard let meal = plannedMealsByID[id] else { return }
        plannedMealsByID[id] = nil
        publish(.deleted(.plannedMeal, id.rawValue, in: meal.householdID))
    }

    public func deleteHousehold(_ id: Identifier<Household>) {
        householdsByID[id] = nil
        membersByID = membersByID.filter { $0.value.householdID != id }
        choresByID = choresByID.filter { $0.value.householdID != id }
        completionsByID = completionsByID.filter { $0.value.householdID != id }
        ledgerEntriesByID = ledgerEntriesByID.filter { $0.value.householdID != id }
        rewardsByID = rewardsByID.filter { $0.value.householdID != id }
        redemptionsByID = redemptionsByID.filter { $0.value.householdID != id }
        shoppingListsByID = shoppingListsByID.filter { $0.value.householdID != id }
        shoppingItemsByID = shoppingItemsByID.filter { $0.value.householdID != id }
        plannedMealsByID = plannedMealsByID.filter { $0.value.householdID != id }
        eventsByID = eventsByID.filter { $0.value.householdID != id }
        coverRequestsByID = coverRequestsByID.filter { $0.value.householdID != id }

        // One change for the whole household rather than one per orphaned
        // record. A subscriber's only reaction is to reload, and reloading a
        // household that has just been erased is what ends its stream — so
        // several hundred notifications would all say the same thing to a
        // subscriber that is about to stop listening.
        publish(.deleted(.household, id.rawValue, in: id))
        finishSubscribers(of: id)
    }

    // MARK: Observing

    public func changes(
        for householdID: Identifier<Household>
    ) -> AsyncStream<HouseholdChange> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(Self.changeBufferSize)) {
            continuation in
            subscribers[token] = Subscription(
                householdID: householdID, continuation: continuation
            )
            // The termination handler runs outside the actor, so removal hops
            // back in. Without it a view that has gone away keeps a
            // continuation alive here for the lifetime of the store.
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(token) }
            }
        }
    }

    /// Delivers a change to everyone watching its household.
    private func publish(_ change: HouseholdChange) {
        for subscription in subscribers.values
        where subscription.householdID == change.householdID {
            subscription.continuation.yield(change)
        }
    }

    /// Ends every stream watching a household that no longer exists.
    private func finishSubscribers(of householdID: Identifier<Household>) {
        for (token, subscription) in subscribers
        where subscription.householdID == householdID {
            subscription.continuation.finish()
            subscribers[token] = nil
        }
    }

    /// Drops a subscription whose consumer has stopped iterating.
    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    /// How many change feeds are currently open, for tests that assert a
    /// cancelled subscription is actually released.
    public var openChangeFeeds: Int { subscribers.count }

    // MARK: Introspection

    /// The number of records held, for tests that assert a write did or did not
    /// land without reaching into private state.
    public var recordCount: Int {
        householdsByID.count + membersByID.count + choresByID.count + completionsByID.count
            + ledgerEntriesByID.count + rewardsByID.count + redemptionsByID.count
            + shoppingListsByID.count
            + shoppingItemsByID.count + plannedMealsByID.count + eventsByID.count
            + coverRequestsByID.count
    }
}
