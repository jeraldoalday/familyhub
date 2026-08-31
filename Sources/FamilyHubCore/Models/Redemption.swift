import Foundation

/// A reward somebody has spent their points on, and what happened to it next.
///
/// Until now a redemption was a single line in the ledger: the points went, the
/// stock went down, and the app considered the matter closed. It is not closed.
/// "Movie night pick" is not a thing an app hands over — a parent is, on some
/// evening that has to be found — and a child who has paid twenty-five points
/// for one has bought a promise rather than a film. The gap between the two is
/// where a rewards system loses a family: the points arrive, nothing arrives
/// after them, and by the third time the currency is worth nothing.
///
/// So a redemption is a record with a life of its own. It is created owed, an
/// adult marks it given when the thing actually happens, and either side can
/// call it off — which refunds the points, because a promise the household
/// cannot keep is not something a child should have paid for.
///
/// The cost is copied onto the record rather than read back off the reward.
/// A parent re-pricing "30 minutes of screen time" from ten points to twenty
/// next month must not change what a redemption from last month refunds, and
/// reading the price live is how a cancelled redemption pays back more than it
/// ever took.
public struct Redemption: Entity {
    public let id: Identifier<Redemption>

    /// The household this redemption belongs to.
    public let householdID: Identifier<Household>

    /// What was redeemed.
    public let rewardID: Identifier<Reward>

    /// Who redeemed it.
    public let memberID: Identifier<Member>

    /// What it cost, as priced at the moment it was redeemed.
    public let cost: Int

    /// When the points were spent.
    public let redeemedAt: Date

    /// Anything the child wanted to say with it — "can we watch it Friday?".
    ///
    /// Optional, and worth having for the same reason a cover request's reason
    /// is: a bare row in a parent's queue is a thing to be worked out before it
    /// can be acted on, and most of the working out is a question the child has
    /// already answered.
    public private(set) var note: ValidatedText?

    /// Where the promise got to.
    public private(set) var state: State

    /// Creates a redemption.
    ///
    /// - Parameters:
    ///   - id: The record's identifier.
    ///   - householdID: The household it belongs to.
    ///   - rewardID: The reward that was redeemed.
    ///   - memberID: Who redeemed it.
    ///   - cost: What it cost them, as priced at that moment.
    ///   - redeemedAt: When the points were spent.
    ///   - note: Anything they wanted to say with it.
    ///   - state: Where it stands. Defaults to owed.
    /// - Throws: ``DomainError/tooLong(field:limit:)`` if the note is longer
    ///   than a note should be.
    public init(
        id: Identifier<Redemption> = Identifier(),
        householdID: Identifier<Household>,
        rewardID: Identifier<Reward>,
        memberID: Identifier<Member>,
        cost: Int,
        redeemedAt: Date,
        note: String? = nil,
        state: State = .owed
    ) throws {
        self.id = id
        self.householdID = householdID
        self.rewardID = rewardID
        self.memberID = memberID
        // Clamped at zero rather than validated against the reward's range. A
        // redemption records what was taken, and taking a negative number of
        // points would refund on cancellation — so the impossible value is
        // flattened here rather than being refused and locking a household out
        // of a record it already has.
        self.cost = max(0, cost)
        self.redeemedAt = redeemedAt
        self.note = try ValidatedText.optional(
            note,
            field: .redemptionNote,
            limit: Limits.notesLength
        )
        self.state = state
    }
}

// MARK: - State

extension Redemption {
    /// What happened to a redemption.
    ///
    /// Three states rather than a `isFulfilled` flag, because "the family owes
    /// this", "it happened on Friday" and "it was called off and the points
    /// went back" are three different rows to draw and only the middle one is
    /// what a boolean would record.
    public enum State: Hashable, Sendable, Codable {
        /// Paid for, not yet handed over. The household owes it.
        case owed

        /// An adult confirmed the reward actually happened.
        case given(by: Identifier<Member>, at: Date)

        /// Called off, and the points refunded.
        ///
        /// Carries who called it off because the two cases read very
        /// differently to a child: cancelling your own redemption is changing
        /// your mind, and having a parent cancel it is being told no. The
        /// history is the only place that distinction survives.
        case cancelled(by: Identifier<Member>, at: Date)

        /// Whether the household still owes this.
        public var isOwed: Bool { self == .owed }

        /// Whether it was handed over.
        public var isGiven: Bool { givenBy != nil }

        /// Whether it was called off.
        public var isCancelled: Bool {
            if case .cancelled = self { return true }
            return false
        }

        /// Who handed it over, when somebody did.
        public var givenBy: Identifier<Member>? {
            if case .given(let memberID, _) = self { return memberID }
            return nil
        }

        /// When it stopped being owed, if it has.
        public var settledAt: Date? {
            switch self {
            case .owed: nil
            case .given(_, let date), .cancelled(_, let date): date
            }
        }

        /// A short phrase for the row that shows the redemption.
        public var label: String {
            switch self {
            case .owed: "Waiting to be given"
            case .given: "Given"
            case .cancelled: "Cancelled"
            }
        }
    }
}

// MARK: - Derived values

extension Redemption {
    /// Whether the household still owes this reward.
    public var isOwed: Bool { state.isOwed }

    /// Whether the points spent on it have been given back.
    ///
    /// Cancelling is the only thing that refunds, so this is the same question
    /// as ``State/isCancelled`` — spelled from the ledger's side, because that
    /// is the side every caller asking it is standing on.
    public var wasRefunded: Bool { state.isCancelled }

    /// How long the household has owed this, in whole days, as of `date`.
    ///
    /// The number the queue sorts and shames by. A reward owed since March is
    /// the single most damaging thing a rewards screen can contain, and it is
    /// invisible unless something counts.
    ///
    /// - Parameters:
    ///   - date: The moment being asked about.
    ///   - calendar: The household's calendar.
    /// - Returns: Days since it was redeemed, never negative.
    public func daysOwed(on date: Date, calendar: Calendar) -> Int {
        let from = calendar.startOfDay(for: redeemedAt)
        let to = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return max(0, days)
    }

    /// Whether this redemption has been owed long enough to be worth chasing.
    ///
    /// Two days rather than one. A reward redeemed this morning is not overdue
    /// by the evening, and a queue that turns red overnight teaches a parent
    /// that the colour means nothing.
    ///
    /// - Parameters:
    ///   - date: The moment being asked about.
    ///   - calendar: The household's calendar.
    /// - Returns: `true` when it is still owed and has been for a while.
    public func isOverdue(on date: Date, calendar: Calendar) -> Bool {
        isOwed && daysOwed(on: date, calendar: calendar) >= Self.overdueAfterDays
    }

    /// How many days a redemption may sit before the app starts calling it
    /// overdue.
    public static let overdueAfterDays = 2

    /// Whether the household still owed this at a given moment.
    ///
    /// Asked of the past rather than of now, which is what a recap of last week
    /// needs: a promise that was outstanding all week and kept on Sunday
    /// evening was outstanding for the week being described, and reading the
    /// current state would quietly rewrite it.
    ///
    /// - Parameter date: The moment being asked about.
    /// - Returns: `true` when it had been redeemed by then and had not yet been
    ///   given or called off.
    public func wasOutstanding(at date: Date) -> Bool {
        guard redeemedAt <= date else { return false }
        guard let settledAt = state.settledAt else { return true }
        return settledAt > date
    }

    /// Whether this reward was actually handed over inside a period.
    ///
    /// - Parameter range: The period being summarised.
    /// - Returns: `true` when it was given during it.
    public func wasGiven(in range: ClosedRange<Date>) -> Bool {
        guard state.isGiven, let settledAt = state.settledAt else { return false }
        return range.contains(settledAt)
    }
}

// MARK: - Mutation

extension Redemption {
    /// Returns a copy an adult has marked as handed over.
    ///
    /// - Parameters:
    ///   - memberID: Who handed it over.
    ///   - date: When.
    /// - Returns: The given redemption.
    /// - Throws: ``DomainError/redemptionAlreadySettled`` if it has already
    ///   been given or cancelled. Two parents both ticking off the same movie
    ///   night is the ordinary case rather than the exotic one, and the second
    ///   of them has to be told rather than silently restamping the first.
    public func given(by memberID: Identifier<Member>, at date: Date) throws -> Redemption {
        try requireOwed()
        var copy = self
        copy.state = .given(by: memberID, at: date)
        return copy
    }

    /// Returns a copy that has been called off.
    ///
    /// - Parameters:
    ///   - memberID: Who called it off.
    ///   - date: When.
    /// - Returns: The cancelled redemption.
    /// - Throws: ``DomainError/redemptionAlreadySettled`` once it has been
    ///   given. A reward that has happened cannot be un-happened, and refunding
    ///   the points for one would let a household watch the film and keep the
    ///   points.
    public func cancelled(by memberID: Identifier<Member>, at date: Date) throws -> Redemption {
        try requireOwed()
        var copy = self
        copy.state = .cancelled(by: memberID, at: date)
        return copy
    }

    /// Returns a copy with a different note, or none.
    public func withNote(_ newNote: String?) throws -> Redemption {
        var copy = self
        copy.note = try ValidatedText.optional(
            newNote,
            field: .redemptionNote,
            limit: Limits.notesLength
        )
        return copy
    }

    /// Throws unless the household still owes this.
    private func requireOwed() throws {
        guard state.isOwed else {
            throw DomainError.redemptionAlreadySettled
        }
    }
}

// MARK: - Ordering

extension Redemption {
    /// The order a queue of owed rewards is worked through: oldest promise
    /// first, with the identifier breaking an exact tie so every device shows
    /// the same list in the same order.
    ///
    /// Oldest first rather than newest, unlike almost every other list in the
    /// app. A queue of promises is not a feed: the row that matters is the one
    /// that has been waiting longest, and putting this morning's redemption at
    /// the top is how the one from three weeks ago is never reached.
    public static func queueOrder(_ lhs: Redemption, _ rhs: Redemption) -> Bool {
        if lhs.redeemedAt != rhs.redeemedAt { return lhs.redeemedAt < rhs.redeemedAt }
        return lhs.id < rhs.id
    }

    /// The order a member's own history reads in: newest first.
    public static func historyOrder(_ lhs: Redemption, _ rhs: Redemption) -> Bool {
        if lhs.redeemedAt != rhs.redeemedAt { return lhs.redeemedAt > rhs.redeemedAt }
        return lhs.id < rhs.id
    }
}

// MARK: - Collections

extension Collection where Element == Redemption {
    /// The redemptions the household still owes, oldest first.
    public var owed: [Redemption] {
        filter(\.isOwed).sorted(by: Redemption.queueOrder)
    }

    /// One member's redemptions, newest first.
    ///
    /// - Parameter memberID: Whose history is being built.
    /// - Returns: Every redemption they have made, in any state.
    public func redeemed(by memberID: Identifier<Member>) -> [Redemption] {
        filter { $0.memberID == memberID }.sorted(by: Redemption.historyOrder)
    }

    /// The redemptions of one reward, newest first.
    ///
    /// - Parameter rewardID: The reward being asked about.
    /// - Returns: Every redemption of it, in any state.
    public func of(_ rewardID: Identifier<Reward>) -> [Redemption] {
        filter { $0.rewardID == rewardID }.sorted(by: Redemption.historyOrder)
    }

    /// When `memberID` last redeemed `rewardID` and kept it.
    ///
    /// Cancelled redemptions are skipped, which is the whole reason this is not
    /// simply "the newest record". A cooldown exists to stop a child redeeming
    /// "skip a chore" seven days running; it is not meant to punish one they
    /// changed their mind about ten minutes later and were refunded for.
    ///
    /// - Parameters:
    ///   - rewardID: The reward being asked about.
    ///   - memberID: Who is asking for it again.
    /// - Returns: When they last redeemed it without it being called off.
    public func lastKeptRedemption(
        of rewardID: Identifier<Reward>,
        by memberID: Identifier<Member>
    ) -> Date? {
        filter { $0.rewardID == rewardID && $0.memberID == memberID && !$0.wasRefunded }
            .map(\.redeemedAt)
            .max()
    }

    /// The owed redemptions that have been waiting long enough to chase.
    ///
    /// - Parameters:
    ///   - date: The moment being asked about.
    ///   - calendar: The household's calendar.
    /// - Returns: The overdue promises, oldest first.
    public func overdue(on date: Date, calendar: Calendar) -> [Redemption] {
        owed.filter { $0.isOverdue(on: date, calendar: calendar) }
    }

    /// What the household owes each member, in points.
    ///
    /// Computed in one pass rather than per member, because the screen that
    /// asks shows every member at once.
    ///
    /// - Returns: The total value of owed redemptions, keyed by member.
    public func owedPointsByMember() -> [Identifier<Member>: Int] {
        reduce(into: [:]) { totals, redemption in
            guard redemption.isOwed else { return }
            totals[redemption.memberID, default: 0] += redemption.cost
        }
    }
}
