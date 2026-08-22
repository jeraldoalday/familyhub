import Foundation

/// An unbroken run of completed work.
///
/// Streaks are the one mechanic in this app that costs nothing to award and
/// changes behaviour anyway. Points buy things; a streak buys nothing, and
/// children protect them harder than they protect their balance. That is worth
/// modelling carefully rather than approximating, because a streak the app gets
/// wrong is worse than no streak at all — a child who did the work and watched
/// the number reset stops trusting every other number on the screen.
public struct Streak: Hashable, Sendable {
    /// How many consecutive occurrences, or days, are in the run.
    public let length: Int

    /// The most recent day counted toward the run, if there is one.
    public let lastDay: Date?

    /// Whether the run is still going as of the day it was measured.
    ///
    /// A finished streak — one that was broken at some point in the past — is
    /// reported with its length for the history screen, but must not be shown
    /// on the home screen as though it were still alive.
    public let isLive: Bool

    /// Creates a streak.
    public init(length: Int, lastDay: Date?, isLive: Bool) {
        self.length = max(0, length)
        self.lastDay = lastDay
        self.isLive = isLive && self.length > 0
    }

    /// The absence of a streak.
    public static let none = Streak(length: 0, lastDay: nil, isLive: false)

    /// Whether there is a run worth showing at all.
    ///
    /// Two is the floor rather than one, because "you have done this once" is
    /// not a streak and labelling it one devalues the word by the time it
    /// means something.
    public var isNoteworthy: Bool { length >= Streak.noteworthyLength }

    /// The shortest run the UI calls a streak.
    public static let noteworthyLength = 2
}

/// Derives streaks from a household's chores and completion records.
///
/// A value type built once and asked many times. The completion index is
/// assembled in the initialiser rather than per query, because the home screen
/// asks about every chore and every member at once — and a household with a
/// year of history has thousands of completions, which is the difference
/// between one pass and one pass per row.
///
/// Everything here is a pure function of the values handed in. There is no
/// clock: the day to measure from is always a parameter, so a streak shown on
/// screen, a streak in a notification, and a streak in a test are computed by
/// the same code with no hidden input.
public struct StreakCalculator: Sendable {

    /// The scheduling engine, carrying the household's calendar.
    public let engine: RecurrenceEngine

    /// The chores under consideration, active ones only — an archived chore
    /// has no future occurrences, so a streak on it can only ever be history.
    private let chores: [Chore]

    /// Every settled occurrence, keyed so that "was this day done" is a lookup
    /// rather than a scan.
    private let completed: Set<ChoreCompletion.OccurrenceKey>

    /// How far back any single query will walk before giving up.
    ///
    /// Half a year of daily chores. Long enough that no real household reaches
    /// it before the free tier's history retention does, and short enough that
    /// a query on a fortnightly chore cannot wander into the engine's own
    /// period ceiling looking for occurrences that were never recorded.
    public static let defaultLookbackDays = 180

    /// Creates a calculator over a household's chores and completions.
    ///
    /// - Parameters:
    ///   - chores: The household's chores. Archived ones are dropped.
    ///   - completions: Every completion record. Records an adult sent back
    ///     are dropped, and duplicates from two devices recording the same
    ///     occurrence collapse, so neither a rejected day nor a synced
    ///     duplicate can count toward a run.
    ///   - engine: The recurrence engine for this household.
    public init(
        chores: some Collection<Chore>,
        completions: some Collection<ChoreCompletion>,
        engine: RecurrenceEngine
    ) {
        self.engine = engine
        self.chores = chores.filter(\.isActive)
        // Filtered before deduplicating, not after. Deduplication keeps the
        // earliest record of an occurrence, so a day that was ticked off, sent
        // back, and done again would otherwise collapse onto the rejected
        // record and lose the run the second attempt earned.
        self.completed = Set(
            completions
                .filter(\.approval.countsAsDone)
                .deduplicatedByOccurrence()
                .map(\.occurrenceKey)
        )
    }

    // MARK: - Per chore

    /// The current run of completions for one chore, measured on `day`.
    ///
    /// Counting walks backwards from the chore's most recent occurrence on or
    /// before `day` and stops at the first one that was not done. An occurrence
    /// falling on `day` itself is treated as still in play rather than as a
    /// miss: a chore due this evening has not been failed at breakfast, and a
    /// home screen that says otherwise is simply lying for most of the day.
    ///
    /// - Parameters:
    ///   - chore: The chore to measure.
    ///   - day: The day to measure as of.
    ///   - lookbackDays: How far back to walk before stopping.
    /// - Returns: The run, or ``Streak/none`` if the most recent settled
    ///   occurrence was missed.
    public func streak(
        for chore: Chore,
        asOf day: Date,
        lookbackDays: Int = StreakCalculator.defaultLookbackDays
    ) -> Streak {
        let today = engine.calendar.startOfDay(for: day)
        let occurrences = pastOccurrences(of: chore, upTo: today, lookbackDays: lookbackDays)
        guard !occurrences.isEmpty else { return .none }

        var index = occurrences.count - 1
        // Today's occurrence, still undone, is neither a hit nor a miss.
        if occurrences[index] == today, !isDone(chore, on: today) {
            index -= 1
        }

        var length = 0
        var lastDay: Date?
        while index >= 0, isDone(chore, on: occurrences[index]) {
            if lastDay == nil { lastDay = occurrences[index] }
            length += 1
            index -= 1
        }

        return Streak(length: length, lastDay: lastDay, isLive: length > 0)
    }

    /// The longest run this chore has ever managed inside the lookback window.
    ///
    /// Shown beside the current streak so a broken run still has something to
    /// aim at. Without it, breaking a thirty-day streak erases thirty days of
    /// evidence that the household can do the thing.
    public func longestStreak(
        for chore: Chore,
        upTo day: Date,
        lookbackDays: Int = StreakCalculator.defaultLookbackDays
    ) -> Streak {
        let today = engine.calendar.startOfDay(for: day)
        let occurrences = pastOccurrences(of: chore, upTo: today, lookbackDays: lookbackDays)

        var best = 0
        var bestLastDay: Date?
        var run = 0
        for occurrence in occurrences {
            // The final occurrence, if it is today and still open, is not a
            // miss — but it is not yet a hit either, so it simply ends the walk.
            if occurrence == today, !isDone(chore, on: today) { break }
            guard isDone(chore, on: occurrence) else {
                run = 0
                continue
            }
            run += 1
            // Greater *or equal*, so that when a later run ties the record it
            // takes the record's last day with it. Strictly-greater leaves
            // `bestLastDay` on the older run while the live check below can
            // still say the record is going — a screen reading "best: 3 days,
            // last on 4 March" beside a run that counted this morning.
            if run >= best {
                best = run
                bestLastDay = occurrence
            }
        }

        let current = streak(for: chore, asOf: today, lookbackDays: lookbackDays)
        return Streak(length: best, lastDay: bestLastDay, isLive: current.length == best)
    }

    // MARK: - Per member

    /// A member's run of days on which they finished everything asked of them.
    ///
    /// Counted in days rather than in chores, and only days that actually asked
    /// something of them. A Sunday with nothing assigned neither extends the
    /// run nor breaks it — a child cannot be rewarded or punished for a day the
    /// household gave them no work, and a streak that resets over the school
    /// holidays teaches them the number is arbitrary.
    ///
    /// Only chores assigned to them specifically count. An open chore is
    /// everybody's and nobody's, so failing to claim one is not a personal
    /// miss.
    ///
    /// - Parameters:
    ///   - memberID: Whose run to measure.
    ///   - day: The day to measure as of. A day still in progress cannot break
    ///     the run.
    ///   - lookbackDays: How far back to walk.
    /// - Returns: The run of complete days, or ``Streak/none`` when the most
    ///   recent settled day left something undone.
    public func streak(
        forMember memberID: Identifier<Member>,
        asOf day: Date,
        lookbackDays: Int = StreakCalculator.defaultLookbackDays
    ) -> Streak {
        let today = engine.calendar.startOfDay(for: day)
        guard
            let earliest = engine.calendar.date(
                byAdding: .day, value: -max(0, lookbackDays), to: today
            )
        else { return .none }

        // Indexed once over the whole window rather than resolved per day. The
        // rota is counted from each chore's start date, so asking "is this mine
        // today" separately for each of a hundred and eighty days walks the
        // whole history a hundred and eighty times per chore.
        let assignments = self.assignments(to: memberID, from: earliest, to: today)
        var length = 0
        var lastDay: Date?

        for offset in 0...max(0, lookbackDays) {
            guard
                let cursor = engine.calendar.date(byAdding: .day, value: -offset, to: today)
            else { break }

            let assigned = assignments[cursor] ?? []
            // A day that asked nothing of them is skipped over entirely.
            guard !assigned.isEmpty else { continue }

            let allDone = assigned.allSatisfy { isDone($0, on: cursor) }
            if allDone {
                if lastDay == nil { lastDay = cursor }
                length += 1
                continue
            }
            // Today is still in play; any earlier miss ends the run.
            if cursor == today { continue }
            break
        }

        return Streak(length: length, lastDay: lastDay, isLive: length > 0)
    }

    // MARK: - What is about to break

    /// A streak that today's outstanding work is about to end.
    public struct AtRisk: Sendable, Identifiable {
        /// The chore whose run is in danger.
        public let chore: Chore

        /// The day the outstanding occurrence falls on.
        public let day: Date

        /// The run that will be lost.
        public let streak: Streak

        /// Who it belongs to, or `nil` when anyone may claim it.
        public let assigneeID: Identifier<Member>?

        public var id: ChoreCompletion.OccurrenceKey {
            ChoreCompletion.OccurrenceKey(choreID: chore.id, day: day)
        }
    }

    /// The chores due today whose streaks end tonight if nobody acts.
    ///
    /// This is the entire basis of the evening reminder. A notification that
    /// says "3 chores left" is ignorable; one that says "your 14-day streak on
    /// feeding the cat ends at midnight" is not, and the difference is knowing
    /// which streaks are actually at stake.
    ///
    /// - Parameters:
    ///   - day: The day in question, normally today.
    ///   - memberID: Limits the result to one person's chores plus the open
    ///     ones. Omit for the whole household.
    ///   - minimumLength: How long a run has to be before it is worth
    ///     interrupting someone about.
    /// - Returns: The chores at risk, longest run first.
    public func streaksAtRisk(
        on day: Date,
        for memberID: Identifier<Member>? = nil,
        minimumLength: Int = Streak.noteworthyLength
    ) -> [AtRisk] {
        let today = engine.calendar.startOfDay(for: day)

        return
            chores
            .compactMap { chore -> AtRisk? in
                // One walk answers both whether it falls today and whose turn
                // it is.
                guard
                    let occurrence =
                        chore
                        .indexedOccurrences(in: today...today, using: engine, maximum: 1)
                        .first
                else { return nil }
                guard !isDone(chore, on: today) else { return nil }

                let assigneeID = chore.assignee(forOccurrenceIndex: occurrence.index)
                if let memberID {
                    // An open chore is at risk for everyone, since anyone can
                    // save it.
                    guard assigneeID == nil || assigneeID == memberID else { return nil }
                }

                let run = streak(for: chore, asOf: today)
                guard run.length >= minimumLength else { return nil }

                return AtRisk(chore: chore, day: today, streak: run, assigneeID: assigneeID)
            }
            .sorted { lhs, rhs in
                if lhs.streak.length != rhs.streak.length {
                    return lhs.streak.length > rhs.streak.length
                }
                // Ties fall back to title then identifier, so the reminder text
                // does not name a different chore each time it is generated.
                let comparison = lhs.chore.title.value
                    .localizedCaseInsensitiveCompare(rhs.chore.title.value)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.chore.id < rhs.chore.id
            }
    }

    // MARK: - Internals

    /// Whether a given occurrence was recorded as done.
    private func isDone(_ chore: Chore, on day: Date) -> Bool {
        completed.contains(ChoreCompletion.OccurrenceKey(choreID: chore.id, day: day))
    }

    /// The chore's occurrences from `lookbackDays` before `day` up to and
    /// including it, ascending.
    private func pastOccurrences(
        of chore: Chore,
        upTo day: Date,
        lookbackDays: Int
    ) -> [Date] {
        guard
            let earliest = engine.calendar.date(
                byAdding: .day,
                value: -max(0, lookbackDays),
                to: day
            )
        else { return [] }
        return chore.occurrences(in: earliest...day, using: engine, maximum: lookbackDays + 1)
    }

    /// The chores assigned specifically to `memberID` on each day of a window.
    ///
    /// Built with one walk of each chore's schedule. Days the member was not
    /// named on are simply absent, which is what lets the streak treat them as
    /// neutral without a second lookup.
    private func assignments(
        to memberID: Identifier<Member>,
        from earliest: Date,
        to latest: Date
    ) -> [Date: [Chore]] {
        var byDay: [Date: [Chore]] = [:]
        for chore in chores where chore.assignment.isSpecific {
            let occurrences = chore.indexedOccurrences(
                in: earliest...latest,
                using: engine,
                maximum: Int.max
            )
            for occurrence in occurrences
            where chore.assignee(forOccurrenceIndex: occurrence.index) == memberID {
                byDay[occurrence.day, default: []].append(chore)
            }
        }
        return byDay
    }
}

// MARK: - Snapshot convenience

extension HouseholdSnapshot {
    /// A streak calculator over this household, ready to query.
    ///
    /// Built fresh each time it is read. That is deliberate: a snapshot is an
    /// immutable value, so a calculator cached on it could only ever be stale
    /// in the one case that matters — after a chore has just been ticked off.
    public var streaks: StreakCalculator {
        StreakCalculator(chores: chores, completions: completions, engine: engine)
    }
}
