import Foundation

/// Text that has been trimmed and checked against a field's length limits.
///
/// Constructing a domain entity takes `ValidatedText` rather than `String` for
/// its user-supplied names and titles. That way the check happens once, at the
/// boundary, and every layer downstream — sorting, search, display, sync — can
/// assume the value is non-blank and bounded. It is not possible to build a
/// `Chore` with a title of forty thousand spaces, because the type will not let
/// you construct one.
public struct ValidatedText: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The trimmed text. Never blank.
    public let value: String

    /// The field this text was validated against.
    public let field: DomainError.Field

    /// Validates and trims `raw`.
    ///
    /// - Throws: ``DomainError/blank(field:)`` if the text is empty or only
    ///   whitespace, or ``DomainError/tooLong(field:limit:)`` if it exceeds the
    ///   field's limit.
    public init(_ raw: String, field: DomainError.Field, limit: Int = 120) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainError.blank(field: field)
        }
        // Counted in Characters, not UTF-8 bytes, so an emoji-heavy chore title
        // ("🧺 Laundry 🧺") is measured the way the person typing it would.
        guard trimmed.count <= limit else {
            throw DomainError.tooLong(field: field, limit: limit)
        }
        self.value = trimmed
        self.field = field
    }

    public var description: String { value }

    /// A lowercased, diacritic-folded form for case-insensitive search and
    /// duplicate detection — so "Bánh mì" is found by typing "banh mi".
    public var searchKey: String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

extension ValidatedText {
    /// Validates text that is allowed to be absent entirely, such as optional
    /// notes on a chore. Blank input becomes `nil` rather than an error.
    public static func optional(
        _ raw: String?,
        field: DomainError.Field,
        limit: Int = 500
    ) throws -> ValidatedText? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try ValidatedText(raw, field: field, limit: limit)
    }
}

/// Numeric bounds enforced across the domain.
///
/// Collected in one place because these limits appear in three separate
/// contexts — validation, UI steppers, and the paywall — and they must agree.
public enum Limits {
    /// Longest permitted household name.
    public static let householdNameLength = 60

    /// Longest permitted member name.
    public static let memberNameLength = 40

    /// Longest permitted chore title.
    public static let choreTitleLength = 80

    /// Longest permitted meal title.
    public static let mealTitleLength = 80

    /// Longest permitted calendar event title.
    public static let eventTitleLength = 80

    /// Longest permitted event location. Longer than a title because an
    /// address is a legitimate thing to paste in here and truncating one to
    /// eighty characters loses the postcode, which is the part that matters.
    public static let eventLocationLength = 140

    /// Longest permitted free-text notes field.
    public static let notesLength = 500

    /// Points that a single chore may be worth.
    public static let pointsPerChore: ClosedRange<Int> = 0...500

    /// Points a reward may cost.
    public static let pointsPerReward: ClosedRange<Int> = 1...100_000

    /// How many people a planned meal may be for. The upper bound is a
    /// typo guard rather than a real limit — a household cooking for more than
    /// fifty is catering, and the number is far more likely to be a slip.
    public static let servings: ClosedRange<Int> = 1...50

    /// How many ingredients one planned meal may list. Generous for a recipe
    /// and low enough that a paste of somebody's entire cookbook is refused.
    public static let ingredientsPerMeal = 30

    /// Quantity of a single shopping list item.
    public static let itemQuantity: ClosedRange<Int> = 1...999

    /// How long a single calendar event may run, in minutes. Twenty-four hours
    /// exactly, so a party can spill past midnight and a fortnight in Spain
    /// has to be an all-day event — which is what it is.
    public static let eventDuration: ClosedRange<Int> = 1...(24 * 60)

    /// How far ahead of an event the household may ask to be told, in minutes.
    /// A week, which covers "the passports need renewing" without letting a
    /// reminder be scheduled beyond the horizon the planner actually plans.
    public static let eventReminderLead: ClosedRange<Int> = 0...(7 * 24 * 60)

    /// How long a single away period may run, counting both ends.
    ///
    /// A year and a day, which covers a sabbatical and refuses the mistyped
    /// year that would otherwise switch a household's rota off until 2035.
    public static let awayPeriodDays = 366

    /// Members allowed in a household on the free tier.
    public static let freeTierMembers = 3

    /// Members allowed in a household on the paid tier. Generous enough to
    /// cover blended and multi-generational families without being unlimited,
    /// which would invite abuse as a general-purpose team tool.
    public static let paidTierMembers = 12
}

extension Int {
    /// Validates that the value lies within `range` for the named field.
    ///
    /// - Throws: ``DomainError/outOfRange(field:allowed:)``.
    public func validated(
        in range: ClosedRange<Int>,
        field: DomainError.Field
    ) throws -> Int {
        guard range.contains(self) else {
            throw DomainError.outOfRange(field: field, allowed: range)
        }
        return self
    }
}
