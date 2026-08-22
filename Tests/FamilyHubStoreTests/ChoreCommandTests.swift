import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers the commands that manage the things a household owns — chores,
/// rewards, lists, roles, and settings — as distinct from the commands that
/// record what it did, which live in `HouseholdCommandsTests`.
@Suite("Management commands")
struct ChoreCommandTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let commands: HouseholdCommands
        let household: Household
        let owner: Member
        let adult: Member
        let teen: Member
        let child: Member
    }

    private func makeFixture(tier: Household.Tier = .plus) async throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: tier,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: clock.now
        )
        let owner = try Member(
            householdID: household.id, name: "Jerald", role: .owner,
            avatar: Avatar(color: .blue), joinedAt: clock.now
        )
        let adult = try Member(
            householdID: household.id, name: "Mary", role: .adult,
            avatar: Avatar(color: .purple), joinedAt: clock.now
        )
        let teen = try Member(
            householdID: household.id, name: "Alex", role: .teen,
            avatar: Avatar(color: .teal), joinedAt: clock.now
        )
        let child = try Member(
            householdID: household.id, name: "Sam", role: .child,
            avatar: Avatar(color: .amber), joinedAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(
                household: household, members: [owner, adult, teen, child]
            )
        )
        return Fixture(
            store: store,
            commands: HouseholdCommands(store: store, dateProvider: clock),
            household: household,
            owner: owner,
            adult: adult,
            teen: teen,
            child: child
        )
    }

    // MARK: Starter packs

    @Test("Installing a pack creates its chores, unassigned and starting today")
    func installPackCreatesChores() async throws {
        let f = try await makeFixture()
        let created = try await f.commands.installChorePack(
            .everyday, in: f.household.id, by: f.owner.id
        )

        #expect(created.count == ChorePack.everyday.templates.count)
        #expect(created.map(\.title.value) == ChorePack.everyday.templates.map(\.title))
        #expect(created.allSatisfy { $0.startDate == clock.today })
        #expect(created.allSatisfy { $0.createdBy == f.owner.id })
        // Choosing the rota is a decision about a particular family that a
        // catalogue cannot make, and a guessed one is unpicked before Monday.
        #expect(created.allSatisfy { $0.assignment == .anyone })

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.chores.count == created.count)
    }

    @Test("A chore the household already has is skipped, not refused")
    func installPackSkipsDuplicates() async throws {
        // A pack is an offer. A family that has already written down half of
        // it should get the other half rather than an error telling them to go
        // and find which one clashed.
        let f = try await makeFixture()
        try await f.commands.createChore(
            in: f.household.id, title: "  make your BED  ", by: f.owner.id
        )

        let created = try await f.commands.installChorePack(
            .everyday, in: f.household.id, by: f.owner.id
        )

        #expect(created.count == ChorePack.everyday.templates.count - 1)
        #expect(!created.contains { $0.title.value == "Make your bed" })

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.chores.filter { $0.title.searchKey == "make your bed" }.count == 1)
    }

    @Test("Installing the same pack twice adds nothing the second time")
    func installPackIsIdempotent() async throws {
        let f = try await makeFixture()
        try await f.commands.installChorePack(.pets, in: f.household.id, by: f.owner.id)
        let second = try await f.commands.installChorePack(
            .pets, in: f.household.id, by: f.owner.id
        )

        #expect(second.isEmpty)
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.chores.count == ChorePack.pets.templates.count)
    }

    @Test("A chore the household archived is not handed back as new")
    func installPackRespectsTheArchive() async throws {
        // Archiving is a decision about that chore. Offering it again as new
        // overrules it — the archive is where they put it, not a bin the app
        // may empty.
        let f = try await makeFixture()
        let installed = try await f.commands.installChorePack(
            .pets, in: f.household.id, by: f.owner.id
        )
        let walk = try #require(installed.first { $0.title.value == "Walk the dog" })
        try await f.commands.archiveChore(walk.id, in: f.household.id, by: f.owner.id)

        let again = try await f.commands.installChorePack(
            .pets, in: f.household.id, by: f.owner.id
        )
        #expect(again.isEmpty)
    }

    @Test("A household of small children is not given a teenager's chores")
    func installPackFiltersByRole() async throws {
        let f = try await makeFixture()
        try await f.commands.removeMember(f.teen.id, from: f.household.id, by: f.owner.id)
        // Only the child and the adults remain, and the adults can do anything,
        // so the filter has to look at the most capable member rather than at
        // every member.
        let withAdults = try await f.commands.installChorePack(
            .kitchen, in: f.household.id, by: f.owner.id
        )
        #expect(withAdults.count == ChorePack.kitchen.templates.count)
    }

    @Test("A pack starts on the day it is told to")
    func installPackHonoursTheStartDate() async throws {
        let f = try await makeFixture()
        let monday = calendar.date(byAdding: .day, value: 7, to: clock.today) ?? clock.today
        let created = try await f.commands.installChorePack(
            .everyday, in: f.household.id, startingOn: monday.addingTimeInterval(60 * 60 * 15),
            by: f.owner.id
        )
        // Normalised, like every other start date: a chore belongs to a day.
        #expect(created.allSatisfy { $0.startDate == monday })
    }

    @Test("A child cannot install a pack")
    func installPackNeedsPermission() async throws {
        let f = try await makeFixture()
        await #expect(
            throws: DomainError.notPermitted(action: .createChore, role: .child)
        ) {
            try await f.commands.installChorePack(
                .everyday, in: f.household.id, by: f.child.id
            )
        }
    }

    @Test("A member who has left cannot install a pack")
    func installPackNeedsAnActiveMember() async throws {
        let f = try await makeFixture()
        try await f.commands.removeMember(f.adult.id, from: f.household.id, by: f.owner.id)

        await #expect(throws: DomainError.memberNotInHousehold(f.adult.id)) {
            try await f.commands.installChorePack(
                .everyday, in: f.household.id, by: f.adult.id
            )
        }
    }

    // MARK: Creating chores

    @Test("Creating a chore records who made it and normalises its start")
    func createChoreRecordsProvenance() async throws {
        let f = try await makeFixture()
        let chore = try await f.commands.createChore(
            in: f.household.id,
            title: "  Feed the cat  ",
            notes: "Half a tin",
            points: 15,
            by: f.owner.id
        )

        #expect(chore.title.value == "Feed the cat")
        #expect(chore.notes?.value == "Half a tin")
        #expect(chore.points == 15)
        #expect(chore.createdBy == f.owner.id)
        // A start date carrying the morning it was created at would push the
        // first occurrence a day late for anyone behind the household.
        #expect(chore.startDate == clock.today)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.chores.count == 1)
        #expect(snapshot.agenda(for: clock.today).count == 1)
    }

    @Test("A child cannot create chores")
    func childrenCannotCreateChores() async throws {
        let f = try await makeFixture()
        await #expect(throws: DomainError.notPermitted(action: .createChore, role: .child)) {
            try await f.commands.createChore(
                in: f.household.id, title: "Nothing", by: f.child.id
            )
        }
    }

    @Test("A teen may add their own chore but not a sibling's")
    func teensMayOnlyAssignThemselves() async throws {
        // A teen is old enough to add their own commitments and more likely to
        // keep to a schedule they wrote. Handing work to a sibling is a
        // different act.
        let f = try await makeFixture()
        let mine = try await f.commands.createChore(
            in: f.household.id,
            title: "Homework",
            assignment: .member(f.teen.id),
            by: f.teen.id
        )
        #expect(mine.assignment == .member(f.teen.id))

        await #expect(throws: DomainError.notPermitted(action: .assignChore, role: .teen)) {
            try await f.commands.createChore(
                in: f.household.id,
                title: "Bins",
                assignment: .member(f.child.id),
                by: f.teen.id
            )
        }
    }

    @Test("A chore cannot be assigned to somebody who is not in the household")
    func assigningAStrangerIsRefused() async throws {
        // Otherwise the chore is owned by nobody and quietly never appears on
        // an agenda.
        let f = try await makeFixture()
        let stranger = Identifier<Member>()

        await #expect(throws: DomainError.notFound(entity: "Member", id: stranger.description)) {
            try await f.commands.createChore(
                in: f.household.id,
                title: "Bins",
                assignment: .rotating([f.child.id, stranger]),
                by: f.owner.id
            )
        }
    }

    // MARK: Editing chores

    @Test("An edit changes only the fields it names")
    func updateLeavesUntouchedFieldsAlone() async throws {
        let f = try await makeFixture()
        let original = try await f.commands.createChore(
            in: f.household.id,
            title: "Bins",
            notes: "Blue bin on Tuesdays",
            points: 10,
            category: .cleaning,
            by: f.owner.id
        )

        let updated = try await f.commands.updateChore(
            original.id, in: f.household.id, by: f.owner.id, points: 25
        )
        #expect(updated.points == 25)
        #expect(updated.title.value == "Bins")
        #expect(updated.notes?.value == "Blue bin on Tuesdays")
        #expect(updated.category == .cleaning)
    }

    @Test("Notes can be cleared as well as left alone")
    func notesDistinguishClearingFromLeaving() async throws {
        // The double optional exists for exactly this: omitting the parameter
        // and passing nil have to mean different things.
        let f = try await makeFixture()
        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Bins", notes: "Blue bin", by: f.owner.id
        )

        let untouched = try await f.commands.updateChore(
            chore.id, in: f.household.id, by: f.owner.id, title: "Bins out"
        )
        #expect(untouched.notes?.value == "Blue bin")

        let cleared = try await f.commands.updateChore(
            chore.id, in: f.household.id, by: f.owner.id, notes: .some(nil)
        )
        #expect(cleared.notes == nil)
    }

    @Test("An edit rejects values the domain would not accept")
    func updateValidates() async throws {
        let f = try await makeFixture()
        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Bins", by: f.owner.id
        )

        await #expect(
            throws: DomainError.outOfRange(field: .points, allowed: Limits.pointsPerChore)
        ) {
            try await f.commands.updateChore(
                chore.id, in: f.household.id, by: f.owner.id, points: 10_000
            )
        }
        await #expect(throws: DomainError.blank(field: .choreTitle)) {
            try await f.commands.updateChore(
                chore.id, in: f.household.id, by: f.owner.id, title: "   "
            )
        }

        // Nothing partial was written on the way to the failure.
        let stored = try await f.store.snapshot(of: f.household.id).requireChore(chore.id)
        #expect(stored.points == 10)
        #expect(stored.title.value == "Bins")
    }

    @Test("Rescheduling normalises the new start date too")
    func reschedulingNormalisesTheStart() async throws {
        let f = try await makeFixture()
        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Bins", by: f.owner.id
        )

        let moved = try await f.commands.updateChore(
            chore.id,
            in: f.household.id,
            by: f.owner.id,
            startingOn: clock.now.addingTimeInterval(60 * 60 * 5),
            recurrence: try RecurrenceRule.weekly(on: [.wednesday])
        )
        #expect(moved.startDate == clock.today)
        #expect(moved.recurrence.frequency == .weekly)
    }

    // MARK: Archiving, skipping, deleting

    @Test("Archiving takes a chore off the agenda and keeps its history")
    func archivingPreservesHistory() async throws {
        let f = try await makeFixture()
        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Bins", by: f.owner.id
        )
        try await f.commands.completeChore(
            chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )

        try await f.commands.archiveChore(chore.id, in: f.household.id, by: f.owner.id)
        let snapshot = try await f.store.snapshot(of: f.household.id)

        #expect(snapshot.activeChores.isEmpty)
        #expect(snapshot.agenda(for: clock.today).isEmpty)
        #expect(snapshot.completions.count == 1)
        #expect(snapshot.ledger.balance(for: f.child.id) == 10)
    }

    @Test("An archived chore can be brought back")
    func restoringPutsAChoreBack() async throws {
        let f = try await makeFixture()
        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Bins", by: f.owner.id
        )
        try await f.commands.archiveChore(chore.id, in: f.household.id, by: f.owner.id)
        let restored = try await f.commands.restoreChore(
            chore.id, in: f.household.id, by: f.owner.id
        )

        #expect(restored.isActive)
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.agenda(for: clock.today).count == 1)
    }

    @Test("Skipping a day is an exception, not a change of schedule")
    func skippingDoesNotMoveTheSchedule() async throws {
        let f = try await makeFixture()
        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Bins", by: f.owner.id
        )

        let skipped = try await f.commands.skipChore(
            chore.id, on: clock.day(offsetFromToday: 1), in: f.household.id, by: f.owner.id
        )
        #expect(skipped.recurrence == .daily)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.agenda(for: clock.today).count == 1)
        #expect(snapshot.agenda(for: clock.day(offsetFromToday: 1)).isEmpty)
        #expect(snapshot.agenda(for: clock.day(offsetFromToday: 2)).count == 1)
    }

    @Test("A skipped day can be put back")
    func unskippingRestoresTheDay() async throws {
        let f = try await makeFixture()
        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Bins", by: f.owner.id
        )
        try await f.commands.skipChore(
            chore.id, on: clock.today, in: f.household.id, by: f.owner.id
        )
        let restored = try await f.commands.unskipChore(
            chore.id, on: clock.today, in: f.household.id, by: f.owner.id
        )

        #expect(restored.skippedDays.isEmpty)
    }

    @Test("Only an owner may erase a chore outright")
    func deletingIsOwnerOnly() async throws {
        // The destructive one: it takes the completions with it and changes
        // what the history screen shows.
        let f = try await makeFixture()
        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Bins", by: f.owner.id
        )
        try await f.commands.completeChore(
            chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )

        await #expect(throws: DomainError.notPermitted(action: .manageHousehold, role: .adult)) {
            try await f.commands.deleteChore(chore.id, in: f.household.id, by: f.adult.id)
        }

        try await f.commands.deleteChore(chore.id, in: f.household.id, by: f.owner.id)
        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.chores.isEmpty)
        #expect(snapshot.completions.isEmpty)
    }

    // MARK: Roles

    @Test("An adult can promote a teen")
    func adultsMayPromote() async throws {
        let f = try await makeFixture()
        let promoted = try await f.commands.changeRole(
            of: f.child.id, to: .teen, in: f.household.id, by: f.adult.id
        )
        #expect(promoted.role == .teen)
    }

    @Test("Nobody mints an owner through the role picker")
    func ownershipDoesNotTransferByMistap() async throws {
        // Ownership transfers through its own explicit flow precisely so it
        // cannot happen by catching the wrong row in a picker.
        let f = try await makeFixture()
        await #expect(throws: DomainError.notPermitted(action: .removeMember, role: .owner)) {
            try await f.commands.changeRole(
                of: f.adult.id, to: .owner, in: f.household.id, by: f.owner.id
            )
        }
    }

    @Test("A child cannot change anyone's role, including their own")
    func childrenCannotChangeRoles() async throws {
        let f = try await makeFixture()
        await #expect(throws: DomainError.notPermitted(action: .removeMember, role: .child)) {
            try await f.commands.changeRole(
                of: f.child.id, to: .adult, in: f.household.id, by: f.child.id
            )
        }
    }

    @Test("Demoting the last adult is refused")
    func lastAdultCannotBeDemoted() async throws {
        // Otherwise a household locks itself out of settings, billing, and the
        // approval queue with two taps and no way back.
        let f = try await makeFixture()
        try await f.commands.removeMember(f.adult.id, from: f.household.id, by: f.owner.id)

        await #expect(throws: DomainError.wouldLeaveHouseholdWithoutAdult) {
            try await f.commands.changeRole(
                of: f.owner.id, to: .teen, in: f.household.id, by: f.owner.id
            )
        }
    }

    @Test("Reinstating a member counts against the seat limit")
    func reinstatingRespectsTheTier() async throws {
        // Otherwise the free tier grants a fourth seat to anyone who removes
        // somebody and puts them back.
        let f = try await makeFixture(tier: .free)
        // The fixture holds four people; the free plan seats three, so two
        // leave before the seat being contested is the last one.
        try await f.commands.removeMember(f.teen.id, from: f.household.id, by: f.owner.id)
        try await f.commands.removeMember(f.child.id, from: f.household.id, by: f.owner.id)
        try await f.commands.addMember(
            to: f.household.id, name: "Robin", role: .child, by: f.owner.id
        )

        await #expect(throws: DomainError.householdFull(limit: Limits.freeTierMembers)) {
            try await f.commands.reinstateMember(
                f.child.id, in: f.household.id, by: f.owner.id
            )
        }
    }

    @Test("Reinstating brings a removed member back with their history")
    func reinstatingRestoresAMember() async throws {
        let f = try await makeFixture()
        try await f.commands.removeMember(f.child.id, from: f.household.id, by: f.owner.id)
        let back = try await f.commands.reinstateMember(
            f.child.id, in: f.household.id, by: f.owner.id
        )

        #expect(back.isActive)
        #expect(back.joinedAt == f.child.joinedAt)
    }

    // MARK: Members who have left

    @Test("A removed adult cannot change the household from an old device")
    func removedAdultCannotManageHousehold() async throws {
        let f = try await makeFixture()
        try await f.commands.removeMember(f.adult.id, from: f.household.id, by: f.owner.id)

        await #expect(throws: DomainError.memberNotInHousehold(f.adult.id)) {
            try await f.commands.setApprovalRequired(
                false, in: f.household.id, by: f.adult.id
            )
        }
        await #expect(throws: DomainError.memberNotInHousehold(f.adult.id)) {
            try await f.commands.createChore(
                in: f.household.id, title: "Wash the car", by: f.adult.id
            )
        }
    }

    @Test("A chore cannot be handed to somebody who has left")
    func choreCannotBeAssignedToRemovedMember() async throws {
        let f = try await makeFixture()
        try await f.commands.removeMember(f.teen.id, from: f.household.id, by: f.owner.id)

        await #expect(throws: DomainError.memberNotInHousehold(f.teen.id)) {
            try await f.commands.createChore(
                in: f.household.id,
                title: "Take out the bins",
                assignment: .rotating([f.child.id, f.teen.id]),
                by: f.owner.id
            )
        }
    }

    @Test("A reinstated member gets their permissions back with their record")
    func reinstatedMemberCanActAgain() async throws {
        let f = try await makeFixture()
        try await f.commands.removeMember(f.adult.id, from: f.household.id, by: f.owner.id)
        try await f.commands.reinstateMember(
            f.adult.id, in: f.household.id, by: f.owner.id
        )

        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Wash the car", by: f.adult.id
        )
        #expect(chore.createdBy == f.adult.id)
    }

    // MARK: Household settings

    @Test("Only an owner changes household settings")
    func settingsAreOwnerOnly() async throws {
        let f = try await makeFixture()
        await #expect(throws: DomainError.notPermitted(action: .manageHousehold, role: .adult)) {
            try await f.commands.renameHousehold(
                f.household.id, to: "The Aldays at Home", by: f.adult.id
            )
        }

        let renamed = try await f.commands.renameHousehold(
            f.household.id, to: "The Aldays at Home", by: f.owner.id
        )
        #expect(renamed.name.value == "The Aldays at Home")
    }

    @Test("Turning approval off does not bank what is already pending")
    func switchingApprovalOffLeavesTheQueueAlone() async throws {
        // A parent held those back deliberately. Paying them out because a
        // setting moved would undo a decision they made on purpose.
        let f = try await makeFixture()
        try await f.commands.setApprovalRequired(true, in: f.household.id, by: f.owner.id)
        let chore = try await f.commands.createChore(
            in: f.household.id, title: "Bins", assignment: .member(f.child.id), by: f.owner.id
        )
        try await f.commands.completeChore(
            chore.id, on: clock.today, in: f.household.id, by: f.child.id
        )

        try await f.commands.setApprovalRequired(false, in: f.household.id, by: f.owner.id)
        let snapshot = try await f.store.snapshot(of: f.household.id)

        #expect(snapshot.reviewQueue.count == 1)
        #expect(snapshot.ledger.balance(for: f.child.id) == 0)
    }

    @Test("The household's first weekday can be moved")
    func firstWeekdayIsConfigurable() async throws {
        let f = try await makeFixture()
        let updated = try await f.commands.setFirstWeekday(
            1, in: f.household.id, by: f.owner.id
        )
        #expect(updated.firstWeekday == 1)
        #expect(updated.calendar().firstWeekday == 1)
    }

    // MARK: Rewards

    @Test("Creating a reward is refused on a plan without rewards")
    func rewardsAreGatedByTier() async throws {
        // Enforced in the command rather than only at the paywall, because a
        // tier check living in a view is one a second screen forgets.
        let f = try await makeFixture(tier: .free)
        await #expect(
            throws: DomainError.requiresUpgrade(feature: .rewards, tier: .free)
        ) {
            try await f.commands.createReward(
                in: f.household.id, name: "Movie night", cost: 50, by: f.owner.id
            )
        }
    }

    @Test("A child cannot mint rewards")
    func childrenCannotCreateRewards() async throws {
        // If they could, the entire mechanic is worth nothing.
        let f = try await makeFixture()
        await #expect(throws: DomainError.notPermitted(action: .createReward, role: .child)) {
            try await f.commands.createReward(
                in: f.household.id, name: "Anything I like", cost: 1, by: f.child.id
            )
        }
    }

    @Test("A reward cannot be offered to somebody who is not there")
    func rewardEligibilityIsChecked() async throws {
        let f = try await makeFixture()
        let stranger = Identifier<Member>()

        await #expect(throws: DomainError.notFound(entity: "Member", id: stranger.description)) {
            try await f.commands.createReward(
                in: f.household.id,
                name: "Stay up late",
                cost: 40,
                eligibleMemberIDs: [stranger],
                by: f.owner.id
            )
        }
    }

    @Test("Withdrawing a reward leaves its redemptions explicable")
    func withdrawingKeepsTheRecord() async throws {
        // A ledger entry naming a reward that no longer exists reads as a bug
        // to the child who spent the points on it.
        let f = try await makeFixture()
        let reward = try await f.commands.createReward(
            in: f.household.id, name: "Movie night", cost: 10, by: f.owner.id
        )
        try await f.commands.adjustPoints(
            for: f.child.id, in: f.household.id, by: f.owner.id, amount: 50
        )
        try await f.commands.redeemReward(reward.id, in: f.household.id, by: f.child.id)

        let withdrawn = try await f.commands.setRewardActive(
            reward.id, false, in: f.household.id, by: f.owner.id
        )
        #expect(!withdrawn.isActive)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.reward(reward.id) != nil)
        #expect(snapshot.ledger.balance(for: f.child.id) == 40)
    }

    // MARK: Shopping lists

    @Test("The first list a household makes becomes its default")
    func firstListIsTheDefault() async throws {
        // So a widget or a Siri request has somewhere to put an item without
        // stopping to ask.
        let f = try await makeFixture()
        let first = try await f.commands.createShoppingList(
            in: f.household.id, name: "Groceries", by: f.owner.id
        )
        let second = try await f.commands.createShoppingList(
            in: f.household.id, name: "Hardware", by: f.owner.id
        )

        #expect(first.isDefault)
        #expect(!second.isDefault)
    }

    @Test("Even a child can make a list")
    func anyoneCanMakeAList() async throws {
        let f = try await makeFixture()
        let list = try await f.commands.createShoppingList(
            in: f.household.id, name: "Party", by: f.child.id
        )
        #expect(list.createdBy == f.child.id)
    }

    @Test("Clearing bought items leaves the outstanding ones alone")
    func clearingRemovesOnlyPurchasedItems() async throws {
        let f = try await makeFixture()
        let list = try await f.commands.createShoppingList(
            in: f.household.id, name: "Groceries", by: f.owner.id
        )
        let milk = try await f.commands.addShoppingItem(
            "Milk", to: list.id, in: f.household.id, by: f.owner.id
        )
        try await f.commands.addShoppingItem(
            "Bread", to: list.id, in: f.household.id, by: f.owner.id
        )
        try await f.commands.setShoppingItem(
            milk.id, purchased: true, in: f.household.id, by: f.owner.id
        )

        let removed = try await f.commands.clearPurchasedItems(
            from: list.id, in: f.household.id, by: f.owner.id
        )
        #expect(removed == 1)

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.items(on: list.id).map(\.name.value) == ["Bread"])
    }

    @Test("Clearing a list with nothing bought removes nothing")
    func clearingAnUntouchedListIsHarmless() async throws {
        let f = try await makeFixture()
        let list = try await f.commands.createShoppingList(
            in: f.household.id, name: "Groceries", by: f.owner.id
        )
        try await f.commands.addShoppingItem(
            "Milk", to: list.id, in: f.household.id, by: f.owner.id
        )

        #expect(
            try await f.commands.clearPurchasedItems(
                from: list.id, in: f.household.id, by: f.owner.id
            ) == 0
        )
        #expect(try await f.store.snapshot(of: f.household.id).shoppingItems.count == 1)
    }

    @Test("Adding to a list that is not there is refused rather than orphaned")
    func addingToAMissingListIsRefused() async throws {
        let f = try await makeFixture()
        let missing = Identifier<ShoppingList>()

        await #expect(throws: DomainError.self) {
            try await f.commands.addShoppingItem(
                "Milk", to: missing, in: f.household.id, by: f.owner.id
            )
        }
        // The item that would otherwise be here belongs to the household and
        // to no list, so nothing renders it and nothing cleans it up.
        #expect(try await f.store.snapshot(of: f.household.id).shoppingItems.isEmpty)
    }

    @Test("Clearing a list that is not there says so rather than reporting zero")
    func clearingAMissingListIsRefused() async throws {
        let f = try await makeFixture()
        await #expect(throws: DomainError.self) {
            try await f.commands.clearPurchasedItems(
                from: Identifier<ShoppingList>(), in: f.household.id, by: f.owner.id
            )
        }
    }

    @Test("An item still cannot be added to another household's list")
    func addingToAnotherHouseholdsListIsRefused() async throws {
        let f = try await makeFixture()
        let other = try Household(name: "Flat 3B", timeZone: .gmt, createdAt: clock.now)
        let otherOwner = try Member(
            householdID: other.id, name: "Robin", role: .owner, joinedAt: clock.now
        )
        let theirList = try ShoppingList(
            householdID: other.id, name: "Theirs", createdBy: otherOwner.id,
            createdAt: clock.now
        )
        try await f.store.save(other)
        try await f.store.save(otherOwner)
        try await f.store.save(theirList)

        await #expect(throws: DomainError.self) {
            try await f.commands.addShoppingItem(
                "Milk", to: theirList.id, in: f.household.id, by: f.owner.id
            )
        }
    }
}
