import Foundation

/// Something on the family calendar.
///
/// Like meal planning before it, the calendar has been half-present in the
/// domain since the beginning: ``DomainError/Field/eventTitle`` names its one
/// piece of validated text, ``DomainError/Action/manageCalendar`` says who may
/// change it, and the role summaries promise a teen "can see the whole family
/// calendar". This is the record those three have been referring to.
///
/// An event is a *template with a schedule*, exactly as a ``Chore`` is, and for
/// the same reason: swimming every Tuesday is one row, not five hundred and
/// twenty. Sharing ``RecurrenceRule`` with chores is not merely thrift — it
/// means the fortnightly-phase and end-date behaviour a family has already
/// learned from the chore editor behaves identically here, and every edge the
/// recurrence engine has been tested against is an edge the calendar inherits.
///
/// Where an event differs from a chore is that it happens at a *time*. That
/// time is stored as minutes past midnight rather than as a moment, so an
/// occurrence still belongs to a day: a 16:00 swimming lesson is at four in
/// the afternoon in the household's own timezone, on every day it recurs,
/// whichever side of a clock change that day falls on. Storing a `Date` per
/// occurrence would instead move the lesson by an hour every spring.
public struct CalendarEvent: Entity {
    public let id: Identifier<CalendarEvent>

    /// The household whose calendar this is on.
    public let householdID: Identifier<Household>

    /// What is happening — "Swimming", "Dentist", "Grandma visits".
    public private(set) var title: ValidatedText

    /// Anything worth knowing: "bring the blue kit bag".
    public private(set) var notes: ValidatedText?

    /// Where it is, when that is worth saying.
    public private(set) var location: ValidatedText?

    /// A grouping used for filtering and for the glyph on the row.
    public private(set) var kind: Kind

    /// The first day the event can occur.
    public private(set) var startDate: Date

    /// When in the day it happens, and for how long.
    public private(set) var timing: Timing

    /// How often it comes around.
    public private(set) var recurrence: RecurrenceRule

    /// Days the family explicitly dropped — a cancelled lesson, a week away.
    ///
    /// An exception rather than an edit to the rule, so "swimming was off that
    /// week" does not permanently move swimming.
    public private(set) var skippedDays: Set<Date>

    /// Who it concerns.
    public private(set) var participants: Participants

    /// How long before it starts the household wants to be told, in minutes.
    ///
    /// `nil` means the event is on the calendar to be looked at rather than to
    /// be interrupted about, which is most of them. A calendar that notifies
    /// for everything on it is a calendar nobody puts anything on.
    public private(set) var reminderMinutesBefore: Int?

    /// Set when the event is called off.
    ///
    /// Cancelled rather than deleted, in the same spirit as an archived chore:
    /// a family that cancels the dentist wants it off the week without losing
    /// the fact that it was ever booked. A genuine delete exists too.
    public private(set) var cancelledAt: Date?

    /// Who put it on the calendar.
    public let createdBy: Identifier<Member>

    /// When they did.
    public let createdAt: Date

    /// Whether the event still appears on the calendar.
    public var isActive: Bool { cancelledAt == nil }

    /// Creates an event.
    ///
    /// - Parameters:
    ///   - id: The event's identifier. A fresh one by default.
    ///   - householdID: The household whose calendar this is on.
    ///   - title: What is happening.
    ///   - notes: Anything worth knowing.
    ///   - location: Where it is.
    ///   - kind: The grouping it belongs to.
    ///   - startDate: The first day it can occur.
    ///   - timing: When in the day it happens.
    ///   - recurrence: How often it comes around.
    ///   - skippedDays: Days the family dropped.
    ///   - participants: Who it concerns.
    ///   - reminderMinutesBefore: How long before to say something.
    ///   - cancelledAt: When it was called off, if it has been.
    ///   - createdBy: Who put it on the calendar.
    ///   - createdAt: When they did.
    ///   - calendar: The household's calendar, used to normalise the start day.
    /// - Throws: ``DomainError/blank(field:)``,
    ///   ``DomainError/tooLong(field:limit:)``, or
    ///   ``DomainError/outOfRange(field:allowed:)`` when the timing or the
    ///   reminder lead is not one a day can hold.
    public init(
        id: Identifier<CalendarEvent> = Identifier(),
        householdID: Identifier<Household>,
        title: String,
        notes: String? = nil,
        location: String? = nil,
        kind: Kind = .other,
        startDate: Date,
        timing: Timing = .allDay,
        recurrence: RecurrenceRule = .once,
        skippedDays: Set<Date> = [],
        participants: Participants = .everyone,
        reminderMinutesBefore: Int? = nil,
        cancelledAt: Date? = nil,
        createdBy: Identifier<Member>,
        createdAt: Date,
        calendar: Calendar
    ) throws {
        self.id = id
        self.householdID = householdID
        self.title = try ValidatedText(title, field: .eventTitle, limit: Limits.eventTitleLength)
        self.notes = try ValidatedText.optional(
            notes, field: .choreNotes, limit: Limits.notesLength)
        self.location = try ValidatedText.optional(
            location, field: .eventTitle, limit: Limits.eventLocationLength
        )
        self.kind = kind
        // Normalised for the same reason a chore's is: the recurrence engine
        // phases weekly and monthly rules from the start day, and a start date
        // carrying an afternoon on it would phase them from a different day in
        // a timezone west of the one it was typed in.
        self.startDate = calendar.startOfDay(for: startDate)
        self.timing = try timing.validated()
        self.recurrence = recurrence
        self.skippedDays = Set(skippedDays.map { calendar.startOfDay(for: $0) })
        self.participants = participants
        self.reminderMinutesBefore = try reminderMinutesBefore.map {
            try $0.validated(in: Limits.eventReminderLead, field: .quantity)
        }
        self.cancelledAt = cancelledAt
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

// MARK: - Timing

extension CalendarEvent {
    /// When in the day an event happens.
    ///
    /// Two cases rather than a nullable pair of times. "All day" is not an
    /// event that happens to run from midnight to midnight — it is a different
    /// kind of entry, drawn in a different place on a week grid, and one that
    /// cannot clash with anything because it is not a claim on a person's
    /// afternoon. Modelling it as its own case is what keeps every caller from
    /// re-deciding that with an `if start == 0 && duration == 1440`.
    public enum Timing: Hashable, Sendable, Codable {
        /// The whole day. Half-terms, birthdays, "Dad is away".
        case allDay

        /// A span of the day, in minutes past midnight in the household's
        /// timezone.
        ///
        /// An event may run past midnight — a party that ends at one in the
        /// morning is one event, not two — so `startMinute + durationMinutes`
        /// is deliberately allowed to exceed a day. The occurrence still
        /// belongs to the day it *starts* on, which is the day the family would
        /// name if asked when the party is.
        case timed(startMinute: Int, durationMinutes: Int)

        /// Whether this is an all-day entry.
        public var isAllDay: Bool { self == .allDay }

        /// Minutes past midnight the event starts, or zero for an all-day one.
        public var startMinute: Int {
            switch self {
            case .allDay: 0
            case .timed(let startMinute, _): startMinute
            }
        }

        /// How long it lasts in minutes, or a whole day for an all-day entry.
        public var durationMinutes: Int {
            switch self {
            case .allDay: Timing.minutesPerDay
            case .timed(_, let durationMinutes): durationMinutes
            }
        }

        /// Minutes in a day, which is what bounds a start time.
        public static let minutesPerDay = 24 * 60

        /// A timed event given as an hour and minute, which is how a picker
        /// hands one over.
        ///
        /// - Parameters:
        ///   - hour: The hour it starts, `0...23`.
        ///   - minute: The minute it starts, `0...59`.
        ///   - durationMinutes: How long it lasts.
        /// - Returns: The timing.
        public static func at(
            hour: Int,
            minute: Int = 0,
            lasting durationMinutes: Int = 60
        ) -> Timing {
            .timed(startMinute: hour * 60 + minute, durationMinutes: durationMinutes)
        }

        /// Checks the span is one a day can hold.
        ///
        /// - Returns: The timing, unchanged, so it can be assigned directly.
        /// - Throws: ``DomainError/outOfRange(field:allowed:)`` when the start
        ///   is not inside a day or the duration is not plausible.
        func validated() throws -> Timing {
            guard case .timed(let startMinute, let durationMinutes) = self else { return self }
            _ = try startMinute.validated(
                in: 0...(Timing.minutesPerDay - 1), field: .quantity
            )
            _ = try durationMinutes.validated(in: Limits.eventDuration, field: .quantity)
            return self
        }
    }
}

// MARK: - Kind

extension CalendarEvent {
    /// What sort of thing the event is.
    ///
    /// A fixed set, for the same reason a chore's category is one: households
    /// do not maintain taxonomies, and a fixed set means every entry gets a
    /// sensible glyph without anybody configuring anything.
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case appointment
        case school
        case activity
        case work
        case social
        case travel
        case celebration
        case other

        public var id: String { rawValue }

        /// The display name.
        public var label: String {
            switch self {
            case .appointment: "Appointment"
            case .school: "School"
            case .activity: "Activity"
            case .work: "Work"
            case .social: "Social"
            case .travel: "Travel"
            case .celebration: "Celebration"
            case .other: "Other"
            }
        }

        /// The SF Symbol shown on the row.
        public var symbolName: String {
            switch self {
            case .appointment: "stethoscope"
            case .school: "backpack"
            case .activity: "figure.run"
            case .work: "briefcase"
            case .social: "person.2"
            case .travel: "airplane"
            case .celebration: "party.popper"
            case .other: "calendar"
            }
        }
    }
}

// MARK: - Participants

extension CalendarEvent {
    /// Who an event concerns.
    ///
    /// The distinction matters because it decides whose day the event lands
    /// on, and therefore what a clash means. A dentist appointment for Sam is
    /// not a clash with Alex's football; the same two things on Sam's calendar
    /// are.
    public enum Participants: Hashable, Sendable, Codable {
        /// The whole household — half-term, a family holiday.
        case everyone

        /// Specific people.
        case members([Identifier<Member>])

        /// The people explicitly named, which is empty for a household-wide
        /// event.
        public var namedMemberIDs: [Identifier<Member>] {
            switch self {
            case .everyone: []
            case .members(let ids): ids
            }
        }

        /// Whether the event lands on this member's day.
        ///
        /// A household-wide event lands on everybody's, which is what makes it
        /// household-wide.
        public func includes(_ memberID: Identifier<Member>) -> Bool {
            switch self {
            case .everyone: true
            case .members(let ids): ids.contains(memberID)
            }
        }

        /// The people this event concerns, resolved against the household.
        ///
        /// - Parameter members: The household's members.
        /// - Returns: The active members it lands on, in display order.
        public func resolved(against members: some Collection<Member>) -> [Member] {
            members
                .filter { $0.isActive && includes($0.id) }
                .sorted(by: Member.displayOrder)
        }
    }
}

// MARK: - Scheduling

extension CalendarEvent {
    /// The days this event falls on inside `range`.
    ///
    /// - Parameters:
    ///   - range: The window of interest.
    ///   - engine: The household's recurrence engine.
    ///   - maximum: A cap on the returned count.
    /// - Returns: Ascending start-of-day dates, empty for a cancelled event.
    public func occurrences(
        in range: ClosedRange<Date>,
        using engine: RecurrenceEngine,
        maximum: Int = 500
    ) -> [Date] {
        guard isActive else { return [] }
        return engine.occurrences(
            of: recurrence,
            startingOn: startDate,
            in: range,
            skipping: skippedDays,
            maximum: maximum
        )
    }

    /// The days this event falls on inside `range`, each with its position in
    /// the whole sequence.
    ///
    /// - Parameters:
    ///   - range: The window of interest.
    ///   - engine: The household's recurrence engine.
    ///   - maximum: A cap on the returned count.
    /// - Returns: Ascending occurrences with their positions.
    public func indexedOccurrences(
        in range: ClosedRange<Date>,
        using engine: RecurrenceEngine,
        maximum: Int = 500
    ) -> [RecurrenceEngine.IndexedOccurrence] {
        guard isActive else { return [] }
        return engine.indexedOccurrences(
            of: recurrence,
            startingOn: startDate,
            in: range,
            skipping: skippedDays,
            maximum: maximum
        )
    }

    /// The next day this event falls on after `date`, if any.
    public func nextOccurrence(after date: Date, using engine: RecurrenceEngine) -> Date? {
        guard isActive else { return nil }
        return engine.nextOccurrence(
            of: recurrence,
            startingOn: startDate,
            after: date,
            skipping: skippedDays
        )
    }

    /// Whether the event falls on `date`.
    public func occurs(on date: Date, using engine: RecurrenceEngine) -> Bool {
        guard isActive else { return false }
        return engine.occurs(
            recurrence,
            startingOn: startDate,
            on: date,
            skipping: skippedDays
        )
    }

    /// The span an occurrence on `day` actually covers.
    ///
    /// An all-day event covers the day itself, midnight to midnight in the
    /// household's timezone. A timed one starts at its minute and runs for its
    /// duration, which may carry it into the next day.
    ///
    /// - Parameters:
    ///   - day: The day the occurrence falls on.
    ///   - calendar: The household's calendar.
    /// - Returns: The absolute interval the occurrence occupies.
    public func interval(on day: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        switch timing {
        case .allDay:
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return DateInterval(start: start, end: max(start, end))
        case .timed(let startMinute, let durationMinutes):
            // Built by adding minutes to the start of the day rather than by
            // setting an hour on it. On the day a clock goes forward there is
            // no half past one, and `date(bySettingHour:)` answers `nil` for
            // it — which would silently drop the school run from the one day
            // of the year it is hardest to remember.
            let begins = calendar.date(byAdding: .minute, value: startMinute, to: start) ?? start
            let ends = calendar.date(byAdding: .minute, value: durationMinutes, to: begins)
            return DateInterval(start: begins, end: max(begins, ends ?? begins))
        }
    }
}

// MARK: - Derived values

extension CalendarEvent {
    /// Whether this is an all-day entry.
    public var isAllDay: Bool { timing.isAllDay }

    /// Whether the event asks to be notified about.
    public var hasReminder: Bool { reminderMinutesBefore != nil }

    /// Whether an occurrence runs past midnight into the following day.
    public var endsAfterMidnight: Bool {
        guard case .timed(let startMinute, let durationMinutes) = timing else { return false }
        return startMinute + durationMinutes > Timing.minutesPerDay
    }

    /// The time of day as a phrase — "All day", "16:00", "16:00–17:30".
    ///
    /// Formatted through the given calendar's locale so a household that reads
    /// the clock in twelve hours is not shown twenty-four.
    ///
    /// - Parameters:
    ///   - day: The day the occurrence falls on.
    ///   - calendar: The household's calendar.
    /// - Returns: The phrase for the event row.
    public func timeSummary(on day: Date, calendar: Calendar) -> String {
        guard !isAllDay else { return "All day" }
        let span = interval(on: day, calendar: calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let start = formatter.string(from: span.start)
        guard span.duration > 0 else { return start }
        return "\(start)–\(formatter.string(from: span.end))"
    }

    /// A one-line description for a compact row: "Swimming — Alex, Sam".
    ///
    /// - Parameter members: The household's members, for resolving names.
    /// - Returns: The line.
    public func summary(members: some Collection<Member>) -> String {
        let people = participants.resolved(against: members)
        guard !people.isEmpty, !participants.namedMemberIDs.isEmpty else { return title.value }
        return "\(title.value) — \(people.map(\.name.value).joined(separator: ", "))"
    }
}

// MARK: - Mutation

extension CalendarEvent {
    /// Returns a copy with a new title.
    public func retitled(to newTitle: String) throws -> CalendarEvent {
        var copy = self
        copy.title = try ValidatedText(
            newTitle, field: .eventTitle, limit: Limits.eventTitleLength
        )
        return copy
    }

    /// Returns a copy with different notes, or none.
    public func withNotes(_ newNotes: String?) throws -> CalendarEvent {
        var copy = self
        copy.notes = try ValidatedText.optional(
            newNotes, field: .choreNotes, limit: Limits.notesLength
        )
        return copy
    }

    /// Returns a copy somewhere else, or nowhere in particular.
    public func at(_ newLocation: String?) throws -> CalendarEvent {
        var copy = self
        copy.location = try ValidatedText.optional(
            newLocation, field: .eventTitle, limit: Limits.eventLocationLength
        )
        return copy
    }

    /// Returns a copy of a different kind.
    public func ofKind(_ newKind: Kind) -> CalendarEvent {
        var copy = self
        copy.kind = newKind
        return copy
    }

    /// Returns a copy at a different time of day.
    ///
    /// - Throws: ``DomainError/outOfRange(field:allowed:)`` when the span is
    ///   not one a day can hold.
    public func timed(_ newTiming: Timing) throws -> CalendarEvent {
        var copy = self
        copy.timing = try newTiming.validated()
        return copy
    }

    /// Returns a copy on a different schedule.
    ///
    /// - Parameters:
    ///   - newStart: The first day it can occur, if it is moving.
    ///   - newRecurrence: How often it comes around, if that is changing.
    ///   - calendar: The household's calendar, for normalising the start day.
    /// - Returns: The rescheduled event.
    public func rescheduled(
        startingOn newStart: Date? = nil,
        recurrence newRecurrence: RecurrenceRule? = nil,
        calendar: Calendar
    ) -> CalendarEvent {
        var copy = self
        if let newStart { copy.startDate = calendar.startOfDay(for: newStart) }
        if let newRecurrence { copy.recurrence = newRecurrence }
        return copy
    }

    /// Returns a copy concerning different people.
    public func attendedBy(_ newParticipants: Participants) -> CalendarEvent {
        var copy = self
        copy.participants = newParticipants
        return copy
    }

    /// Returns a copy that says something a given number of minutes ahead, or
    /// nothing at all.
    ///
    /// - Parameter minutes: How far ahead to speak up, or `nil` for silence.
    /// - Returns: The event.
    /// - Throws: ``DomainError/outOfRange(field:allowed:)`` when the lead is
    ///   longer than the calendar plans ahead.
    public func reminding(minutesBefore minutes: Int?) throws -> CalendarEvent {
        var copy = self
        copy.reminderMinutesBefore = try minutes.map {
            try $0.validated(in: Limits.eventReminderLead, field: .quantity)
        }
        return copy
    }

    /// Returns a copy with `date` dropped from the schedule.
    public func skipping(_ date: Date, calendar: Calendar) -> CalendarEvent {
        var copy = self
        copy.skippedDays.insert(calendar.startOfDay(for: date))
        return copy
    }

    /// Returns a copy with `date` back on the schedule.
    public func unskipping(_ date: Date, calendar: Calendar) -> CalendarEvent {
        var copy = self
        copy.skippedDays.remove(calendar.startOfDay(for: date))
        return copy
    }

    /// Returns a copy called off.
    public func cancelled(at date: Date) -> CalendarEvent {
        var copy = self
        copy.cancelledAt = date
        return copy
    }

    /// Returns a copy back on the calendar.
    public func reinstated() -> CalendarEvent {
        var copy = self
        copy.cancelledAt = nil
        return copy
    }
}

// MARK: - Collections

extension Collection where Element == CalendarEvent {
    /// The events still on the calendar.
    public var active: [CalendarEvent] {
        filter(\.isActive)
    }

    /// The events concerning a given member, household-wide ones included.
    public func concerning(_ memberID: Identifier<Member>) -> [CalendarEvent] {
        filter { $0.participants.includes(memberID) }
    }
}
