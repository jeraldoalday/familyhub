import Foundation

/// A record that a specific occurrence of a chore was done.
///
/// Keyed by chore *and day*, not by chore alone. A daily chore has one
/// completion per day, and the pair is what makes "already done" answerable
/// without scanning history — and what stops the same Tuesday being ticked off
/// twice from two devices and paying out twice.
public struct ChoreCompletion: Entity {
    public let id: Identifier<ChoreCompletion>

    /// The household, denormalised so a member's history can be fetched
    /// without joining through every chore.
    public let householdID: Identifier<Household>

    /// The chore that was done.
    public let choreID: Identifier<Chore>

    /// Which occurrence — the start of the day the chore was due.
    public let occurrenceDay: Date

    /// Who did it.
    public let completedBy: Identifier<Member>

    /// When they marked it done, which may be later than the day it was due.
    public let completedAt: Date

    /// The approval state, when the household requires sign-off.
    public private(set) var approval: Approval

    /// Points captured at completion time.
    ///
    /// Snapshotted rather than read back from the chore, because a parent
    /// raising a chore from 10 points to 20 must not retroactively inflate
    /// every balance in the household's history.
    public let pointsAwarded: Int

    /// Creates a completion record.
    public init(
        id: Identifier<ChoreCompletion> = Identifier(),
        householdID: Identifier<Household>,
        choreID: Identifier<Chore>,
        occurrenceDay: Date,
        completedBy: Identifier<Member>,
        completedAt: Date,
        approval: Approval = .notRequired,
        pointsAwarded: Int,
        calendar: Calendar
    ) {
        self.id = id
        self.householdID = householdID
        self.choreID = choreID
        // Normalised on the way in so that two devices recording the same
        // occurrence at different times of day still produce the same key.
        self.occurrenceDay = calendar.startOfDay(for: occurrenceDay)
        self.completedBy = completedBy
        self.completedAt = completedAt
        self.approval = approval
        self.pointsAwarded = max(0, pointsAwarded)
    }
}

// MARK: - Approval

extension ChoreCompletion {
    /// Whether an adult still needs to sign this off.
    public enum Approval: Hashable, Sendable, Codable {
        /// The household does not require approval; points are already banked.
        case notRequired

        /// Waiting for an adult.
        case pending

        /// Signed off by an adult at the given time.
        case approved(by: Identifier<Member>, at: Date)

        /// Sent back, with an optional reason the child can act on.
        case rejected(by: Identifier<Member>, at: Date, reason: String?)

        /// Whether the points count toward a balance.
        ///
        /// Pending work is deliberately excluded. Showing points that could
        /// still be taken away teaches a child that the number is negotiable,
        /// which is the opposite of what the mechanic is for.
        public var countsTowardBalance: Bool {
            switch self {
            case .notRequired, .approved: true
            case .pending, .rejected: false
            }
        }

        /// Whether an adult still needs to act.
        public var needsReview: Bool { self == .pending }

        /// Whether the occurrence should still be treated as finished.
        ///
        /// Wider than ``countsTowardBalance`` by exactly one case, and the
        /// difference is deliberate. Work waiting on a parent is done — the
        /// child has swept the floor, and a home screen that shows the chore as
        /// outstanding until an adult opens the app is telling them it did not
        /// count. Work that was *sent back* is not done, because the whole
        /// meaning of rejecting a completion is that it has to happen again.
        public var countsAsDone: Bool {
            switch self {
            case .notRequired, .pending, .approved: true
            case .rejected: false
            }
        }

        /// Whether an adult sent this back for another go.
        public var isRejected: Bool {
            if case .rejected = self { return true }
            return false
        }

        /// Why it was sent back, when a reason was given.
        public var rejectionReason: String? {
            if case .rejected(_, _, let reason) = self { return reason }
            return nil
        }
    }
}

// MARK: - Derived values

extension ChoreCompletion {
    /// The composite key identifying the occurrence this record settles.
    ///
    /// Two completions sharing a key are the same occurrence recorded twice —
    /// the exact collision an offline-first app produces when two devices tick
    /// the same chore off before syncing.
    public struct OccurrenceKey: Hashable, Sendable, Codable {
        public let choreID: Identifier<Chore>
        public let day: Date

        public init(choreID: Identifier<Chore>, day: Date) {
            self.choreID = choreID
            self.day = day
        }
    }

    /// This completion's occurrence key.
    public var occurrenceKey: OccurrenceKey {
        OccurrenceKey(choreID: choreID, day: occurrenceDay)
    }

    /// Whether the chore was completed later than the day it was due.
    public func wasLate(calendar: Calendar) -> Bool {
        calendar.startOfDay(for: completedAt) > occurrenceDay
    }

    /// How many whole days late, or zero if on time.
    public func daysLate(calendar: Calendar) -> Int {
        let completedDay = calendar.startOfDay(for: completedAt)
        let components = calendar.dateComponents([.day], from: occurrenceDay, to: completedDay)
        return max(0, components.day ?? 0)
    }
}

// MARK: - Mutation

extension ChoreCompletion {
    /// Returns a copy approved by an adult.
    public func approved(by memberID: Identifier<Member>, at date: Date) -> ChoreCompletion {
        var copy = self
        copy.approval = .approved(by: memberID, at: date)
        return copy
    }

    /// Returns a copy sent back for another go.
    public func rejected(
        by memberID: Identifier<Member>,
        at date: Date,
        reason: String? = nil
    ) -> ChoreCompletion {
        var copy = self
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.approval = .rejected(
            by: memberID,
            at: date,
            reason: (trimmed?.isEmpty ?? true) ? nil : trimmed
        )
        return copy
    }
}

// MARK: - Collections

extension Collection where Element == ChoreCompletion {
    /// The completions that count toward a point balance.
    public var banked: [ChoreCompletion] {
        filter(\.approval.countsTowardBalance)
    }

    /// The completions waiting on an adult, oldest first, so the review queue
    /// clears in the order children submitted.
    public var awaitingReview: [ChoreCompletion] {
        filter(\.approval.needsReview).sorted { $0.completedAt < $1.completedAt }
    }

    /// The completions an adult sent back, which are outstanding work again
    /// rather than history.
    public var rejected: [ChoreCompletion] {
        filter(\.approval.isRejected)
    }

    /// The completions recorded by a given member.
    public func by(_ memberID: Identifier<Member>) -> [ChoreCompletion] {
        filter { $0.completedBy == memberID }
    }

    /// Deduplicates by occurrence, keeping the earliest completion of each.
    ///
    /// Two devices offline at once will both record the same chore being done.
    /// Neither is wrong, so the conflict resolves by wall-clock order rather
    /// than by whichever synced first, which would be arbitrary — and the
    /// identifier breaks an exact tie so every device converges on the same
    /// winner without needing to negotiate.
    public func deduplicatedByOccurrence() -> [ChoreCompletion] {
        var winners: [ChoreCompletion.OccurrenceKey: ChoreCompletion] = [:]
        for completion in self {
            guard let existing = winners[completion.occurrenceKey] else {
                winners[completion.occurrenceKey] = completion
                continue
            }
            if completion.completedAt < existing.completedAt
                || (completion.completedAt == existing.completedAt && completion.id < existing.id)
            {
                winners[completion.occurrenceKey] = completion
            }
        }
        // Sorted with the identifier as a tiebreaker for the same reason the
        // winner is chosen with one. Ticking four chores off in one go stamps
        // them all with the same instant, and `Dictionary.values` has no order
        // worth relying on — Swift seeds its hashing per process, so sorting on
        // the timestamp alone returns those four in a different sequence on
        // every launch. A history list that reshuffles itself between reads
        // looks like data changing when nothing has.
        return winners.values.sorted { lhs, rhs in
            if lhs.completedAt != rhs.completedAt { return lhs.completedAt < rhs.completedAt }
            return lhs.id < rhs.id
        }
    }
}
