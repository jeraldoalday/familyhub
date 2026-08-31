import Foundation

/// A single signed movement of points, and the reason for it.
///
/// The ledger is append-only. A balance is never stored, only summed. That
/// costs a little arithmetic on read and buys three things that matter more:
///
/// - **It syncs without conflict.** Entries are immutable and independent, so
///   two devices adding entries offline merge by union. A stored balance would
///   need last-write-wins, and last-write-wins on a number silently discards
///   whichever device was slower — which is to say, discards real chores a
///   child actually did.
/// - **It is auditable.** "Where did my points go?" is a question children ask
///   constantly, and it is answerable here by listing entries rather than by
///   apologising.
/// - **It cannot drift.** A stored balance and a history that disagree is a bug
///   with no correct resolution. There is only one number here, and it is
///   derived.
public struct LedgerEntry: Entity {
    public let id: Identifier<LedgerEntry>

    /// The household this movement belongs to.
    public let householdID: Identifier<Household>

    /// Whose balance moves.
    public let memberID: Identifier<Member>

    /// The signed change. Positive earns, negative spends.
    public let amount: Int

    /// Why the balance moved.
    public let source: Source

    /// When it happened.
    public let occurredAt: Date

    /// An optional note, shown in the history list.
    public let note: String?

    /// Creates a ledger entry.
    public init(
        id: Identifier<LedgerEntry> = Identifier(),
        householdID: Identifier<Household>,
        memberID: Identifier<Member>,
        amount: Int,
        source: Source,
        occurredAt: Date,
        note: String? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.memberID = memberID
        self.amount = amount
        self.source = source
        self.occurredAt = occurredAt
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

// MARK: - Source

extension LedgerEntry {
    /// What caused the movement.
    public enum Source: Hashable, Sendable, Codable {
        /// A chore was completed and approved.
        case choreCompleted(Identifier<ChoreCompletion>)

        /// A chore that had already been paid for was sent back by an adult.
        ///
        /// The ledger is append-only, so taking points back is an entry rather
        /// than an erasure. That is not merely a technical constraint: a child
        /// whose balance drops needs to be able to see why it dropped, and a
        /// history with a gap where ten points used to be is exactly the thing
        /// that makes them stop trusting the number.
        case choreSentBack(Identifier<ChoreCompletion>)

        /// A reward was redeemed.
        case rewardRedeemed(Identifier<Reward>)

        /// A redemption was called off and the points given back.
        ///
        /// An entry rather than an erasure, for the same reason sending a
        /// chore back is one. A child whose balance goes up by twenty-five
        /// points needs to be able to see that it went up because the film
        /// never happened — and a household that could quietly delete the
        /// original line would be a household where a parent can take a
        /// reward back and leave no trace of having done it.
        case rewardRefunded(Identifier<Reward>)

        /// An adult granted or removed points by hand.
        case adjustment(by: Identifier<Member>)

        /// A one-off bonus for something not on the chore list.
        case bonus(by: Identifier<Member>)

        /// Points expired or were reset at the start of a season.
        case reset(by: Identifier<Member>)

        /// A short label for the history row.
        public var label: String {
            switch self {
            case .choreCompleted: "Chore"
            case .choreSentBack: "Sent back"
            case .rewardRedeemed: "Reward"
            case .rewardRefunded: "Refund"
            case .adjustment: "Adjustment"
            case .bonus: "Bonus"
            case .reset: "Reset"
            }
        }

        /// The SF Symbol for the history row.
        public var symbolName: String {
            switch self {
            case .choreCompleted: "checkmark.circle.fill"
            case .choreSentBack: "arrow.uturn.backward.circle.fill"
            case .rewardRedeemed: "gift.fill"
            case .rewardRefunded: "gift.circle"
            case .adjustment: "slider.horizontal.3"
            case .bonus: "star.fill"
            case .reset: "arrow.counterclockwise"
            }
        }

        /// Whether an adult made this entry by hand, which the history view
        /// marks so a child can see the change was deliberate rather than a bug.
        public var wasManual: Bool {
            switch self {
            // Sending work back is an adult's decision, and the history marks
            // it as one so a child can see the change was deliberate rather
            // than a bug — which is the entire reason this flag exists.
            case .adjustment, .bonus, .reset, .choreSentBack: true
            case .choreCompleted, .rewardRedeemed, .rewardRefunded: false
            }
        }
    }
}

// MARK: - Convenience constructors

extension LedgerEntry {
    /// The entry recording an approved chore completion.
    public static func earned(
        _ completion: ChoreCompletion,
        note: String? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            householdID: completion.householdID,
            memberID: completion.completedBy,
            amount: completion.pointsAwarded,
            source: .choreCompleted(completion.id),
            occurredAt: completion.completedAt,
            note: note
        )
    }

    /// The entry taking back what an approved completion had already paid.
    ///
    /// Negated here rather than at the call site, for the same reason a
    /// redemption is: a caller cannot accidentally credit points by rejecting
    /// somebody's work.
    ///
    /// Stamped with the moment of the rejection rather than of the completion,
    /// so the history reads in the order the family experienced it — the points
    /// arrived, and then later they went away.
    ///
    /// - Parameters:
    ///   - completion: The completion being sent back.
    ///   - date: When the adult sent it back.
    ///   - note: The reason they gave, if they gave one.
    /// - Returns: The reversing entry.
    public static func sentBack(
        _ completion: ChoreCompletion,
        at date: Date,
        note: String? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            householdID: completion.householdID,
            memberID: completion.completedBy,
            amount: -abs(completion.pointsAwarded),
            source: .choreSentBack(completion.id),
            occurredAt: date,
            note: note
        )
    }

    /// The entry recording a redemption. The amount is negated here rather than
    /// at the call site, so a caller cannot accidentally credit points by
    /// redeeming a reward.
    public static func spent(
        on reward: Reward,
        by memberID: Identifier<Member>,
        at date: Date,
        note: String? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            householdID: reward.householdID,
            memberID: memberID,
            amount: -abs(reward.cost),
            source: .rewardRedeemed(reward.id),
            occurredAt: date,
            note: note ?? reward.name.value
        )
    }

    /// The entry giving back what a redemption took, when it is called off.
    ///
    /// Reads the amount off the redemption rather than off the reward, which
    /// is the whole reason the redemption carries a cost of its own: a parent
    /// who re-prices "30 minutes of screen time" from ten points to twenty
    /// must not thereby turn a refund into a profit.
    ///
    /// Stamped with the moment of the cancellation rather than of the
    /// redemption, so the history reads in the order the family experienced
    /// it — the points went, and then later they came back.
    ///
    /// - Parameters:
    ///   - redemption: The redemption being called off.
    ///   - date: When it was called off.
    ///   - note: The reason, if one was given.
    /// - Returns: The refunding entry.
    public static func refunded(
        _ redemption: Redemption,
        at date: Date,
        note: String? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            householdID: redemption.householdID,
            memberID: redemption.memberID,
            amount: abs(redemption.cost),
            source: .rewardRefunded(redemption.rewardID),
            occurredAt: date,
            note: note
        )
    }

    /// A manual adjustment by an adult, positive or negative.
    public static func adjustment(
        householdID: Identifier<Household>,
        memberID: Identifier<Member>,
        amount: Int,
        by adultID: Identifier<Member>,
        at date: Date,
        note: String? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            householdID: householdID,
            memberID: memberID,
            amount: amount,
            source: .adjustment(by: adultID),
            occurredAt: date,
            note: note
        )
    }
}

// MARK: - Derived values

extension LedgerEntry {
    /// Whether this entry adds to a balance.
    public var isCredit: Bool { amount > 0 }

    /// The amount formatted for display, signed: "+10", "−25".
    ///
    /// Uses a true minus sign rather than a hyphen, because in the tabular
    /// figures used by the history list a hyphen sits at the wrong optical
    /// weight and misaligns the column.
    public var signedDescription: String {
        amount >= 0 ? "+\(amount)" : "−\(abs(amount))"
    }
}
