import Foundation

/// Supplies the current moment and the calendar to interpret it in.
///
/// Nothing in the domain reads `Date()` directly. A chore that recurs "every
/// Monday" or a streak that breaks at midnight is a function of *when you ask*,
/// and a test suite that cannot control that clock is a test suite that fails
/// on the first Monday after the developer wrote it — or, worse, passes only in
/// the timezone it was written in.
///
/// Production code injects ``SystemDateProvider``; tests inject
/// ``FixedDateProvider`` and move time deliberately.
public protocol DateProvider: Sendable {
    /// The current moment.
    var now: Date { get }

    /// The calendar used for every date computation in the domain, already
    /// configured with the household's timezone and first-day-of-week.
    var calendar: Calendar { get }
}

extension DateProvider {
    /// The start of today, in this provider's calendar.
    public var today: Date {
        calendar.startOfDay(for: now)
    }

    /// The start of the day `days` from today. Negative values look backwards.
    public func day(offsetFromToday days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: today) ?? today
    }
}

/// The real clock, reading system time.
public struct SystemDateProvider: DateProvider {
    public var calendar: Calendar

    public var now: Date { Date() }

    /// Creates a provider using the given calendar, defaulting to the user's
    /// current calendar with the household's week-start preference applied.
    ///
    /// - Parameters:
    ///   - calendar: The base calendar. Defaults to `Calendar.current`.
    ///   - firstWeekday: Which day the household considers the start of the
    ///     week, as an ISO weekday where Sunday is 1. Passing `nil` keeps the
    ///     locale's own convention.
    ///   - timeZone: Overrides the calendar's timezone when supplied.
    public init(
        calendar: Calendar = .current,
        firstWeekday: Int? = nil,
        timeZone: TimeZone? = nil
    ) {
        var resolved = calendar
        if let firstWeekday {
            resolved.firstWeekday = firstWeekday
        }
        if let timeZone {
            resolved.timeZone = timeZone
        }
        self.calendar = resolved
    }
}

/// A clock frozen at a chosen moment, for deterministic tests and previews.
public struct FixedDateProvider: DateProvider {
    public var now: Date
    public var calendar: Calendar

    /// Creates a frozen clock.
    ///
    /// The calendar defaults to Gregorian in UTC with weeks starting on Monday,
    /// so that a test asserting "the next occurrence is Monday" means the same
    /// thing on a machine in Manila as on a CI runner in us-east-1.
    public init(now: Date, calendar: Calendar = .testDefault) {
        self.now = now
        self.calendar = calendar
    }

    /// Creates a frozen clock from calendar components, which reads far better
    /// in a test than a raw `timeIntervalSince1970`.
    ///
    /// ```swift
    /// let clock = FixedDateProvider(year: 2026, month: 3, day: 2)  // a Monday
    /// ```
    public init(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        calendar: Calendar = .testDefault
    ) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        // A malformed literal in a test is a programmer error, not a runtime
        // condition worth propagating — fail loudly and immediately.
        guard let date = calendar.date(from: components) else {
            preconditionFailure("Invalid date components: \(year)-\(month)-\(day)")
        }
        self.now = date
        self.calendar = calendar
    }

    /// Returns a copy of this clock advanced by the given interval.
    public func advanced(by interval: TimeInterval) -> Self {
        var copy = self
        copy.now = now.addingTimeInterval(interval)
        return copy
    }

    /// Returns a copy of this clock advanced by whole days.
    public func advanced(byDays days: Int) -> Self {
        var copy = self
        copy.now = calendar.date(byAdding: .day, value: days, to: now) ?? now
        return copy
    }
}

extension Calendar {
    /// Gregorian, UTC, weeks starting Monday. Used by tests and previews so
    /// date assertions do not depend on the machine running them.
    public static var testDefault: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }
}
