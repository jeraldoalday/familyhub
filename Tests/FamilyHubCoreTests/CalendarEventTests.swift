import Foundation
import Testing

@testable import FamilyHubCore

/// Covers the calendar event itself: what it refuses to be built as, where an
/// occurrence actually sits in the day, and who it lands on.
@Suite("Calendar events")
struct CalendarEventTests {

    private let calendar = Calendar.testDefault
    private let householdID = Identifier<Household>()
    private let parent = Identifier<Member>()
    private let alex = Identifier<Member>()
    private let sam = Identifier<Member>()

    /// March 2026 — the 2nd is a Monday.
    private func date(_ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        FixedDateProvider(
            year: 2026, month: 3, day: day, hour: hour, minute: minute, calendar: .testDefault
        ).now
    }

    private func event(
        title: String = "Swimming",
        notes: String? = nil,
        location: String? = nil,
        kind: CalendarEvent.Kind = .activity,
        day: Int = 2,
        hour: Int = 0,
        timing: CalendarEvent.Timing = .at(hour: 16, lasting: 60),
        recurrence: RecurrenceRule = .once,
        skippedDays: Set<Date> = [],
        participants: CalendarEvent.Participants = .everyone,
        reminderMinutesBefore: Int? = nil,
        cancelledAt: Date? = nil
    ) throws -> CalendarEvent {
        try CalendarEvent(
            householdID: householdID,
            title: title,
            notes: notes,
            location: location,
            kind: kind,
            startDate: date(day, hour: hour),
            timing: timing,
            recurrence: recurrence,
            skippedDays: skippedDays,
            participants: participants,
            reminderMinutesBefore: reminderMinutesBefore,
            cancelledAt: cancelledAt,
            createdBy: parent,
            createdAt: date(1),
            calendar: calendar
        )
    }

    private var engine: RecurrenceEngine { RecurrenceEngine(calendar: calendar) }

    // MARK: Construction

    @Test("The start day is pinned to midnight whatever time it was typed at")
    func startDayIsNormalised() throws {
        let afternoon = try event(hour: 19)
        #expect(afternoon.startDate == date(2))
    }

    @Test("An event needs something to call it")
    func blankTitleIsRefused() {
        #expect(throws: DomainError.blank(field: .eventTitle)) {
            _ = try event(title: "   ")
        }
    }

    @Test("A title longer than the field allows is refused")
    func longTitleIsRefused() {
        #expect(
            throws: DomainError.tooLong(field: .eventTitle, limit: Limits.eventTitleLength)
        ) {
            _ = try event(title: String(repeating: "a", count: Limits.eventTitleLength + 1))
        }
    }

    @Test("An address fits where a title would not")
    func locationHasItsOwnLimit() throws {
        let address = String(repeating: "b", count: Limits.eventTitleLength + 10)
        let booked = try event(location: address)
        #expect(booked.location?.value == address)

        #expect(
            throws: DomainError.tooLong(field: .eventTitle, limit: Limits.eventLocationLength)
        ) {
            _ = try event(location: String(repeating: "b", count: Limits.eventLocationLength + 1))
        }
    }

    @Test("A start time outside the day is refused")
    func startMinuteIsBounded() {
        #expect(throws: DomainError.self) {
            _ = try event(timing: .timed(startMinute: 24 * 60, durationMinutes: 30))
        }
        #expect(throws: DomainError.self) {
            _ = try event(timing: .timed(startMinute: -1, durationMinutes: 30))
        }
    }

    @Test("An event lasting longer than a day has to be an all-day one")
    func durationIsBounded() {
        #expect(
            throws: DomainError.outOfRange(field: .quantity, allowed: Limits.eventDuration)
        ) {
            _ = try event(timing: .at(hour: 9, lasting: 24 * 60 + 1))
        }
        #expect(throws: DomainError.outOfRange(field: .quantity, allowed: Limits.eventDuration)) {
            _ = try event(timing: .at(hour: 9, lasting: 0))
        }
    }

    @Test("A reminder further ahead than the planner plans is refused")
    func reminderLeadIsBounded() {
        #expect(
            throws: DomainError.outOfRange(field: .quantity, allowed: Limits.eventReminderLead)
        ) {
            _ = try event(reminderMinutesBefore: 8 * 24 * 60)
        }
    }

    @Test("Skipped days are normalised on the way in")
    func skippedDaysAreNormalised() throws {
        let dropped = try event(skippedDays: [date(9, hour: 14)])
        #expect(dropped.skippedDays == [date(9)])
    }

    // MARK: The span an occurrence covers

    @Test("An all-day event covers the day, midnight to midnight")
    func allDaySpansTheDay() throws {
        let holiday = try event(timing: .allDay)
        let span = holiday.interval(on: date(2), calendar: calendar)
        #expect(span.start == date(2))
        #expect(span.end == date(3))
        #expect(holiday.isAllDay)
        #expect(!holiday.endsAfterMidnight)
    }

    @Test("A timed event starts at its minute and runs for its duration")
    func timedSpansItsMinutes() throws {
        let lesson = try event(timing: .at(hour: 16, minute: 30, lasting: 45))
        let span = lesson.interval(on: date(2), calendar: calendar)
        #expect(span.start == date(2, hour: 16, minute: 30))
        #expect(span.end == date(2, hour: 17, minute: 15))
        #expect(span.duration == 45 * 60)
    }

    @Test("A party that ends after midnight is still one event on one day")
    func timedMayRunPastMidnight() throws {
        let party = try event(timing: .at(hour: 21, lasting: 4 * 60))
        let span = party.interval(on: date(2), calendar: calendar)
        #expect(span.start == date(2, hour: 21))
        #expect(span.end == date(3, hour: 1))
        #expect(party.endsAfterMidnight)
    }

    @Test("The same recurring event happens at the same clock time on each day")
    func timeIsStableAcrossDays() throws {
        let lesson = try event(timing: .at(hour: 16), recurrence: try .weekly(on: [.monday]))
        let first = lesson.interval(on: date(2), calendar: calendar)
        let second = lesson.interval(on: date(9), calendar: calendar)
        #expect(calendar.component(.hour, from: first.start) == 16)
        #expect(calendar.component(.hour, from: second.start) == 16)
    }

    // MARK: Scheduling

    @Test("A weekly event produces one occurrence per week from its start")
    func weeklyOccurrences() throws {
        let lesson = try event(recurrence: try .weekly(on: [.monday]))
        let days = lesson.occurrences(in: date(1)...date(31), using: engine)
        #expect(days == [date(2), date(9), date(16), date(23), date(30)])
    }

    @Test("A skipped week is dropped but still advances the sequence")
    func skippedDaysAreDroppedAndCounted() throws {
        let lesson = try event(
            recurrence: try .weekly(on: [.monday]),
            skippedDays: [date(9)]
        )
        let occurrences = lesson.indexedOccurrences(in: date(1)...date(20), using: engine)
        #expect(occurrences.map(\.day) == [date(2), date(16)])
        #expect(occurrences.map(\.index) == [0, 2])
    }

    @Test("A cancelled event falls on no day at all")
    func cancelledEventHasNoOccurrences() throws {
        let dropped = try event(
            recurrence: try .weekly(on: [.monday]),
            cancelledAt: date(3)
        ).cancelled(at: date(3))
        #expect(dropped.occurrences(in: date(1)...date(31), using: engine).isEmpty)
        #expect(!dropped.occurs(on: date(9), using: engine))
        #expect(dropped.nextOccurrence(after: date(2), using: engine) == nil)
        #expect(!dropped.isActive)

        let back = dropped.reinstated()
        #expect(back.isActive)
        #expect(back.occurs(on: date(9), using: engine))
    }

    @Test("The next occurrence looks past the day asked about")
    func nextOccurrenceLooksForward() throws {
        let lesson = try event(recurrence: try .weekly(on: [.monday]))
        #expect(lesson.nextOccurrence(after: date(2), using: engine) == date(9))
    }

    // MARK: Participants

    @Test("A household-wide event lands on everybody")
    func everyoneIncludesEverybody() throws {
        let halfTerm = try event(participants: .everyone)
        #expect(halfTerm.participants.includes(alex))
        #expect(halfTerm.participants.includes(sam))
        #expect(halfTerm.participants.namedMemberIDs.isEmpty)
    }

    @Test("A named event lands only on the people named")
    func namedParticipants() throws {
        let dentist = try event(participants: .members([sam]))
        #expect(dentist.participants.includes(sam))
        #expect(!dentist.participants.includes(alex))
        #expect(dentist.participants.namedMemberIDs == [sam])
    }

    @Test("Resolving participants skips people who have left")
    func resolvedSkipsRemovedMembers() throws {
        let stillHere = try Member(
            id: alex, householdID: householdID, name: "Alex", role: .teen, joinedAt: date(1)
        )
        let gone = try Member(
            id: sam, householdID: householdID, name: "Sam", role: .child, joinedAt: date(1)
        ).removed(at: date(2))

        let outing = try event(participants: .members([alex, sam]))
        let people = outing.participants.resolved(against: [stillHere, gone])
        #expect(people.map(\.id) == [alex])
    }

    @Test("A collection filters to the events one person is on")
    func collectionFiltersByMember() throws {
        let shared = try event(title: "Half term", participants: .everyone)
        let hers = try event(title: "Dentist", participants: .members([sam]))
        let his = try event(title: "Football", participants: .members([alex]))
        let all = [shared, hers, his]

        #expect(all.concerning(sam).map(\.title.value) == ["Half term", "Dentist"])
        #expect(all.active.count == 3)
        #expect([shared.cancelled(at: date(3)), hers].active.map(\.title.value) == ["Dentist"])
    }

    // MARK: Display

    @Test("An all-day event says so rather than showing midnight")
    func allDayTimeSummary() throws {
        let holiday = try event(timing: .allDay)
        #expect(holiday.timeSummary(on: date(2), calendar: calendar) == "All day")
    }

    @Test("A timed event shows both ends of its span")
    func timedSummaryShowsBothEnds() throws {
        let lesson = try event(timing: .at(hour: 16, lasting: 90))
        let phrase = lesson.timeSummary(on: date(2), calendar: calendar)
        #expect(phrase.contains("–"))
    }

    @Test("A summary names the people an event is for, and nobody for a shared one")
    func summaryNamesParticipants() throws {
        let members = [
            try Member(
                id: alex, householdID: householdID, name: "Alex", role: .teen, joinedAt: date(1)
            ),
            try Member(
                id: sam, householdID: householdID, name: "Sam", role: .child, joinedAt: date(1)
            ),
        ]
        let shared = try event(title: "Half term", participants: .everyone)
        let hers = try event(title: "Dentist", participants: .members([sam]))

        #expect(shared.summary(members: members) == "Half term")
        #expect(hers.summary(members: members) == "Dentist — Sam")
    }

    // MARK: Mutation

    @Test("Editing returns a copy and leaves the original alone")
    func mutationIsCopying() throws {
        let original = try event()
        let edited =
            try original
            .retitled(to: "Swimming lesson")
            .withNotes("Bring the blue bag")
            .at("Leisure centre")
            .ofKind(.school)
            .timed(.at(hour: 17, lasting: 30))
            .attendedBy(.members([alex]))
            .reminding(minutesBefore: 30)

        #expect(original.title.value == "Swimming")
        #expect(edited.title.value == "Swimming lesson")
        #expect(edited.notes?.value == "Bring the blue bag")
        #expect(edited.location?.value == "Leisure centre")
        #expect(edited.kind == .school)
        #expect(edited.timing == .timed(startMinute: 17 * 60, durationMinutes: 30))
        #expect(edited.participants == .members([alex]))
        #expect(edited.reminderMinutesBefore == 30)
        #expect(edited.hasReminder)
    }

    @Test("Clearing the optional fields empties them rather than storing blanks")
    func optionalFieldsClear() throws {
        let filled = try event(notes: "Bring kit", location: "Pool", reminderMinutesBefore: 15)
        let cleared = try filled.withNotes(nil).at("   ").reminding(minutesBefore: nil)
        #expect(cleared.notes == nil)
        #expect(cleared.location == nil)
        #expect(cleared.reminderMinutesBefore == nil)
        #expect(!cleared.hasReminder)
    }

    @Test("Rescheduling normalises the new start day")
    func reschedulingNormalises() throws {
        let moved = try event().rescheduled(
            startingOn: date(9, hour: 22),
            recurrence: try .weekly(on: [.monday]),
            calendar: calendar
        )
        #expect(moved.startDate == date(9))
        #expect(moved.recurrence.frequency == .weekly)
    }

    @Test("Skipping and unskipping a day are exact inverses")
    func skippingRoundTrips() throws {
        let lesson = try event(recurrence: try .weekly(on: [.monday]))
        let skipped = lesson.skipping(date(9, hour: 8), calendar: calendar)
        #expect(skipped.skippedDays == [date(9)])
        #expect(skipped.unskipping(date(9), calendar: calendar).skippedDays.isEmpty)
    }

    // MARK: Round-tripping

    @Test("An event survives a round trip through JSON")
    func codableRoundTrip() throws {
        let original = try event(
            notes: "Bring kit",
            location: "Leisure centre",
            timing: .at(hour: 16, minute: 15, lasting: 45),
            recurrence: try .weekly(on: [.monday, .thursday]),
            skippedDays: [date(9)],
            participants: .members([alex, sam]),
            reminderMinutesBefore: 30
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CalendarEvent.self, from: data)
        #expect(restored == original)
    }

    // MARK: Kinds

    @Test("Every kind has a label and a glyph")
    func kindsAreComplete() {
        for kind in CalendarEvent.Kind.allCases {
            #expect(!kind.label.isEmpty)
            #expect(!kind.symbolName.isEmpty)
            #expect(kind.id == kind.rawValue)
        }
    }
}
