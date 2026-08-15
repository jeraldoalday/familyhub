import Foundation

/// A person in the household.
///
/// A value type, deliberately. Members are read constantly — every chore row,
/// every leaderboard, every avatar — and passed across actor boundaries as the
/// app syncs. Making them immutable values means none of that needs locking,
/// and mutation goes through explicit `with…` methods that return a new copy,
/// so an accidental write from a background task cannot corrupt what the UI is
/// currently rendering.
public struct Member: Entity {
    public let id: Identifier<Member>

    /// The household this member belongs to.
    public let householdID: Identifier<Household>

    /// The member's display name, validated non-blank.
    public private(set) var name: ValidatedText

    /// What the member is allowed to do.
    public private(set) var role: MemberRole

    /// The colour and glyph shown wherever this member appears.
    public private(set) var avatar: Avatar

    /// The member's birthday, if they chose to share it. Used for age-appropriate
    /// defaults and for the family calendar.
    public private(set) var birthday: Date?

    /// When the member joined the household.
    public let joinedAt: Date

    /// Set when a member is removed. Removed members are retained rather than
    /// deleted so that historical chore completions and point ledger entries
    /// keep referring to a real person instead of dangling.
    public private(set) var removedAt: Date?

    /// Whether the member is currently part of the household.
    public var isActive: Bool { removedAt == nil }

    /// Creates a member.
    ///
    /// - Throws: ``DomainError/blank(field:)`` or
    ///   ``DomainError/tooLong(field:limit:)`` if the name is unusable.
    public init(
        id: Identifier<Member> = Identifier(),
        householdID: Identifier<Household>,
        name: String,
        role: MemberRole,
        avatar: Avatar = .random(),
        birthday: Date? = nil,
        joinedAt: Date,
        removedAt: Date? = nil
    ) throws {
        self.id = id
        self.householdID = householdID
        self.name = try ValidatedText(
            name,
            field: .memberName,
            limit: Limits.memberNameLength
        )
        self.role = role
        self.avatar = avatar
        self.birthday = birthday
        self.joinedAt = joinedAt
        self.removedAt = removedAt
    }
}

// MARK: - Derived values

extension Member {
    /// One or two initials for the avatar fallback, derived from the name.
    ///
    /// Takes the first character of the first and last word so that "Mary Jane
    /// Alday" reads as "MA" rather than "M". Grapheme-cluster based, so names
    /// written in scripts where a character is several code points — or names
    /// that start with an emoji — do not get sliced in half.
    public var initials: String {
        let words = name.value
            .split(separator: " ", omittingEmptySubsequences: true)
            .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        switch words.count {
        case 0:
            // The name is non-blank but has no alphanumeric start — an emoji-only
            // name, for instance. Show its first grapheme rather than nothing.
            return name.value.first.map(String.init) ?? "?"
        case 1:
            return words[0].prefix(1).uppercased()
        default:
            let first = words[0].prefix(1)
            let last = words[words.count - 1].prefix(1)
            return (first + last).uppercased()
        }
    }

    /// The member's age in whole years, if a birthday is known.
    public func age(on date: Date, calendar: Calendar) -> Int? {
        guard let birthday else { return nil }
        return calendar.dateComponents([.year], from: birthday, to: date).year
    }

    /// Whether today is this member's birthday, for the celebratory banner on
    /// the home screen.
    public func hasBirthday(on date: Date, calendar: Calendar) -> Bool {
        guard let birthday else { return false }
        return calendar.isDate(birthday, equalTo: date, toGranularity: .day)
            || (calendar.component(.month, from: birthday) == calendar.component(.month, from: date)
                && calendar.component(.day, from: birthday) == calendar.component(.day, from: date))
    }
}

// MARK: - Mutation

extension Member {
    /// Returns a copy with a new name.
    public func renamed(to newName: String) throws -> Member {
        var copy = self
        copy.name = try ValidatedText(
            newName,
            field: .memberName,
            limit: Limits.memberNameLength
        )
        return copy
    }

    /// Returns a copy with a different role.
    public func withRole(_ newRole: MemberRole) -> Member {
        var copy = self
        copy.role = newRole
        return copy
    }

    /// Returns a copy with a different avatar.
    public func withAvatar(_ newAvatar: Avatar) -> Member {
        var copy = self
        copy.avatar = newAvatar
        return copy
    }

    /// Returns a copy with a different birthday, or none.
    public func withBirthday(_ newBirthday: Date?) -> Member {
        var copy = self
        copy.birthday = newBirthday
        return copy
    }

    /// Returns a copy marked as removed from the household at `date`.
    ///
    /// Removal is a tombstone rather than a delete: past chore completions and
    /// point ledger entries still reference this member, and rewriting history
    /// to erase someone would silently change every family member's totals.
    public func removed(at date: Date) -> Member {
        var copy = self
        copy.removedAt = date
        return copy
    }

    /// Returns a copy restored to active membership.
    public func reinstated() -> Member {
        var copy = self
        copy.removedAt = nil
        return copy
    }
}

// MARK: - Sorting

extension Member {
    /// The order members appear in lists: adults first, then alphabetically,
    /// with identifier as a final tiebreaker so the order never flickers
    /// between launches when two people share a name.
    public static func displayOrder(_ lhs: Member, _ rhs: Member) -> Bool {
        if lhs.role != rhs.role {
            return lhs.role > rhs.role
        }
        let comparison = lhs.name.value.localizedCaseInsensitiveCompare(rhs.name.value)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}
