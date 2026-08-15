import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Points ledger")
struct PointsLedgerTests {

    private let calendar = Calendar.testDefault
    private let householdID = Identifier<Household>()
    private let alex = Identifier<Member>()
    private let sam = Identifier<Member>()
    private let parent = Identifier<Member>()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        FixedDateProvider(year: y, month: m, day: d, hour: hour, calendar: calendar).now
    }

    private func entry(
        _ amount: Int,
        for memberID: Identifier<Member>? = nil,
        on day: Int = 2,
        source: LedgerEntry.Source? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            householdID: householdID,
            memberID: memberID ?? alex,
            amount: amount,
            source: source ?? .adjustment(by: parent),
            occurredAt: date(2026, 3, day)
        )
    }

    private func makeReward(
        cost: Int = 50,
        cooldownDays: Int? = nil,
        remaining: Int? = nil,
        isActive: Bool = true
    ) throws -> Reward {
        try Reward(
            householdID: householdID,
            name: "Movie night pick",
            cost: cost,
            remainingRedemptions: remaining,
            cooldownDays: cooldownDays,
            isActive: isActive,
            createdAt: date(2026, 1, 1)
        )
    }

    // MARK: Balances

    @Test("Balance sums signed entries")
    func balanceSumsEntries() {
        let ledger = PointsLedger(entries: [entry(10), entry(25), entry(-15)])
        #expect(ledger.balance(for: alex) == 20)
    }

    @Test("An empty ledger reports zero, not nil")
    func emptyLedgerIsZero() {
        #expect(PointsLedger(entries: []).balance(for: alex) == 0)
    }

    @Test("Balances are computed per member")
    func balancesArePerMember() {
        let ledger = PointsLedger(entries: [
            entry(10, for: alex),
            entry(30, for: sam),
            entry(-5, for: alex),
        ])
        #expect(ledger.balance(for: alex) == 5)
        #expect(ledger.balance(for: sam) == 30)
        #expect(ledger.balances() == [alex: 5, sam: 30])
    }

    @Test("A balance can go negative if an adult takes points away")
    func balanceCanGoNegative() {
        // Not a state the app offers a button for, but a parent removing points
        // for something serious should not be silently clamped to zero — the
        // history would then disagree with the balance.
        let ledger = PointsLedger(entries: [entry(10), entry(-40)])
        #expect(ledger.balance(for: alex) == -30)
    }

    @Test("A historical balance ignores later entries")
    func historicalBalance() {
        let ledger = PointsLedger(entries: [
            entry(10, on: 2),
            entry(20, on: 5),
            entry(40, on: 9),
        ])
        #expect(ledger.balance(for: alex, asOf: date(2026, 3, 5), calendar: calendar) == 30)
    }

    @Test("A historical balance includes everything on the day itself")
    func historicalBalanceIncludesWholeDay() {
        // The cutoff is the end of the day, not the moment asked about, so
        // 'what did I have on Sunday' does not depend on the time of the tap.
        let ledger = PointsLedger(entries: [
            LedgerEntry(
                householdID: householdID,
                memberID: alex,
                amount: 10,
                source: .adjustment(by: parent),
                occurredAt: date(2026, 3, 5, hour: 23)
            )
        ])
        let asOf = date(2026, 3, 5, hour: 1)
        #expect(ledger.balance(for: alex, asOf: asOf, calendar: calendar) == 10)
    }

    // MARK: Earned versus spent

    @Test("Earned and spent are tracked separately from the balance")
    func earnedAndSpent() {
        let ledger = PointsLedger(entries: [entry(30), entry(20), entry(-45)])
        #expect(ledger.totalEarned(by: alex) == 50)
        #expect(ledger.totalSpent(by: alex) == 45)
        #expect(ledger.balance(for: alex) == 5)
    }

    @Test("Standings rank on points earned, not on the balance")
    func standingsRankOnEarned() throws {
        // Ranking on the balance rewards hoarding and punishes a child for
        // spending what they earned — which makes the reward system a reason
        // not to use the reward system.
        let spender = try Member(
            id: alex, householdID: householdID, name: "Alex",
            role: .child, joinedAt: date(2026, 1, 1)
        )
        let hoarder = try Member(
            id: sam, householdID: householdID, name: "Sam",
            role: .child, joinedAt: date(2026, 1, 1)
        )
        let ledger = PointsLedger(entries: [
            entry(100, for: alex),
            entry(-90, for: alex),
            entry(60, for: sam),
        ])

        let standings = ledger.standings(among: [spender, hoarder])
        #expect(standings.map(\.member.id) == [alex, sam])
        #expect(standings[0].pointsEarned == 100)
        #expect(standings[0].balance == 10)
        #expect(standings[0].rank == 1)
        #expect(standings[1].rank == 2)
    }

    @Test("A member with no entries still appears on the board")
    func newMemberAppearsOnBoard() throws {
        // A child who has not started yet needs to see themselves there, or the
        // board reads as something they are excluded from.
        let newcomer = try Member(
            id: sam, householdID: householdID, name: "Sam",
            role: .child, joinedAt: date(2026, 3, 1)
        )
        let ledger = PointsLedger(entries: [])
        let standings = ledger.standings(among: [newcomer])
        #expect(standings.count == 1)
        #expect(standings[0].pointsEarned == 0)
    }

    @Test("Removed members are left off the board")
    func removedMembersAreExcluded() throws {
        let active = try Member(
            id: alex, householdID: householdID, name: "Alex",
            role: .child, joinedAt: date(2026, 1, 1)
        )
        let departed = try Member(
            id: sam, householdID: householdID, name: "Sam",
            role: .child, joinedAt: date(2026, 1, 1)
        ).removed(at: date(2026, 2, 1))

        let standings = PointsLedger(entries: []).standings(among: [active, departed])
        #expect(standings.map(\.member.id) == [alex])
    }

    @Test("A tie on the board resolves in a stable order")
    func tiedStandingsAreStable() throws {
        let a = try Member(
            id: alex, householdID: householdID, name: "Alex",
            role: .child, joinedAt: date(2026, 1, 1)
        )
        let b = try Member(
            id: sam, householdID: householdID, name: "Sam",
            role: .child, joinedAt: date(2026, 1, 1)
        )
        let ledger = PointsLedger(entries: [])
        #expect(
            ledger.standings(among: [a, b]).map(\.member.id)
                == ledger.standings(among: [b, a]).map(\.member.id)
        )
    }

    // MARK: History

    @Test("History is newest first and can be limited")
    func historyIsNewestFirst() {
        let ledger = PointsLedger(entries: [
            entry(10, on: 2), entry(20, on: 5), entry(30, on: 9),
        ])
        #expect(ledger.history(for: alex).map(\.amount) == [30, 20, 10])
        #expect(ledger.history(for: alex, limit: 2).map(\.amount) == [30, 20])
    }

    @Test("Entries at the same instant keep a stable order")
    func simultaneousEntriesAreOrdered() {
        // Ticking off four chores in one go writes four entries at the same
        // timestamp; without the identifier tiebreak the history list would
        // reshuffle on every read.
        let same = date(2026, 3, 2)
        let entries = (0..<4).map { _ in
            LedgerEntry(
                householdID: householdID, memberID: alex, amount: 5,
                source: .adjustment(by: parent), occurredAt: same
            )
        }
        let forward = PointsLedger(entries: entries).entries.map(\.id)
        let backward = PointsLedger(entries: entries.reversed()).entries.map(\.id)
        #expect(forward == backward)
    }

    @Test("Earned in a range excludes entries outside it")
    func earnedInRange() {
        let ledger = PointsLedger(entries: [
            entry(10, on: 1), entry(20, on: 5), entry(40, on: 20),
        ])
        let week = date(2026, 3, 2, hour: 0)...date(2026, 3, 8, hour: 23)
        #expect(ledger.earned(by: alex, in: week) == 20)
    }

    // MARK: Redemption

    @Test("Redeeming with enough points is allowed")
    func redemptionWithEnoughPoints() throws {
        let reward = try makeReward(cost: 50)
        let ledger = PointsLedger(entries: [entry(60)])
        try ledger.authorizeRedemption(
            of: reward, by: alex, on: date(2026, 3, 10), calendar: calendar
        )
    }

    @Test("An unaffordable reward reports the shortfall, not just a refusal")
    func shortfallIsReported() throws {
        let reward = try makeReward(cost: 50)
        let ledger = PointsLedger(entries: [entry(38)])
        #expect(throws: DomainError.insufficientPoints(balance: 38, required: 50)) {
            try ledger.authorizeRedemption(
                of: reward, by: alex, on: date(2026, 3, 10), calendar: calendar
            )
        }
    }

    @Test("A cooldown blocks a second redemption of the same reward")
    func cooldownBlocksRepeat() throws {
        // Stops a child banking points all month then redeeming 'skip a chore'
        // seven days running.
        let reward = try makeReward(cost: 10, cooldownDays: 7)
        let ledger = PointsLedger(entries: [
            entry(100, on: 1),
            LedgerEntry(
                householdID: householdID, memberID: alex, amount: -10,
                source: .rewardRedeemed(reward.id), occurredAt: date(2026, 3, 8)
            ),
        ])

        #expect(throws: (any Error).self) {
            try ledger.authorizeRedemption(
                of: reward, by: alex, on: date(2026, 3, 10), calendar: calendar
            )
        }
        // Past the cooldown it is available again.
        try ledger.authorizeRedemption(
            of: reward, by: alex, on: date(2026, 3, 16), calendar: calendar
        )
    }

    @Test("One member's cooldown does not block another's redemption")
    func cooldownIsPerMember() throws {
        let reward = try makeReward(cost: 10, cooldownDays: 7)
        let ledger = PointsLedger(entries: [
            entry(100, for: sam, on: 1),
            LedgerEntry(
                householdID: householdID, memberID: alex, amount: -10,
                source: .rewardRedeemed(reward.id), occurredAt: date(2026, 3, 8)
            ),
        ])
        try ledger.authorizeRedemption(
            of: reward, by: sam, on: date(2026, 3, 9), calendar: calendar
        )
    }

    @Test("A sold-out reward is refused even with points to spare")
    func soldOutIsRefused() throws {
        let reward = try makeReward(cost: 10, remaining: 0)
        let ledger = PointsLedger(entries: [entry(500)])
        #expect(throws: DomainError.rewardUnavailable(reason: "there are none left")) {
            try ledger.authorizeRedemption(
                of: reward, by: alex, on: date(2026, 3, 10), calendar: calendar
            )
        }
    }

    @Test("A withdrawn reward is refused")
    func withdrawnIsRefused() throws {
        let reward = try makeReward(cost: 10, isActive: false)
        let ledger = PointsLedger(entries: [entry(500)])
        #expect(throws: DomainError.rewardUnavailable(reason: "it's been switched off")) {
            try ledger.authorizeRedemption(
                of: reward, by: alex, on: date(2026, 3, 10), calendar: calendar
            )
        }
    }

    // MARK: Entry construction

    @Test("Spending on a reward always debits, never credits")
    func spendingAlwaysDebits() throws {
        // The sign is applied inside the constructor so a call site cannot
        // accidentally hand out points by redeeming something.
        let reward = try makeReward(cost: 50)
        let spend = LedgerEntry.spent(on: reward, by: alex, at: date(2026, 3, 10))
        #expect(spend.amount == -50)
        #expect(!spend.isCredit)
        #expect(spend.note == "Movie night pick")
    }

    @Test("Earning mirrors the completion's snapshotted points")
    func earningMirrorsCompletion() {
        let completion = ChoreCompletion(
            householdID: householdID,
            choreID: Identifier(),
            occurrenceDay: date(2026, 3, 2),
            completedBy: alex,
            completedAt: date(2026, 3, 2),
            pointsAwarded: 15,
            calendar: calendar
        )
        let earned = LedgerEntry.earned(completion)
        #expect(earned.amount == 15)
        #expect(earned.memberID == alex)
        #expect(earned.source == .choreCompleted(completion.id))
    }

    @Test("Signed description uses a true minus sign")
    func signedDescriptionUsesMinusSign() {
        // A hyphen sits at the wrong optical weight in the tabular figures the
        // history column uses, and misaligns the whole column.
        #expect(entry(10).signedDescription == "+10")
        #expect(entry(-10).signedDescription == "−10")
    }

    @Test("A blank note is stored as nil")
    func blankNoteIsDropped() {
        let entry = LedgerEntry(
            householdID: householdID, memberID: alex, amount: 5,
            source: .bonus(by: parent), occurredAt: date(2026, 3, 2), note: "   "
        )
        #expect(entry.note == nil)
    }
}
