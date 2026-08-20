import Foundation
import Testing

@testable import FamilyHubCore

/// Covers reading the calendar: what is on today, what is next, and the
/// double-bookings that are the reason a shared calendar is worth having.
@Suite("Family calendar")
struct FamilyCalendarTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    private let householdID = Identifier<Household>()
    private let parentID = Identifier<Member>()
    private let alexID = Identifier<Member>()
    private let samID = Identifier<Member>()

    /// March 2026 — the 2nd is a Monday.
    private func date(_ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        FixedDateProvider(
            year: 2026, month: 3, day: day, hour: hour, minute: minute, calendar: .testDefault
        ).now
    }

    private func members() throws -> [Member] {
        [
            try Member(
                id: parentID, householdID: householdID, name: "Mary", role: .adult,
                joinedAt: date(1)
            ),
            try Member(
                id: alexID, householdID: householdID, name: "Alex", role: .teen, joinedAt: date(1)
            ),
            try Member(
                id: samID, householdID: householdID, name: "Sam", role: .child, joinedAt: date(1)
            ),
        ]
    }

    private func event(
        _ title: String,
        day: Int = 2,
        timing: CalendarEvent.Timing = .at(hour: 16, lasting: 60),
        recurrence: RecurrenceRule = .once,
        participants: CalendarEvent.Participants = .everyone,
        skippedDays: Set<Date> = [],
        cancelledAt: Date? = nil
    ) throws -> CalendarEvent {
        try CalendarEvent(
            householdID: householdID,
            title: title,
            startDate: date(day),
            timing: timing,
            recurrence: recurrence,
            skippedDays: skippedDays,
            participants: participants,
            cancelledAt: cancelledAt,
            createdBy: parentID,
            createdAt: date(1),
            calendar: calendar
        )
    }

    private func makeCalendar(_ events: [CalendarEvent]) -> FamilyCalendar {
        FamilyCalendar(events: events, engine: RecurrenceEngine(calendar: calendar))
    }

    // MARK: Expansion

    @Test("A cancelled event is dropped before anything else looks at it")
    func cancelledEventsAreDropped() throws {
        let subject = makeCalendar([
            try event("Swimming"),
            try event("Dentist", cancelledAt: date(1)),
        ])
        #expect(subject.events.map(\.title.value) == ["Swimming"])
        #expect(subject.occurrences(on: date(2)).count == 1)
    }

    @Test("A recurring event is expanded across the window in one pass")
    func recurringEventsExpand() throws {
        let subject = makeCalendar([
            try event("Swimming", recurrence: try .weekly(on: [.monday]))
        ])
        let found = subject.occurrences(from: date(1), to: date(31))
        #expect(found.map(\.day) == [date(2), date(9), date(16), date(23), date(30)])
        #expect(found.map(\.occurrenceIndex) == [0, 1, 2, 3, 4])
    }

    @Test("A skipped week does not appear")
    func skippedDaysAreOmitted() throws {
        let subject = makeCalendar([
            try event("Swimming", recurrence: try .weekly(on: [.monday]), skippedDays: [date(9)])
        ])
        #expect(subject.occurrences(on: date(9)).isEmpty)
        #expect(subject.occurrences(on: date(16)).count == 1)
    }

    @Test("An inverted range is read as the single day it starts on")
    func invertedRangeIsClamped() throws {
        let subject = makeCalendar([try event("Swimming")])
        #expect(subject.occurrences(from: date(2), to: date(1)).count == 1)
        #expect(subject.days(from: date(2), to: date(1)).count == 1)
    }

    // MARK: Ordering

    @Test("All-day entries head the day, then the day runs in time order")
    func dayIsOrdered() throws {
        let subject = makeCalendar([
            try event("Football", timing: .at(hour: 18, lasting: 90)),
            try event("Dentist", timing: .at(hour: 9, lasting: 30)),
            try event("Half term", timing: .allDay),
        ])
        let today = subject.occurrences(on: date(2))
        #expect(today.map(\.event.title.value) == ["Half term", "Dentist", "Football"])
    }

    @Test("Two things at the same minute settle alphabetically")
    func tiesSettleAlphabetically() throws {
        let subject = makeCalendar([
            try event("Zumba", timing: .at(hour: 9, lasting: 60)),
            try event("Assembly", timing: .at(hour: 9, lasting: 60)),
        ])
        #expect(
            subject.occurrences(on: date(2)).map(\.event.title.value) == ["Assembly", "Zumba"]
        )
    }

    @Test("A day splits into the entries that head it and the ones inside it")
    func daySplitsAllDayFromTimed() throws {
        let subject = makeCalendar([
            try event("Half term", timing: .allDay),
            try event("Dentist", timing: .at(hour: 9, lasting: 30)),
        ])
        let day = subject.days(from: date(2), to: date(2))[0]
        #expect(day.allDay.map(\.event.title.value) == ["Half term"])
        #expect(day.timed.map(\.event.title.value) == ["Dentist"])
        #expect(day.count == 2)
        #expect(!day.isEmpty)
    }

    // MARK: Days and weeks

    @Test("Empty days are still returned, so a grid has something to tap")
    func emptyDaysAreIncluded() throws {
        let subject = makeCalendar([try event("Swimming", day: 4)])
        let days = subject.days(from: date(2), to: date(8))
        #expect(days.count == 7)
        #expect(days.filter(\.isEmpty).count == 6)
        #expect(days.first { !$0.isEmpty }?.day == date(4))
    }

    @Test("A week runs seven days from the household's own start of week")
    func weekIsSevenDays() throws {
        let subject = makeCalendar([
            try event("Swimming", day: 4),
            try event("Roast", day: 8, timing: .at(hour: 13, lasting: 120)),
        ])
        let week = subject.week(containing: date(5))
        #expect(week.start == date(2))
        #expect(week.end == date(8))
        #expect(week.days.count == 7)
        #expect(week.count == 2)
        #expect(!week.isEmpty)
        #expect(week.busyDays.map(\.day) == [date(4), date(8)])
        #expect(week.occurrences.map(\.event.title.value) == ["Swimming", "Roast"])
    }

    @Test("A clear week says so")
    func emptyWeek() throws {
        let subject = makeCalendar([try event("Swimming", day: 20)])
        #expect(subject.week(containing: date(5)).isEmpty)
    }

    // MARK: Whose day it is

    @Test("A household-wide event lands on everybody's day")
    func householdWideEventsLandOnEveryone() throws {
        let subject = makeCalendar([try event("Half term", timing: .allDay)])
        #expect(subject.occurrences(on: date(2), for: samID).count == 1)
        #expect(subject.occurrences(on: date(2), for: alexID).count == 1)
    }

    @Test("A named event lands only on the days of the people named")
    func namedEventsLandOnTheirPeople() throws {
        let subject = makeCalendar([
            try event("Dentist", timing: .at(hour: 9, lasting: 30), participants: .members([samID]))
        ])
        #expect(subject.occurrences(on: date(2), for: samID).count == 1)
        #expect(subject.occurrences(on: date(2), for: alexID).isEmpty)
        #expect(subject.occurrences(on: date(2)).count == 1)
    }

    @Test("A week can be read for one person")
    func weekFiltersByMember() throws {
        let subject = makeCalendar([
            try event("Football", day: 3, participants: .members([alexID])),
            try event("Dentist", day: 4, participants: .members([samID])),
            try event("Half term", day: 5, timing: .allDay),
        ])
        #expect(subject.week(containing: date(2), for: samID).count == 2)
        #expect(subject.week(containing: date(2), for: alexID).count == 2)
        #expect(subject.week(containing: date(2)).count == 3)
    }

    // MARK: What is next

    @Test("What is next skips what has already started")
    func nextSkipsWhatIsUnderway() throws {
        let subject = makeCalendar([
            try event("Dentist", timing: .at(hour: 9, lasting: 60)),
            try event("Football", timing: .at(hour: 18, lasting: 90)),
        ])
        let next = subject.next(after: date(2, hour: 9, minute: 30))
        #expect(next?.event.title.value == "Football")
    }

    @Test("What is next looks into following days")
    func nextLooksAhead() throws {
        let subject = makeCalendar([try event("Swimming", day: 6)])
        #expect(subject.next(after: date(2, hour: 20))?.day == date(6))
    }

    @Test("Nothing inside the horizon answers nothing")
    func nextGivesUpPastTheHorizon() throws {
        let subject = makeCalendar([try event("Swimming", day: 25)])
        #expect(subject.next(after: date(2), horizonDays: 3) == nil)
    }

    @Test("All-day entries are never what is next, because they are not a time")
    func nextIgnoresAllDay() throws {
        let subject = makeCalendar([try event("Half term", day: 3, timing: .allDay)])
        #expect(subject.next(after: date(2)) == nil)
    }

    @Test("What is happening now includes an event that started last night")
    func happeningSpansMidnight() throws {
        let subject = makeCalendar([
            try event("Party", day: 2, timing: .at(hour: 21, lasting: 4 * 60))
        ])
        let now = date(3, hour: 0, minute: 30)
        #expect(subject.happening(at: now).map(\.event.title.value) == ["Party"])
        #expect(subject.happening(at: date(3, hour: 2)).isEmpty)
    }

    @Test("An occurrence knows whether a moment falls inside it")
    func occurrenceKnowsItsSpan() throws {
        let subject = makeCalendar([try event("Swimming", timing: .at(hour: 16, lasting: 60))])
        let occurrence = try #require(subject.occurrences(on: date(2)).first)
        #expect(occurrence.isHappening(at: date(2, hour: 16, minute: 30)))
        #expect(!occurrence.isHappening(at: date(2, hour: 17)))
        #expect(occurrence.start == date(2, hour: 16))
        #expect(occurrence.end == date(2, hour: 17))
    }

    // MARK: Clashes

    @Test("Two things for the same person at the same time clash")
    func sharedParticipantClashes() throws {
        let subject = makeCalendar([
            try event(
                "Swimming", timing: .at(hour: 16, lasting: 60), participants: .members([samID])
            ),
            try event(
                "Dentist", timing: .at(hour: 16, minute: 30, lasting: 30),
                participants: .members([samID])
            ),
        ])
        let clashes = subject.clashes(on: date(2), among: try members())
        #expect(clashes.count == 1)
        let clash = try #require(clashes.first)
        #expect(clash.earlier.event.title.value == "Swimming")
        #expect(clash.later.event.title.value == "Dentist")
        #expect(clash.overlapMinutes == 30)
        #expect(clash.members.map(\.id) == [samID])
    }

    @Test("Two children busy at once is a Tuesday, not a clash")
    func differentPeopleDoNotClash() throws {
        let subject = makeCalendar([
            try event(
                "Swimming", timing: .at(hour: 16, lasting: 60), participants: .members([samID])
            ),
            try event(
                "Football", timing: .at(hour: 16, lasting: 60), participants: .members([alexID])
            ),
        ])
        #expect(subject.clashes(on: date(2), among: try members()).isEmpty)
    }

    @Test("An all-day entry never clashes with anything")
    func allDayNeverClashes() throws {
        let subject = makeCalendar([
            try event("Half term", timing: .allDay),
            try event("Dentist", timing: .at(hour: 9, lasting: 30)),
        ])
        #expect(subject.clashes(on: date(2), among: try members()).isEmpty)
    }

    @Test("Things that merely touch at the boundary do not clash")
    func adjacentEventsDoNotClash() throws {
        let subject = makeCalendar([
            try event("Swimming", timing: .at(hour: 16, lasting: 60)),
            try event("Tea", timing: .at(hour: 17, lasting: 30)),
        ])
        #expect(subject.clashes(on: date(2), among: try members()).isEmpty)
    }

    @Test("A member who has left is not reported as double-booked")
    func removedMembersAreNotCounted() throws {
        let gone = try Member(
            id: samID, householdID: householdID, name: "Sam", role: .child, joinedAt: date(1)
        ).removed(at: date(1))
        let subject = makeCalendar([
            try event(
                "Swimming", timing: .at(hour: 16, lasting: 60), participants: .members([samID])
            ),
            try event(
                "Dentist", timing: .at(hour: 16, lasting: 60), participants: .members([samID])
            ),
        ])
        #expect(subject.clashes(on: date(2), among: [gone]).isEmpty)
    }

    @Test("Clashes are found across a whole range, earliest first")
    func clashesAcrossARange() throws {
        let subject = makeCalendar([
            try event("Swimming", day: 2, timing: .at(hour: 16, lasting: 60)),
            try event("Dentist", day: 2, timing: .at(hour: 16, lasting: 60)),
            try event("Cinema", day: 4, timing: .at(hour: 19, lasting: 120)),
            try event("Homework club", day: 4, timing: .at(hour: 20, lasting: 60)),
        ])
        let clashes = subject.clashes(from: date(1), to: date(8), among: try members())
        #expect(clashes.count == 2)
        #expect(clashes.map(\.earlier.day) == [date(2), date(4)])
    }

    @Test("A proposed span reports what is already in the way")
    func conflictsForAProposedSpan() throws {
        let subject = makeCalendar([
            try event(
                "Swimming", timing: .at(hour: 16, lasting: 60), participants: .members([samID])
            ),
            try event(
                "Football", timing: .at(hour: 16, lasting: 60), participants: .members([alexID])
            ),
        ])
        let proposed = DateInterval(
            start: date(2, hour: 16, minute: 30), end: date(2, hour: 17, minute: 30)
        )
        #expect(
            subject.conflicts(for: samID, during: proposed).map(\.event.title.value)
                == ["Swimming"]
        )
        #expect(subject.conflicts(for: parentID, during: proposed).isEmpty)
    }

    @Test("A proposed span sees an event that began the previous evening")
    func conflictsSeeYesterdaysLateEvent() throws {
        let subject = makeCalendar([
            try event(
                "Party", day: 2, timing: .at(hour: 21, lasting: 5 * 60),
                participants: .members([alexID])
            )
        ])
        let proposed = DateInterval(start: date(3, hour: 1), end: date(3, hour: 3))
        #expect(subject.conflicts(for: alexID, during: proposed).count == 1)
    }

    // MARK: Identity

    @Test("The same event on the same day is the same row across reloads")
    func occurrenceIdentityIsStable() throws {
        let swimming = try event("Swimming", recurrence: try .weekly(on: [.monday]))
        let first = makeCalendar([swimming]).occurrences(on: date(9))
        let second = makeCalendar([swimming]).occurrences(on: date(9))
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.first?.id != makeCalendar([swimming]).occurrences(on: date(16)).first?.id)
    }

    @Test("Occurrence keys sort by day and then by event")
    func occurrenceKeysAreOrdered() {
        let eventA = Identifier<CalendarEvent>()
        let eventB = Identifier<CalendarEvent>()
        let monday = FamilyCalendar.OccurrenceKey(eventID: eventA, day: date(2))
        let tuesday = FamilyCalendar.OccurrenceKey(eventID: eventA, day: date(3))
        #expect(monday < tuesday)

        let sameDayA = FamilyCalendar.OccurrenceKey(eventID: min(eventA, eventB), day: date(2))
        let sameDayB = FamilyCalendar.OccurrenceKey(eventID: max(eventA, eventB), day: date(2))
        #expect(sameDayA < sameDayB)
    }
}
