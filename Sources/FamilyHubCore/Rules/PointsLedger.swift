import Foundation

/// Reads balances, history, and standings out of a set of ledger entries.
///
/// A value type over a slice of the ledger rather than a service with a
/// database behind it. Everything it answers is a fold over entries the caller
/// already holds, which keeps the rewards screen a pure function of its data —
/// no loading states, no cache to invalidate, no possibility of the balance and
/// the history disagreeing.
public struct PointsLedger: Sendable {

    /// The entries under consideration, ordered oldest first.
    public let entries: [LedgerEntry]

    /// Creates a ledger over the given entries.
    public init(entries: some Sequence<LedgerEntry>) {
        self.entries = entries.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            // Identical timestamps are common when several chores are ticked
            // off in one go. Ordering by identifier keeps the history list
            // stable rather than reshuffling on each read.
            return lhs.id < rhs.id
        }
    }

    // MARK: - Balances

    /// The current balance for one member.
    public func balance(for memberID: Identifier<Member>) -> Int {
        entries.reduce(into: 0) { total, entry in
            guard entry.memberID == memberID else { return }
            total += entry.amount
        }
    }

    /// Balances for everyone who appears in the ledger, keyed by member.
    ///
    /// Computed in a single pass rather than by calling ``balance(for:)`` per
    /// member, which would be quadratic on a household screen that shows all of
    /// them at once.
    public func balances() -> [Identifier<Member>: Int] {
        entries.reduce(into: [:]) { totals, entry in
            totals[entry.memberID, default: 0] += entry.amount
        }
    }

    /// The balance as it stood at the end of `date`.
    ///
    /// Powers the "you had 40 points last Sunday" comparison, and is what makes
    /// a disputed balance answerable rather than arguable.
    public func balance(
        for memberID: Identifier<Member>,
        asOf date: Date,
        calendar: Calendar
    ) -> Int {
        let startOfDay = calendar.startOfDay(for: date)
        // Stepped by a calendar day rather than by 86,400 seconds. The day the
        // clocks go forward is twenty-three hours long, so adding a fixed day's
        // worth of seconds to its midnight lands an hour into the *next* day —
        // and a chore ticked off at 00:30 on Monday would then be counted in
        // Sunday's total. Twice a year, on exactly the days a family is most
        // likely to be checking a disputed balance.
        let cutoff = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return entries.reduce(into: 0) { total, entry in
            guard entry.memberID == memberID, entry.occurredAt < cutoff else { return }
            total += entry.amount
        }
    }

    /// Total points earned, ignoring anything spent.
    ///
    /// This is the number a leaderboard should rank on. Ranking on the current
    /// balance rewards hoarding and punishes a child for spending what they
    /// earned, which turns the reward system into a reason not to use it.
    public func totalEarned(by memberID: Identifier<Member>) -> Int {
        entries.reduce(into: 0) { total, entry in
            guard entry.memberID == memberID, entry.amount > 0 else { return }
            total += entry.amount
        }
    }

    /// Total points spent, as a positive number.
    public func totalSpent(by memberID: Identifier<Member>) -> Int {
        entries.reduce(into: 0) { total, entry in
            guard entry.memberID == memberID, entry.amount < 0 else { return }
            total += abs(entry.amount)
        }
    }

    // MARK: - History

    /// One member's entries, newest first, as the history screen shows them.
    public func history(for memberID: Identifier<Member>, limit: Int? = nil) -> [LedgerEntry] {
        let filtered = entries.filter { $0.memberID == memberID }.reversed()
        guard let limit else { return Array(filtered) }
        return Array(filtered.prefix(limit))
    }

    /// Entries within a date range, for the weekly and monthly summaries.
    public func entries(in range: ClosedRange<Date>) -> [LedgerEntry] {
        entries.filter { range.contains($0.occurredAt) }
    }

    /// Points earned by one member within a range — the number on the weekly
    /// recap card.
    public func earned(
        by memberID: Identifier<Member>,
        in range: ClosedRange<Date>
    ) -> Int {
        entries.reduce(into: 0) { total, entry in
            guard entry.memberID == memberID,
                entry.amount > 0,
                range.contains(entry.occurredAt)
            else { return }
            total += entry.amount
        }
    }

    // MARK: - Standings

    /// Members ranked by points earned, highest first.
    ///
    /// - Parameters:
    ///   - members: The household's members. Anyone with no entries is included
    ///     on zero rather than omitted, because a child who has not started yet
    ///     still needs to see themselves on the board.
    ///   - range: When supplied, scores only entries inside it — the weekly and
    ///     monthly boards. Omitting it ranks on all time.
    /// - Returns: Rows ordered highest first, each carrying its rank.
    public func standings(
        among members: some Collection<Member>,
        in range: ClosedRange<Date>? = nil
    ) -> [Standing] {
        let scored = members.filter(\.isActive).map { member -> Standing in
            let earned: Int
            if let range {
                earned = self.earned(by: member.id, in: range)
            } else {
                earned = totalEarned(by: member.id)
            }
            return Standing(
                member: member,
                pointsEarned: earned,
                balance: balance(for: member.id)
            )
        }

        return
            scored
            .sorted { lhs, rhs in
                if lhs.pointsEarned != rhs.pointsEarned {
                    return lhs.pointsEarned > rhs.pointsEarned
                }
                // A tie falls back to the household's normal display order, so
                // the board does not reshuffle between reads while everyone is
                // still on zero.
                return Member.displayOrder(lhs.member, rhs.member)
            }
            .enumerated()
            .map { index, standing in
                var ranked = standing
                ranked.rank = index + 1
                return ranked
            }
    }

    /// One row of the leaderboard.
    public struct Standing: Sendable, Identifiable {
        public let member: Member
        public let pointsEarned: Int
        public let balance: Int

        /// Position on the board, assigned by ``PointsLedger/standings(among:in:)``.
        public internal(set) var rank: Int = 0

        public var id: Identifier<Member> { member.id }
    }

    // MARK: - Redemption

    /// Checks that `memberID` can afford `reward` and may have it now.
    ///
    /// - Throws: ``DomainError/insufficientPoints(balance:required:)`` carrying
    ///   the shortfall, or ``DomainError/rewardUnavailable(reason:)``.
    public func authorizeRedemption(
        of reward: Reward,
        by memberID: Identifier<Member>,
        on date: Date,
        calendar: Calendar
    ) throws {
        let currentBalance = balance(for: memberID)
        let availability = reward.availability(
            forBalance: currentBalance,
            lastRedemption: lastRedemption(of: reward, by: memberID),
            on: date,
            calendar: calendar
        )

        switch availability {
        case .available:
            return
        case .tooExpensive:
            throw DomainError.insufficientPoints(balance: currentBalance, required: reward.cost)
        case .cooling(let until):
            throw DomainError.rewardUnavailable(
                reason: "it's available again on \(Self.dayFormatter.string(from: until))"
            )
        case .soldOut:
            throw DomainError.rewardUnavailable(reason: "there are none left")
        case .withdrawn:
            throw DomainError.rewardUnavailable(reason: "it's been switched off")
        }
    }

    /// When `memberID` last redeemed `reward`, if ever.
    public func lastRedemption(
        of reward: Reward,
        by memberID: Identifier<Member>
    ) -> Date? {
        entries.last { entry in
            entry.memberID == memberID && entry.source == .rewardRedeemed(reward.id)
        }?.occurredAt
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
