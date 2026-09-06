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

    /// The household's trips, already filtered to the ones still standing.
    private let awayPeriods: [AwayPeriod]

    /// Creates an insights view over a household.
    public init(snapshot: HouseholdSnapshot) {
        self.snapshot = snapshot
        self.calendar = snapshot.household.calendar()
        self.engine = snapshot.engine
        self.awayPeriods = snapshot.awayPeriods.filter(\.isActive)
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

        /// Rewards actually handed over during the period.
        ///
        /// The half of the reward economy a household can otherwise never see.
        /// Points spent are visible on every screen; promises kept are visible
        /// nowhere, and a week where the family delivered two of them is a week
        /// worth telling them about.
        public let rewardsGiven: Int

        /// Rewards paid for and still not handed over when the period ended.
        ///
        /// Counted as the period saw it rather than as things stand now, so a
        /// recap of last week does not quietly rewrite itself once somebody
        /// settles up on Monday.
        public let rewardsOwed: Int

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

        /// Whether the household ended the period owing nobody anything.
        ///
        /// Worth saying out loud on the recap card, and worth saying only when
        /// it is true. A family that keeps its promises about rewards is a
        /// family whose points mean something, and it is the one part of this
        /// summary the adults control entirely.
        public var keptEveryPromise: Bool { rewardsOwed == 0 }
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

        /// Rewards they had paid for and were still waiting on when the period
        /// ended.
        ///
        /// On the member's own row because that is where it is actionable. A
        /// household total tells an adult that somebody is waiting; this tells
        /// them who, on the same card that is already telling them how much
        /// that person did.
        public let rewardsOwed: Int

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

        let completions = Dictionary(
            settledCompletions.map { ($0.occurrenceKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // A chore due today counts as scheduled even though it has not been
        // missed yet. Excluding it would make the completion rate climb every
        // morning and fall every evening for reasons unrelated to the work.
        let settled = occurrences(in: range, completed: Set(completions.keys))

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
        // Earned rather than credited: a refund puts points back into a
        // balance without anybody having done anything, and a recap that
        // counted it would congratulate a household for a promise it broke.
        let pointsEarned = entries.filter(\.isEarned).reduce(0) { $0 + $1.amount }

        let periodEnd = endOfDay(lastDay)
        return Recap(
            range: range,
            scheduled: settled.count,
            completed: completed,
            onTime: onTime,
            pointsEarned: pointsEarned,
            members: memberSummaries(in: range, occurrences: settled, completions: completions),
            busiestDay: busiestDay(from: perDay),
            mostMissedChore: mostMissed(from: missesByChore),
            rewardsGiven: snapshot.redemptions.count {
                $0.wasGiven(in: firstDay...periodEnd)
            },
            rewardsOwed: snapshot.redemptions.count { $0.wasOutstanding(at: periodEnd) }
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
    /// A covered occurrence counts against whoever took it on, for the same
    /// reason: crediting the person the rota named for work somebody else
    /// agreed to do is not a guess but a known-wrong number.
    ///
    /// - Parameters:
    ///   - start: The first day counted.
    ///   - end: The last day counted.
    /// - Returns: The balance, with members ordered heaviest first.
    public func workloadBalance(from start: Date, to end: Date) -> WorkloadBalance {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = max(firstDay, calendar.startOfDay(for: end))
        let occurrences = self.occurrences(
            in: firstDay...lastDay,
            completed: Set(settledCompletions.map(\.occurrenceKey))
        )

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

        /// Who the work actually belonged to that day: whoever took it on when
        /// somebody covered, and otherwise whoever the rota named.
        let assigneeID: Identifier<Member>?
    }

    /// Every occurrence of every active chore inside the range.
    ///
    /// One walk of the schedule per chore. Resolving the rota by asking for
    /// each day's position separately walks from the chore's start once per
    /// day, which on a week of daily chores is seven times the work for the
    /// same answer — and grows with the household's whole history rather than
    /// with the week being summarised.
    ///
    /// An occurrence somebody covered counts against the person who covered
    /// it. A fairness screen crediting the rota rather than the household is a
    /// fairness screen that is wrong about the exact weeks somebody carried
    /// more than their share, which are the only weeks anybody opens it.
    ///
    /// An occurrence nobody was here for is not counted as having been asked
    /// for at all. It leaves both numbers this feeds: a family that spent half
    /// a week in Spain is not a family that completed 40% of its chores, and a
    /// child who was at their grandmother's did not carry a lighter load than
    /// their sibling that week — they were not offered one.
    ///
    /// - Parameters:
    ///   - range: The window to expand.
    ///   - completed: The occurrences that were recorded as done. An away day
    ///     somebody did the work on anyway stays in, because it was work the
    ///     household got, and a fairness screen that dropped it would credit
    ///     nobody for it.
    /// - Returns: The occurrences the household was actually asked for.
    private func occurrences(
        in range: ClosedRange<Date>,
        completed: Set<ChoreCompletion.OccurrenceKey>
    ) -> [ScheduledOccurrence] {
        let covers = snapshot.coverRequests.acceptedCoversByOccurrence()
        return snapshot.activeChores.flatMap { chore -> [ScheduledOccurrence] in
            chore.indexedOccurrences(in: range, using: engine, maximum: Int.max)
                .compactMap { occurrence in
                    let key = ChoreCompletion.OccurrenceKey(
                        choreID: chore.id, day: occurrence.day
                    )
                    let rota = chore.assignee(forOccurrenceIndex: occurrence.index)
                    let assigneeID = covers[key]?.resolution.coveringMemberID ?? rota

                    if !completed.contains(key), wasAway(assigneeID, on: occurrence.day) {
                        return nil
                    }
                    return ScheduledOccurrence(
                        chore: chore,
                        day: occurrence.day,
                        assigneeID: assigneeID
                    )
                }
        }
    }

    /// Whether the person a piece of work fell to was away that day.
    ///
    /// Passed `nil` — a chore open to anybody — only an empty house counts, on
    /// the same terms the agenda and the streak calculator apply: "whoever gets
    /// there first" has somebody to be right up until there is nobody left.
    private func wasAway(_ memberID: Identifier<Member>?, on day: Date) -> Bool {
        guard !awayPeriods.isEmpty else { return false }
        return awayPeriods.contains { period in
            guard period.covers(day, calendar: calendar) else { return false }
            guard let memberID else { return period.isWholeHousehold }
            return period.covers(memberID)
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
                streak: streaks.streak(forMember: member.id, asOf: range.upperBound),
                rewardsOwed: snapshot.redemptions.count {
                    $0.memberID == member.id && $0.wasOutstanding(at: periodRange.upperBound)
                }
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
