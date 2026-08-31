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
    ///
    /// A refund is a credit and is not earning. Counting one would let a child
    /// climb the board by redeeming an expensive reward and cancelling it,
    /// which is a scoreboard a nine year old finds in an afternoon.
    public func totalEarned(by memberID: Identifier<Member>) -> Int {
        entries.reduce(into: 0) { total, entry in
            guard entry.memberID == memberID, entry.isEarned else { return }
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
    ///
    /// Refunds are excluded on the same argument as ``totalEarned(by:)``: a
    /// week in which a child was given back the points for a promise the
    /// household failed to keep was not a week they earned more.
    public func earned(
        by memberID: Identifier<Member>,
        in range: ClosedRange<Date>
    ) -> Int {
        entries.reduce(into: 0) { total, entry in
            guard entry.memberID == memberID,
                entry.isEarned,
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
    /// - Parameters:
    ///   - reward: What they want.
    ///   - memberID: Who wants it.
    ///   - date: The current moment.
    ///   - calendar: The household calendar.
    ///   - redemptions: The household's redemption records, when the caller
    ///     holds them. They are the exact answer to the cooldown question,
    ///     because a record knows whether it was refunded and the ledger can
    ///     only infer it. Left empty — which is what a household restored from
    ///     a backup taken before redemptions were records looks like — the
    ///     cooldown falls back to ``lastRedemption(of:by:)``.
    /// - Throws: ``DomainError/insufficientPoints(balance:required:)`` carrying
    ///   the shortfall, or ``DomainError/rewardUnavailable(reason:)``.
    public func authorizeRedemption(
        of reward: Reward,
        by memberID: Identifier<Member>,
        on date: Date,
        calendar: Calendar,
        redemptions: some Collection<Redemption> = EmptyCollection<Redemption>()
    ) throws {
        let currentBalance = balance(for: memberID)
        let lastKept =
            redemptions.isEmpty
            ? lastRedemption(of: reward, by: memberID)
            : redemptions.lastKeptRedemption(of: reward.id, by: memberID)
        let availability = reward.availability(
            forBalance: currentBalance,
            lastRedemption: lastKept,
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

    /// When `memberID` last redeemed `reward` and kept it, if ever.
    ///
    /// Refunds are netted off rather than ignored. A cooldown exists to stop a
    /// child redeeming "skip a chore" seven days running; a redemption they
    /// changed their mind about ten minutes later, and were given the points
    /// back for, is not one of those seven days and must not lock them out for
    /// a week.
    ///
    /// The pairing walks backwards and cancels each refund against the next
    /// older redemption of the same reward. That is a reconstruction rather
    /// than a reading: the ledger records that a refund happened, not which
    /// redemption it belonged to, and two of each in flight at once can only be
    /// matched by assumption. Callers holding the redemption records themselves
    /// should ask them instead — see
    /// ``Swift/Collection/lastKeptRedemption(of:by:)`` — and pass the answer to
    /// ``authorizeRedemption(of:by:on:calendar:lastRedemption:)``. This is the
    /// answer for the household whose records predate them.
    ///
    /// - Parameters:
    ///   - reward: The reward being asked about.
    ///   - memberID: Who is asking for it again.
    /// - Returns: When they last redeemed it without being refunded.
    public func lastRedemption(
        of reward: Reward,
        by memberID: Identifier<Member>
    ) -> Date? {
        var refundsToAccountFor = 0
        for entry in entries.reversed() where entry.memberID == memberID {
            if entry.source == .rewardRefunded(reward.id) {
                refundsToAccountFor += 1
            } else if entry.source == .rewardRedeemed(reward.id) {
                guard refundsToAccountFor == 0 else {
                    refundsToAccountFor -= 1
                    continue
                }
                return entry.occurredAt
            }
        }
        return nil
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
