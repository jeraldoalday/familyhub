import Foundation
import Testing

@testable import FamilyHubCore

/// Guards the read paths that run on every render against quietly becoming
/// quadratic again.
///
/// These are not benchmarks and the budgets are deliberately loose — a shared
/// CI runner under load is several times slower than a laptop, and a test that
/// fails on a busy afternoon gets disabled rather than investigated.
///
/// They are still narrow enough to catch the regression they exist for. With
/// every caller resolving occurrence positions one day at a time, the member
/// streak below measured 3.7 seconds and the weekly recap 9.1 on the machine
/// this was written on; sharing one walk of each chore's schedule brought them
/// to 0.24 and 0.39, most of which is building the fixture. A budget of two
/// seconds sits far enough above the fast path to survive a loaded runner and
/// far enough below the slow one to fail if it comes back.
@Suite("Hot paths")
struct HotPathTests {

    private let calendar = Calendar.testDefault
    private var engine: RecurrenceEngine { RecurrenceEngine(calendar: calendar) }

    /// A household two years into daily use: the shape the agenda has to stay
    /// fast on, not the empty one it is easy to be fast on.
    private struct BusyHousehold {
        let snapshot: HouseholdSnapshot
        let today: Date
        let members: [Member]
    }

    /// Two years of planned meals, three a day, every one of them with a cook
    /// and a short shopping list.
    ///
    /// A household that has used the meal planner since it launched, which is
    /// the only history that tells you whether reading one week out of it is a
    /// lookup or a walk.
    private func withMealPlan(
        _ busy: BusyHousehold, historyDays: Int = 730
    ) throws
        -> BusyHousehold
    {
        var snapshot = busy.snapshot
        let members = busy.members
        var meals: [PlannedMeal] = []

        for offset in stride(from: -historyDays, through: 7, by: 1) {
            guard
                let day = calendar.date(byAdding: .day, value: offset, to: busy.today)
            else { continue }
            for (index, slot) in PlannedMeal.Slot.planned.enumerated() {
                meals.append(
                    try PlannedMeal(
                        householdID: snapshot.household.id,
                        day: day,
                        slot: slot,
                        title: "Meal \(offset)-\(slot.rawValue)",
                        cookID: members[(offset + index + historyDays) % members.count].id,
                        ingredients: ["Mince", "Rice", "Peppers"],
                        plannedBy: members[0].id,
                        createdAt: day,
                        calendar: calendar
                    )
                )
            }
        }

        snapshot.plannedMeals = meals
        return BusyHousehold(snapshot: snapshot, today: busy.today, members: members)
    }

    private func makeBusyHousehold(
        choreCount: Int = 20,
        historyDays: Int = 730
    ) throws -> BusyHousehold {
        let clock = FixedDateProvider(year: 2026, month: 3, day: 2, calendar: calendar)
        let today = clock.today
        let start = calendar.date(byAdding: .day, value: -historyDays, to: today) ?? today

        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: start
        )
        let members = try (0..<4).map { index in
            try Member(
                householdID: household.id,
                name: "Member \(index)",
                role: index == 0 ? .owner : .child,
                joinedAt: start
            )
        }
        let rota = members.map(\.id)

        let chores = try (0..<choreCount).map { index in
            try Chore(
                householdID: household.id,
                title: "Chore \(index)",
                // Rotating, because a rota is what forces every caller to
                // resolve an occurrence's position rather than just its date.
                assignment: .rotating(rota),
                // Staggered starts, so the rota does not land every chore on
                // the same person on the same day the way a single shared start
                // date would.
                startDate: calendar.date(byAdding: .day, value: index % rota.count, to: start)
                    ?? start,
                recurrence: .daily,
                createdBy: rota[0],
                createdAt: start
            )
        }

        // Roughly two years of completions: every chore, every day, done.
        var completions: [ChoreCompletion] = []
        for chore in chores {
            for occurrence in chore.indexedOccurrences(
                in: chore.startDate...today, using: engine, maximum: Int.max
            ) {
                guard let assignee = chore.assignee(forOccurrenceIndex: occurrence.index) else {
                    continue
                }
                completions.append(
                    ChoreCompletion(
                        householdID: household.id,
                        choreID: chore.id,
                        occurrenceDay: occurrence.day,
                        completedBy: assignee,
                        completedAt: occurrence.day.addingTimeInterval(60 * 60 * 18),
                        pointsAwarded: 10,
                        calendar: calendar
                    )
                )
            }
        }

        return BusyHousehold(
            snapshot: HouseholdSnapshot(
                household: household,
                members: members,
                chores: chores,
                completions: completions
            ),
            today: today,
            members: members
        )
    }

    /// A calendar two years deep: a handful of long-running weekly
    /// commitments plus a daily one, all of them still recurring today.
    ///
    /// Recurring entries rather than one-off ones on purpose. A thousand
    /// single-day events is a thousand rows to filter, which is easy; a
    /// commitment that started two years ago is a schedule that has to be
    /// walked from its start every time somebody asks about this week, which is
    /// the shape that goes quadratic.
    private func withCalendar(
        _ busy: BusyHousehold,
        eventCount: Int = 20,
        historyDays: Int = 730
    ) throws -> BusyHousehold {
        var snapshot = busy.snapshot
        let members = busy.members
        let start =
            calendar.date(byAdding: .day, value: -historyDays, to: busy.today) ?? busy.today

        snapshot.events = try (0..<eventCount).map { index in
            let weekday = Weekday.allCases[index % Weekday.allCases.count]
            return try CalendarEvent(
                householdID: snapshot.household.id,
                title: "Commitment \(index)",
                location: "Somewhere \(index)",
                startDate: start,
                timing: .at(hour: 9 + index % 8, lasting: 60),
                recurrence: index % 5 == 0 ? .daily : try .weekly(on: [weekday]),
                participants: .members([members[index % members.count].id]),
                createdBy: members[0].id,
                createdAt: start,
                calendar: calendar
            )
        }
        return BusyHousehold(snapshot: snapshot, today: busy.today, members: members)
    }

    /// Two years of swaps: one accepted cover on every chore, every fourth
    /// day, plus the asks that were turned down along the way.
    ///
    /// A household that actually uses the feature, which is the only history
    /// that tells you whether reading "who is doing this today" is a lookup or
    /// a walk through every favour the family has ever done each other.
    private func withCoverRequests(_ busy: BusyHousehold) throws -> BusyHousehold {
        var snapshot = busy.snapshot
        let members = busy.members
        var requests: [CoverRequest] = []

        for chore in snapshot.chores {
            for occurrence in chore.indexedOccurrences(
                in: chore.startDate...busy.today, using: engine, maximum: Int.max
            ) where occurrence.index % 4 == 0 {
                guard let asker = chore.assignee(forOccurrenceIndex: occurrence.index) else {
                    continue
                }
                let coverer = members[(occurrence.index + 1) % members.count].id
                guard coverer != asker else { continue }
                let asked = try CoverRequest(
                    householdID: snapshot.household.id,
                    choreID: chore.id,
                    day: occurrence.day,
                    requestedBy: asker,
                    createdAt: occurrence.day,
                    calendar: calendar
                )
                requests.append(try asked.accepted(by: coverer, at: occurrence.day))
                // The ones that were turned down stay on file too, and a
                // household that reads only the accepted ones is a household
                // that has not been asked to filter anything.
                requests.append(
                    try CoverRequest(
                        householdID: snapshot.household.id,
                        choreID: chore.id,
                        day: occurrence.day,
                        requestedBy: asker,
                        askedOf: members[(occurrence.index + 2) % members.count].id,
                        createdAt: occurrence.day,
                        calendar: calendar
                    )
                    .declined(
                        by: members[(occurrence.index + 2) % members.count].id,
                        at: occurrence.day)
                )
            }
        }

        snapshot.coverRequests = requests
        return BusyHousehold(snapshot: snapshot, today: busy.today, members: members)
    }

    /// How long `work` took.
    private func duration(of work: () throws -> Void) rethrows -> TimeInterval {
        let started = Date()
        try work()
        return Date().timeIntervalSince(started)
    }

    @Test("Today's agenda stays fast on two years of history")
    func agendaIsFastOnALargeHousehold() throws {
        let busy = try makeBusyHousehold()
        var rows = 0

        let elapsed = duration {
            rows = busy.snapshot.agenda(for: busy.today, memberID: busy.members[1].id).count
        }

        // A rotating chore only appears on the day it is that person's turn, so
        // this is a slice of the twenty rather than all of them.
        #expect(rows > 0)
        #expect(elapsed < 1.0)
    }

    @Test("The agenda stays fast on two years of swapping chores")
    func agendaIsFastWithManyCoverRequests() throws {
        // The index is built once per agenda rather than searched per chore.
        // Asking per chore would put a scan of every favour the household has
        // ever done inside the loop that renders today.
        let busy = try withCoverRequests(try makeBusyHousehold())
        var rows = 0

        #expect(busy.snapshot.coverRequests.count > 1_000)

        let elapsed = duration {
            rows = busy.snapshot.agenda(for: busy.today, memberID: busy.members[1].id).count
        }

        #expect(rows > 0)
        #expect(elapsed < 1.0)
    }

    @Test("The fairness screen stays fast on two years of swapping chores")
    func workloadIsFastWithManyCoverRequests() throws {
        let busy = try withCoverRequests(try makeBusyHousehold())
        var shares = 0

        let elapsed = duration {
            shares =
                busy.snapshot.insights
                .workloadBalance(from: busy.today, to: busy.today)
                .shares.count
        }

        #expect(shares == busy.members.count)
        #expect(elapsed < 2.0)
    }

    @Test("A swap moves the row and does not duplicate it")
    func coverMovesExactlyOneRow() throws {
        // Speed is only worth having if the answer is unchanged: every covered
        // occurrence has to leave one list and arrive on exactly one other.
        let busy = try withCoverRequests(try makeBusyHousehold())
        let household = busy.snapshot.agenda(for: busy.today)
        let perMember = busy.members.flatMap {
            busy.snapshot.agenda(for: busy.today, memberID: $0.id)
        }

        #expect(household.count == perMember.count)
        #expect(Set(perMember.map(\.id)).count == perMember.count)
    }

    @Test("A member's streak stays fast on two years of history")
    func memberStreakIsFastOnALargeHousehold() throws {
        // The worst of the three before the schedule walk was shared: one walk
        // of every chore's whole history for each of a hundred and eighty days.
        let busy = try makeBusyHousehold()
        var streak = Streak.none

        let elapsed = duration {
            streak = busy.snapshot.streaks.streak(
                forMember: busy.members[1].id, asOf: busy.today
            )
        }

        #expect(streak.length > 0)
        #expect(elapsed < 2.0)
    }

    @Test("A weekly recap stays fast on two years of history")
    func recapIsFastOnALargeHousehold() throws {
        let busy = try makeBusyHousehold()
        var scheduled = 0

        let elapsed = duration {
            scheduled =
                busy.snapshot.insights
                .weeklyRecap(forWeekContaining: busy.today)
                .scheduled
        }

        #expect(scheduled > 0)
        #expect(elapsed < 2.0)
    }

    @Test("The agenda gives the same answer on a large household as a small one")
    func scaleDoesNotChangeTheAnswer() throws {
        // Speed is only worth having if the answer is unchanged. The rota is
        // the part most likely to shift, since it depends on counting from each
        // chore's start rather than from the day being rendered.
        let busy = try makeBusyHousehold(choreCount: 3, historyDays: 400)
        let agenda = busy.snapshot.agenda(for: busy.today)

        for entry in agenda {
            let index = try #require(
                entry.chore.occurrenceIndex(of: busy.today, using: engine)
            )
            #expect(entry.occurrenceIndex == index)
            #expect(entry.assignee?.id == entry.chore.assignee(forOccurrenceIndex: index))
        }
        #expect(agenda.count == 3)
    }

    // MARK: The meal plan

    @Test("A week of the meal plan stays fast on two years of meals")
    func mealWeekIsFastOnALargePlan() throws {
        // Answering a day by filtering the whole plan makes rendering a week
        // seven passes over two thousand meals, and the week view is the screen
        // the whole feature opens on.
        let busy = try withMealPlan(try makeBusyHousehold(choreCount: 1, historyDays: 30))
        var planned = 0

        let elapsed = duration {
            planned = busy.snapshot.mealPlan.week(containing: busy.today).plannedCount
        }

        #expect(planned == 7 * PlannedMeal.Slot.planned.count)
        #expect(elapsed < 1.0)
    }

    @Test("Turning a week into a shopping list stays fast on two years of meals")
    func mealShoppingIsFastOnALargePlan() throws {
        let busy = try withMealPlan(try makeBusyHousehold(choreCount: 1, historyDays: 30))
        let week = busy.snapshot.mealPlan.week(containing: busy.today)
        var wanted = 0

        let elapsed = duration {
            wanted =
                busy.snapshot.mealPlan
                .ingredientsToBuy(from: week.start, to: week.end)
                .count
        }

        // Three ingredients repeated across every meal collapse to three lines,
        // which is the deduplication doing its job on a realistic plan.
        #expect(wanted == 3)
        #expect(elapsed < 1.0)
    }

    @Test("The cooking split stays fast on two years of meals")
    func cookBalanceIsFastOnALargePlan() throws {
        let busy = try withMealPlan(try makeBusyHousehold(choreCount: 1, historyDays: 30))
        var shares = 0

        let elapsed = duration {
            shares =
                busy.snapshot.mealPlan
                .cookBalance(
                    among: busy.members,
                    from: busy.snapshot.mealPlan.week(containing: busy.today).start,
                    to: busy.today
                )
                .shares.count
        }

        #expect(shares == busy.members.count)
        #expect(elapsed < 1.0)
    }

    @Test("A day of the plan gives the same answer indexed as it did filtered")
    func indexedDayMatchesTheFilter() throws {
        // Speed is only worth having if the answer is unchanged, and reading a
        // day from the slot index is a different route to it than filtering.
        let busy = try withMealPlan(try makeBusyHousehold(choreCount: 1, historyDays: 30))
        let plan = busy.snapshot.mealPlan

        for offset in 0..<7 {
            let day = try #require(
                calendar.date(byAdding: .day, value: offset, to: busy.today)
            )
            #expect(
                plan.meals(on: day).map(\.id)
                    == plan.meals.onDay(day, calendar: calendar).map(\.id)
            )
        }
    }

    // MARK: Search

    @Test("Searching the whole household stays fast on two years of everything")
    func searchIsFastOnALargeHousehold() throws {
        // Every keystroke re-runs this. A search box is the one screen where a
        // hundred milliseconds is visible as the field lagging behind the
        // person typing into it, so what is guarded here is that matching never
        // starts expanding a schedule: a chore's summary is a phrase, and
        // asking twenty chores with two years of history what days they fall on
        // to decide whether their titles match would be exactly that mistake.
        let busy = try withCalendar(try withMealPlan(try makeBusyHousehold()))
        var found = 0

        let elapsed = duration {
            found = busy.snapshot.search.results(for: "commitment").count
        }

        #expect(found > 0)
        #expect(elapsed < 1.0)
    }

    @Test("A query matching almost everything still returns only what was asked for")
    func searchLimitBoundsTheAnswer() throws {
        // The limit has to bound the work the caller does with the answer, not
        // only the answer: a query matching a thousand records must not hand
        // back a thousand rows for a list showing eight.
        let busy = try withCalendar(try withMealPlan(try makeBusyHousehold()))
        var results: [HouseholdSearch.Result] = []

        let elapsed = duration {
            results = busy.snapshot.search.results(for: "meal", limit: 10)
        }

        #expect(results.count == 10)
        #expect(elapsed < 1.0)
    }

    // MARK: The calendar

    @Test("A week of the calendar stays fast on two years of commitments")
    func calendarWeekIsFastOnALongHistory() throws {
        // Expanding each event's schedule once across the window rather than
        // asking each event about each day. The second shape is seven walks of
        // a two-year rota per event, on the screen the feature opens on.
        let busy = try withCalendar(try makeBusyHousehold(choreCount: 1, historyDays: 30))
        var count = 0

        let elapsed = duration {
            count = busy.snapshot.familyCalendar.week(containing: busy.today).count
        }

        #expect(count > 0)
        #expect(elapsed < 1.0)
    }

    @Test("One person's week stays fast on two years of commitments")
    func filteredCalendarWeekIsFast() throws {
        let busy = try withCalendar(try makeBusyHousehold(choreCount: 1, historyDays: 30))
        var count = 0

        let elapsed = duration {
            count =
                busy.snapshot.familyCalendar
                .week(containing: busy.today, for: busy.members[1].id)
                .count
        }

        #expect(count > 0)
        #expect(elapsed < 1.0)
    }

    @Test("Finding what is next stays fast on two years of commitments")
    func nextUpIsFastOnALongHistory() throws {
        let busy = try withCalendar(try makeBusyHousehold(choreCount: 1, historyDays: 30))
        var found: FamilyCalendar.Occurrence?

        let elapsed = duration {
            found = busy.snapshot.familyCalendar.next(after: busy.today)
        }

        #expect(found != nil)
        #expect(elapsed < 1.0)
    }

    @Test("Checking a month for clashes stays fast on two years of commitments")
    func clashDetectionIsFastOnALongHistory() throws {
        // The one query here that is quadratic by nature — every occurrence
        // against every later one — so what is being guarded is that the
        // expansion feeding it is not, and that the early exit on the sorted
        // list actually fires.
        let busy = try withCalendar(try makeBusyHousehold(choreCount: 1, historyDays: 30))
        let monthEnd = try #require(
            calendar.date(byAdding: .day, value: 30, to: busy.today)
        )
        var clashes = 0

        let elapsed = duration {
            clashes =
                busy.snapshot.familyCalendar
                .clashes(from: busy.today, to: monthEnd, among: busy.members)
                .count
        }

        #expect(clashes >= 0)
        #expect(elapsed < 1.0)
    }

    @Test("A day of the calendar gives the same answer read alone as inside a week")
    func dayMatchesTheWeekItIsIn() throws {
        // Speed is only worth having if the answer is unchanged, and a day read
        // on its own takes a different route through the expansion than the
        // same day read as part of a week.
        let busy = try withCalendar(try makeBusyHousehold(choreCount: 1, historyDays: 30))
        let familyCalendar = busy.snapshot.familyCalendar
        let week = familyCalendar.week(containing: busy.today)

        for day in week.days {
            #expect(
                familyCalendar.occurrences(on: day.day).map(\.id) == day.occurrences.map(\.id)
            )
        }
    }
}
