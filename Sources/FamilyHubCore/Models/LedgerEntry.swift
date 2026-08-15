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

        /// A reward was redeemed.
        case rewardRedeemed(Identifier<Reward>)

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
            case .rewardRedeemed: "Reward"
            case .adjustment: "Adjustment"
            case .bonus: "Bonus"
            case .reset: "Reset"
            }
        }

        /// The SF Symbol for the history row.
        public var symbolName: String {
            switch self {
            case .choreCompleted: "checkmark.circle.fill"
            case .rewardRedeemed: "gift.fill"
            case .adjustment: "slider.horizontal.3"
            case .bonus: "star.fill"
            case .reset: "arrow.counterclockwise"
            }
        }

        /// Whether an adult made this entry by hand, which the history view
        /// marks so a child can see the change was deliberate rather than a bug.
        public var wasManual: Bool {
            switch self {
            case .adjustment, .bonus, .reset: true
            case .choreCompleted, .rewardRedeemed: false
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
