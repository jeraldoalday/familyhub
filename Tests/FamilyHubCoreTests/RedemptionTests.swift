import Foundation
import Testing

@testable import FamilyHubCore

/// Covers the record a household keeps when somebody spends points on a reward:
/// what it remembers, how it settles, and how the queue of promises reads back.
@Suite("Redemptions")
struct RedemptionTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 9)

    private let householdID = Identifier<Household>()
    private let movieNight = Identifier<Reward>()
    private let screenTime = Identifier<Reward>()
    private let sam = Identifier<Member>()
    private let alex = Identifier<Member>()
    private let mary = Identifier<Member>()

    private func makeRedemption(
        reward: Identifier<Reward>? = nil,
        member: Identifier<Member>? = nil,
        cost: Int = 25,
        redeemedAt: Date? = nil,
        note: String? = nil,
        state: Redemption.State = .owed
    ) throws -> Redemption {
        try Redemption(
            householdID: householdID,
            rewardID: reward ?? movieNight,
            memberID: member ?? sam,
            cost: cost,
            redeemedAt: redeemedAt ?? clock.now,
            note: note,
            state: state
        )
    }

    // MARK: Construction

    @Test("A redemption remembers what it cost at the moment it was made")
    func remembersCost() throws {
        let redemption = try makeRedemption(cost: 25)

        #expect(redemption.cost == 25)
        #expect(redemption.isOwed)
        #expect(redemption.state == .owed)
    }

    @Test("A negative cost is flattened rather than refused")
    func negativeCostIsClamped() throws {
        #expect(try makeRedemption(cost: -10).cost == 0)
    }

    @Test("A blank note is no note rather than an error")
    func blankNoteBecomesNil() throws {
        #expect(try makeRedemption(note: "  \n ").note == nil)
        #expect(try makeRedemption(note: nil).note == nil)
        #expect(
            try makeRedemption(note: " Can we watch it Friday? ").note?.value
                == "Can we watch it Friday?")
    }

    @Test("A note longer than a notes field is refused")
    func longNoteIsRefused() {
        #expect(throws: DomainError.tooLong(field: .redemptionNote, limit: Limits.notesLength)) {
            try makeRedemption(note: String(repeating: "a", count: Limits.notesLength + 1))
        }
    }

    @Test("A note can be changed afterwards, or removed")
    func noteCanBeReplaced() throws {
        let redemption = try makeRedemption(note: "Friday?")

        #expect(try redemption.withNote("Saturday instead").note?.value == "Saturday instead")
        #expect(try redemption.withNote(nil).note == nil)
    }

    // MARK: Settling

    @Test("Handing a reward over records who did it and when")
    func givenRecordsWho() throws {
        let evening = clock.advanced(byDays: 3).now
        let given = try makeRedemption().given(by: mary, at: evening)

        #expect(given.state == .given(by: mary, at: evening))
        #expect(given.state.isGiven)
        #expect(given.state.givenBy == mary)
        #expect(given.state.settledAt == evening)
        #expect(!given.isOwed)
        #expect(!given.wasRefunded)
    }

    @Test("Cancelling records who called it off, because who matters to a child")
    func cancelledRecordsWho() throws {
        let byThemselves = try makeRedemption().cancelled(by: sam, at: clock.now)
        let byAParent = try makeRedemption().cancelled(by: mary, at: clock.now)

        #expect(byThemselves.state == .cancelled(by: sam, at: clock.now))
        #expect(byAParent.state == .cancelled(by: mary, at: clock.now))
        #expect(byThemselves.wasRefunded)
        #expect(byAParent.state.isCancelled)
    }

    @Test("The second parent to tick off the same movie night is told")
    func cannotGiveTwice() throws {
        let given = try makeRedemption().given(by: mary, at: clock.now)

        #expect(throws: DomainError.redemptionAlreadySettled) {
            try given.given(by: alex, at: clock.advanced(byDays: 1).now)
        }
    }

    @Test("A reward that has happened cannot be refunded")
    func cannotCancelOnceGiven() throws {
        let given = try makeRedemption().given(by: mary, at: clock.now)

        #expect(throws: DomainError.redemptionAlreadySettled) {
            try given.cancelled(by: sam, at: clock.advanced(byDays: 1).now)
        }
    }

    @Test("A cancelled redemption cannot be handed over afterwards")
    func cannotGiveOnceCancelled() throws {
        let cancelled = try makeRedemption().cancelled(by: sam, at: clock.now)

        #expect(throws: DomainError.redemptionAlreadySettled) {
            try cancelled.given(by: mary, at: clock.advanced(byDays: 1).now)
        }
    }

    @Test("Every state has a label a row can show")
    func statesHaveLabels() throws {
        #expect(Redemption.State.owed.label == "Waiting to be given")
        #expect(Redemption.State.given(by: mary, at: clock.now).label == "Given")
        #expect(Redemption.State.cancelled(by: sam, at: clock.now).label == "Cancelled")
        #expect(Redemption.State.owed.settledAt == nil)
    }

    // MARK: Age

    @Test("The days a promise has been waiting are counted in whole days")
    func countsDaysOwed() throws {
        let redemption = try makeRedemption()
        let laterThatDay = clock.advanced(by: 60 * 60 * 8).now
        let threeDaysOn = clock.advanced(byDays: 3).now

        #expect(redemption.daysOwed(on: clock.now, calendar: calendar) == 0)
        #expect(redemption.daysOwed(on: laterThatDay, calendar: calendar) == 0)
        #expect(redemption.daysOwed(on: threeDaysOn, calendar: calendar) == 3)
    }

    @Test("A clock that has gone backwards does not report a negative age")
    func neverNegative() throws {
        let redemption = try makeRedemption()
        let yesterday = clock.advanced(byDays: -1).now

        #expect(redemption.daysOwed(on: yesterday, calendar: calendar) == 0)
    }

    @Test("A promise made this morning is not overdue by this evening")
    func notOverdueOnTheSameDay() throws {
        let redemption = try makeRedemption()
        let thisEvening = clock.advanced(by: 60 * 60 * 10).now

        #expect(!redemption.isOverdue(on: thisEvening, calendar: calendar))
        #expect(!redemption.isOverdue(on: clock.advanced(byDays: 1).now, calendar: calendar))
        #expect(redemption.isOverdue(on: clock.advanced(byDays: 2).now, calendar: calendar))
    }

    @Test("A reward already handed over is never overdue, however long it took")
    func settledIsNeverOverdue() throws {
        let given = try makeRedemption().given(by: mary, at: clock.advanced(byDays: 9).now)
        let cancelled = try makeRedemption().cancelled(by: mary, at: clock.now)
        let muchLater = clock.advanced(byDays: 30).now

        #expect(!given.isOverdue(on: muchLater, calendar: calendar))
        #expect(!cancelled.isOverdue(on: muchLater, calendar: calendar))
    }

    // MARK: Collections

    @Test("The queue puts the oldest promise first, not the newest")
    func queueIsOldestFirst() throws {
        let old = try makeRedemption(redeemedAt: clock.advanced(byDays: -20).now)
        let recent = try makeRedemption(redeemedAt: clock.advanced(byDays: -1).now)
        let settled = try makeRedemption(redeemedAt: clock.advanced(byDays: -30).now)
            .given(by: mary, at: clock.now)

        let queue = [recent, settled, old].owed

        #expect(queue.map(\.id) == [old.id, recent.id])
    }

    @Test("A member's own history reads newest first")
    func historyIsNewestFirst() throws {
        let old = try makeRedemption(redeemedAt: clock.advanced(byDays: -20).now)
        let recent = try makeRedemption(redeemedAt: clock.advanced(byDays: -1).now)
        let somebodyElse = try makeRedemption(member: alex)

        let history = [old, somebodyElse, recent].redeemed(by: sam)

        #expect(history.map(\.id) == [recent.id, old.id])
    }

    @Test("Redemptions can be read back per reward")
    func filtersByReward() throws {
        let film = try makeRedemption(reward: movieNight)
        let screen = try makeRedemption(reward: screenTime)

        #expect([film, screen].of(movieNight).map(\.id) == [film.id])
        #expect([film, screen].of(screenTime).map(\.id) == [screen.id])
    }

    @Test("A cooldown counts the last redemption somebody kept, not one refunded")
    func lastKeptSkipsRefunds() throws {
        let kept = try makeRedemption(redeemedAt: clock.advanced(byDays: -6).now)
        let changedTheirMind = try makeRedemption(redeemedAt: clock.advanced(byDays: -1).now)
            .cancelled(by: sam, at: clock.now)
        let somebodyElse = try makeRedemption(member: alex, redeemedAt: clock.now)

        let all = [kept, changedTheirMind, somebodyElse]

        #expect(all.lastKeptRedemption(of: movieNight, by: sam) == kept.redeemedAt)
        #expect(all.lastKeptRedemption(of: movieNight, by: alex) == somebodyElse.redeemedAt)
        #expect(all.lastKeptRedemption(of: screenTime, by: sam) == nil)
    }

    @Test("Overdue promises are the ones worth chasing, oldest first")
    func overdueFiltersTheQueue() throws {
        let ancient = try makeRedemption(redeemedAt: clock.advanced(byDays: -20).now)
        let stale = try makeRedemption(redeemedAt: clock.advanced(byDays: -3).now)
        let today = try makeRedemption()

        let chase = [today, stale, ancient].overdue(on: clock.now, calendar: calendar)

        #expect(chase.map(\.id) == [ancient.id, stale.id])
    }

    @Test("What the household owes is totalled per member in one pass")
    func totalsOwedPerMember() throws {
        let samsFilm = try makeRedemption(cost: 25)
        let samsScreenTime = try makeRedemption(reward: screenTime, cost: 10)
        let alexsFilm = try makeRedemption(member: alex, cost: 25)
        let alreadyGiven = try makeRedemption(cost: 100).given(by: mary, at: clock.now)

        let owed = [samsFilm, samsScreenTime, alexsFilm, alreadyGiven].owedPointsByMember()

        #expect(owed[sam] == 35)
        #expect(owed[alex] == 25)
        #expect(owed[mary] == nil)
    }

    // MARK: Round-tripping

    @Test("A redemption survives a trip through JSON in every state")
    func roundTripsThroughJSON() throws {
        let states: [Redemption.State] = [
            .owed,
            .given(by: mary, at: clock.now),
            .cancelled(by: sam, at: clock.now),
        ]

        for state in states {
            let original = try makeRedemption(note: "Friday?", state: state)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(Redemption.self, from: data)

            #expect(decoded == original)
            #expect(decoded.state == state)
            #expect(decoded.note?.value == "Friday?")
        }
    }
}
