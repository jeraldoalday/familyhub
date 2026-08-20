import Foundation

/// How often a chore comes around.
///
/// Deliberately narrower than RFC 5545. A household needs "every day", "every
/// Monday and Thursday", "the 1st and 15th", and "the last day of the month" —
/// it does not need "the third Tuesday of every other month unless it is a
/// public holiday". Every field here exists because a real family schedule
/// needs it, and the constrained shape is what lets the engine stay exact and
/// exhaustively testable.
public struct RecurrenceRule: Hashable, Sendable, Codable {

    /// The base cadence.
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        /// Happens once, on the start date. Not a recurrence at all, but
        /// modelling it here means a chore has one scheduling type rather than
        /// an optional rule plus a special case at every call site.
        case once

        /// Every `interval` days.
        case daily

        /// On the selected weekdays, every `interval` weeks.
        case weekly

        /// On the selected days of the month, every `interval` months.
        case monthly
    }

    /// The base cadence.
    public let frequency: Frequency

    /// How many periods between occurrences. `2` with `.weekly` means
    /// fortnightly. Always at least 1.
    public let interval: Int

    /// Which weekdays the chore falls on. Only meaningful for `.weekly`.
    public let weekdays: Set<Weekday>

    /// Which days of the month the chore falls on. Only meaningful for
    /// `.monthly`. The sentinel ``RecurrenceRule/lastDayOfMonth`` means the
    /// final day, whatever its number.
    public let daysOfMonth: Set<Int>

    /// The last day the rule produces occurrences, inclusive.
    public let endDate: Date?

    /// The maximum number of occurrences the rule ever produces.
    public let occurrenceLimit: Int?

    /// Sentinel for `daysOfMonth` meaning "the last day of the month".
    ///
    /// Needed because "the 31st" silently skips February, April, June,
    /// September, and November — five months a year in which a chore set to run
    /// on the 31st would simply never appear.
    public static let lastDayOfMonth = -1

    /// Creates a recurrence rule.
    ///
    /// - Throws: ``DomainError/unsatisfiableRecurrence(reason:)`` when the rule
    ///   as described could never produce a date. Catching this at construction
    ///   means the scheduling engine never has to defend against a rule that
    ///   loops forever looking for a day that does not exist.
    public init(
        frequency: Frequency,
        interval: Int = 1,
        weekdays: Set<Weekday> = [],
        daysOfMonth: Set<Int> = [],
        endDate: Date? = nil,
        occurrenceLimit: Int? = nil
    ) throws {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.daysOfMonth = daysOfMonth
        self.endDate = endDate
        self.occurrenceLimit = occurrenceLimit.map { max(0, $0) }

        try validate()
    }

    private func validate() throws {
        switch frequency {
        case .once, .daily:
            break
        case .weekly:
            guard !weekdays.isEmpty else {
                throw DomainError.unsatisfiableRecurrence(
                    reason: "a weekly chore needs at least one day of the week"
                )
            }
        case .monthly:
            guard !daysOfMonth.isEmpty else {
                throw DomainError.unsatisfiableRecurrence(
                    reason: "a monthly chore needs at least one day of the month"
                )
            }
            let valid = daysOfMonth.allSatisfy { day in
                day == Self.lastDayOfMonth || (1...31).contains(day)
            }
            guard valid else {
                throw DomainError.unsatisfiableRecurrence(
                    reason: "a day of the month must be between 1 and 31"
                )
            }
        }

        if let occurrenceLimit, occurrenceLimit == 0 {
            throw DomainError.unsatisfiableRecurrence(
                reason: "the chore is limited to zero occurrences"
            )
        }
    }
}

// MARK: - Convenience constructors

extension RecurrenceRule {
    /// A one-off chore.
    public static var once: RecurrenceRule {
        // Force-tried: `.once` has no fields that can fail validation, and
        // making the common constructors throwing would push noise into every
        // call site for a case that cannot occur.
        try! RecurrenceRule(frequency: .once)
    }

    /// Every day.
    public static var daily: RecurrenceRule {
        try! RecurrenceRule(frequency: .daily)
    }

    /// Every `days` days.
    public static func everyDays(_ days: Int) -> RecurrenceRule {
        try! RecurrenceRule(frequency: .daily, interval: days)
    }

    /// On the given weekdays, every week.
    ///
    /// - Throws: ``DomainError/unsatisfiableRecurrence(reason:)`` if no
    ///   weekdays are given.
    public static func weekly(
        on weekdays: Set<Weekday>,
        everyWeeks interval: Int = 1
    ) throws -> RecurrenceRule {
        try RecurrenceRule(frequency: .weekly, interval: interval, weekdays: weekdays)
    }

    /// On the given days of the month.
    ///
    /// - Throws: ``DomainError/unsatisfiableRecurrence(reason:)`` if no days
    ///   are given or a day is out of range.
    public static func monthly(
        on days: Set<Int>,
        everyMonths interval: Int = 1
    ) throws -> RecurrenceRule {
        try RecurrenceRule(frequency: .monthly, interval: interval, daysOfMonth: days)
    }

    /// On the last day of every month.
    public static var lastDayOfEveryMonth: RecurrenceRule {
        try! RecurrenceRule(frequency: .monthly, daysOfMonth: [lastDayOfMonth])
    }

    /// Returns a copy that stops producing occurrences after `date`.
    public func ending(on date: Date) throws -> RecurrenceRule {
        try RecurrenceRule(
            frequency: frequency,
            interval: interval,
            weekdays: weekdays,
            daysOfMonth: daysOfMonth,
            endDate: date,
            occurrenceLimit: occurrenceLimit
        )
    }

    /// Returns a copy that produces at most `count` occurrences.
    public func limited(to count: Int) throws -> RecurrenceRule {
        try RecurrenceRule(
            frequency: frequency,
            interval: interval,
            weekdays: weekdays,
            daysOfMonth: daysOfMonth,
            endDate: endDate,
            occurrenceLimit: count
        )
    }
}

// MARK: - Description

extension RecurrenceRule {
    /// A short phrase for the chore row: "Daily", "Every 2 weeks on Mon, Thu",
    /// with the days in the order the household's week runs.
    ///
    /// - Parameter firstWeekday: The day the household starts its week on, as
    ///   an ISO weekday where Sunday is 1.
    /// - Returns: The phrase for the chore row.
    public func summary(firstWeekday: Int) -> String {
        switch frequency {
        case .once:
            return "Once"
        case .daily:
            return interval == 1 ? "Daily" : "Every \(interval) days"
        case .weekly:
            let days = weekdays.summary(firstWeekday: firstWeekday)
            if interval == 1 {
                return weekdays == Weekday.everyDay ? "Daily" : days
            }
            return "Every \(interval) weeks on \(days)"
        case .monthly:
            let days =
                daysOfMonth
                .sorted()
                .map { $0 == Self.lastDayOfMonth ? "last day" : $0.ordinalDescription }
                .joined(separator: ", ")
            return interval == 1
                ? "Monthly on the \(days)" : "Every \(interval) months on the \(days)"
        }
    }

    /// The summary in the locale's own week order, for callers with no
    /// household to hand.
    public var summary: String {
        summary(firstWeekday: Calendar.current.firstWeekday)
    }

    /// Whether the rule can produce more than one occurrence.
    public var isRepeating: Bool { frequency != .once }
}

extension Int {
    /// "1st", "2nd", "3rd", "4th" — used for days of the month.
    fileprivate var ordinalDescription: String {
        let suffix: String
        switch (self % 100, self % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(self)\(suffix)"
    }
}
