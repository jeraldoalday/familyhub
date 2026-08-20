import Foundation

/// Reads a household's calendar the way the fridge door does.
///
/// A value type over the events the caller already holds, in the same spirit
/// as ``MealPlan`` and ``PointsLedger``: nothing is stored, everything is
/// derived, and a week grid is a pure function of a snapshot. The questions it
/// answers are the ones a family actually asks — what is on today, who has to
/// be where, what is next, and whether two things have been booked on top of
/// each other — and answering them here rather than in a view is what keeps
/// the answers the same on the calendar screen, on the home screen, and in a
/// notification.
///
/// Every query expands each event's schedule once across the whole window
/// asked for. The alternative — asking each event whether it falls on each day
/// — walks from the event's start date once per day, which turns rendering a
/// month into thirty walks of a rota that may run back years. The agenda, the
/// recap, and the streak calculator all learned this the same way.
public struct FamilyCalendar: Sendable {

    /// The events under consideration, cancelled ones already dropped.
    public let events: [CalendarEvent]

    /// The engine every expansion goes through, carrying the household's
    /// calendar.
    public let engine: RecurrenceEngine

    /// The household's calendar, which decides where its weeks begin and what
    /// timezone a four o'clock lesson is at four o'clock in.
    public var calendar: Calendar { engine.calendar }

    /// Creates a calendar over a household's events.
    ///
    /// - Parameters:
    ///   - events: Every event on file, including cancelled ones.
    ///   - engine: The household's recurrence engine.
    public init(events: some Collection<CalendarEvent>, engine: RecurrenceEngine) {
        self.events = events.active
        self.engine = engine
    }

    /// Creates a calendar over a household's events, using its own calendar.
    ///
    /// - Parameters:
    ///   - events: Every event on file, including cancelled ones.
    ///   - household: The household whose calendar to read them in.
    public init(events: some Collection<CalendarEvent>, household: Household) {
        self.init(events: events, engine: RecurrenceEngine(household: household))
    }

    // MARK: - One occurrence

    /// The day-and-event pair that identifies one instance of a recurring
    /// event.
    ///
    /// The same shape as ``ChoreCompletion/OccurrenceKey``, and for the same
    /// reason: it is what gives a row a stable identity across reloads, so
    /// list animations behave when the week is rebuilt underneath them.
    public struct OccurrenceKey: Hashable, Sendable, Codable, Comparable {
        public let eventID: Identifier<CalendarEvent>
        public let day: Date

        public init(eventID: Identifier<CalendarEvent>, day: Date) {
            self.eventID = eventID
            self.day = day
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            return lhs.eventID < rhs.eventID
        }
    }

    /// One event, on one day, with everything a row needs to render itself.
    public struct Occurrence: Sendable, Hashable, Identifiable {
        /// The event this is an instance of.
        public let event: CalendarEvent

        /// The day it falls on, at the start of the day.
        public let day: Date

        /// Its zero-based position in the event's whole sequence.
        public let occurrenceIndex: Int

        /// The absolute span it occupies, which for a timed event may run past
        /// midnight into the following day.
        public let interval: DateInterval

        /// A stable identity across reloads.
        public var id: OccurrenceKey {
            OccurrenceKey(eventID: event.id, day: day)
        }

        /// Whether this is an all-day entry.
        public var isAllDay: Bool { event.isAllDay }

        /// When it starts.
        public var start: Date { interval.start }

        /// When it ends.
        public var end: Date { interval.end }

        /// Whether the moment falls inside it.
        public func isHappening(at moment: Date) -> Bool {
            moment >= interval.start && moment < interval.end
        }

        /// The order occurrences appear in a day: all-day entries first,
        /// because they are the day's context rather than part of its
        /// sequence, then by start time, then alphabetically, with the
        /// identifier as a final tiebreaker so the order never flickers.
        public static func displayOrder(_ lhs: Occurrence, _ rhs: Occurrence) -> Bool {
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            let comparison = lhs.event.title.value
                .localizedCaseInsensitiveCompare(rhs.event.title.value)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.event.id < rhs.event.id
        }
    }

    // MARK: - Expanding the schedule

    /// Every occurrence inside a range of days, in the order they happen.
    ///
    /// - Parameters:
    ///   - start: The first day of interest.
    ///   - end: The last day of interest. Clamped to be no earlier than
    ///     `start`.
    ///   - memberID: When supplied, limits the result to the events that land
    ///     on that person's day — the ones naming them, plus the
    ///     household-wide ones that land on everybody's.
    /// - Returns: Occurrences in display order.
    public func occurrences(
        from start: Date,
        to end: Date,
        for memberID: Identifier<Member>? = nil
    ) -> [Occurrence] {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = max(firstDay, calendar.startOfDay(for: end))
        let range = firstDay...lastDay

        return
            events
            .filter { event in
                guard let memberID else { return true }
                return event.participants.includes(memberID)
            }
            .flatMap { event -> [Occurrence] in
                event.indexedOccurrences(in: range, using: engine, maximum: Int.max)
                    .map { occurrence in
                        Occurrence(
                            event: event,
                            day: occurrence.day,
                            occurrenceIndex: occurrence.index,
                            interval: event.interval(on: occurrence.day, calendar: calendar)
                        )
                    }
            }
            .sorted(by: Occurrence.displayOrder)
    }

    /// What is on for one day.
    ///
    /// - Parameters:
    ///   - day: The day of interest.
    ///   - memberID: When supplied, limits the result to that person's day.
    /// - Returns: Occurrences in display order.
    public func occurrences(
        on day: Date,
        for memberID: Identifier<Member>? = nil
    ) -> [Occurrence] {
        occurrences(from: day, to: day, for: memberID)
    }

    // MARK: - Days and weeks

    /// One day of the calendar, split the way a day view draws it.
    public struct Day: Sendable, Identifiable {
        /// The day itself, at the start of the day.
        public let day: Date

        /// Everything on it, in display order.
        public let occurrences: [Occurrence]

        public var id: Date { day }

        /// The all-day entries, which head the day rather than sitting in it.
        public var allDay: [Occurrence] { occurrences.filter(\.isAllDay) }

        /// The entries that occupy a span of the day.
        public var timed: [Occurrence] { occurrences.filter { !$0.isAllDay } }

        /// Whether the day has nothing on it.
        public var isEmpty: Bool { occurrences.isEmpty }

        /// How many things are on it.
        public var count: Int { occurrences.count }
    }

    /// The calendar across a range of days, one entry per day whether or not
    /// anything is on.
    ///
    /// Empty days are included rather than omitted, for the same reason the
    /// meal plan includes them: a grid that renders only the days with
    /// something on them is a grid a family cannot tap to fill the days
    /// without.
    ///
    /// - Parameters:
    ///   - start: The first day.
    ///   - end: The last day.
    ///   - memberID: When supplied, limits the result to one person's day.
    /// - Returns: One entry per day, earliest first.
    public func days(
        from start: Date,
        to end: Date,
        for memberID: Identifier<Member>? = nil
    ) -> [Day] {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = max(firstDay, calendar.startOfDay(for: end))

        // Grouped from one expansion of the window rather than expanded once
        // per day, which is the whole reason this type exists.
        let byDay = Dictionary(
            grouping: occurrences(from: firstDay, to: lastDay, for: memberID),
            by: \.day
        )

        var result: [Day] = []
        var cursor = firstDay
        while cursor <= lastDay {
            result.append(Day(day: cursor, occurrences: byDay[cursor] ?? []))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// A household's week, bounded by the day it starts its week on.
    public struct Week: Sendable {
        /// The first day of the week, in the household's own convention.
        public let start: Date

        /// The last day of the week.
        public let end: Date

        /// Seven days, always, whether or not anything is on them.
        public let days: [Day]

        /// How many things are on across the week.
        public var count: Int { days.reduce(0) { $0 + $1.count } }

        /// Whether the week is completely clear.
        public var isEmpty: Bool { count == 0 }

        /// The days with something on them.
        public var busyDays: [Day] { days.filter { !$0.isEmpty } }

        /// Everything in the week, in the order it happens.
        public var occurrences: [Occurrence] { days.flatMap(\.occurrences) }
    }

    /// The week containing `day`, starting on whichever day the household
    /// considers the start of its week.
    ///
    /// - Parameters:
    ///   - day: A day inside the week of interest.
    ///   - memberID: When supplied, limits the week to one person's day.
    /// - Returns: The week.
    public func week(
        containing day: Date,
        for memberID: Identifier<Member>? = nil
    ) -> Week {
        let anchor = calendar.startOfDay(for: day)
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        let startDay = calendar.startOfDay(for: start)
        let end = calendar.date(byAdding: .day, value: 6, to: startDay) ?? startDay
        return Week(start: startDay, end: end, days: days(from: startDay, to: end, for: memberID))
    }

    // MARK: - What is next

    /// The next thing due to start after a given moment.
    ///
    /// Takes a moment rather than a day, so a home screen at seven in the
    /// evening says what is on tomorrow morning rather than repeating the
    /// swimming lesson that finished three hours ago.
    ///
    /// An occurrence already in progress is not "next" — it is now, and
    /// ``happening(at:for:)`` is the question that asks about it.
    ///
    /// - Parameters:
    ///   - moment: The current time.
    ///   - memberID: When supplied, limits the answer to one person's day.
    ///   - horizonDays: How far ahead to look before giving up.
    /// - Returns: The next occurrence, or `nil` if nothing is inside the
    ///   horizon.
    public func next(
        after moment: Date,
        for memberID: Identifier<Member>? = nil,
        horizonDays: Int = 30
    ) -> Occurrence? {
        let today = calendar.startOfDay(for: moment)
        let horizon =
            calendar.date(byAdding: .day, value: max(0, horizonDays), to: today) ?? today
        return occurrences(from: today, to: horizon, for: memberID)
            .filter { !$0.isAllDay && $0.start > moment }
            .min { $0.start < $1.start }
    }

    /// What is going on right now.
    ///
    /// - Parameters:
    ///   - moment: The current time.
    ///   - memberID: When supplied, limits the answer to one person's day.
    /// - Returns: The occurrences the moment falls inside, in display order.
    public func happening(
        at moment: Date,
        for memberID: Identifier<Member>? = nil
    ) -> [Occurrence] {
        // Yesterday is included in the window because an event that started at
        // nine last night and runs until one this morning is happening now,
        // and it belongs to yesterday's day.
        let today = calendar.startOfDay(for: moment)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return occurrences(from: yesterday, to: today, for: memberID)
            .filter { $0.isHappening(at: moment) }
    }

    // MARK: - Clashes

    /// Two things booked on top of each other for the same person.
    public struct Clash: Sendable, Identifiable {
        /// The one that starts first.
        public let earlier: Occurrence

        /// The one that starts on top of it.
        public let later: Occurrence

        /// The span they share.
        public let overlap: DateInterval

        /// The people who are expected at both, in display order.
        public let members: [Member]

        /// A stable identity: the same pair on the same day is the same clash.
        public var id: String { "\(earlier.id.eventID)|\(later.id.eventID)|\(earlier.day)" }

        /// How long the two overlap by.
        public var overlapMinutes: Int { Int(overlap.duration / 60) }
    }

    /// The double-bookings across a range of days.
    ///
    /// Reported per person rather than per household, because a household is
    /// meant to have several things happening at once — Sam at the dentist
    /// while Alex is at football is a Tuesday, not a problem. A clash is only
    /// a clash when the same person is expected in two places, which is what
    /// makes the warning worth showing at all.
    ///
    /// All-day entries never clash. Half-term is not a booking that competes
    /// with a dentist appointment, and a calendar that says otherwise trains
    /// the family to ignore the warning.
    ///
    /// - Parameters:
    ///   - start: The first day to check.
    ///   - end: The last day to check.
    ///   - members: The household's members, for resolving who is expected.
    /// - Returns: The clashes, earliest first.
    public func clashes(
        from start: Date,
        to end: Date,
        among members: some Collection<Member>
    ) -> [Clash] {
        let active = members.filter(\.isActive)
        // Sorted by start so each occurrence only has to be compared with the
        // ones after it, and so the pair is always reported earlier-first.
        let timed = occurrences(from: start, to: end)
            .filter { !$0.isAllDay }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id < rhs.id
            }

        var found: [Clash] = []
        for (offset, earlier) in timed.enumerated() {
            for later in timed[(offset + 1)...] {
                // The list is sorted by start, so once one candidate begins
                // after this occurrence has finished, every later one does too.
                guard later.start < earlier.end else { break }
                guard let overlap = earlier.interval.intersection(with: later.interval),
                    overlap.duration > 0
                else { continue }

                let shared = active.filter {
                    earlier.event.participants.includes($0.id)
                        && later.event.participants.includes($0.id)
                }
                guard !shared.isEmpty else { continue }

                found.append(
                    Clash(
                        earlier: earlier,
                        later: later,
                        overlap: overlap,
                        members: shared.sorted(by: Member.displayOrder)
                    )
                )
            }
        }
        return found
    }

    /// The double-bookings on one day.
    ///
    /// - Parameters:
    ///   - day: The day to check.
    ///   - members: The household's members.
    /// - Returns: The clashes, earliest first.
    public func clashes(
        on day: Date,
        among members: some Collection<Member>
    ) -> [Clash] {
        clashes(from: day, to: day, among: members)
    }

    /// Whether a member already has something timed inside a span.
    ///
    /// What an event editor asks before offering to save, so a parent finds
    /// out that Sam is at swimming *while* they are typing the dentist rather
    /// than on the morning of.
    ///
    /// - Parameters:
    ///   - memberID: The person to check.
    ///   - span: The span the new commitment would occupy.
    /// - Returns: The occurrences already in the way, in display order.
    public func conflicts(
        for memberID: Identifier<Member>,
        during span: DateInterval
    ) -> [Occurrence] {
        // Widened by a day at each end so that an event starting late the
        // previous evening, or an all-day-spanning span, is still compared
        // against.
        let from = calendar.date(byAdding: .day, value: -1, to: span.start) ?? span.start
        return occurrences(from: from, to: span.end, for: memberID)
            .filter { !$0.isAllDay }
            .filter { occurrence in
                guard let overlap = occurrence.interval.intersection(with: span) else {
                    return false
                }
                return overlap.duration > 0
            }
    }
}

// MARK: - Snapshot convenience

extension HouseholdSnapshot {
    /// The family calendar over this household, ready to query.
    public var familyCalendar: FamilyCalendar {
        FamilyCalendar(events: events, engine: engine)
    }
}
