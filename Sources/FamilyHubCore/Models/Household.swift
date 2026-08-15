import Foundation

/// The family unit that owns everything else in the app.
///
/// Every chore, list, reward, and event hangs off exactly one household. That
/// single ownership root is what makes the eventual move to shared iCloud
/// storage tractable: one household is one sync scope.
public struct Household: Entity {
    public let id: Identifier<Household>

    /// What the family calls itself — "The Aldays", "Flat 3B", "Home".
    public private(set) var name: ValidatedText

    /// The subscription tier, which determines the member limit and which
    /// features are unlocked.
    public private(set) var tier: Tier

    /// The day the household considers the start of its week, as an ISO
    /// weekday where Sunday is 1. Drives weekly chore resets and the calendar.
    public private(set) var firstWeekday: Int

    /// The timezone chore deadlines are evaluated in.
    ///
    /// Pinned to the household rather than read from each device, so a parent
    /// travelling abroad does not see every chore flip to "overdue" because
    /// their phone crossed a date line.
    public private(set) var timeZoneIdentifier: String

    /// Whether completed chores need an adult's approval before points are
    /// awarded. Households with older children usually turn this off.
    public private(set) var requiresApproval: Bool

    /// When the household was created.
    public let createdAt: Date

    /// Creates a household.
    ///
    /// - Throws: ``DomainError/blank(field:)`` or
    ///   ``DomainError/tooLong(field:limit:)`` if the name is unusable.
    public init(
        id: Identifier<Household> = Identifier(),
        name: String,
        tier: Tier = .free,
        firstWeekday: Int = 2,
        timeZone: TimeZone = .current,
        requiresApproval: Bool = true,
        createdAt: Date
    ) throws {
        self.id = id
        self.name = try ValidatedText(
            name,
            field: .householdName,
            limit: Limits.householdNameLength
        )
        self.tier = tier
        // Clamped rather than thrown on: an out-of-range weekday can only come
        // from a corrupt record or a bad migration, and refusing to load the
        // household would lock the family out over a cosmetic preference.
        self.firstWeekday = (1...7).contains(firstWeekday) ? firstWeekday : 2
        self.timeZoneIdentifier = timeZone.identifier
        self.requiresApproval = requiresApproval
        self.createdAt = createdAt
    }
}

// MARK: - Tier

extension Household {
    /// What the household has paid for.
    public enum Tier: String, Codable, Sendable, CaseIterable, Comparable {
        /// Free: up to three members, chores and one shopping list.
        case free

        /// Paid: the full member limit, rewards, meal planning, and history.
        case plus

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs == .free && rhs == .plus
        }

        /// How many members the tier allows.
        public var memberLimit: Int {
            switch self {
            case .free: Limits.freeTierMembers
            case .plus: Limits.paidTierMembers
            }
        }

        /// Whether points and rewards are available.
        public var includesRewards: Bool { self == .plus }

        /// Whether meal planning is available.
        public var includesMealPlanning: Bool { self == .plus }

        /// How far back completion history is retained. The free tier keeps a
        /// fortnight, which is long enough to be useful and short enough that
        /// the streak and stats screens read as a reason to upgrade.
        public var historyRetentionDays: Int {
            switch self {
            case .free: 14
            case .plus: 3650
            }
        }

        public var label: String {
            switch self {
            case .free: "Free"
            case .plus: "FamilyHub Plus"
            }
        }
    }
}

// MARK: - Derived values

extension Household {
    /// The household's timezone, falling back to the device's if the stored
    /// identifier is not one this OS version knows about.
    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    /// A calendar configured with the household's week start and timezone.
    /// Every scheduling computation for this household should use it.
    public func calendar(base: Calendar = .current) -> Calendar {
        var calendar = base
        calendar.timeZone = timeZone
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// A date provider bound to this household's calendar.
    public func dateProvider() -> SystemDateProvider {
        SystemDateProvider(
            firstWeekday: firstWeekday,
            timeZone: timeZone
        )
    }

    /// Whether another member can be added at the current tier.
    public func canAddMember(currentCount: Int) -> Bool {
        currentCount < tier.memberLimit
    }

    /// Checks that another member fits within the tier's limit.
    ///
    /// - Throws: ``DomainError/householdFull(limit:)`` when the household is at
    ///   capacity, carrying the limit so the paywall can name it.
    public func validateCanAddMember(currentCount: Int) throws {
        guard canAddMember(currentCount: currentCount) else {
            throw DomainError.householdFull(limit: tier.memberLimit)
        }
    }
}

// MARK: - Mutation

extension Household {
    /// Returns a copy with a new name.
    public func renamed(to newName: String) throws -> Household {
        var copy = self
        copy.name = try ValidatedText(
            newName,
            field: .householdName,
            limit: Limits.householdNameLength
        )
        return copy
    }

    /// Returns a copy on a different subscription tier.
    ///
    /// Downgrading does not delete anything. Members beyond the free limit stay
    /// in the record and become read-only, because silently deleting a child's
    /// profile and their point balance when a card expires would be indefensible.
    public func onTier(_ newTier: Tier) -> Household {
        var copy = self
        copy.tier = newTier
        return copy
    }

    /// Returns a copy with a different first day of the week.
    public func withFirstWeekday(_ weekday: Int) -> Household {
        guard (1...7).contains(weekday) else { return self }
        var copy = self
        copy.firstWeekday = weekday
        return copy
    }

    /// Returns a copy pinned to a different timezone.
    public func withTimeZone(_ timeZone: TimeZone) -> Household {
        var copy = self
        copy.timeZoneIdentifier = timeZone.identifier
        return copy
    }

    /// Returns a copy with approval of completed chores switched on or off.
    public func withApprovalRequired(_ required: Bool) -> Household {
        var copy = self
        copy.requiresApproval = required
        return copy
    }
}
