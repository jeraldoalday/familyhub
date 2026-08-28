import Foundation
import Testing

@testable import FamilyHubCore

/// Covers what an accepted cover does to the household's agenda: which list the
/// chore appears on, who the row says it is waiting for, and what is left for
/// the person who asked to be let off.
@Suite("Cover on the agenda")
struct CoverAgendaTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        FixedDateProvider(year: year, month: month, day: day, hour: hour, calendar: calendar).now
    }

    /// 2 March 2026, a Monday.
    private var monday: Date { date(2026, 3, 2, hour: 0) }

    private struct Fixture {
        var snapshot: HouseholdSnapshot
        let parent: Member
        let sam: Member
        let alex: Member
        let bins: Chore
    }

    private func makeFixture() throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: date(2026, 1, 1)
        )
        let parent = try Member(
            householdID: household.id, name: "Mary", role: .adult,
            avatar: Avatar(color: .purple), joinedAt: date(2026, 1, 1)
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child,
            avatar: Avatar(color: .amber), joinedAt: date(2026, 1, 1)
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen,
            avatar: Avatar(color: .teal), joinedAt: date(2026, 1, 1)
        )
        let bins = try Chore(
            householdID: household.id,
            title: "Take out the bins",
            assignment: .member(sam.id),
            points: 15,
            startDate: date(2026, 3, 1),
            recurrence: .daily,
            createdBy: parent.id,
            createdAt: date(2026, 3, 1)
        )
        return Fixture(
            snapshot: HouseholdSnapshot(
                household: household,
                members: [parent, sam, alex],
                chores: [bins]
            ),
            parent: parent,
            sam: sam,
            alex: alex,
            bins: bins
        )
    }

    private func request(
        _ fixture: Fixture,
        askedOf: Identifier<Member>? = nil,
        day: Date? = nil,
        createdAt: Date? = nil
    ) throws -> CoverRequest {
        try CoverRequest(
            householdID: fixture.snapshot.household.id,
            choreID: fixture.bins.id,
            day: day ?? monday,
            requestedBy: fixture.sam.id,
            askedOf: askedOf,
            createdAt: createdAt ?? date(2026, 3, 1),
            calendar: calendar
        )
    }

    // MARK: Whose list it appears on

    @Test("An accepted cover moves the chore onto the other person's list")
    func coverMovesTheChore() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [
            try request(f).accepted(by: f.alex.id, at: date(2026, 3, 1))
        ]

        let alexes = f.snapshot.agenda(for: monday, memberID: f.alex.id)
        #expect(alexes.map(\.chore.id) == [f.bins.id])
        #expect(alexes.first?.isCovered == true)
        #expect(alexes.first?.responsible?.id == f.alex.id)
        // The row still knows whose turn it was, so it can say so.
        #expect(alexes.first?.assignee?.id == f.sam.id)
        #expect(alexes.first?.cover?.requestedBy == f.sam.id)
    }

    @Test("It leaves the list of the person who asked")
    func coverClearsTheRequestersList() throws {
        // The morning digest counts what is outstanding for a person, so a
        // chore somebody else has taken on has to go — otherwise the swap
        // achieves nothing where it matters most.
        var f = try makeFixture()
        f.snapshot.coverRequests = [
            try request(f).accepted(by: f.alex.id, at: date(2026, 3, 1))
        ]

        #expect(f.snapshot.agenda(for: monday, memberID: f.sam.id).isEmpty)
    }

    @Test("The household's own agenda still shows it, once")
    func householdAgendaKeepsTheChore() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [
            try request(f).accepted(by: f.alex.id, at: date(2026, 3, 1))
        ]

        let all = f.snapshot.agenda(for: monday)
        #expect(all.count == 1)
        #expect(all.first?.coveringMember?.id == f.alex.id)
    }

    @Test("An unanswered request changes nothing about the agenda")
    func openRequestDoesNotMoveTheChore() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f, askedOf: f.alex.id)]

        #expect(f.snapshot.agenda(for: monday, memberID: f.sam.id).count == 1)
        #expect(f.snapshot.agenda(for: monday, memberID: f.alex.id).isEmpty)
        #expect(f.snapshot.agenda(for: monday, memberID: f.sam.id).first?.isCovered == false)
    }

    @Test("A declined request leaves the chore where it was")
    func declinedRequestDoesNotMoveTheChore() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [
            try request(f, askedOf: f.alex.id).declined(by: f.alex.id, at: date(2026, 3, 1))
        ]

        #expect(f.snapshot.agenda(for: monday, memberID: f.sam.id).count == 1)
        #expect(f.snapshot.agenda(for: monday, memberID: f.alex.id).isEmpty)
    }

    @Test("A cover applies to its own day and no other")
    func coverIsPerOccurrence() throws {
        // The whole point of covering an occurrence rather than editing the
        // rota: Tuesday is still Sam's.
        var f = try makeFixture()
        f.snapshot.coverRequests = [
            try request(f).accepted(by: f.alex.id, at: date(2026, 3, 1))
        ]
        let tuesday = date(2026, 3, 3, hour: 0)

        #expect(f.snapshot.agenda(for: tuesday, memberID: f.sam.id).count == 1)
        #expect(f.snapshot.agenda(for: tuesday, memberID: f.alex.id).isEmpty)
    }

    @Test("Two acceptances for one occurrence resolve to the earlier one")
    func earliestAcceptanceWinsOnTheAgenda() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [
            try request(f).accepted(by: f.parent.id, at: date(2026, 3, 1, hour: 18)),
            try request(f).accepted(by: f.alex.id, at: date(2026, 3, 1, hour: 12)),
        ]

        #expect(f.snapshot.agenda(for: monday).first?.coveringMember?.id == f.alex.id)
        #expect(f.snapshot.agenda(for: monday, memberID: f.parent.id).isEmpty)
    }

    // MARK: Reading requests back off the snapshot

    @Test("A person's inbox holds what they can answer today")
    func inboxHoldsAnswerableRequests() throws {
        var f = try makeFixture()
        let toAlex = try request(f, askedOf: f.alex.id)
        let toAnyone = try request(f, createdAt: date(2026, 3, 1, hour: 10))
        let lapsed = try request(
            f, day: date(2026, 3, 1, hour: 0), createdAt: date(2026, 3, 1, hour: 11)
        )
        f.snapshot.coverRequests = [toAlex, toAnyone, lapsed]

        let inbox = f.snapshot.coverInbox(for: f.alex.id, on: monday)

        #expect(inbox.map(\.id) == [toAlex.id, toAnyone.id])
        #expect(f.snapshot.coverInbox(for: f.sam.id, on: monday).isEmpty)
    }

    @Test("Live requests exclude the ones whose day has gone")
    func liveRequestsExcludeLapsedOnes() throws {
        var f = try makeFixture()
        let today = try request(f)
        let yesterday = try request(f, day: date(2026, 3, 1, hour: 0))
        f.snapshot.coverRequests = [today, yesterday]

        #expect(f.snapshot.liveCoverRequests(on: monday).map(\.id) == [today.id])
    }

    @Test("The snapshot answers who is covering an occurrence")
    func snapshotAnswersWhoIsCovering() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [
            try request(f).accepted(by: f.alex.id, at: date(2026, 3, 1))
        ]
        let key = ChoreCompletion.OccurrenceKey(choreID: f.bins.id, day: monday)

        #expect(f.snapshot.cover(for: key) == f.alex.id)
        #expect(
            f.snapshot.cover(
                for: ChoreCompletion.OccurrenceKey(
                    choreID: f.bins.id, day: date(2026, 3, 3, hour: 0)
                )
            ) == nil
        )
    }

    // MARK: Decoding

    @Test("A snapshot written before covers existed decodes as one with none")
    func snapshotWithoutCoversDecodes() throws {
        // Every backup a family already has was written without this
        // collection, and refusing those files would be the worst possible way
        // to ship a feature about doing each other favours.
        let f = try makeFixture()
        var withoutCovers = f.snapshot
        withoutCovers.coverRequests = []
        let data = try JSONEncoder().encode(withoutCovers)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "coverRequests")
        let trimmed = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(HouseholdSnapshot.self, from: trimmed)

        #expect(decoded.coverRequests.isEmpty)
        #expect(decoded.members.count == 3)
    }
}
