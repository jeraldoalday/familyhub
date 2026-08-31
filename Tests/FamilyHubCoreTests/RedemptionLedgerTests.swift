import Foundation
import Testing

@testable import FamilyHubCore

/// Covers what happens to the ledger when a redemption is called off: the
/// points come back as an entry rather than as an erasure, and the reward's
/// cooldown stops counting a promise nobody ever received.
@Suite("Refunding a redemption")
struct RedemptionLedgerTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 9)

    private let householdID = Identifier<Household>()
    private let sam = Identifier<Member>()
    private let mary = Identifier<Member>()

    private func makeReward(cost: Int = 25, cooldownDays: Int? = nil) throws -> Reward {
        try Reward(
            householdID: householdID,
            name: "Movie night pick",
            cost: cost,
            cooldownDays: cooldownDays,
            createdAt: clock.now
        )
    }

    private func makeRedemption(
        of reward: Reward,
        cost: Int? = nil,
        redeemedAt: Date? = nil
    ) throws -> Redemption {
        try Redemption(
            householdID: householdID,
            rewardID: reward.id,
            memberID: sam,
            cost: cost ?? reward.cost,
            redeemedAt: redeemedAt ?? clock.now
        )
    }

    /// The pair of entries a redemption and its cancellation produce.
    private func entries(
        redeeming reward: Reward,
        on redeemedAt: Date,
        refundedOn refundedAt: Date? = nil,
        redemptionCost: Int? = nil
    ) throws -> [LedgerEntry] {
        let redemption = try makeRedemption(
            of: reward, cost: redemptionCost, redeemedAt: redeemedAt
        )
        var entries = [LedgerEntry.spent(on: reward, by: sam, at: redeemedAt)]
        if let refundedAt {
            entries.append(.refunded(redemption, at: refundedAt))
        }
        return entries
    }

    // MARK: The refunding entry

    @Test("A refund gives back exactly what the redemption took")
    func refundMatchesTheRecordedCost() throws {
        let reward = try makeReward(cost: 25)
        // The parent has since re-priced the reward, which must not change what
        // last month's redemption is worth giving back.
        let repriced = try reward.costing(60)
        let redemption = try makeRedemption(of: reward, cost: 25)

        let refund = LedgerEntry.refunded(redemption, at: clock.now)

        #expect(refund.amount == 25)
        #expect(refund.memberID == sam)
        #expect(refund.source == .rewardRefunded(reward.id))
        #expect(repriced.cost == 60)
    }

    @Test("A refund is stamped when it happened, not when the points went")
    func refundIsStampedAtTheCancellation() throws {
        let reward = try makeReward()
        let lastWeek = clock.advanced(byDays: -7).now
        let redemption = try makeRedemption(of: reward, redeemedAt: lastWeek)

        let refund = LedgerEntry.refunded(redemption, at: clock.now, note: "Cinema was closed")

        #expect(refund.occurredAt == clock.now)
        #expect(refund.note == "Cinema was closed")
    }

    @Test("A refunded redemption leaves the spend in the history, not a gap")
    func historyKeepsBothSides() throws {
        let reward = try makeReward(cost: 25)
        let ledger = PointsLedger(
            entries: [
                LedgerEntry.adjustment(
                    householdID: householdID, memberID: sam, amount: 40,
                    by: mary, at: clock.advanced(byDays: -2).now
                )
            ]
                + (try entries(
                    redeeming: reward,
                    on: clock.advanced(byDays: -1).now,
                    refundedOn: clock.now
                ))
        )

        #expect(ledger.balance(for: sam) == 40)
        #expect(ledger.history(for: sam).count == 3)
        #expect(ledger.history(for: sam).first?.source == .rewardRefunded(reward.id))
        #expect(ledger.totalSpent(by: sam) == 25)
    }

    @Test("A refund is not an adult's hand-entered number")
    func refundIsNotManual() throws {
        #expect(!LedgerEntry.Source.rewardRefunded(Identifier<Reward>()).wasManual)
        #expect(LedgerEntry.Source.rewardRefunded(Identifier<Reward>()).label == "Refund")
        #expect(!LedgerEntry.Source.rewardRefunded(Identifier<Reward>()).symbolName.isEmpty)
    }

    @Test("A refund source survives a trip through JSON")
    func refundSourceRoundTrips() throws {
        let reward = try makeReward()
        let original = LedgerEntry.refunded(try makeRedemption(of: reward), at: clock.now)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LedgerEntry.self, from: data)

        #expect(decoded.source == .rewardRefunded(reward.id))
        #expect(decoded.amount == 25)
    }

    // MARK: Cooldown

    @Test("A redemption that stuck still holds the cooldown open")
    func cooldownCountsAKeptRedemption() throws {
        let reward = try makeReward(cooldownDays: 7)
        let yesterday = clock.advanced(byDays: -1).now
        let ledger = PointsLedger(
            entries: [
                LedgerEntry.adjustment(
                    householdID: householdID, memberID: sam, amount: 100,
                    by: mary, at: clock.advanced(byDays: -9).now
                )
            ] + (try entries(redeeming: reward, on: yesterday))
        )

        #expect(ledger.lastRedemption(of: reward, by: sam) == yesterday)
        #expect(throws: DomainError.self) {
            try ledger.authorizeRedemption(
                of: reward, by: sam, on: clock.now, calendar: calendar
            )
        }
    }

    @Test("A redemption that was refunded does not lock the reward for a week")
    func cooldownIgnoresARefundedRedemption() throws {
        let reward = try makeReward(cooldownDays: 7)
        let ledger = PointsLedger(
            entries: [
                LedgerEntry.adjustment(
                    householdID: householdID, memberID: sam, amount: 100,
                    by: mary, at: clock.advanced(byDays: -9).now
                )
            ]
                + (try entries(
                    redeeming: reward,
                    on: clock.advanced(byDays: -1).now,
                    refundedOn: clock.now
                ))
        )

        #expect(ledger.lastRedemption(of: reward, by: sam) == nil)
        try ledger.authorizeRedemption(of: reward, by: sam, on: clock.now, calendar: calendar)
    }

    @Test("A refund cancels one redemption, not every redemption before it")
    func refundsPairOffOneForOne() throws {
        let reward = try makeReward(cooldownDays: 7)
        let fortnightAgo = clock.advanced(byDays: -14).now
        let ledger = PointsLedger(
            entries: (try entries(redeeming: reward, on: fortnightAgo))
                + (try entries(
                    redeeming: reward,
                    on: clock.advanced(byDays: -1).now,
                    refundedOn: clock.now
                ))
        )

        // The fortnight-old redemption is still the one that counts: the refund
        // belongs to yesterday's, and cancels only that.
        #expect(ledger.lastRedemption(of: reward, by: sam) == fortnightAgo)
    }

    @Test("Somebody else's refund is not netted off this member's cooldown")
    func refundsAreScopedToTheMember() throws {
        let reward = try makeReward(cooldownDays: 7)
        let yesterday = clock.advanced(byDays: -1).now
        let sisterRedemption = try Redemption(
            householdID: householdID,
            rewardID: reward.id,
            memberID: mary,
            cost: reward.cost,
            redeemedAt: yesterday
        )
        let ledger = PointsLedger(
            entries: (try entries(redeeming: reward, on: yesterday))
                + [LedgerEntry.refunded(sisterRedemption, at: clock.now)]
        )

        #expect(ledger.lastRedemption(of: reward, by: sam) == yesterday)
        #expect(ledger.lastRedemption(of: reward, by: mary) == nil)
    }

    @Test("A caller holding the records is judged on the records, not the ledger")
    func recordsBeatTheLedger() throws {
        let reward = try makeReward(cooldownDays: 7)
        let yesterday = clock.advanced(byDays: -1).now
        let ledger = PointsLedger(
            entries: [
                LedgerEntry.adjustment(
                    householdID: householdID, memberID: sam, amount: 100,
                    by: mary, at: clock.advanced(byDays: -9).now
                )
            ] + (try entries(redeeming: reward, on: yesterday))
        )
        // The ledger alone would hold the cooldown open, because nothing in it
        // says the film was called off. The record does say so.
        let cancelled = try makeRedemption(of: reward, redeemedAt: yesterday)
            .cancelled(by: mary, at: clock.now)

        #expect(ledger.lastRedemption(of: reward, by: sam) == yesterday)
        try ledger.authorizeRedemption(
            of: reward,
            by: sam,
            on: clock.now,
            calendar: calendar,
            redemptions: [cancelled]
        )
    }

    @Test("Records that say the reward was kept still hold the cooldown")
    func recordsCanRefuseToo() throws {
        let reward = try makeReward(cooldownDays: 7)
        let yesterday = clock.advanced(byDays: -1).now
        let ledger = PointsLedger(
            entries: [
                LedgerEntry.adjustment(
                    householdID: householdID, memberID: sam, amount: 100,
                    by: mary, at: clock.advanced(byDays: -9).now
                )
            ] + (try entries(redeeming: reward, on: yesterday))
        )
        let kept = try makeRedemption(of: reward, redeemedAt: yesterday)

        #expect(throws: DomainError.self) {
            try ledger.authorizeRedemption(
                of: reward,
                by: sam,
                on: clock.now,
                calendar: calendar,
                redemptions: [kept]
            )
        }
    }
}
