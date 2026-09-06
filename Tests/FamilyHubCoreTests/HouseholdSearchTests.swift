import Foundation
import Testing

@testable import FamilyHubCore

/// Covers the one search box that crosses every screen. The cases that matter
/// are the ones where a household would otherwise have to know which screen a
/// word lives on: an ingredient in the meal plan, a location on an event, a
/// note on a chore.
@Suite("Household search")
struct HouseholdSearchTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, calendar: .testDefault)

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: clock.today) ?? clock.today
    }

    private struct Fixture {
        let snapshot: HouseholdSnapshot
        let sam: Member
        let alex: Member
        let swimming: CalendarEvent
        let towels: Chore
        let bins: Chore
    }

    private func makeFixture() throws -> Fixture {
        let household = try Household(
            name: "The Aldays", tier: .plus, timeZone: .gmt, createdAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child,
            avatar: Avatar(color: .amber), joinedAt: clock.now
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen,
            avatar: Avatar(color: .teal), joinedAt: clock.now
        )
        let gone = try Member(
            householdID: household.id, name: "Sasha", role: .teen,
            avatar: Avatar(color: .blue), joinedAt: clock.now
        ).removed(at: clock.now)

        let towels = try Chore(
            householdID: household.id,
            title: "Hang up the wet towels",
            notes: "After swimming, not the next morning",
            startDate: clock.today,
            createdBy: alex.id,
            createdAt: clock.now
        )
        let bins = try Chore(
            householdID: household.id,
            title: "Bins",
            startDate: clock.today,
            recurrence: .weekly(on: [.wednesday]),
            createdBy: alex.id,
            createdAt: clock.now
        )
        let retired = try Chore(
            householdID: household.id,
            title: "Swimming kit check",
            startDate: clock.today,
            createdBy: alex.id,
            createdAt: clock.now
        ).archived(at: clock.now)

        let swimming = try CalendarEvent(
            householdID: household.id,
            title: "Swimming lesson",
            location: "Riverside Pool",
            kind: .activity,
            startDate: day(3),
            timing: .timed(startMinute: 16 * 60, durationMinutes: 60),
            participants: .members([sam.id]),
            createdBy: alex.id,
            createdAt: clock.now,
            calendar: calendar
        )
        let cancelled = try CalendarEvent(
            householdID: household.id,
            title: "Swimming gala",
            startDate: day(9),
            createdBy: alex.id,
            createdAt: clock.now,
            calendar: calendar
        ).cancelled(at: clock.now)

        let meal = try PlannedMeal(
            householdID: household.id,
            day: day(1),
            slot: .dinner,
            title: "Moussaka",
            ingredients: ["Aubergine", "Lamb mince"],
            plannedBy: alex.id,
            createdAt: clock.now,
            calendar: calendar
        )

        let reward = try Reward(
            householdID: household.id, name: "Swimming pool trip", cost: 100,
            createdAt: clock.now
        )
        let withdrawn = try Reward(
            householdID: household.id, name: "Swimming badge", cost: 50, isActive: false,
            createdAt: clock.now
        )

        let list = try ShoppingList(
            householdID: household.id, name: "Groceries", createdBy: alex.id,
            createdAt: clock.now
        )
        let goggles = try ShoppingItem(
            listID: list.id, householdID: household.id, name: "Swimming goggles",
            note: "The blue ones", addedBy: sam.id, addedAt: clock.now
        )
        let bought = try ShoppingItem(
            listID: list.id, householdID: household.id, name: "Swimming cap",
            addedBy: sam.id, addedAt: clock.now,
            purchase: .init(by: alex.id, at: clock.now)
        )

        let halfTerm = try AwayPeriod(
            householdID: household.id,
            firstDay: day(5),
            lastDay: day(8),
            memberIDs: [sam.id],
            reason: "Swimming camp",
            createdBy: alex.id,
            createdAt: clock.now,
            calendar: calendar
        )
        let calledOff = try AwayPeriod(
            householdID: household.id,
            firstDay: day(20),
            lastDay: day(24),
            reason: "Swimming in Spain",
            createdBy: alex.id,
            createdAt: clock.now,
            calendar: calendar
        ).cancelled(at: clock.now)

        let snapshot = HouseholdSnapshot(
            household: household,
            members: [sam, alex, gone],
            chores: [towels, bins, retired],
            rewards: [reward, withdrawn],
            shoppingLists: [list],
            shoppingItems: [goggles, bought],
            plannedMeals: [meal],
            events: [swimming, cancelled],
            awayPeriods: [halfTerm, calledOff]
        )
        return Fixture(
            snapshot: snapshot, sam: sam, alex: alex, swimming: swimming,
            towels: towels, bins: bins
        )
    }

    // MARK: Crossing screens

    @Test("One word reaches every kind of record it appears in")
    func searchCrossesScreens() throws {
        // The whole point: somebody who remembers "swimming" should not have to
        // know which of six screens the word lives on.
        let f = try makeFixture()
        let kinds = Set(f.snapshot.search.results(for: "swimming").map(\.kind))

        #expect(kinds.contains(.event))
        #expect(kinds.contains(.reward))
        #expect(kinds.contains(.shoppingItem))
        // Found through the chore's notes rather than its title.
        #expect(kinds.contains(.chore))
    }

    @Test("An ingredient finds the meal that uses it")
    func ingredientsAreSearchable() throws {
        // "What were we doing with the aubergine" is a question about the meal
        // plan that nobody would think to ask the meal plan.
        let f = try makeFixture()
        let results = f.snapshot.search.results(for: "aubergine")

        #expect(results.count == 1)
        #expect(results.first?.title == "Moussaka")
        #expect(results.first?.strength == .contains)
    }

    @Test("A location finds the event held there")
    func locationsAreSearchable() throws {
        let f = try makeFixture()
        let results = f.snapshot.search.results(for: "riverside")
        #expect(results.map(\.title) == ["Swimming lesson"])
    }

    // MARK: Ranking

    @Test("The stronger kind of match comes first")
    func rankingPrefersStrongerMatches() throws {
        let f = try makeFixture()
        let strengths = f.snapshot.search.results(for: "swimming").map(\.strength)
        #expect(strengths == strengths.sorted())
        // "Swimming lesson" starts with the query; the towels chore only
        // mentions it in its notes.
        #expect(strengths.first == .prefix)
    }

    @Test("An exact name beats one that merely starts with the query")
    func exactBeatsPrefix() throws {
        let f = try makeFixture()
        let results = f.snapshot.search.results(for: "bins")
        #expect(results.first?.strength == .exact)
        #expect(results.first?.title == "Bins")
    }

    @Test("A word inside the name beats a match buried in notes")
    func wordPrefixBeatsContains() throws {
        let f = try makeFixture()
        let results = f.snapshot.search.results(for: "towels")
        #expect(results.first?.title == "Hang up the wet towels")
        #expect(results.first?.strength == .wordPrefix)
    }

    @Test("Text that is not the record's own name can only ever be a weak hit")
    func secondaryTextNeverRanksHighly() throws {
        // A chore whose *notes* begin with the query is not a better answer
        // than one actually called that.
        let f = try makeFixture()
        let match = HouseholdSearch.match(
            "after", in: "Hang up the wet towels",
            alsoIn: [
                "After swimming, not the next morning"
            ])
        #expect(match == .contains)
    }

    // MARK: Folding

    @Test("Case, accents, and padding are ignored")
    func foldsTheQuery() throws {
        let f = try makeFixture()
        #expect(f.snapshot.search.results(for: "  MOUSSAKA ").count == 1)
        #expect(f.snapshot.search.results(for: "swimming lesson").count == 1)
        #expect(HouseholdSearch.fold("  Bánh   Mì  ") == "banh mi")
    }

    @Test("Whitespace inside the query is collapsed, not taken literally")
    func collapsesInnerWhitespace() throws {
        let f = try makeFixture()
        #expect(f.snapshot.search.results(for: "swimming    lesson").count == 1)
    }

    @Test("The shortcut for one-word queries agrees with the long way round")
    func fastPathAgreesWithFolding() {
        // A query with no space is answered without building a folded copy of
        // the text, which is sound only because collapsing whitespace can
        // neither create nor destroy a match that contains none. This is the
        // test that says so out loud, including for the names where it is
        // least obvious.
        let names = [
            "Swimming lesson", "Bánh mì", "  Bánh   mì  ", "GRAPEFRUIT",
            "Tidy  your   room", "Crème fraîche", "école", "no match here",
        ]
        let queries = ["swimming", "banh", "mi", "grapefruit", "room", "creme", "ecole", "zzz"]

        for name in names {
            for query in queries {
                let needle = HouseholdSearch.fold(query)
                let theLongWay = HouseholdSearch.fold(name).contains(needle)
                let matched = HouseholdSearch.match(needle, in: name) != nil
                #expect(matched == theLongWay, "\(query) in \(name)")
            }
        }
    }

    @Test("A multi-word query still finds a name typed with extra spaces")
    func multiWordQueriesTakeTheLongWay() {
        // The shortcut deliberately does not apply here: "tidy your room" has
        // to find a record somebody typed with two spaces in it.
        let needle = HouseholdSearch.fold("tidy your room")
        #expect(HouseholdSearch.match(needle, in: "Tidy  your   room") == .exact)
        #expect(HouseholdSearch.match(needle, in: "Please tidy  your room") == .contains)
    }

    // MARK: What is left out

    @Test("A single character is not a query")
    func shortQueriesReturnNothing() throws {
        // One letter matches most of a household, and answering it is slower
        // and less useful than waiting for the second keystroke.
        let f = try makeFixture()
        #expect(f.snapshot.search.results(for: "s").isEmpty)
        #expect(f.snapshot.search.results(for: " ").isEmpty)
        #expect(f.snapshot.search.results(for: "").isEmpty)
    }

    @Test("Retired records stay out of the way until they are asked for")
    func retiredRecordsAreScoped() throws {
        let f = try makeFixture()
        let active = f.snapshot.search.results(for: "swimming")
        #expect(active.allSatisfy { !$0.isRetired })

        let everything = f.snapshot.search.results(for: "swimming", scope: .everything)
        #expect(everything.count > active.count)
        // The archived chore, the cancelled event, the withdrawn reward, the
        // cap that was already bought, and the holiday that was called off.
        #expect(everything.filter(\.isRetired).count == 5)
    }

    @Test("A member who has left is found only when everything is asked for")
    func removedMembersAreScoped() throws {
        let f = try makeFixture()
        #expect(f.snapshot.search.results(for: "sasha").isEmpty)

        let everything = f.snapshot.search.results(for: "sasha", scope: .everything)
        #expect(everything.map(\.title) == ["Sasha"])
        #expect(everything.first?.isRetired == true)
    }

    @Test("A trip is found by where they went")
    func findsATripByItsReason() throws {
        let f = try makeFixture()
        let hit = try #require(
            f.snapshot.search.results(for: "Swimming camp").first
        )
        #expect(hit.kind == .awayPeriod)
        #expect(hit.title == "Swimming camp")
        #expect(hit.detail == "Sam · 4 days")
    }

    @Test("A trip is found by the name of whoever is on it")
    func findsATripByWhoIsOnIt() throws {
        let f = try makeFixture()
        let results = f.snapshot.search.results(for: "Sam")

        // The person comes first and their trip comes with them, which is the
        // whole reason the search crosses screens: nobody would think to ask
        // the away screen when Sam is at his gran's.
        #expect(results.first?.kind == .member)
        #expect(
            results.contains {
                if case .awayPeriod(let period) = $0.subject { return period.covers(f.sam.id) }
                return false
            }
        )
    }

    @Test("A trip with nowhere written down is still findable")
    func findsATripWithNoReason() throws {
        var f = try makeFixture()
        var snapshot = f.snapshot
        snapshot.awayPeriods = [
            try AwayPeriod(
                householdID: snapshot.household.id,
                firstDay: day(2),
                lastDay: day(3),
                createdBy: f.alex.id,
                createdAt: clock.now,
                calendar: calendar
            )
        ]
        f = Fixture(
            snapshot: snapshot, sam: f.sam, alex: f.alex, swimming: f.swimming,
            towels: f.towels, bins: f.bins
        )

        let hit = try #require(f.snapshot.search.results(for: "away").first)
        #expect(hit.title == "Away")
        #expect(hit.detail == "Everyone · 2 days")
    }

    @Test("A trip that was called off stays out of the way")
    func cancelledTripsAreRetired() throws {
        let f = try makeFixture()
        let live = f.snapshot.search.results(for: "Swimming in Spain")
        #expect(live.isEmpty)

        let everything = f.snapshot.search.results(for: "Swimming in Spain", scope: .everything)
        #expect(everything.count == 1)
        #expect(everything[0].isRetired)
    }

    @Test("Nothing matching is an empty list, not an error")
    func noMatches() throws {
        let f = try makeFixture()
        #expect(f.snapshot.search.results(for: "trombone").isEmpty)
    }

    // MARK: Shape of the answer

    @Test("The limit is honoured and keeps the best results")
    func limitKeepsTheBest() throws {
        let f = try makeFixture()
        let capped = f.snapshot.search.results(for: "swimming", limit: 2)
        #expect(capped.count == 2)

        let full = f.snapshot.search.results(for: "swimming")
        #expect(capped.map(\.id) == Array(full.prefix(2).map(\.id)))
        #expect(f.snapshot.search.results(for: "swimming", limit: 0).isEmpty)
    }

    @Test("Sections come back in a fixed order with their ranking intact")
    func sectionsAreOrdered() throws {
        let f = try makeFixture()
        let sections = f.snapshot.search.sections(for: "swimming")
        #expect(sections.map(\.kind) == sections.map(\.kind).sorted())
        #expect(sections.allSatisfy { !$0.results.isEmpty })

        let flat = f.snapshot.search.results(for: "swimming")
        #expect(sections.flatMap(\.results).count == flat.count)
    }

    @Test("The same query always produces the same order")
    func orderIsStable() throws {
        // Two chores can share a title — households really do have "Tidy your
        // room" once per child — and a list that swaps them between reads
        // reads as flickering.
        let f = try makeFixture()
        let runs = (0..<10).map { _ in f.snapshot.search.results(for: "swimming").map(\.id) }
        #expect(Set(runs.map { $0.joined(separator: ",") }).count == 1)
    }

    @Test("A result carries the record, not just its name")
    func resultsCarryTheirSubject() throws {
        let f = try makeFixture()
        let result = try #require(f.snapshot.search.results(for: "swimming lesson").first)
        guard case .event(let event) = result.subject else {
            Issue.record("expected the event")
            return
        }
        #expect(event.id == f.swimming.id)
        #expect(result.detail?.isEmpty == false)
    }
}
