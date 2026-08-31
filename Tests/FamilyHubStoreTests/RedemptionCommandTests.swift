import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

/// Covers the commands a household runs around a reward: spending points on
/// one, confirming it happened, and calling it off when it cannot.
@Suite("Redemption commands")
struct RedemptionCommandTests {

    // MARK: Fixture

    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    private struct Fixture {
        let store: InMemoryHouseholdStore
        let commands: HouseholdCommands
        let household: Household
        let mary: Member
        let alex: Member
        let sam: Member
        /// 25 points, unlimited.
        let movieNight: Reward
        /// 20 points, one left in stock.
        let cinemaTicket: Reward
    }

    private func makeFixture(startingPoints: Int = 60) async throws -> Fixture {
        let household = try Household(
            name: "The Aldays", tier: .plus, timeZone: .gmt, createdAt: clock.now
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .owner, joinedAt: clock.now
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen, joinedAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: clock.now
        )
        let movieNight = try Reward(
            householdID: household.id, name: "Movie night pick", cost: 25, createdAt: clock.now
        )
        let cinemaTicket = try Reward(
            householdID: household.id, name: "Cinema ticket", cost: 20,
            remainingRedemptions: 1, createdAt: clock.now
        )
        let store = InMemoryHouseholdStore(
            seed: HouseholdSnapshot(
                household: household,
                members: [mary, alex, sam],
                ledgerEntries: [
                    LedgerEntry.adjustment(
                        householdID: household.id, memberID: sam.id, amount: startingPoints,
                        by: mary.id, at: clock.advanced(byDays: -1).now
                    )
                ],
                rewards: [movieNight, cinemaTicket]
            )
        )
        return Fixture(
            store: store,
            commands: HouseholdCommands(store: store, dateProvider: clock),
            household: household,
            mary: mary,
            alex: alex,
            sam: sam,
            movieNight: movieNight,
            cinemaTicket: cinemaTicket
        )
    }

    // MARK: Redeeming

    @Test("Redeeming leaves a promise the household can see it owes")
    func redeemingRecordsWhatIsOwed() async throws {
        let f = try await makeFixture()

        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id, note: "Can we watch it Friday?"
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(redemption.cost == 25)
        #expect(redemption.isOwed)
        #expect(redemption.note?.value == "Can we watch it Friday?")
        #expect(snapshot.ledger.balance(for: f.sam.id) == 35)
        #expect(snapshot.owedRedemptions.map(\.id) == [redemption.id])
        #expect(snapshot.owedPoints(to: f.sam.id) == 25)
    }

    @Test("The promise records what the reward cost on the day, not later")
    func costIsSnapshotted() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id
        )

        try await f.store.save(try f.movieNight.costing(60))
        let snapshot = try await f.store.snapshot(of: f.household.id)

        #expect(snapshot.redemption(redemption.id)?.cost == 25)
        #expect(snapshot.reward(f.movieNight.id)?.cost == 60)
    }

    @Test("Redeeming still debits the points and consumes the stock")
    func redeemingStillMovesPointsAndStock() async throws {
        let f = try await makeFixture()

        try await f.commands.redeemReward(
            f.cinemaTicket.id, in: f.household.id, by: f.sam.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.ledger.balance(for: f.sam.id) == 40)
        #expect(snapshot.reward(f.cinemaTicket.id)?.remainingRedemptions == 0)
        #expect(snapshot.ledgerEntries.contains { $0.source == .rewardRedeemed(f.cinemaTicket.id) })
    }

    @Test("A reward nobody can afford is refused before anything is recorded")
    func refusedRedemptionRecordsNothing() async throws {
        let f = try await makeFixture(startingPoints: 8)

        await #expect(throws: DomainError.insufficientPoints(balance: 8, required: 25)) {
            try await f.commands.redeemReward(
                f.movieNight.id, in: f.household.id, by: f.sam.id
            )
        }

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(snapshot.redemptions.isEmpty)
        #expect(snapshot.ledger.balance(for: f.sam.id) == 8)
    }

    // MARK: Handing over

    @Test("A parent confirming the film closes the promise")
    func handingOverSettlesTheQueue() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id
        )

        let given = try await f.commands.handOverReward(
            redemption.id, in: f.household.id, by: f.mary.id
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(given.state == .given(by: f.mary.id, at: clock.now))
        #expect(snapshot.owedRedemptions.isEmpty)
        #expect(snapshot.owedPoints(to: f.sam.id) == 0)
        // Handing over is not a second transaction: nothing moves.
        #expect(snapshot.ledger.balance(for: f.sam.id) == 35)
    }

    @Test("A child cannot confirm their own reward happened")
    func childCannotHandOver() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id
        )

        await #expect(throws: DomainError.notPermitted(action: .handOverReward, role: .child)) {
            try await f.commands.handOverReward(
                redemption.id, in: f.household.id, by: f.sam.id
            )
        }
        #expect(try await f.store.snapshot(of: f.household.id).owedRedemptions.count == 1)
    }

    @Test("The second parent to confirm the same reward is told")
    func handingOverTwiceIsRefused() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id
        )
        try await f.commands.handOverReward(redemption.id, in: f.household.id, by: f.mary.id)

        await #expect(throws: DomainError.redemptionAlreadySettled) {
            try await f.commands.handOverReward(
                redemption.id, in: f.household.id, by: f.mary.id
            )
        }
    }

    @Test("A promise another device deleted names itself rather than crashing")
    func handingOverAMissingRedemption() async throws {
        let f = try await makeFixture()

        await #expect(throws: DomainError.self) {
            try await f.commands.handOverReward(
                Identifier<Redemption>(), in: f.household.id, by: f.mary.id
            )
        }
    }

    // MARK: Cancelling

    @Test("Cancelling gives the points back and puts the stock back")
    func cancellingRefundsAndRestocks() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.cinemaTicket.id, in: f.household.id, by: f.sam.id
        )

        let cancelled = try await f.commands.cancelRedemption(
            redemption.id, in: f.household.id, by: f.mary.id, reason: "Cinema was closed"
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        #expect(cancelled.state == .cancelled(by: f.mary.id, at: clock.now))
        #expect(snapshot.ledger.balance(for: f.sam.id) == 60)
        #expect(snapshot.reward(f.cinemaTicket.id)?.remainingRedemptions == 1)
        #expect(snapshot.owedRedemptions.isEmpty)
    }

    @Test("The refund says why, and leaves the spend in the history")
    func refundExplainsItself() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id
        )
        try await f.commands.cancelRedemption(
            redemption.id, in: f.household.id, by: f.mary.id, reason: "Cinema was closed"
        )

        let snapshot = try await f.store.snapshot(of: f.household.id)
        let history = snapshot.ledger.history(for: f.sam.id)
        // Looked up rather than taken from the front of the list: the clock is
        // frozen, so the spend and the refund share a timestamp and the history
        // orders them by identifier.
        let refund = history.first { $0.source == .rewardRefunded(f.movieNight.id) }

        #expect(refund?.note == "Cinema was closed")
        #expect(refund?.amount == 25)
        #expect(history.contains { $0.source == .rewardRedeemed(f.movieNight.id) })
    }

    @Test("A child may put back a reward they redeemed by mistake")
    func childMayCancelTheirOwn() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id
        )

        try await f.commands.cancelRedemption(
            redemption.id, in: f.household.id, by: f.sam.id
        )

        #expect(try await f.store.snapshot(of: f.household.id).ledger.balance(for: f.sam.id) == 60)
    }

    @Test("A sibling cannot cancel somebody else's reward")
    func siblingCannotCancel() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id
        )

        await #expect(throws: DomainError.notPermitted(action: .cancelRedemption, role: .teen)) {
            try await f.commands.cancelRedemption(
                redemption.id, in: f.household.id, by: f.alex.id
            )
        }
        #expect(try await f.store.snapshot(of: f.household.id).ledger.balance(for: f.sam.id) == 35)
    }

    @Test("A reward already handed over cannot be refunded")
    func cannotCancelOnceGiven() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id
        )
        try await f.commands.handOverReward(redemption.id, in: f.household.id, by: f.mary.id)

        await #expect(throws: DomainError.redemptionAlreadySettled) {
            try await f.commands.cancelRedemption(
                redemption.id, in: f.household.id, by: f.mary.id
            )
        }
        #expect(try await f.store.snapshot(of: f.household.id).ledger.balance(for: f.sam.id) == 35)
    }

    @Test("Cancelling twice cannot pay a child twice")
    func cancellingTwiceIsRefused() async throws {
        let f = try await makeFixture()
        let redemption = try await f.commands.redeemReward(
            f.movieNight.id, in: f.household.id, by: f.sam.id
        )
        try await f.commands.cancelRedemption(redemption.id, in: f.household.id, by: f.mary.id)

        await #expect(throws: DomainError.redemptionAlreadySettled) {
            try await f.commands.cancelRedemption(
                redemption.id, in: f.household.id, by: f.mary.id
            )
        }
        #expect(try await f.store.snapshot(of: f.household.id).ledger.balance(for: f.sam.id) == 60)
    }

    // MARK: Cooldown

    @Test("A cancelled redemption does not hold the reward's cooldown open")
    func cancellingClearsTheCooldown() async throws {
        let f = try await makeFixture()
        let weekly = try Reward(
            householdID: f.household.id, name: "Skip a chore", cost: 10,
            cooldownDays: 7, createdAt: clock.now
        )
        try await f.store.save(weekly)
        let first = try await f.commands.redeemReward(
            weekly.id, in: f.household.id, by: f.sam.id
        )

        // Redeeming again immediately is refused while the first one stands.
        await #expect(throws: DomainError.self) {
            try await f.commands.redeemReward(weekly.id, in: f.household.id, by: f.sam.id)
        }

        try await f.commands.cancelRedemption(first.id, in: f.household.id, by: f.sam.id)
        let second = try await f.commands.redeemReward(
            weekly.id, in: f.household.id, by: f.sam.id
        )

        #expect(second.isOwed)
        #expect(try await f.store.snapshot(of: f.household.id).ledger.balance(for: f.sam.id) == 50)
    }

    @Test("A redemption somebody kept still holds the cooldown open")
    func keptRedemptionHoldsTheCooldown() async throws {
        let f = try await makeFixture()
        let weekly = try Reward(
            householdID: f.household.id, name: "Skip a chore", cost: 10,
            cooldownDays: 7, createdAt: clock.now
        )
        try await f.store.save(weekly)
        let first = try await f.commands.redeemReward(
            weekly.id, in: f.household.id, by: f.sam.id
        )
        try await f.commands.handOverReward(first.id, in: f.household.id, by: f.mary.id)

        await #expect(throws: DomainError.self) {
            try await f.commands.redeemReward(weekly.id, in: f.household.id, by: f.sam.id)
        }
    }
}
