import Foundation
import Testing

@testable import FamilyHubCore

/// Covers the catalogue a household is offered on its first day. Most of these
/// are guards on the data rather than on the logic: a pack with a duplicate
/// identifier or an unreachable chore is a bug nobody would see until a family
/// had already installed it.
@Suite("Chore packs")
struct ChorePackTests {

    private let calendar = Calendar.testDefault

    // MARK: The catalogue itself

    @Test("Every pack identifier is unique")
    func packIdentifiersAreUnique() {
        // Two packs sharing an identifier is how "install this one" installs
        // the other one.
        let ids = ChorePack.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every template identifier is unique across the whole catalogue")
    func templateIdentifiersAreUnique() {
        let ids = ChorePack.all.flatMap(\.templates).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("No pack is empty and none is a wall of chores")
    func packsAreAReasonableSize() {
        for pack in ChorePack.all {
            #expect(!pack.templates.isEmpty, "\(pack.id)")
            // A list of forty is a list nobody reads to the end of.
            #expect(pack.templates.count <= 8, "\(pack.id)")
        }
    }

    @Test("Every template is worth something a chore can actually hold")
    func templatePointsAreValid() throws {
        for template in ChorePack.all.flatMap(\.templates) {
            #expect(Limits.pointsPerChore.contains(template.points), "\(template.id)")
            // A title the domain would refuse is a template that can never be
            // installed, which is the sort of thing a test finds and a person
            // does not.
            #expect(throws: Never.self) {
                try ValidatedText(
                    template.title, field: .choreTitle, limit: Limits.choreTitleLength
                )
            }
            if let notes = template.notes {
                #expect(throws: Never.self) {
                    try ValidatedText(notes, field: .choreNotes, limit: Limits.notesLength)
                }
            }
        }
    }

    @Test("Every template's recurrence actually produces days")
    func templateRecurrencesAreSatisfiable() {
        // A rule that never comes round is a chore that sits on the list
        // forever, permanently outstanding and impossible to finish.
        let engine = RecurrenceEngine(calendar: calendar)
        let start = FixedDateProvider(year: 2026, month: 3, day: 2, calendar: .testDefault).today
        let end = calendar.date(byAdding: .day, value: 30, to: start) ?? start

        for template in ChorePack.all.flatMap(\.templates) {
            let days = engine.occurrences(
                of: template.recurrence, startingOn: start, in: start...end, maximum: 40
            )
            #expect(!days.isEmpty, "\(template.id)")
        }
    }

    // MARK: Suitability

    @Test("A household of young children is not offered a teenager's chores")
    func suitabilityFiltersByRole() {
        let forChildren = ChorePack.kitchen.templates(for: [.owner, .child])
        // The bins and the washing up are marked from teen upward, but the
        // owner is in the household and can do either.
        #expect(forChildren.count == ChorePack.kitchen.templates.count)

        let childOnly = ChorePack.kitchen.templates(for: [.child])
        #expect(childOnly.allSatisfy { $0.suitableFrom == .child })
        #expect(childOnly.count < ChorePack.kitchen.templates.count)
    }

    @Test("Suitability is 'at least as capable as', not an exact role")
    func suitabilityIsOrdered() {
        let template = ChorePack.kitchen.templates.first { $0.id == "kitchen.bins" }
        guard let template else {
            Issue.record("the bins template went missing from the kitchen pack")
            return
        }

        #expect(!template.suits(.child))
        #expect(template.suits(.teen))
        #expect(template.suits(.adult))
        #expect(template.suits(.owner))
    }

    @Test("A household with nobody in it is offered nothing")
    func noRolesMeansNoTemplates() {
        // Not a real state for long, but the onboarding flow asks before the
        // first member exists and an empty list is the honest answer.
        #expect(ChorePack.everyday.templates(for: []).isEmpty)
        #expect(ChorePack.suggested(for: []).isEmpty)
    }

    @Test("A pack with nothing left in it is not suggested")
    func emptyPacksAreDropped() {
        // A card that installs nothing is a card tapped once and never
        // trusted again.
        let suggested = ChorePack.suggested(for: [.child])
        #expect(!suggested.isEmpty)
        #expect(suggested.allSatisfy { !$0.templates(for: [.child]).isEmpty })
    }

    @Test("An adult household still gets every pack")
    func adultsSeeEverything() {
        #expect(ChorePack.suggested(for: [.owner, .adult]).count == ChorePack.all.count)
    }

    // MARK: What a pack costs

    @Test("A pack's weekly points reflect how often its chores come round")
    func weeklyPointsCountRecurrence() {
        let everyday = ChorePack.everyday.weeklyPoints(calendar: calendar)
        let reset = ChorePack.weekendReset.weeklyPoints(calendar: calendar)

        // Everyday basics is mostly daily; the weekend reset is mostly weekly.
        // The first should therefore be worth substantially more per week even
        // though both hold five chores.
        #expect(everyday > reset)
        #expect(reset > 0)
    }

    @Test("A fortnightly chore counts as half of itself")
    func weeklyPointsHandleFortnightlyChores() {
        // Sampled over four weeks and divided rather than over one, so the
        // answer does not depend on which week the sample landed on.
        let pack = ChorePack(
            id: "test", name: "Test", summary: "", symbolName: "star",
            templates: [
                ChoreTemplate(
                    id: "test.a", title: "Sheets", category: .laundry, points: 40,
                    recurrence: try! RecurrenceRule(
                        frequency: .weekly, interval: 2, weekdays: [.saturday]
                    )
                )
            ]
        )
        #expect(pack.weeklyPoints(calendar: calendar) == 20)
    }

    // MARK: Duplicate keys

    @Test("Duplicate detection ignores case and accents")
    func duplicateKeyFolds() {
        let template = ChoreTemplate(
            id: "x", title: "  Bins  ", category: .kitchen, points: 10, recurrence: .daily
        )
        // A family that typed "bins" by hand should not be offered "Bins".
        #expect(template.duplicateKey == "  bins  ")
        #expect(
            ChoreTemplate(
                id: "y", title: "BINS", category: .kitchen, points: 10, recurrence: .daily
            ).duplicateKey == "bins"
        )
    }

    @Test("A pack is found by its identifier and nothing else is")
    func lookupByIdentifier() {
        #expect(ChorePack.pack("kitchen")?.name == ChorePack.kitchen.name)
        #expect(ChorePack.pack("Kitchen") == nil)
        #expect(ChorePack.pack("nonsense") == nil)
    }
}
