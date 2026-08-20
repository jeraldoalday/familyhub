import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Household snapshot")
struct HouseholdSnapshotTests {

    private let calendar = Calendar.testDefault

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 9) -> Date {
        FixedDateProvider(year: y, month: m, day: d, hour: hour, calendar: calendar).now
    }

    private struct Fixture {
        var snapshot: HouseholdSnapshot
        let parent: Member
        let alex: Member
        let sam: Member
    }

    private func makeFixture() throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: date(2026, 1, 1)
        )
        let parent = try Member(
            householdID: household.id, name: "Jerald", role: .owner,
            avatar: Avatar(color: .blue), joinedAt: date(2026, 1, 1)
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .child,
            avatar: Avatar(color: .teal), joinedAt: date(2026, 1, 1)
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child,
            avatar: Avatar(color: .green), joinedAt: date(2026, 1, 1)
        )
        return Fixture(
            snapshot: HouseholdSnapshot(household: household, members: [parent, alex, sam]),
            parent: parent,
            alex: alex,
            sam: sam
        )
    }

    private func chore(
        _ title: String,
        in fixture: Fixture,
        assignment: Chore.Assignment = .anyone,
        recurrence: RecurrenceRule = .daily
    ) throws -> Chore {
        try Chore(
            householdID: fixture.snapshot.household.id,
            title: title,
            assignment: assignment,
            points: 10,
            startDate: date(2026, 3, 2),
            recurrence: recurrence,
            createdBy: fixture.parent.id,
            createdAt: date(2026, 3, 1)
        )
    }

    // MARK: Agenda

    @Test("The agenda lists the chores due that day")
    func agendaListsDueChores() throws {
        var f = try makeFixture()
        f.snapshot.chores = [
            try chore("Bins", in: f, recurrence: try .weekly(on: [.monday])),
            try chore("Dishes", in: f),
        ]

        let monday = f.snapshot.agenda(for: date(2026, 3, 2))
        #expect(monday.map(\.chore.title.value) == ["Bins", "Dishes"])

        let tuesday = f.snapshot.agenda(for: date(2026, 3, 3))
        #expect(tuesday.map(\.chore.title.value) == ["Dishes"])
    }

    @Test("Filtering by member keeps their chores and the unassigned ones")
    func agendaKeepsOpenChores() throws {
        // An unassigned chore stays on everyone's list — being open for whoever
        // gets there first is the entire point of leaving it unassigned.
        var f = try makeFixture()
        f.snapshot.chores = [
            try chore("Alex's room", in: f, assignment: .member(f.alex.id)),
            try chore("Sam's room", in: f, assignment: .member(f.sam.id)),
            try chore("Dishes", in: f, assignment: .anyone),
        ]

        let agenda = f.snapshot.agenda(for: date(2026, 3, 2), memberID: f.alex.id)
        #expect(agenda.map(\.chore.title.value) == ["Alex's room", "Dishes"])
    }

    @Test("A rotating chore shows whose turn it is")
    func agendaResolvesRotation() throws {
        var f = try makeFixture()
        f.snapshot.chores = [
            try chore("Bins", in: f, assignment: .rotating([f.alex.id, f.sam.id]))
        ]

        let monday = try #require(f.snapshot.agenda(for: date(2026, 3, 2)).first)
        #expect(monday.assignee?.id == f.alex.id)

        let tuesday = try #require(f.snapshot.agenda(for: date(2026, 3, 3)).first)
        #expect(tuesday.assignee?.id == f.sam.id)
    }

    @Test("Outstanding chores sort above completed ones")
    func agendaPutsOutstandingFirst() throws {
        // A list that opens on a wall of ticks buries the thing the person
        // actually came to do.
        var f = try makeFixture()
        let done = try chore("Aaa done", in: f)
        let todo = try chore("Zzz to do", in: f)
        f.snapshot.chores = [done, todo]
        f.snapshot.completions = [
            ChoreCompletion(
                householdID: f.snapshot.household.id,
                choreID: done.id,
                occurrenceDay: date(2026, 3, 2),
                completedBy: f.alex.id,
                completedAt: date(2026, 3, 2, hour: 8),
                pointsAwarded: 10,
                calendar: calendar
            )
        ]

        let agenda = f.snapshot.agenda(for: date(2026, 3, 2))
        #expect(agenda.map(\.chore.title.value) == ["Zzz to do", "Aaa done"])
        #expect(agenda.last?.isDone == true)
    }

    @Test("An archived chore drops off the agenda")
    func archivedChoresAreHidden() throws {
        var f = try makeFixture()
        f.snapshot.chores = [try chore("Bins", in: f).archived(at: date(2026, 3, 1))]
        #expect(f.snapshot.agenda(for: date(2026, 3, 2)).isEmpty)
    }

    @Test("Agenda rows keep a stable identity across reloads")
    func agendaIdentityIsStable() throws {
        // The identity drives list animations; a row that changes identity on
        // reload animates out and back in for no reason.
        var f = try makeFixture()
        f.snapshot.chores = [try chore("Bins", in: f)]

        let first = f.snapshot.agenda(for: date(2026, 3, 2)).map(\.id)
        let second = f.snapshot.agenda(for: date(2026, 3, 2, hour: 22)).map(\.id)
        #expect(first == second)
    }

    @Test("Duplicate completions do not produce duplicate agenda rows")
    func duplicateCompletionsCollapse() throws {
        var f = try makeFixture()
        let bins = try chore("Bins", in: f)
        f.snapshot.chores = [bins]
        f.snapshot.completions = (0..<2).map { offset in
            ChoreCompletion(
                householdID: f.snapshot.household.id,
                choreID: bins.id,
                occurrenceDay: date(2026, 3, 2),
                completedBy: f.alex.id,
                completedAt: date(2026, 3, 2, hour: 8 + offset),
                pointsAwarded: 10,
                calendar: calendar
            )
        }

        let agenda = f.snapshot.agenda(for: date(2026, 3, 2))
        #expect(agenda.count == 1)
        #expect(agenda[0].isDone)
    }

    // MARK: Lookups

    @Test("Removed members are excluded from the active list but still findable")
    func removedMembersRemainResolvable() throws {
        // Historical completions name them, so the record has to stay
        // reachable even though the member list hides them.
        var f = try makeFixture()
        f.snapshot.members = [f.parent, f.alex.removed(at: date(2026, 2, 1))]

        #expect(f.snapshot.activeMembers.map(\.id) == [f.parent.id])
        #expect(f.snapshot.member(f.alex.id) != nil)
    }

    @Test("Requiring a missing record throws rather than returning nil")
    func requireThrows() throws {
        let f = try makeFixture()
        let missing = Identifier<Chore>()
        #expect(throws: DomainError.notFound(entity: "Chore", id: missing.description)) {
            _ = try f.snapshot.requireChore(missing)
        }
    }

    @Test("Members sort adults first in the active list")
    func activeMembersAreInDisplayOrder() throws {
        let f = try makeFixture()
        #expect(f.snapshot.activeMembers.map(\.name.value) == ["Jerald", "Alex", "Sam"])
    }

    // MARK: Review queue

    @Test("The review queue holds only pending completions")
    func reviewQueueFiltersPending() throws {
        var f = try makeFixture()
        let bins = try chore("Bins", in: f)
        f.snapshot.chores = [bins]
        f.snapshot.completions = [
            ChoreCompletion(
                householdID: f.snapshot.household.id, choreID: bins.id,
                occurrenceDay: date(2026, 3, 2), completedBy: f.alex.id,
                completedAt: date(2026, 3, 2), approval: .pending,
                pointsAwarded: 10, calendar: calendar
            ),
            ChoreCompletion(
                householdID: f.snapshot.household.id, choreID: bins.id,
                occurrenceDay: date(2026, 3, 3), completedBy: f.alex.id,
                completedAt: date(2026, 3, 3), approval: .notRequired,
                pointsAwarded: 10, calendar: calendar
            ),
        ]
        #expect(f.snapshot.reviewQueue.count == 1)
    }

    // MARK: Rejected work

    @Test("A rejected completion puts the chore back on the agenda")
    func rejectedCompletionIsOutstandingAgain() throws {
        var f = try makeFixture()
        let bins = try chore("Bins", in: f)
        f.snapshot.chores = [bins]
        f.snapshot.completions = [
            ChoreCompletion(
                householdID: f.snapshot.household.id, choreID: bins.id,
                occurrenceDay: date(2026, 3, 2), completedBy: f.alex.id,
                completedAt: date(2026, 3, 2),
                approval: .rejected(
                    by: f.parent.id, at: date(2026, 3, 2, hour: 18),
                    reason: "You missed under the table"
                ),
                pointsAwarded: 10, calendar: calendar
            )
        ]

        let row = try #require(f.snapshot.agenda(for: date(2026, 3, 2)).first)
        #expect(!row.isDone)
        #expect(row.wasRejected)
        #expect(row.rejectionReason == "You missed under the table")
        // The record stays attached: the row has to be able to say why it came
        // back, and it is also what the redo replaces.
        #expect(row.completion != nil)
    }

    @Test("Work waiting on a parent still counts as done")
    func pendingCompletionCountsAsDone() throws {
        var f = try makeFixture()
        let bins = try chore("Bins", in: f)
        f.snapshot.chores = [bins]
        f.snapshot.completions = [
            ChoreCompletion(
                householdID: f.snapshot.household.id, choreID: bins.id,
                occurrenceDay: date(2026, 3, 2), completedBy: f.alex.id,
                completedAt: date(2026, 3, 2), approval: .pending,
                pointsAwarded: 10, calendar: calendar
            )
        ]

        let row = try #require(f.snapshot.agenda(for: date(2026, 3, 2)).first)
        #expect(row.isDone)
        #expect(row.needsApproval)
        #expect(!row.wasRejected)
    }

    @Test("A rejected chore sorts above the finished ones")
    func rejectedChoreSortsWithOutstandingWork() throws {
        var f = try makeFixture()
        let bins = try chore("Bins", in: f)
        let dishes = try chore("Dishes", in: f)
        f.snapshot.chores = [bins, dishes]
        f.snapshot.completions = [
            ChoreCompletion(
                householdID: f.snapshot.household.id, choreID: dishes.id,
                occurrenceDay: date(2026, 3, 2), completedBy: f.alex.id,
                completedAt: date(2026, 3, 2), approval: .notRequired,
                pointsAwarded: 10, calendar: calendar
            ),
            ChoreCompletion(
                householdID: f.snapshot.household.id, choreID: bins.id,
                occurrenceDay: date(2026, 3, 2), completedBy: f.alex.id,
                completedAt: date(2026, 3, 2),
                approval: .rejected(by: f.parent.id, at: date(2026, 3, 2), reason: nil),
                pointsAwarded: 10, calendar: calendar
            ),
        ]

        let rows = f.snapshot.agenda(for: date(2026, 3, 2))
        #expect(rows.map(\.chore.title.value) == ["Bins", "Dishes"])
    }
}
