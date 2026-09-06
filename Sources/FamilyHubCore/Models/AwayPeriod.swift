import Foundation

/// A stretch of days the household, or some of it, is not here.
///
/// A rota is a promise about ordinary weeks, and the weeks a family remembers
/// are the other ones. Until now the app had one answer for a fortnight in
/// Spain: skip every occurrence of every chore, one day at a time, and hope
/// somebody remembers to do it before leaving rather than after. Nobody does.
/// What actually happens is that the family comes home to a fortnight of red,
/// every streak in the house broken, a completion rate that says they gave up,
/// and a phone that spent the holiday asking a nine year old to feed a cat two
/// thousand miles away.
///
/// An away period is the record that stops all four. It says nothing about the
/// chores themselves — the schedule is untouched, exactly as a cover request
/// leaves it untouched — it says that the people it names were not here, and
/// every screen that judges a person by what they did that day reads it and
/// declines to judge.
///
/// It names people rather than assuming the whole family, because the common
/// case is not the family holiday. It is one child at their grandmother's for
/// half term while the rest of the household carries on, and a record that
/// could only mean "everybody" would either be unusable for that or would
/// switch the household off for a week to describe it.
public struct AwayPeriod: Entity {
    public let id: Identifier<AwayPeriod>

    /// The household this belongs to.
    public let householdID: Identifier<Household>

    /// The first day away, inclusive.
    public private(set) var firstDay: Date

    /// The last day away, inclusive.
    ///
    /// Inclusive rather than exclusive because a family says "we are away from
    /// the 12th to the 19th" and means both ends. An exclusive bound is a
    /// correct answer to a question nobody asked and an off-by-one in every
    /// screen that renders it.
    public private(set) var lastDay: Date

    /// Who is away. Empty means the whole household.
    ///
    /// Empty as the sentinel rather than an optional set, because "away" with
    /// nobody named is not missing information — it is the family holiday, and
    /// the shape that makes it awkward to express is the wrong shape.
    public private(set) var memberIDs: Set<Identifier<Member>>

    /// Where they have gone, in the family's words — "Spain", "Nan's".
    ///
    /// Optional and worth having for the same reason a cover request's note is:
    /// a chore quietly not being asked for is confusing, and a chore not being
    /// asked for because Sam is at his grandmother's is obvious.
    public private(set) var reason: ValidatedText?

    /// Who recorded it.
    public let createdBy: Identifier<Member>

    /// When it was recorded.
    public let createdAt: Date

    /// Set when the trip is called off.
    ///
    /// Cancelled rather than deleted, because a household that cancels a
    /// holiday after the fact wants the days to count again, and a household
    /// that deleted the record would have no way to say so on a screen that
    /// has already stopped showing it.
    public private(set) var cancelledAt: Date?

    /// Whether the record still counts.
    public var isActive: Bool { cancelledAt == nil }

    /// Creates an away period.
    ///
    /// - Parameters:
    ///   - id: The record's identifier.
    ///   - householdID: The household it belongs to.
    ///   - firstDay: The first day away, normalised to the start of the day.
    ///   - lastDay: The last day away, inclusive, normalised the same way.
    ///   - memberIDs: Who is away. Empty means everyone.
    ///   - reason: Where they have gone.
    ///   - createdBy: Who recorded it.
    ///   - createdAt: When they recorded it.
    ///   - cancelledAt: When the trip was called off, if it was.
    ///   - calendar: The household's calendar, used to normalise both ends.
    /// - Throws: ``DomainError/impossibleDateRange(reason:)`` when the dates
    ///   are back to front or the stretch is longer than the app will accept,
    ///   or ``DomainError/tooLong(field:limit:)`` for an unusable reason.
    public init(
        id: Identifier<AwayPeriod> = Identifier(),
        householdID: Identifier<Household>,
        firstDay: Date,
        lastDay: Date,
        memberIDs: Set<Identifier<Member>> = [],
        reason: String? = nil,
        createdBy: Identifier<Member>,
        createdAt: Date,
        cancelledAt: Date? = nil,
        calendar: Calendar
    ) throws {
        // Normalised on the way in for the same reason a completion's day is:
        // two devices recording the same trip at different times of day have to
        // produce the same days, or a chore is excused on one phone and overdue
        // on the other.
        let start = calendar.startOfDay(for: firstDay)
        let end = calendar.startOfDay(for: lastDay)

        guard start <= end else {
            throw DomainError.impossibleDateRange(
                reason: "it ends before it starts"
            )
        }
        let span = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        guard span + 1 <= Limits.awayPeriodDays else {
            throw DomainError.impossibleDateRange(
                reason: "a trip can't be longer than \(Limits.awayPeriodDays) days"
            )
        }

        self.id = id
        self.householdID = householdID
        self.firstDay = start
        self.lastDay = end
        self.memberIDs = memberIDs
        self.reason = try ValidatedText.optional(
            reason,
            field: .awayReason,
            limit: Limits.notesLength
        )
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.cancelledAt = cancelledAt
    }
}

// MARK: - Derived values

extension AwayPeriod {
    /// The days away, as a range that can be tested against directly.
    public var days: ClosedRange<Date> { firstDay...lastDay }

    /// How many days the trip runs for, counting both ends.
    public func dayCount(calendar: Calendar) -> Int {
        (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1
    }

    /// Whether nobody in particular is named, which means everybody.
    public var isWholeHousehold: Bool { memberIDs.isEmpty }

    /// Whether the trip takes `memberID` out of the household.
    ///
    /// - Parameter memberID: The person being asked about.
    /// - Returns: `true` when the record names them, or names nobody at all.
    public func covers(_ memberID: Identifier<Member>) -> Bool {
        isWholeHousehold || memberIDs.contains(memberID)
    }

    /// Whether `day` falls inside the trip.
    ///
    /// - Parameters:
    ///   - day: The day being asked about.
    ///   - calendar: The household's calendar.
    /// - Returns: `true` when the record is live and the day is one of its own.
    public func covers(_ day: Date, calendar: Calendar) -> Bool {
        guard isActive else { return false }
        return days.contains(calendar.startOfDay(for: day))
    }

    /// Whether `memberID` is away on `day`.
    ///
    /// The question every other screen actually asks, in one place so that the
    /// agenda, the streak, and the notification cannot answer it differently.
    public func covers(
        _ memberID: Identifier<Member>,
        on day: Date,
        calendar: Calendar
    ) -> Bool {
        covers(memberID) && covers(day, calendar: calendar)
    }

    /// Whether the trip touches any day of `range`.
    public func overlaps(_ range: ClosedRange<Date>, calendar: Calendar) -> Bool {
        guard isActive else { return false }
        let lower = calendar.startOfDay(for: range.lowerBound)
        let upper = calendar.startOfDay(for: range.upperBound)
        return firstDay <= upper && lastDay >= lower
    }

    /// Whether the trip has not started yet as of `day`.
    public func isUpcoming(on day: Date, calendar: Calendar) -> Bool {
        isActive && calendar.startOfDay(for: day) < firstDay
    }

    /// Whether the trip is over as of `day`.
    public func hasEnded(on day: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: day) > lastDay
    }

    /// Who the trip is about, named for the row that shows it.
    ///
    /// - Parameter members: The household's members, for looking names up.
    /// - Returns: "Everyone" for a family holiday, otherwise the names in the
    ///   household's usual display order.
    public func who(among members: some Collection<Member>) -> String {
        guard !isWholeHousehold else { return "Everyone" }
        let names =
            members
            .filter { memberIDs.contains($0.id) }
            .sorted(by: Member.displayOrder)
            .map(\.name.value)
        guard !names.isEmpty else { return "Nobody" }
        guard names.count > 1 else { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

// MARK: - Mutation

extension AwayPeriod {
    /// Returns a copy running over different days.
    ///
    /// - Throws: ``DomainError/impossibleDateRange(reason:)`` on the same terms
    ///   as the initialiser.
    public func rescheduled(
        firstDay newFirst: Date? = nil,
        lastDay newLast: Date? = nil,
        calendar: Calendar
    ) throws -> AwayPeriod {
        try AwayPeriod(
            id: id,
            householdID: householdID,
            firstDay: newFirst ?? firstDay,
            lastDay: newLast ?? lastDay,
            memberIDs: memberIDs,
            reason: reason?.value,
            createdBy: createdBy,
            createdAt: createdAt,
            cancelledAt: cancelledAt,
            calendar: calendar
        )
    }

    /// Returns a copy covering a different set of people. Empty means everyone.
    public func covering(_ newMembers: Set<Identifier<Member>>) -> AwayPeriod {
        var copy = self
        copy.memberIDs = newMembers
        return copy
    }

    /// Returns a copy with a different reason, or none.
    public func withReason(_ newReason: String?) throws -> AwayPeriod {
        var copy = self
        copy.reason = try ValidatedText.optional(
            newReason,
            field: .awayReason,
            limit: Limits.notesLength
        )
        return copy
    }

    /// Returns a copy of a trip that is not happening after all.
    public func cancelled(at date: Date) -> AwayPeriod {
        var copy = self
        copy.cancelledAt = date
        return copy
    }

    /// Returns a copy of a trip that is back on.
    public func reinstated() -> AwayPeriod {
        var copy = self
        copy.cancelledAt = nil
        return copy
    }
}

// MARK: - Ordering

extension AwayPeriod {
    /// Chronological, with the identifier breaking an exact tie so a list of
    /// trips does not reshuffle between reads.
    public static func chronologicalOrder(_ lhs: AwayPeriod, _ rhs: AwayPeriod) -> Bool {
        if lhs.firstDay != rhs.firstDay { return lhs.firstDay < rhs.firstDay }
        if lhs.lastDay != rhs.lastDay { return lhs.lastDay < rhs.lastDay }
        return lhs.id < rhs.id
    }
}

// MARK: - Collections

extension Collection where Element == AwayPeriod {
    /// The trips that have not been called off, in date order.
    public var active: [AwayPeriod] {
        filter(\.isActive).sorted(by: AwayPeriod.chronologicalOrder)
    }

    /// The trips running on `day`, in date order.
    public func live(on day: Date, calendar: Calendar) -> [AwayPeriod] {
        active.filter { $0.covers(day, calendar: calendar) }
    }

    /// The trip that takes `memberID` out of the household on `day`.
    ///
    /// - Returns: The earliest matching record, so that two overlapping trips
    ///   — the family holiday and the half term that runs into it — resolve to
    ///   the same one on every device.
    public func covering(
        _ memberID: Identifier<Member>,
        on day: Date,
        calendar: Calendar
    ) -> AwayPeriod? {
        active.first { $0.covers(memberID, on: day, calendar: calendar) }
    }

    /// Whether `memberID` is away on `day`.
    public func isAway(
        _ memberID: Identifier<Member>,
        on day: Date,
        calendar: Calendar
    ) -> Bool {
        covering(memberID, on: day, calendar: calendar) != nil
    }

    /// Whether the whole household is away on `day`.
    ///
    /// Distinct from everyone happening to be away individually: a chore open
    /// to anybody has nobody to fall to when the house is empty, and that is
    /// the only case in which an unassigned chore is excused.
    public func isHouseholdAway(on day: Date, calendar: Calendar) -> Bool {
        live(on: day, calendar: calendar).contains { $0.isWholeHousehold }
    }

    /// The days inside `range` on which `memberID` is away.
    ///
    /// Built once and handed to the callers that ask about many days at a time
    /// — the streak calculator, the weekly recap — so that neither of them puts
    /// a scan of the household's whole travel history inside a walk of a
    /// hundred and eighty days.
    ///
    /// - Parameters:
    ///   - memberID: The person being asked about, or `nil` for the days the
    ///     whole household was away.
    ///   - range: The window of interest.
    ///   - calendar: The household's calendar.
    /// - Returns: Start-of-day dates, unordered.
    public func awayDays(
        for memberID: Identifier<Member>?,
        in range: ClosedRange<Date>,
        calendar: Calendar
    ) -> Set<Date> {
        let lower = calendar.startOfDay(for: range.lowerBound)
        let upper = calendar.startOfDay(for: range.upperBound)

        var days: Set<Date> = []
        for period in self where period.isActive {
            if let memberID {
                guard period.covers(memberID) else { continue }
            } else {
                guard period.isWholeHousehold else { continue }
            }
            var cursor = Swift.max(period.firstDay, lower)
            let end = Swift.min(period.lastDay, upper)
            while cursor <= end {
                days.insert(cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        return days
    }
}
