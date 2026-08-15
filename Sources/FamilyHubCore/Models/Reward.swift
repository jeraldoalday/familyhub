import Foundation

/// Something a family member can spend earned points on.
///
/// Rewards are what make a chore app stick. Points with nothing to buy are a
/// score, and children stop caring about a score within a week.
public struct Reward: Entity {
    public let id: Identifier<Reward>

    /// The household that offers this reward.
    public let householdID: Identifier<Household>

    /// What the reward is — "Movie night pick", "30 min extra screen time".
    public private(set) var name: ValidatedText

    /// What it costs in points.
    public private(set) var cost: Int

    /// An emoji shown on the reward card.
    public private(set) var emoji: String?

    /// Who may redeem it. Empty means everyone in the household.
    ///
    /// Lets a parent scope "stay up an hour late" to teens without it appearing
    /// on a six year old's rewards screen as something to save for.
    public private(set) var eligibleMemberIDs: Set<Identifier<Member>>

    /// How many times it may still be redeemed, or `nil` for unlimited.
    ///
    /// Models genuinely scarce rewards — one cinema ticket, one choice of
    /// Saturday's outing — so the app cannot promise something twice.
    public private(set) var remainingRedemptions: Int?

    /// Shortest gap between redemptions by the same member, in days.
    ///
    /// Stops a child banking points all month and then redeeming "skip a chore"
    /// seven days running.
    public private(set) var cooldownDays: Int?

    /// Whether the reward is currently offered.
    public private(set) var isActive: Bool

    /// When the reward was created.
    public let createdAt: Date

    /// Creates a reward.
    ///
    /// - Throws: ``DomainError/blank(field:)``,
    ///   ``DomainError/tooLong(field:limit:)``, or
    ///   ``DomainError/outOfRange(field:allowed:)`` if the cost is not sane.
    public init(
        id: Identifier<Reward> = Identifier(),
        householdID: Identifier<Household>,
        name: String,
        cost: Int,
        emoji: String? = nil,
        eligibleMemberIDs: Set<Identifier<Member>> = [],
        remainingRedemptions: Int? = nil,
        cooldownDays: Int? = nil,
        isActive: Bool = true,
        createdAt: Date
    ) throws {
        self.id = id
        self.householdID = householdID
        self.name = try ValidatedText(
            name,
            field: .rewardName,
            limit: Limits.choreTitleLength
        )
        self.cost = try cost.validated(in: Limits.pointsPerReward, field: .points)
        self.emoji = emoji
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(\.first)
            .map(String.init)
        self.eligibleMemberIDs = eligibleMemberIDs
        self.remainingRedemptions = remainingRedemptions.map { max(0, $0) }
        self.cooldownDays = cooldownDays.map { max(0, $0) }
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

// MARK: - Availability

extension Reward {
    /// Whether the reward is offered to a given member at all, ignoring their
    /// balance. A reward they are not eligible for is hidden entirely rather
    /// than shown as unaffordable.
    public func isOffered(to memberID: Identifier<Member>) -> Bool {
        guard isActive else { return false }
        guard (remainingRedemptions ?? 1) > 0 else { return false }
        return eligibleMemberIDs.isEmpty || eligibleMemberIDs.contains(memberID)
    }

    /// Whether `memberID` may redeem this reward right now.
    ///
    /// - Parameters:
    ///   - balance: The member's current point balance.
    ///   - lastRedemption: When this member last redeemed *this* reward.
    ///   - date: The current moment.
    ///   - calendar: The household calendar.
    public func availability(
        forBalance balance: Int,
        lastRedemption: Date?,
        on date: Date,
        calendar: Calendar
    ) -> Availability {
        guard isActive else { return .withdrawn }
        if let remaining = remainingRedemptions, remaining <= 0 {
            return .soldOut
        }
        if let cooldownDays, let lastRedemption {
            let readyDate = calendar.date(
                byAdding: .day,
                value: cooldownDays,
                to: calendar.startOfDay(for: lastRedemption)
            )
            if let readyDate, date < readyDate {
                return .cooling(until: readyDate)
            }
        }
        if balance < cost {
            return .tooExpensive(shortBy: cost - balance)
        }
        return .available
    }

    /// Why a reward can or cannot be redeemed.
    ///
    /// The unaffordable case carries the shortfall rather than just saying no,
    /// because "12 more points" is a goal and "you can't have this" is a dead
    /// end — and the difference is the whole point of the feature.
    public enum Availability: Hashable, Sendable {
        /// Ready to redeem.
        case available

        /// The member needs `shortBy` more points.
        case tooExpensive(shortBy: Int)

        /// Redeemed too recently; available again on the given date.
        case cooling(until: Date)

        /// No redemptions remain.
        case soldOut

        /// A parent has switched the reward off.
        case withdrawn

        /// Whether redemption may proceed.
        public var canRedeem: Bool { self == .available }
    }
}

// MARK: - Mutation

extension Reward {
    /// Returns a copy with one redemption consumed.
    ///
    /// Unlimited rewards are returned unchanged rather than counting downward
    /// from some sentinel, so an unlimited reward can never accidentally run out.
    public func consumingRedemption() -> Reward {
        guard let remaining = remainingRedemptions else { return self }
        var copy = self
        copy.remainingRedemptions = max(0, remaining - 1)
        return copy
    }

    /// Returns a copy with a new name.
    public func renamed(to newName: String) throws -> Reward {
        var copy = self
        copy.name = try ValidatedText(
            newName,
            field: .rewardName,
            limit: Limits.choreTitleLength
        )
        return copy
    }

    /// Returns a copy priced differently.
    public func costing(_ newCost: Int) throws -> Reward {
        var copy = self
        copy.cost = try newCost.validated(in: Limits.pointsPerReward, field: .points)
        return copy
    }

    /// Returns a copy with restocked redemptions, or unlimited when `nil`.
    public func restocked(to count: Int?) -> Reward {
        var copy = self
        copy.remainingRedemptions = count.map { max(0, $0) }
        return copy
    }

    /// Returns a copy switched on or off.
    public func active(_ newValue: Bool) -> Reward {
        var copy = self
        copy.isActive = newValue
        return copy
    }
}
