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

    /// Longest permitted free-text notes field.
    public static let notesLength = 500

    /// Points that a single chore may be worth.
    public static let pointsPerChore: ClosedRange<Int> = 0...500

    /// Points a reward may cost.
    public static let pointsPerReward: ClosedRange<Int> = 1...100_000

    /// Quantity of a single shopping list item.
    public static let itemQuantity: ClosedRange<Int> = 1...999

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
