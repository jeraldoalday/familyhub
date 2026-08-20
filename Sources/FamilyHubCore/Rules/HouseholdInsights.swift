import Foundation

/// Answers the questions a household actually argues about.
///
/// Two of them, specifically: "did we keep up this week?" and "am I doing more
/// than everyone else?" The second one is the reason a chore app gets deleted,
/// and it is not answerable by any single screen the app already has — the
/// agenda shows today, the ledger shows points, and neither shows whether the
/// work was shared out evenly.
///
/// Everything here is derived from a snapshot on demand. Nothing is stored,
/// because a stored summary is a summary that can disagree with the records it
/// came from, and a disagreement about who did more is exactly the wrong place
/// to have one.
public struct HouseholdInsights: Sendable {

    private let snapshot: HouseholdSnapshot
    private let calendar: Calendar
    private let engine: RecurrenceEngine

    /// Creates an insights view over a household.
    public init(snapshot: HouseholdSnapshot) {
        self.snapshot = snapshot
        self.calendar = snapshot.household.calendar()
        self.engine = snapshot.engine
    }

    // MARK: - The week in review

    /// How a household did over a period.
    public struct Recap: Sendable {
        /// The days covered, inclusive.
        public let range: ClosedRange<Date>

        /// Occurrences that fell due in the period.
        public let scheduled: Int

        /// Occurrences that were completed.
        public let completed: Int

        /// Completions recorded on the day they were due.
        public let onTime: Int

        /// Points earned across the household.
        public let pointsEarned: Int

        /// One row per active member.
        public let members: [MemberSummary]

        /// The day with the most work due, for the "Wednesdays are brutal"
        /// observation that leads a family to move something.
        public let busiestDay: Date?

        /// The chore missed most often, which is nearly always a chore that
        /// wants rescheduling rather than a family that wants nagging.
        public let mostMissedChore: Chore?

        /// The proportion of due work that got done, `0...1`.
        ///
        /// A period that asked nothing scores 1 rather than 0. Nothing due and
        /// nothing done is a quiet week, not a failure, and showing a family
        /// 0% for a week they were on holiday is both wrong and demoralising.
        public var completionRate: Double {
            guard scheduled > 0 else { return 1 }
            return Double(completed) / Double(scheduled)
        }

        /// The proportion of completed work done on the day it was due.
        public var punctualityRate: Double {
            guard completed > 0 else { return 1 }
            return Double(onTime) / Double(completed)
        }

        /// Whether anything at all was asked of the household.
        public var isQuiet: Bool { scheduled == 0 }
    }

    /// One member's week.
    public struct MemberSummary: Sendable, Identifiable {
        public let member: Member

        /// Occurrences assigned specifically to them.
        public let assigned: Int

        /// Of those, how many were completed — by anyone. A parent covering
        /// for a child still means the work happened, and the recap is about
        /// the household keeping up rather than about blame.
        public let completed: Int

        /// Occurrences they personally ticked off, including open chores they
        /// claimed and chores assigned to somebody else.
        public let completedByThem: Int

        /// Points banked in the period.
        public let pointsEarned: Int

        /// Their run of complete days, measured at the end of the period.
        public let streak: Streak

        public var id: Identifier<Member> { member.id }

        /// The proportion of their own work that got done, `0...1`.
        public var completionRate: Double {
            guard assigned > 0 else { return 1 }
            return Double(completed) / Double(assigned)
        }
    }

    /// Summarises the week containing `day`, up to and including it.
    ///
    /// The week boundary is the household's own — a family that starts its week
    /// on Sunday gets a Sunday-to-Saturday recap — and the period never runs
    /// past `day`, because counting Friday's chores as missed on Tuesday would
    /// make every mid-week recap read like a disaster.
    public func weeklyRecap(forWeekContaining day: Date) -> Recap {
        let today = calendar.startOfDay(for: day)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today) else {
            return recap(from: today, to: today)
        }
        let start = calendar.startOfDay(for: week.start)
        return recap(from: start, to: today)
    }

    /// Summarises an explicit range of days, inclusive.
    ///
    /// - Parameters:
    ///   - start: The first day counted.
    ///   - end: The last day counted. Clamped to be no earlier than `start`.
    /// - Returns: The recap.
    public func recap(from start: Date, to end: Date) -> Recap {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = max(firstDay, calendar.startOfDay(for: end))
        let range = firstDay...lastDay

        // A chore due today counts as scheduled even though it has not been
        // missed yet. Excluding it would make the completion rate climb every
        // morning and fall every evening for reasons unrelated to the work.
        let settled = occurrences(in: range)
        let completions = Dictionary(
            settledCompletions.map { ($0.occurrenceKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var completed = 0
        var onTime = 0
        var perDay: [Date: Int] = [:]
        var missesByChore: [Identifier<Chore>: Int] = [:]

        for occurrence in settled {
            perDay[occurrence.day, default: 0] += 1
            let key = ChoreCompletion.OccurrenceKey(
                choreID: occurrence.chore.id, day: occurrence.day
            )
            guard let record = completions[key] else {
                missesByChore[occurrence.chore.id, default: 0] += 1
                continue
            }
            completed += 1
            if !record.wasLate(calendar: calendar) { onTime += 1 }
        }

        let entries = snapshot.ledger.entries(in: firstDay...endOfDay(lastDay))
        let pointsEarned = entries.filter(\.isCredit).reduce(0) { $0 + $1.amount }

        return Recap(
            range: range,
            scheduled: settled.count,
            completed: completed,
            onTime: onTime,
            pointsEarned: pointsEarned,
            members: memberSummaries(in: range, occurrences: settled, completions: completions),
            busiestDay: busiestDay(from: perDay),
            mostMissedChore: mostMissed(from: missesByChore)
        )
    }

    /// The completions that count as the work having been done.
    ///
    /// A record an adult sent back does not. The whole meaning of rejecting a
    /// completion is that the work has to happen again, which is why the home
    /// screen shows the chore as outstanding and why the streak calculator
    /// treats the day as a miss — and a recap that counted it anyway would tell
    /// a family they finished a week they are still halfway through.
    ///
    /// Filtered before deduplicating rather than after, so an occurrence with
    /// both a rejected record and its replacement resolves to the replacement
    /// rather than to whichever came first. The streak calculator resolves the
    /// same collision the same way, and the two disagreeing is the bug this
    /// property exists to prevent.
    private var settledCompletions: [ChoreCompletion] {
        snapshot.completions
            .filter(\.approval.countsAsDone)
            .deduplicatedByOccurrence()
    }

    // MARK: - Who is doing the work

    /// One member's share of the household's work.
    public struct WorkloadShare: Sendable, Identifiable {
        public let member: Member

        /// Occurrences assigned to them in the period.
        public let occurrences: Int

        /// The points those occurrences are worth.
        ///
        /// Share is measured in points rather than in chore counts, because the
        /// household has already said what the work is worth: emptying a bin
        /// and cleaning a bathroom are both "one chore" and nobody involved
        /// thinks they are the same job.
        public let points: Int

        /// Their proportion of all assigned points, `0...1`.
        public let share: Double

        /// The proportion they would carry if the work were split evenly.
        public let evenShare: Double

        public var id: Identifier<Member> { member.id }

        /// How far above or below an even split they are, in proportion points.
        /// Positive means they carry more than their share.
        public var deviation: Double { share - evenShare }
    }

    /// How evenly a household's work is divided.
    public struct WorkloadBalance: Sendable {
        /// One row per member who could be assigned work, heaviest first.
        public let shares: [WorkloadShare]

        /// Occurrences nobody was named on, open for whoever gets to them.
        public let unassignedOccurrences: Int

        /// The largest gap between any member's share and an even split.
        public let widestGap: Double

        /// Whether the split is close enough to even to leave alone.
        ///
        /// The tolerance is deliberately loose. Households are not payroll
        /// systems, ages differ, and an app that flags a five-point imbalance
        /// invents an argument that nobody was having.
        public var isBalanced: Bool { widestGap <= WorkloadBalance.tolerance }

        /// How far from an even split counts as uneven.
        public static let tolerance = 0.15

        /// The member carrying the most, when there is a meaningful imbalance.
        public var carryingMost: Member? {
            guard !isBalanced else { return nil }
            return shares.first?.member
        }
    }

    /// How the work assigned in a period was divided.
    ///
    /// Only specifically-assigned occurrences count toward a person. Open
    /// chores are reported separately rather than divided by hand, because
    /// guessing who "would have" done an unclaimed chore is exactly the sort of
    /// invented number that makes a fairness screen untrustworthy.
    ///
    /// - Parameters:
    ///   - start: The first day counted.
    ///   - end: The last day counted.
    /// - Returns: The balance, with members ordered heaviest first.
    public func workloadBalance(from start: Date, to end: Date) -> WorkloadBalance {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = max(firstDay, calendar.startOfDay(for: end))
        let occurrences = self.occurrences(in: firstDay...lastDay)

        var pointsByMember: [Identifier<Member>: Int] = [:]
        var countByMember: [Identifier<Member>: Int] = [:]
        var unassigned = 0

        for occurrence in occurrences {
            guard let assigneeID = occurrence.assigneeID else {
                unassigned += 1
                continue
            }
            pointsByMember[assigneeID, default: 0] += occurrence.chore.points
            countByMember[assigneeID, default: 0] += 1
        }

        // Everyone who could be given work appears, including anyone currently
        // on zero — a member carrying nothing is the most important row on a
        // fairness screen and omitting them would hide the whole point.
        let candidates = snapshot.activeMembers
        let totalPoints = pointsByMember.values.reduce(0, +)
        let evenShare = candidates.isEmpty ? 0 : 1 / Double(candidates.count)

        let shares =
            candidates
            .map { member -> WorkloadShare in
                let points = pointsByMember[member.id] ?? 0
                return WorkloadShare(
                    member: member,
                    occurrences: countByMember[member.id] ?? 0,
                    points: points,
                    share: totalPoints > 0 ? Double(points) / Double(totalPoints) : evenShare,
                    evenShare: evenShare
                )
            }
            .sorted { lhs, rhs in
                if lhs.points != rhs.points { return lhs.points > rhs.points }
                return Member.displayOrder(lhs.member, rhs.member)
            }

        let widestGap = shares.map { abs($0.deviation) }.max() ?? 0
        return WorkloadBalance(
            shares: shares,
            unassignedOccurrences: unassigned,
            widestGap: widestGap
        )
    }

    // MARK: - Occurrence expansion

    /// One scheduled occurrence, resolved to the person it fell to.
    private struct ScheduledOccurrence {
        let chore: Chore
        let day: Date
        let assigneeID: Identifier<Member>?
    }

    /// Every occurrence of every active chore inside the range.
    ///
    /// One walk of the schedule per chore. Resolving the rota by asking for
    /// each day's position separately walks from the chore's start once per
    /// day, which on a week of daily chores is seven times the work for the
    /// same answer — and grows with the household's whole history rather than
    /// with the week being summarised.
    private func occurrences(in range: ClosedRange<Date>) -> [ScheduledOccurrence] {
        snapshot.activeChores.flatMap { chore -> [ScheduledOccurrence] in
            chore.indexedOccurrences(in: range, using: engine, maximum: Int.max)
                .map { occurrence in
                    ScheduledOccurrence(
                        chore: chore,
                        day: occurrence.day,
                        assigneeID: chore.assignee(forOccurrenceIndex: occurrence.index)
                    )
                }
        }
    }

    /// Per-member rows for the recap.
    private func memberSummaries(
        in range: ClosedRange<Date>,
        occurrences: [ScheduledOccurrence],
        completions: [ChoreCompletion.OccurrenceKey: ChoreCompletion]
    ) -> [MemberSummary] {
        let ledger = snapshot.ledger
        let streaks = snapshot.streaks
        let periodRange = range.lowerBound...endOfDay(range.upperBound)

        return snapshot.activeMembers.map { member in
            let theirs = occurrences.filter { $0.assigneeID == member.id }
            let done = theirs.filter { occurrence in
                completions[
                    ChoreCompletion.OccurrenceKey(choreID: occurrence.chore.id, day: occurrence.day)
                ] != nil
            }
            let byThem = completions.values.filter { record in
                record.completedBy == member.id && range.contains(record.occurrenceDay)
            }

            return MemberSummary(
                member: member,
                assigned: theirs.count,
                completed: done.count,
                completedByThem: byThem.count,
                pointsEarned: ledger.earned(by: member.id, in: periodRange),
                streak: streaks.streak(forMember: member.id, asOf: range.upperBound)
            )
        }
    }

    // MARK: - Superlatives

    /// The day with the most work due; `nil` when nothing was due at all.
    ///
    /// Ties resolve to the earlier day so the answer does not move about
    /// between reads of the same week.
    private func busiestDay(from perDay: [Date: Int]) -> Date? {
        perDay
            .filter { $0.value > 0 }
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }?
            .key
    }

    /// The chore missed most often; `nil` when nothing was missed.
    private func mostMissed(from misses: [Identifier<Chore>: Int]) -> Chore? {
        let worst = misses.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }
        return worst.flatMap { snapshot.chore($0.key) }
    }

    /// The last instant of a day, for ranges that must include everything
    /// recorded on it.
    private func endOfDay(_ day: Date) -> Date {
        let start = calendar.startOfDay(for: day)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return next.addingTimeInterval(-1)
    }
}

// MARK: - Snapshot convenience

extension HouseholdSnapshot {
    /// Insights derived from this snapshot.
    public var insights: HouseholdInsights {
        HouseholdInsights(snapshot: self)
    }
}
