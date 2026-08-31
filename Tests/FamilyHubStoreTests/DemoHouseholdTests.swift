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

    // MARK: The meal plan

    @Test("This week's meals are planned, but not every one of them")
    func mealPlanHasGapsWorthShowing() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let week = snapshot.mealPlan.week(containing: clock.today)

        #expect(!week.isEmpty)
        #expect(!week.isComplete)
        // A week with every dinner filled shows a family who have already
        // solved the problem the screen exists for.
        #expect(week.days.contains { $0.dinner == nil })
        #expect(week.days.contains { $0.dinner != nil })
    }

    @Test("There is something for dinner tonight")
    func tonightHasAMeal() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let tonight = snapshot.mealPlan.meal(on: clock.today, slot: .dinner)

        #expect(tonight?.title.value == "Chicken traybake")
        #expect(tonight?.hasCook == true)
    }

    @Test("Some of the week's shopping is already done and some is not")
    func mealPlanLeavesShoppingToDo() throws {
        // The 'add what's missing' action needs something real to do. If every
        // ingredient were already listed it would do nothing, and if none were
        // it would never demonstrate the deduplication.
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let week = snapshot.mealPlan.week(containing: clock.today)
        let outstanding = snapshot.mealPlan.ingredientsToBuy(
            from: week.start,
            to: week.end,
            excluding: snapshot.shoppingItems
        )
        let everything = snapshot.mealPlan.ingredientsToBuy(from: week.start, to: week.end)

        #expect(!outstanding.isEmpty)
        #expect(outstanding.count < everything.count)
    }

    @Test("Nobody is doing all the cooking, and nobody unreasonable is doing any")
    func cookingIsShared() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let week = snapshot.mealPlan.week(containing: clock.today)
        let balance = snapshot.mealPlan.cookBalance(
            among: snapshot.activeMembers, from: week.start, to: week.end
        )
        let cooks = Set(
            snapshot.mealPlan.meals.compactMap(\.cookID)
        )

        #expect(cooks.count >= 3)
        #expect(balance.unassignedMeals > 0)
        // Sam is nine. A demo that shows a nine year old rostered to cook the
        // family dinner is making a recommendation it should not make.
        let sam = try #require(snapshot.activeMembers.first { $0.name.value == "Sam" })
        #expect(!cooks.contains(sam.id))
    }

    // MARK: The calendar

    @Test("The demo week has something on the calendar every day it should")
    func calendarIsPopulated() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        #expect(!snapshot.events.isEmpty)
        #expect(snapshot.events.allSatisfy { $0.householdID == snapshot.household.id })
        #expect(snapshot.activeEvents.count == snapshot.events.count)

        let week = snapshot.familyCalendar.week(containing: clock.today)
        #expect(week.count >= 5)
    }

    @Test("The demo calendar has a clash, because that is what a shared one is for")
    func calendarHasSomethingToWarnAbout() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let clashes = snapshot.familyCalendar.clashes(
            from: clock.today,
            to: clock.day(offsetFromToday: 6),
            among: snapshot.members
        )
        #expect(!clashes.isEmpty)
        let clash = try #require(clashes.first)
        #expect(clash.members.count == 1)
        #expect(clash.overlapMinutes > 0)
    }

    @Test("The demo calendar shows an all-day entry alongside timed ones")
    func calendarMixesAllDayAndTimed() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        #expect(snapshot.events.contains { $0.isAllDay })
        #expect(snapshot.events.contains { !$0.isAllDay })
        #expect(snapshot.events.contains { $0.participants == .everyone })
        #expect(snapshot.events.contains { !$0.participants.namedMemberIDs.isEmpty })
    }

    @Test("The demo has a commitment that has been running for a while")
    func calendarHasARecurringEntry() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let repeating = snapshot.events.filter { $0.recurrence.isRepeating }
        let recurring = try #require(repeating.first)
        #expect(recurring.startDate < clock.today)

        let engine = snapshot.engine
        let past = recurring.occurrences(
            in: clock.day(offsetFromToday: -30)...clock.day(offsetFromToday: -1), using: engine
        )
        #expect(past.count >= 3)
    }

    @Test("Some of the demo calendar asks to be reminded about, and some does not")
    func calendarHasBothLoudAndQuietEntries() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        #expect(snapshot.events.contains { $0.hasReminder })
        #expect(snapshot.events.contains { !$0.hasReminder })
    }

    @Test("The demo has an ask still waiting and one a sibling took on")
    func demoHasCoverRequestsInBothStates() throws {
        // Somebody asking to be let off is the ordinary case rather than the
        // exception, and a demo where every request is settled shows only half
        // of what the feature is.
        let snapshot = try DemoHousehold.snapshot(asOf: clock)

        #expect(snapshot.coverRequests.count == 2)
        #expect(snapshot.coverRequests.open.count == 1)
        #expect(snapshot.coverRequests.contains { $0.resolution.isAccepted })
    }

    @Test("The ask still waiting is about a day the chore is actually due")
    func openCoverRequestIsAboutARealOccurrence() throws {
        // The demo is built around whatever day it is run on, so a hard-coded
        // Tuesday would be an ask about a chore that is not due.
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let engine = snapshot.engine
        let open = try #require(snapshot.coverRequests.open.first)
        let chore = try #require(snapshot.chore(open.choreID))

        #expect(chore.occurs(on: open.day, using: engine))
        #expect(open.day >= clock.today)
        // Asked by whoever the rota actually named that day.
        let index = try #require(chore.occurrenceIndex(of: open.day, using: engine))
        #expect(chore.assignee(forOccurrenceIndex: index) == open.requestedBy)
    }

    @Test("The covered day moved onto the other child's agenda")
    func acceptedCoverMovedTheChore() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let accepted = try #require(
            snapshot.coverRequests.first { $0.resolution.isAccepted }
        )
        let coverer = try #require(accepted.resolution.coveringMemberID)

        #expect(coverer != accepted.requestedBy)
        #expect(snapshot.cover(for: accepted.occurrenceKey) == coverer)
        #expect(
            snapshot.agenda(for: accepted.day, memberID: coverer)
                .contains { $0.chore.id == accepted.choreID }
        )
        #expect(
            snapshot.agenda(for: accepted.day, memberID: accepted.requestedBy)
                .contains { $0.chore.id == accepted.choreID } == false
        )
    }

    @Test("Every named participant is somebody still in the household")
    func calendarNamesRealPeople() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let active = Set(snapshot.activeMembers.map(\.id))
        for event in snapshot.events {
            #expect(Set(event.participants.namedMemberIDs).isSubset(of: active))
        }
    }

    // MARK: Redemptions

    @Test("The demo opens with a reward the household has forgotten to give")
    func hasAPromiseOutstanding() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)

        let owed = snapshot.owedRedemptions
        #expect(owed.count == 1)
        #expect(snapshot.overdueRedemptions(on: clock.now).count == 1)
        // The parent's queue is the screen this feature lives on, and a demo
        // where it is empty shows a household with nothing to settle.
        #expect(owed.first?.daysOwed(on: clock.now, calendar: clock.calendar) == 4)
    }

    @Test("The demo shows all three things that can happen to a redemption")
    func showsEveryRedemptionState() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)

        #expect(snapshot.redemptions.count == 3)
        #expect(snapshot.redemptions.contains { $0.isOwed })
        #expect(snapshot.redemptions.contains { $0.state.isGiven })
        #expect(snapshot.redemptions.contains { $0.wasRefunded })
    }

    @Test("A refunded redemption leaves both halves in the history")
    func refundReadsAsAPair() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)
        let refunded = try #require(snapshot.redemptions.first { $0.wasRefunded })
        let history = snapshot.ledger.history(for: refunded.memberID)

        #expect(history.contains { $0.source == .rewardRedeemed(refunded.rewardID) })
        #expect(history.contains { $0.source == .rewardRefunded(refunded.rewardID) })
    }

    @Test("Every redemption was something its member could actually afford")
    func nobodyIsOverdrawn() throws {
        let snapshot = try DemoHousehold.snapshot(asOf: clock)

        for member in snapshot.activeMembers {
            #expect(snapshot.ledger.balance(for: member.id) >= 0)
        }
    }
}
