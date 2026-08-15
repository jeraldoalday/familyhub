import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Chore completions")
struct ChoreCompletionTests {

    private let calendar = Calendar.testDefault
    private let householdID = Identifier<Household>()
    private let choreID = Identifier<Chore>()
    private let alex = Identifier<Member>()
    private let parent = Identifier<Member>()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        FixedDateProvider(year: y, month: m, day: d, hour: hour, calendar: calendar).now
    }

    private func makeCompletion(
        id: Identifier<ChoreCompletion> = Identifier(),
        chore: Identifier<Chore>? = nil,
        occurrence: Date? = nil,
        completedAt: Date? = nil,
        approval: ChoreCompletion.Approval = .notRequired,
        points: Int = 10
    ) -> ChoreCompletion {
        ChoreCompletion(
            id: id,
            householdID: householdID,
            choreID: chore ?? choreID,
            occurrenceDay: occurrence ?? date(2026, 3, 2),
            completedBy: alex,
            completedAt: completedAt ?? date(2026, 3, 2, hour: 18),
            approval: approval,
            pointsAwarded: points,
            calendar: calendar
        )
    }

    // MARK: Normalisation

    @Test("The occurrence day is normalised to the start of day")
    func normalisesOccurrenceDay() {
        // Two devices recording the same occurrence at different times must
        // produce the same key, or the duplicate check never fires.
        let evening = makeCompletion(occurrence: date(2026, 3, 2, hour: 21))
        let morning = makeCompletion(occurrence: date(2026, 3, 2, hour: 7))
        #expect(evening.occurrenceKey == morning.occurrenceKey)
    }

    @Test("Negative points are floored at zero")
    func pointsCannotBeNegative() {
        #expect(makeCompletion(points: -50).pointsAwarded == 0)
    }

    // MARK: Point snapshotting

    @Test("Points are snapshotted at completion time")
    func pointsAreSnapshotted() {
        // A parent raising a chore from 10 to 20 points must not retroactively
        // inflate every balance in the household's history.
        let completion = makeCompletion(points: 10)
        #expect(completion.pointsAwarded == 10)
    }

    // MARK: Approval

    @Test("Pending points do not count toward a balance")
    func pendingDoesNotCount() {
        // Showing points that could still be taken away teaches a child the
        // number is negotiable, which defeats the mechanic.
        #expect(!ChoreCompletion.Approval.pending.countsTowardBalance)
        #expect(ChoreCompletion.Approval.notRequired.countsTowardBalance)
        #expect(
            ChoreCompletion.Approval
                .approved(by: Identifier<Member>(), at: Date())
                .countsTowardBalance
        )
        #expect(
            !ChoreCompletion.Approval
                .rejected(by: Identifier<Member>(), at: Date(), reason: nil)
                .countsTowardBalance
        )
    }

    @Test("Approving banks the points")
    func approvingBanksPoints() {
        let pending = makeCompletion(approval: .pending)
        #expect(!pending.approval.countsTowardBalance)

        let approved = pending.approved(by: parent, at: date(2026, 3, 3))
        #expect(approved.approval.countsTowardBalance)
        #expect(approved.pointsAwarded == pending.pointsAwarded)
    }

    @Test("A blank rejection reason becomes nil")
    func blankRejectionReasonIsDropped() {
        let rejected = makeCompletion(approval: .pending)
            .rejected(by: parent, at: date(2026, 3, 3), reason: "   ")
        guard case .rejected(_, _, let reason) = rejected.approval else {
            Issue.record("Expected a rejected approval")
            return
        }
        #expect(reason == nil)
    }

    @Test("The review queue is oldest first")
    func reviewQueueIsOldestFirst() {
        let later = makeCompletion(completedAt: date(2026, 3, 2, hour: 20), approval: .pending)
        let earlier = makeCompletion(completedAt: date(2026, 3, 2, hour: 8), approval: .pending)
        let settled = makeCompletion(approval: .notRequired)

        let queue = [later, settled, earlier].awaitingReview
        #expect(queue.count == 2)
        #expect(queue.first?.completedAt == earlier.completedAt)
    }

    // MARK: Lateness

    @Test("Completing on the due day is not late")
    func onTimeIsNotLate() {
        let completion = makeCompletion(
            occurrence: date(2026, 3, 2),
            completedAt: date(2026, 3, 2, hour: 23)
        )
        #expect(!completion.wasLate(calendar: calendar))
        #expect(completion.daysLate(calendar: calendar) == 0)
    }

    @Test("Completing after the due day counts whole days late")
    func lateIsCountedInDays() {
        let completion = makeCompletion(
            occurrence: date(2026, 3, 2),
            completedAt: date(2026, 3, 5, hour: 9)
        )
        #expect(completion.wasLate(calendar: calendar))
        #expect(completion.daysLate(calendar: calendar) == 3)
    }

    @Test("Completing early reports zero days late, not a negative")
    func earlyIsNotNegativelyLate() {
        let completion = makeCompletion(
            occurrence: date(2026, 3, 5),
            completedAt: date(2026, 3, 2, hour: 9)
        )
        #expect(completion.daysLate(calendar: calendar) == 0)
    }

    // MARK: Conflict resolution

    @Test("Duplicate completions of one occurrence collapse to the earliest")
    func duplicatesCollapseToEarliest() {
        // Two devices offline at once will both record the same chore. Neither
        // is wrong, so the earliest wall-clock completion wins rather than
        // whichever happened to sync first.
        let first = makeCompletion(completedAt: date(2026, 3, 2, hour: 8))
        let second = makeCompletion(completedAt: date(2026, 3, 2, hour: 19))

        let resolved = [second, first].deduplicatedByOccurrence()
        #expect(resolved.count == 1)
        #expect(resolved.first?.id == first.id)
    }

    @Test("An exact timestamp tie resolves the same way on every device")
    func timestampTieIsDeterministic() {
        // Without a tiebreaker, two devices would each keep their own record
        // and the households' balances would diverge permanently.
        let sameMoment = date(2026, 3, 2, hour: 12)
        let a = makeCompletion(id: Identifier(), completedAt: sameMoment)
        let b = makeCompletion(id: Identifier(), completedAt: sameMoment)

        let forward = [a, b].deduplicatedByOccurrence().map(\.id)
        let backward = [b, a].deduplicatedByOccurrence().map(\.id)
        #expect(forward == backward)
        #expect(forward == [min(a.id, b.id)])
    }

    @Test("Different occurrences of the same chore are both kept")
    func differentDaysAreNotDuplicates() {
        let monday = makeCompletion(occurrence: date(2026, 3, 2))
        let tuesday = makeCompletion(occurrence: date(2026, 3, 3))
        #expect([monday, tuesday].deduplicatedByOccurrence().count == 2)
    }

    @Test("The same day across different chores is not a duplicate")
    func differentChoresAreNotDuplicates() {
        let bins = makeCompletion(chore: Identifier<Chore>())
        let dishes = makeCompletion(chore: Identifier<Chore>())
        #expect([bins, dishes].deduplicatedByOccurrence().count == 2)
    }

    // MARK: Filtering

    @Test("Banked filters to completions that count")
    func bankedFilters() {
        let completions = [
            makeCompletion(approval: .notRequired),
            makeCompletion(occurrence: date(2026, 3, 3), approval: .pending),
            makeCompletion(
                occurrence: date(2026, 3, 4),
                approval: .approved(by: parent, at: date(2026, 3, 4))
            ),
        ]
        #expect(completions.banked.count == 2)
    }
}
