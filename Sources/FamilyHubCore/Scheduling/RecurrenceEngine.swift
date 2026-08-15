import Foundation

/// Turns a ``RecurrenceRule`` into actual dates.
///
/// The engine is a pure function of its inputs — a rule, a start date, and a
/// calendar — with no storage and no clock of its own. That is what makes the
/// scheduling behaviour of the whole app testable in microseconds instead of by
/// waiting until next Tuesday.
///
/// Every date it produces is a *start of day* in the engine's calendar. Chores
/// belong to a day, not to a moment; a chore due "Monday" is not due at 09:00
/// on Monday, and storing a time would make the same chore appear on different
/// days for family members in different timezones.
public struct RecurrenceEngine: Sendable {

    /// The calendar all arithmetic is performed in — the household's, so that
    /// week boundaries and month lengths match what the family sees.
    public let calendar: Calendar

    /// A ceiling on how many candidate periods the engine will step through
    /// before giving up.
    ///
    /// A rule cannot loop forever — validation rejects the unsatisfiable ones —
    /// but a caller asking for occurrences between now and `Date.distantFuture`
    /// would otherwise generate a million dates and exhaust memory. Ten
    /// thousand periods is roughly 27 years of daily chores, far beyond any
    /// screen that could display them.
    private static let periodCeiling = 10_000

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    /// Creates an engine using a household's calendar.
    public init(household: Household) {
        self.calendar = household.calendar()
    }

    // MARK: - Public queries

    /// The occurrences of `rule` that fall inside `range`.
    ///
    /// - Parameters:
    ///   - rule: The recurrence to expand.
    ///   - start: The chore's start date. Occurrences never precede it.
    ///   - range: The window of interest, typically the visible month or week.
    ///   - exceptions: Days the family explicitly skipped. Excluded from the
    ///     result but still counted against the rule's occurrence limit, so
    ///     skipping a week does not extend a "10 times" chore to eleven.
    ///   - maximum: A cap on the returned count, to bound a list view.
    /// - Returns: Ascending, de-duplicated start-of-day dates.
    public func occurrences(
        of rule: RecurrenceRule,
        startingOn start: Date,
        in range: ClosedRange<Date>,
        skipping exceptions: Set<Date> = [],
        maximum: Int = 500
    ) -> [Date] {
        guard maximum > 0 else { return [] }
        let lowerBound = calendar.startOfDay(for: range.lowerBound)
        let upperBound = calendar.startOfDay(for: range.upperBound)
        let normalizedExceptions = Set(exceptions.map { calendar.startOfDay(for: $0) })

        var results: [Date] = []
        enumerate(rule: rule, startingOn: start, notAfter: upperBound) { date in
            guard date >= lowerBound else { return .continue }
            guard !normalizedExceptions.contains(date) else { return .continue }
            results.append(date)
            return results.count >= maximum ? .stop : .continue
        }
        return results
    }

    /// The first occurrence strictly after `date`, or `nil` if the rule has run
    /// out — reached its end date, exhausted its occurrence limit, or was a
    /// one-off that has already happened.
    ///
    /// - Parameters:
    ///   - rule: The recurrence to expand.
    ///   - start: The chore's start date. Occurrences never precede it.
    ///   - date: The day to search forward from.
    ///   - exceptions: Days the family explicitly skipped.
    ///   - searchLimit: How far ahead to look before concluding there is no
    ///     next occurrence. Ten years comfortably covers a fortnightly chore
    ///     that was skipped for a season.
    /// - Returns: The next start-of-day occurrence, or `nil` if the rule is
    ///   exhausted.
    public func nextOccurrence(
        of rule: RecurrenceRule,
        startingOn start: Date,
        after date: Date,
        skipping exceptions: Set<Date> = [],
        searchLimit: TimeInterval = 60 * 60 * 24 * 365 * 10
    ) -> Date? {
        let threshold = calendar.startOfDay(for: date)
        let horizon = date.addingTimeInterval(searchLimit)
        let normalizedExceptions = Set(exceptions.map { calendar.startOfDay(for: $0) })

        var found: Date?
        enumerate(rule: rule, startingOn: start, notAfter: horizon) { candidate in
            guard candidate > threshold else { return .continue }
            guard !normalizedExceptions.contains(candidate) else { return .continue }
            found = candidate
            return .stop
        }
        return found
    }

    /// Whether the rule produces an occurrence on the given day.
    public func occurs(
        _ rule: RecurrenceRule,
        startingOn start: Date,
        on date: Date,
        skipping exceptions: Set<Date> = []
    ) -> Bool {
        let day = calendar.startOfDay(for: date)
        return !occurrences(
            of: rule,
            startingOn: start,
            in: day...day,
            skipping: exceptions,
            maximum: 1
        ).isEmpty
    }

    // MARK: - Generation

    /// Whether enumeration should carry on.
    private enum Step {
        case `continue`
        case stop
    }

    /// Walks the rule's occurrences in ascending order from `start`, calling
    /// `body` for each, and stops when `body` says so, when the horizon is
    /// passed, or when the rule is exhausted.
    ///
    /// Occurrences are always generated from the chore's start date rather than
    /// from the start of the requested window, because the occurrence limit and
    /// the fortnightly phase are both defined relative to the start. Jumping
    /// straight to the window would lose the phase and produce a chore that
    /// lands on the wrong week.
    private func enumerate(
        rule: RecurrenceRule,
        startingOn start: Date,
        notAfter horizon: Date,
        _ body: (Date) -> Step
    ) {
        let startDay = calendar.startOfDay(for: start)
        let effectiveHorizon = min(
            calendar.startOfDay(for: horizon),
            rule.endDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
        )
        guard startDay <= effectiveHorizon else { return }

        // Counts every occurrence the rule generates, including ones the caller
        // filters out, so that `occurrenceLimit` means "happens N times" rather
        // than "N times land in whatever window was asked for".
        var generated = 0
        let limit = rule.occurrenceLimit ?? Int.max

        func emit(_ date: Date) -> Step {
            guard generated < limit else { return .stop }
            generated += 1
            return body(date)
        }

        switch rule.frequency {
        case .once:
            _ = emit(startDay)

        case .daily:
            var period = 0
            while period < Self.periodCeiling {
                guard
                    let date = calendar.date(
                        byAdding: .day,
                        value: period * rule.interval,
                        to: startDay
                    )
                else { return }
                guard date <= effectiveHorizon else { return }
                if emit(date) == .stop { return }
                period += 1
            }

        case .weekly:
            // Phase is anchored to the week containing the start date, so an
            // "every 2 weeks" chore keeps landing on the same alternating week
            // regardless of which window is being rendered.
            guard let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: startDay)?.start
            else { return }

            // Within a week, emit in the order the days actually occur, which
            // depends on where the household starts its week.
            let orderedDays = rule.weekdays.ordered(firstWeekday: calendar.firstWeekday)

            var period = 0
            while period < Self.periodCeiling {
                guard
                    let weekStart = calendar.date(
                        byAdding: .weekOfYear,
                        value: period * rule.interval,
                        to: anchorWeek
                    )
                else { return }
                // The whole week is past the horizon, so every later week is too.
                guard weekStart <= effectiveHorizon else { return }

                for weekday in orderedDays {
                    let offset = (weekday.rawValue - calendar.firstWeekday + 7) % 7
                    guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart)
                    else { continue }
                    guard date >= startDay else { continue }
                    guard date <= effectiveHorizon else { return }
                    if emit(date) == .stop { return }
                }
                period += 1
            }

        case .monthly:
            guard let anchorMonth = calendar.dateInterval(of: .month, for: startDay)?.start
            else { return }

            var period = 0
            while period < Self.periodCeiling {
                guard
                    let monthStart = calendar.date(
                        byAdding: .month,
                        value: period * rule.interval,
                        to: anchorMonth
                    )
                else { return }
                guard monthStart <= effectiveHorizon else { return }

                for date in daysInMonth(rule.daysOfMonth, of: monthStart) {
                    guard date >= startDay else { continue }
                    guard date <= effectiveHorizon else { return }
                    if emit(date) == .stop { return }
                }
                period += 1
            }
        }
    }

    /// Resolves the requested days of the month against a specific month,
    /// returned in ascending order.
    ///
    /// A day that does not exist in this month is dropped rather than clamped.
    /// Clamping the 31st onto the 28th would silently make a monthly chore
    /// arrive three days early in February and collide with a rule that also
    /// asks for the 28th. The ``RecurrenceRule/lastDayOfMonth`` sentinel exists
    /// precisely so a family that means "the end of the month" can say so.
    private func daysInMonth(_ requested: Set<Int>, of monthStart: Date) -> [Date] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else {
            return []
        }
        let lastDay = dayRange.upperBound - 1

        var resolved: Set<Int> = []
        for day in requested {
            if day == RecurrenceRule.lastDayOfMonth {
                resolved.insert(lastDay)
            } else if day <= lastDay {
                resolved.insert(day)
            }
        }

        return resolved.sorted().compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: monthStart)
        }
    }
}
