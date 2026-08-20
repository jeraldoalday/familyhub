import Foundation

/// A day of the week.
///
/// Raw values match `Calendar`'s weekday numbering, where Sunday is 1, so the
/// two can be converted without a lookup table — and, more importantly, without
/// an off-by-one that would silently shift every weekly chore by a day.
public enum Weekday: Int, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    public var id: Int { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The weekday `date` falls on in the given calendar.
    public init(date: Date, calendar: Calendar) {
        let component = calendar.component(.weekday, from: date)
        // `Calendar` guarantees 1...7 for the Gregorian and every other
        // calendar the app supports, but a defensive fallback keeps a corrupt
        // calendar from trapping in a UI update.
        self = Weekday(rawValue: component) ?? .sunday
    }

    /// Monday through Friday.
    public static let weekdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    /// Saturday and Sunday.
    public static let weekend: Set<Weekday> = [.saturday, .sunday]

    /// Every day.
    public static let everyDay: Set<Weekday> = Set(Weekday.allCases)

    /// The full localized name, such as "Monday".
    public var name: String {
        let symbols = Calendar.current.weekdaySymbols
        let index = rawValue - 1
        return symbols.indices.contains(index) ? symbols[index] : "\(self)"
    }

    /// The abbreviated localized name, such as "Mon", for compact chips.
    public var shortName: String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let index = rawValue - 1
        return symbols.indices.contains(index) ? symbols[index] : "\(self)"
    }

    /// A single letter for the seven-across weekday picker.
    ///
    /// Taken from the localized short name rather than hardcoded, so a Spanish
    /// user sees L M X J V S D rather than M T W T F S S.
    public var initial: String {
        shortName.prefix(1).uppercased()
    }
}

extension Set where Element == Weekday {
    /// The weekdays in the order they appear in a week that starts on
    /// `firstWeekday`, so a picker reads M T W T F S S for a household that
    /// starts its week on Monday and S M T W T F S for one that starts Sunday.
    public func ordered(firstWeekday: Int) -> [Weekday] {
        sorted { lhs, rhs in
            let lhsOffset = (lhs.rawValue - firstWeekday + 7) % 7
            let rhsOffset = (rhs.rawValue - firstWeekday + 7) % 7
            return lhsOffset < rhsOffset
        }
    }

    /// A human-readable summary: "Every day", "Weekdays", "Weekends", or a
    /// comma-separated list. Used on the chore row, where there is no room to
    /// spell out a full recurrence description.
    ///
    /// The list runs in the order the household's own week does, which is what
    /// ``ordered(firstWeekday:)`` exists for. A family whose week starts on
    /// Monday reads "Sat, Sun"; sorting by the raw weekday number instead gives
    /// them "Sun, Sat", which is not how anybody says it and reads as a bug in
    /// the picker they just used.
    ///
    /// - Parameter firstWeekday: The day the household starts its week on, as
    ///   an ISO weekday where Sunday is 1.
    /// - Returns: The phrase for the chore row.
    public func summary(firstWeekday: Int) -> String {
        if self == Weekday.everyDay { return "Every day" }
        if self == Weekday.weekdays { return "Weekdays" }
        if self == Weekday.weekend { return "Weekends" }
        if isEmpty { return "Never" }
        return ordered(firstWeekday: firstWeekday).map(\.shortName).joined(separator: ", ")
    }

    /// The summary in the locale's own week order.
    ///
    /// For callers that have no household to hand — a preview, a log line. Code
    /// rendering a real household should pass its `firstWeekday`, because a
    /// household may start its week somewhere the device's locale does not.
    public var summary: String {
        summary(firstWeekday: Calendar.current.firstWeekday)
    }
}
