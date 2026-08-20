import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

@Suite("Household commands")
struct HouseholdCommandsTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault)

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let commands: HouseholdCommands
        let household: Household
        let parent: Member
        let child: Member
        let chore: Chore
        let reward: Reward
        let list: ShoppingList
    }

    private func makeFixture(
        requiresApproval: Bool = false,
        tier: Household.Tier = .plus,
        chorePoints: Int = 10
    ) async throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: tier,
            timeZone: .gmt,
            requiresApproval: requiresApproval,
            createdAt: clock.now
        )
        // Seeded with distinct avatars, mirroring what `addMember` does for
        // every member the app itself creates.
        let parent = try Member(
            householdID: household.id, name: "Jerald", role: .owner,
            avatar: Avatar(color: .blue), joinedAt: clock.now
        )
        let child = try Member(
            householdID: household.id, name: "Sam", role: .child,
            avatar: Avatar(color: .teal), joinedAt: clock.now
        )
        let chore = try Chore(
            householdID: household.id,
            title: "Take out the bins",
            assignment: .member(child.id),
            points: chorePoints,
            startDate: clock.today,
            recurrence: .daily,
            createdBy: parent.id,
            createdAt: clock.now
        )
        let reward = try Reward(
            householdID: household.id,
            name: "Movie night pick",
            cost: 20,
            createdAt: clock.now
        )
        let list = try ShoppingList(
            householdID: household.id,
            name: "Groceries",
            isDefault: true,
            createdBy: parent.id,
            createdAt: clock.now
        )

        let snapshot = HouseholdSnapshot(
            household: household,
            members: [parent, child],
            chores: [chore],
            rewards: [reward],
            shoppingLists: [list]
        )
        let store = InMemoryHouseholdStore(seed: snapshot)
        return Fixture(
            store: store,
            commands: HouseholdCommands(store: store, dateProvider: clock),
            household: household,
            parent: parent,
            child: child,
            chore: chore,
            reward: reward,
            list: list
        )
    }

    // MARK: Completing chores

    @Test("Completing a chore records it and pays the points")
    func completingPaysPoints() async throws {
        let f = try await makeFixture()
        try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.completions.count == 1)
        #expect(snapshot.ledger.balance(for: f.child.id) == 10)
    }

    @Test("Completing the same occurrence twice is refused")
    func doubleCompletionIsRefused() async throws {
        // A double tap, or two devices, must not pay the same Tuesday out
        // twice.
        let f = try await makeFixture()
        try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )

        await #expect(throws: DomainError.alreadyCompleted) {
            try await f.commands.completeChore(
                f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
            )
        }

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.ledger.balance(for: f.child.id) == 10)
    }

    @Test("The same chore on a different day is a separate completion")
    func differentDaysAreSeparate() async throws {
        let f = try await makeFixture()
        try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )
        try await f.commands.completeChore(
            f.chore.id, on: clock.day(offsetFromToday: 1), in: f.household.id, by: f.child.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.completions.count == 2)
        #expect(snapshot.ledger.balance(for: f.child.id) == 20)
    }

    @Test("A chore cannot be completed on a day it is not due")
    func unscheduledDayIsRefused() async throws {
        // The fixture chore is daily, so it needs a schedule with gaps to have
        // a day that genuinely is not an occurrence.
        let f = try await makeFixture()
        let mondaysOnly = try Chore(
            householdID: f.household.id,
            title: "Put the bins out",
            assignment: .member(f.child.id),
            startDate: clock.today,
            recurrence: try RecurrenceRule.weekly(on: [.monday]),
            createdBy: f.parent.id,
            createdAt: clock.now
        )
        try await f.store.save(mondaysOnly)

        // 2 March 2026 is a Monday, so the Tuesday after it is not an occurrence.
        let tuesday = clock.day(offsetFromToday: 1)
        await #expect(throws: DomainError.notScheduled(on: tuesday)) {
            try await f.commands.completeChore(
                mondaysOnly.id, on: tuesday, in: f.household.id, by: f.child.id
            )
        }

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.completions.isEmpty)
        #expect(snapshot.ledger.balance(for: f.child.id) == 0)
    }

    @Test("A skipped day cannot be completed")
    func skippedDayIsRefused() async throws {
        // Skipping is how a family says 'not this week'. Leaving the occurrence
        // completable would make the skip cosmetic — the chore would vanish
        // from the agenda while a widget still holding it could pay it out.
        let f = try await makeFixture()
        try await f.store.save(f.chore.skipping(clock.today, calendar: calendar))

        await #expect(throws: DomainError.notScheduled(on: clock.today)) {
            try await f.commands.completeChore(
                f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
            )
        }
    }

    @Test("An archived chore cannot be completed")
    func archivedChoreIsRefused() async throws {
        // Archiving retires a chore without destroying its history. A stale
        // agenda on another device must not be able to bank points for work
        // the household has stopped asking for.
        let f = try await makeFixture()
        try await f.store.save(f.chore.archived(at: clock.now))

        await #expect(throws: DomainError.notScheduled(on: clock.today)) {
            try await f.commands.completeChore(
                f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
            )
        }
    }

    @Test("A child cannot complete a sibling's chore")
    func siblingCompletionIsRefused() async throws {
        let f = try await makeFixture()
        let sibling = try await f.commands.addMember(
            to: f.household.id, name: "Alex", role: .child, by: f.parent.id
        )

        await #expect(throws: DomainError.notPermitted(action: .completeOthersChore, role: .child))
        {
            try await f.commands.completeChore(
                f.chore.id, on: clock.today, in: f.household.id, by: sibling.id
            )
        }
    }

    @Test("A zero-point chore writes no ledger entry")
    func zeroPointChoreWritesNoEntry() async throws {
        // An empty entry would clutter the history screen with rows that say
        // nothing happened.
        let f = try await makeFixture(chorePoints: 0)
        try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.completions.count == 1)
        #expect(snapshot.ledgerEntries.isEmpty)
    }

    // MARK: Approval

    @Test("With approval on, points are withheld until an adult signs off")
    func approvalWithholdsPoints() async throws {
        // Paying out on a pending completion and clawing it back on rejection
        // shows a child a number that drops for reasons they cannot see.
        let f = try await makeFixture(requiresApproval: true)
        let completion = try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )
        #expect(completion.approval == .pending)

        var snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.ledger.balance(for: f.child.id) == 0)
        #expect(snapshot.reviewQueue.count == 1)

        try await f.commands.approveCompletion(
            completion.id, in: f.household.id, by: f.parent.id
        )

        snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.ledger.balance(for: f.child.id) == 10)
        #expect(snapshot.reviewQueue.isEmpty)
    }

    @Test("Approving twice does not pay twice")
    func doubleApprovalIsIdempotent() async throws {
        // A slow network makes a parent tap approve more than once.
        let f = try await makeFixture(requiresApproval: true)
        let completion = try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )
        try await f.commands.approveCompletion(
            completion.id, in: f.household.id, by: f.parent.id
        )
        try await f.commands.approveCompletion(
            completion.id, in: f.household.id, by: f.parent.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.ledgerEntries.count == 1)
        #expect(snapshot.ledger.balance(for: f.child.id) == 10)
    }

    @Test("Rejecting leaves the points unbanked")
    func rejectionWithholdsPoints() async throws {
        let f = try await makeFixture(requiresApproval: true)
        let completion = try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )
        let rejected = try await f.commands.rejectCompletion(
            completion.id, in: f.household.id, by: f.parent.id, reason: "Bin still full"
        )

        #expect(!rejected.approval.countsTowardBalance)
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.ledger.balance(for: f.child.id) == 0)
    }

    @Test("A chore sent back can be done again")
    func rejectedChoreCanBeRedone() async throws {
        let f = try await makeFixture(requiresApproval: true)
        let first = try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )
        try await f.commands.rejectCompletion(
            first.id, in: f.household.id, by: f.parent.id, reason: "Bin still full"
        )

        let redo = try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )
        #expect(redo.approval == .pending)

        // The redo supersedes the rejection rather than sitting beside it, so
        // the occurrence is still one row and one thing for a parent to review.
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.completions.count == 1)
        #expect(redo.id == first.id)
        #expect(snapshot.reviewQueue.count == 1)

        try await f.commands.approveCompletion(
            redo.id, in: f.household.id, by: f.parent.id
        )
        let settled = try await f.store.snapshot(of: f.household.id)
        #expect(settled.ledger.balance(for: f.child.id) == 10)
        #expect(settled.ledgerEntries.count == 1)
    }

    @Test("A completion that was not rejected still refuses a second attempt")
    func acceptedChoreCannotBeRedone() async throws {
        let f = try await makeFixture(requiresApproval: true)
        let first = try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )
        try await f.commands.approveCompletion(
            first.id, in: f.household.id, by: f.parent.id
        )

        await #expect(throws: DomainError.alreadyCompleted) {
            try await f.commands.completeChore(
                f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
            )
        }
    }

    @Test("An adult's own chore skips the approval queue")
    func adultsSkipApproval() async throws {
        // Requiring a parent to approve their own washing-up is ceremony, and
        // self-approval is refused anyway — so it would deadlock the queue.
        let f = try await makeFixture(requiresApproval: true)
        let parentChore = try Chore(
            householdID: f.household.id,
            title: "Do the washing up",
            assignment: .member(f.parent.id),
            points: 5,
            startDate: clock.today,
            createdBy: f.parent.id,
            createdAt: clock.now
        )
        try await f.store.save(parentChore)

        let completion = try await f.commands.completeChore(
            parentChore.id, on: clock.today, in: f.household.id, by: f.parent.id
        )
        #expect(completion.approval == .notRequired)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.ledger.balance(for: f.parent.id) == 5)
    }

    // MARK: Rewards

    @Test("Redeeming debits points and consumes stock together")
    func redeemingDebitsAndConsumes() async throws {
        let f = try await makeFixture()
        let limited = try Reward(
            householdID: f.household.id,
            name: "Cinema ticket",
            cost: 20,
            remainingRedemptions: 1,
            createdAt: clock.now
        )
        try await f.store.save(limited)
        try await f.commands.adjustPoints(
            for: f.child.id, in: f.household.id, by: f.parent.id, amount: 50
        )

        try await f.commands.redeemReward(limited.id, in: f.household.id, by: f.child.id)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.ledger.balance(for: f.child.id) == 30)
        #expect(snapshot.reward(limited.id)?.remainingRedemptions == 0)

        // The stock is gone, so a second redemption fails even though the
        // child can still afford it.
        await #expect(throws: DomainError.rewardUnavailable(reason: "there are none left")) {
            try await f.commands.redeemReward(limited.id, in: f.household.id, by: f.child.id)
        }
    }

    @Test("Redeeming without enough points reports the shortfall")
    func redeemingReportsShortfall() async throws {
        let f = try await makeFixture()
        try await f.commands.adjustPoints(
            for: f.child.id, in: f.household.id, by: f.parent.id, amount: 8
        )

        await #expect(throws: DomainError.insufficientPoints(balance: 8, required: 20)) {
            try await f.commands.redeemReward(f.reward.id, in: f.household.id, by: f.child.id)
        }
    }

    @Test("A child cannot adjust points")
    func childCannotAdjustPoints() async throws {
        let f = try await makeFixture()
        await #expect(throws: DomainError.notPermitted(action: .adjustPoints, role: .child)) {
            try await f.commands.adjustPoints(
                for: f.child.id, in: f.household.id, by: f.child.id, amount: 1_000
            )
        }
    }

    @Test("A reward not offered to a member is refused")
    func ineligibleRewardIsRefused() async throws {
        let f = try await makeFixture()
        let teenOnly = try Reward(
            householdID: f.household.id,
            name: "Stay up an hour late",
            cost: 5,
            eligibleMemberIDs: [f.parent.id],
            createdAt: clock.now
        )
        try await f.store.save(teenOnly)
        try await f.commands.adjustPoints(
            for: f.child.id, in: f.household.id, by: f.parent.id, amount: 100
        )

        await #expect(throws: DomainError.rewardUnavailable(reason: "it isn't offered to you")) {
            try await f.commands.redeemReward(teenOnly.id, in: f.household.id, by: f.child.id)
        }
    }

    // MARK: Membership

    @Test("The free tier refuses a fourth member and names the limit")
    func freeTierIsEnforced() async throws {
        let f = try await makeFixture(tier: .free)
        try await f.commands.addMember(
            to: f.household.id, name: "Alex", role: .child, by: f.parent.id
        )

        await #expect(throws: DomainError.householdFull(limit: Limits.freeTierMembers)) {
            try await f.commands.addMember(
                to: f.household.id, name: "Jo", role: .child, by: f.parent.id
            )
        }
    }

    @Test("A child cannot invite anyone")
    func childCannotInvite() async throws {
        let f = try await makeFixture()
        await #expect(throws: DomainError.notPermitted(action: .inviteMember, role: .child)) {
            try await f.commands.addMember(
                to: f.household.id, name: "Jo", role: .child, by: f.child.id
            )
        }
    }

    @Test("Removing the last adult is refused")
    func cannotRemoveLastAdult() async throws {
        let f = try await makeFixture()
        await #expect(throws: DomainError.wouldLeaveHouseholdWithoutAdult) {
            try await f.commands.removeMember(
                f.parent.id, from: f.household.id, by: f.parent.id
            )
        }
    }

    @Test("New members get a colour nobody else is using")
    func newMembersGetDistinctColours() async throws {
        let f = try await makeFixture()
        try await f.commands.addMember(
            to: f.household.id, name: "Alex", role: .child, by: f.parent.id
        )
        try await f.commands.addMember(
            to: f.household.id, name: "Jo", role: .teen, by: f.parent.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        let colours = snapshot.activeMembers.map(\.avatar.color)
        #expect(Set(colours).count == colours.count)
    }

    // MARK: Shopping

    @Test("Adding an item already on the list merges instead of duplicating")
    func addingMergesDuplicates() async throws {
        let f = try await makeFixture()
        try await f.commands.addShoppingItem(
            "Milk", quantity: 1, to: f.list.id, in: f.household.id, by: f.parent.id
        )
        let merged = try await f.commands.addShoppingItem(
            " milk ", quantity: 2, to: f.list.id, in: f.household.id, by: f.child.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.shoppingItems.count == 1)
        #expect(merged.quantity == 3)
    }

    @Test("A purchased item does not absorb a newly added one")
    func purchasedItemsDoNotAbsorb() async throws {
        // Milk bought last week must not silently swallow this week's milk.
        let f = try await makeFixture()
        let first = try await f.commands.addShoppingItem(
            "Milk", to: f.list.id, in: f.household.id, by: f.parent.id
        )
        try await f.commands.setShoppingItem(
            first.id, purchased: true, in: f.household.id, by: f.parent.id
        )
        try await f.commands.addShoppingItem(
            "Milk", to: f.list.id, in: f.household.id, by: f.parent.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.shoppingItems.count == 2)
        #expect(snapshot.items(on: f.list.id).pending.count == 1)
    }

    @Test("Even a child can add to the shopping list")
    func childrenCanShop() async throws {
        let f = try await makeFixture()
        try await f.commands.addShoppingItem(
            "Cereal", to: f.list.id, in: f.household.id, by: f.child.id
        )
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.items(on: f.list.id).count == 1)
    }

    // MARK: Missing records

    @Test("Operating on a deleted chore reports it as gone")
    func deletedChoreIsReported() async throws {
        // Another family member deleting a chore while this device shows it is
        // routine, not exceptional.
        let f = try await makeFixture()
        try await f.store.deleteChore(f.chore.id)

        await #expect(throws: DomainError.notFound(entity: "Chore", id: f.chore.id.description)) {
            try await f.commands.completeChore(
                f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
            )
        }
    }

    @Test("Deleting a chore takes its completions with it")
    func deletingChoreRemovesCompletions() async throws {
        let f = try await makeFixture()
        try await f.commands.completeChore(
            f.chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )
        try await f.store.deleteChore(f.chore.id)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.completions.isEmpty)
    }

    @Test("An unknown household is reported, not returned empty")
    func unknownHouseholdThrows() async throws {
        let store = InMemoryHouseholdStore()
        let id = Identifier<Household>()
        await #expect(throws: DomainError.notFound(entity: "Household", id: id.description)) {
            try await store.snapshot(of: id)
        }
    }
}
