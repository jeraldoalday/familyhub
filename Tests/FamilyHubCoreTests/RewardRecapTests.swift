import Foundation
import Testing

@testable import FamilyHubCore

/// Covers the half of the reward economy a household could otherwise never
/// see: promises kept during a period, and promises still outstanding when it
/// ended.
@Suite("Rewards in the recap")
struct RewardRecapTests {

    // MARK: Fixture

    /// 8 March 2026, a Sunday — the last day of a week starting on Monday.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 8, hour: 20, calendar: .testDefault
    )

    private struct Fixture {
        var snapshot: HouseholdSnapshot
        let mary: Member
        let sam: Member
        let alex: Member
        let movieNight: Reward
    }

    private func makeFixture() throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            firstWeekday: 2,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: clock.advanced(byDays: -60).now
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .adult, joinedAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: clock.now
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .child, joinedAt: clock.now
        )
        let movieNight = try Reward(
            householdID: household.id, name: "Movie night pick", cost: 25, createdAt: clock.now
        )
        return Fixture(
            snapshot: HouseholdSnapshot(
                household: household, members: [mary, sam, alex], rewards: [movieNight]
            ),
            mary: mary,
            sam: sam,
            alex: alex,
            movieNight: movieNight
        )
    }

    private func day(_ offset: Int) -> Date {
        clock.advanced(byDays: offset).now
    }

    private func redemption(
        in fixture: Fixture,
        by member: Member? = nil,
        redeemedDaysAgo: Int,
        state: Redemption.State = .owed
    ) throws -> Redemption {
        try Redemption(
            householdID: fixture.snapshot.household.id,
            rewardID: fixture.movieNight.id,
            memberID: (member ?? fixture.sam).id,
            cost: fixture.movieNight.cost,
            redeemedAt: day(-redeemedDaysAgo),
            state: state
        )
    }

    private func recap(_ fixture: Fixture) -> HouseholdInsights.Recap {
        HouseholdInsights(snapshot: fixture.snapshot)
            .weeklyRecap(forWeekContaining: clock.now)
    }

    // MARK: What was kept

    @Test("A week with nothing to give reports nothing and no debt")
    func quietWeek() throws {
        let summary = recap(try makeFixture())

        #expect(summary.rewardsGiven == 0)
        #expect(summary.rewardsOwed == 0)
        #expect(summary.keptEveryPromise)
    }

    @Test("Rewards handed over during the week are counted")
    func countsPromisesKept() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [
            try redemption(
                in: fixture, redeemedDaysAgo: 10, state: .given(by: fixture.mary.id, at: day(-3))),
            try redemption(
                in: fixture, by: fixture.alex, redeemedDaysAgo: 4,
                state: .given(by: fixture.mary.id, at: day(-1))
            ),
        ]

        let summary = recap(fixture)

        #expect(summary.rewardsGiven == 2)
        #expect(summary.rewardsOwed == 0)
        #expect(summary.keptEveryPromise)
    }

    @Test("A reward handed over before the week began belongs to that week, not this one")
    func earlierHandOversAreNotCounted() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [
            try redemption(
                in: fixture, redeemedDaysAgo: 30, state: .given(by: fixture.mary.id, at: day(-20))
            )
        ]

        #expect(recap(fixture).rewardsGiven == 0)
    }

    @Test("A cancelled redemption is not a promise kept")
    func cancellationsAreNotHandOvers() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [
            try redemption(
                in: fixture, redeemedDaysAgo: 4,
                state: .cancelled(by: fixture.mary.id, at: day(-2))
            )
        ]

        let summary = recap(fixture)

        #expect(summary.rewardsGiven == 0)
        #expect(summary.rewardsOwed == 0)
    }

    // MARK: What is still owed

    @Test("A promise from before the week still counts against the week it ran through")
    func olderDebtsStillCount() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [try redemption(in: fixture, redeemedDaysAgo: 30)]

        let summary = recap(fixture)

        #expect(summary.rewardsOwed == 1)
        #expect(!summary.keptEveryPromise)
    }

    @Test("The recap reads the period as it stood, not as things stand now")
    func settlingLaterDoesNotRewriteHistory() throws {
        var fixture = try makeFixture()
        // Outstanding all week, and settled the following Tuesday. Last week
        // was still a week the household owed something.
        fixture.snapshot.redemptions = [
            try redemption(
                in: fixture, redeemedDaysAgo: 20,
                state: .given(by: fixture.mary.id, at: day(2))
            )
        ]

        let summary = recap(fixture)

        #expect(summary.rewardsOwed == 1)
        #expect(summary.rewardsGiven == 0)
    }

    @Test("A member's own row names what they are still waiting for")
    func perMemberDebts() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [
            try redemption(in: fixture, redeemedDaysAgo: 3),
            try redemption(in: fixture, redeemedDaysAgo: 2),
            try redemption(
                in: fixture, by: fixture.alex, redeemedDaysAgo: 5,
                state: .given(by: fixture.mary.id, at: day(-4))
            ),
        ]

        let summary = recap(fixture)
        let samsRow = summary.members.first { $0.member.id == fixture.sam.id }
        let alexsRow = summary.members.first { $0.member.id == fixture.alex.id }

        #expect(samsRow?.rewardsOwed == 2)
        #expect(alexsRow?.rewardsOwed == 0)
        #expect(summary.rewardsOwed == 2)
    }

    @Test("A refund does not read as a week's earnings")
    func refundsDoNotInflateTheRecap() throws {
        var fixture = try makeFixture()
        let called = try redemption(
            in: fixture, redeemedDaysAgo: 4, state: .cancelled(by: fixture.mary.id, at: day(-3))
        )
        fixture.snapshot.redemptions = [called]
        fixture.snapshot.ledgerEntries = [
            LedgerEntry.spent(on: fixture.movieNight, by: fixture.sam.id, at: day(-4)),
            LedgerEntry.refunded(called, at: day(-3)),
        ]

        let summary = recap(fixture)

        #expect(summary.pointsEarned == 0)
        #expect(summary.members.first { $0.member.id == fixture.sam.id }?.pointsEarned == 0)
    }
}
