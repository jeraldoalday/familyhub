import Foundation

/// A type-safe identifier.
///
/// Every entity in the domain is identified by `Identifier<Self>` rather than a
/// bare `UUID`. The phantom `Subject` parameter carries no runtime cost but
/// makes it a compile-time error to pass a member's identifier where a chore's
/// identifier is expected — a mistake that is otherwise trivial to make and
/// very hard to spot in a diff, because both spell as the same 36 characters.
///
/// ```swift
/// let member: Member.ID = Identifier()
/// let chore: Chore.ID = member   // ❌ does not compile
/// ```
public struct Identifier<Subject>: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The underlying value. Stable across launches and safe to persist.
    public let rawValue: UUID

    /// Creates an identifier, generating a fresh value by default.
    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// Reconstructs an identifier from its string form, as stored on disk or
    /// received from a sync payload. Returns `nil` if the string is malformed.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String { rawValue.uuidString }

    // Encoded as a bare string rather than a keyed container, so that an
    // identifier round-trips through JSON as `"5B2C…"` instead of
    // `{"rawValue":"5B2C…"}`. Sync payloads and debug logs stay readable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Identifier: Comparable {
    /// Ordering by the underlying UUID. Not meaningful to a user, but it gives
    /// collections of entities a stable tiebreaker when a sort key ties, which
    /// keeps list animations from shuffling rows unpredictably.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

/// A domain entity: an immutable value with a stable identity.
///
/// The same-type constraint pins `Identifiable`'s associated type, so the rest
/// of the codebase can say `Member.ID` and mean `Identifier<Member>` — and so a
/// conformer cannot accidentally satisfy `Identifiable` with a bare `UUID`.
public protocol Entity: Identifiable, Hashable, Sendable, Codable
where ID == Identifier<Self> {
    var id: Identifier<Self> { get }
}
