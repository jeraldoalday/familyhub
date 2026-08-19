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
}
