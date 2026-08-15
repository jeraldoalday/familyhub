import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Chores")
struct ChoreTests {

    private let calendar = Calendar.testDefault
    private var engine: RecurrenceEngine { RecurrenceEngine(calendar: calendar) }
    private let householdID = Identifier<Household>()
    private let creator = Identifier<Member>()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        FixedDateProvider(year: year, month: month, day: day, calendar: calendar).now
    }

    private func makeChore(
        title: String = "Take out the bins",
        assignment: Chore.Assignment = .anyone,
        points: Int = 10,
        recurrence: RecurrenceRule = .daily,
        start: Date? = nil
    ) throws -> Chore {
        try Chore(
            householdID: householdID,
            title: title,
            assignment: assignment,
            points: points,
            startDate: start ?? date(2026, 3, 2),
            recurrence: recurrence,
            createdBy: creator,
            createdAt: date(2026, 3, 1)
        )
    }

    // MARK: Validation

    @Test("Rejects a blank title")
    func rejectsBlankTitle() {
        #expect(throws: DomainError.blank(field: .choreTitle)) {
            _ = try makeChore(title: "  ")
        }
    }

    @Test("Rejects points outside the permitted range")
    func rejectsAbsurdPoints() {
        #expect(throws: DomainError.outOfRange(field: .points, allowed: Limits.pointsPerChore)) {
            _ = try makeChore(points: 10_000)
        }
    }

    @Test("Allows a zero-point chore")
    func allowsZeroPoints() throws {
        // Not every household uses points, and a chore worth nothing is a
        // legitimate reminder rather than an error.
        #expect(try makeChore(points: 0).points == 0)
    }

    // MARK: Rotation

    @Test("A rotating chore advances one person per occurrence")
    func rotationAdvances() throws {
        let alex = Identifier<Member>()
        let sam = Identifier<Member>()
        let chore = try makeChore(assignment: .rotating([alex, sam]))

        #expect(chore.assignee(forOccurrenceIndex: 0) == alex)
        #expect(chore.assignee(forOccurrenceIndex: 1) == sam)
        #expect(chore.assignee(forOccurrenceIndex: 2) == alex)
        #expect(chore.assignee(forOccurrenceIndex: 3) == sam)
    }

    @Test("The rota is derived from position, not from a stored counter")
    func rotationIsDerivedFromPosition() throws {
        // A stored 'whose turn is it' counter drifts the moment a device syncs
        // late or a completion is deleted. Deriving it from the occurrence's
        // position means every device computes the same answer from the same
        // schedule, with nothing to reconcile.
        let alex = Identifier<Member>()
        let sam = Identifier<Member>()
        let jo = Identifier<Member>()
        let chore = try makeChore(assignment: .rotating([alex, sam, jo]))

        let thursday = date(2026, 3, 5)
        let index = try #require(chore.occurrenceIndex(of: thursday, using: engine))
        #expect(index == 3)
        #expect(chore.assignee(forOccurrenceIndex: index) == alex)
    }

    @Test("Skipping a day still advances the rota")
    func skippingAdvancesTheRota() throws {
        // If a skipped week did not advance the rota, the person whose turn was
        // missed would silently be made to do it again the following week.
        let alex = Identifier<Member>()
        let sam = Identifier<Member>()
        var chore = try makeChore(assignment: .rotating([alex, sam]))
        chore = chore.skipping(date(2026, 3, 3), calendar: calendar)

        let wednesday = date(2026, 3, 4)
        let index = try #require(chore.occurrenceIndex(of: wednesday, using: engine))
        #expect(index == 2)
        #expect(chore.assignee(forOccurrenceIndex: index) == alex)
    }

    @Test("An empty rotation assigns nobody rather than trapping")
    func emptyRotationIsSafe() throws {
        let chore = try makeChore(assignment: .rotating([]))
        #expect(chore.assignee(forOccurrenceIndex: 0) == nil)
    }

    @Test("An open chore may be completed by anyone")
    func openChoreAllowsAnyone() throws {
        let chore = try makeChore(assignment: .anyone)
        #expect(chore.isAssigned(Identifier<Member>(), occurrenceIndex: 0))
    }

    @Test("A chore assigned to one person excludes everyone else")
    func assignedChoreExcludesOthers() throws {
        let alex = Identifier<Member>()
        let chore = try makeChore(assignment: .member(alex))
        #expect(chore.isAssigned(alex, occurrenceIndex: 5))
        #expect(!chore.isAssigned(Identifier<Member>(), occurrenceIndex: 5))
    }

    // MARK: Skipping

    @Test("A skipped day drops out of the schedule")
    func skippedDayIsExcluded() throws {
        var chore = try makeChore()
        chore = chore.skipping(date(2026, 3, 3), calendar: calendar)

        let occurrences = chore.occurrences(
            in: date(2026, 3, 2)...date(2026, 3, 5),
            using: engine
        )
        #expect(!occurrences.contains(date(2026, 3, 3)))
        #expect(occurrences.count == 3)
    }

    @Test("Skipping is reversible and does not touch the rule")
    func skippingIsReversible() throws {
        // 'We skipped bin day that once' must not permanently rewrite the
        // schedule, so exceptions live beside the rule rather than in it.
        var chore = try makeChore()
        let original = chore.recurrence
        chore = chore.skipping(date(2026, 3, 3), calendar: calendar)
        chore = chore.unskipping(date(2026, 3, 3), calendar: calendar)

        #expect(chore.skippedDays.isEmpty)
        #expect(chore.recurrence == original)
        #expect(chore.occurs(on: date(2026, 3, 3), using: engine))
    }

    @Test("Skipping normalises the time of day")
    func skippingNormalisesTime() throws {
        // The skip is recorded from a tap at some arbitrary moment; it has to
        // match an occurrence stored at start of day.
        var chore = try makeChore()
        let afternoon = FixedDateProvider(
            year: 2026, month: 3, day: 3, hour: 15, minute: 30, calendar: calendar
        ).now
        chore = chore.skipping(afternoon, calendar: calendar)
        #expect(!chore.occurs(on: date(2026, 3, 3), using: engine))
    }

    // MARK: Archiving

    @Test("An archived chore produces no occurrences")
    func archivedChoreIsSilent() throws {
        let chore = try makeChore().archived(at: date(2026, 3, 4))
        #expect(chore.occurrences(in: date(2026, 3, 1)...date(2026, 3, 31), using: engine).isEmpty)
        #expect(chore.nextOccurrence(after: date(2026, 3, 1), using: engine) == nil)
        #expect(!chore.occurs(on: date(2026, 3, 2), using: engine))
    }

    @Test("Archiving is reversible")
    func archivingIsReversible() throws {
        let chore = try makeChore().archived(at: date(2026, 3, 4)).unarchived()
        #expect(chore.isActive)
        #expect(chore.occurs(on: date(2026, 3, 2), using: engine))
    }

    // MARK: Occurrence index

    @Test("A date before the start has no occurrence index")
    func indexBeforeStartIsNil() throws {
        let chore = try makeChore()
        #expect(chore.occurrenceIndex(of: date(2026, 3, 1), using: engine) == nil)
    }

    @Test("A date the chore does not fall on has no occurrence index")
    func indexOffScheduleIsNil() throws {
        let chore = try makeChore(recurrence: try .weekly(on: [.monday]))
        #expect(chore.occurrenceIndex(of: date(2026, 3, 3), using: engine) == nil)
        #expect(chore.occurrenceIndex(of: date(2026, 3, 9), using: engine) == 1)
    }
}
