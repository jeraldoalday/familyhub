import Foundation
import Testing

@testable import FamilyHubCore

/// Covers how a household reads its redemptions back: the queue of what it
/// still owes, what one member is waiting for, and whether a reward can be
/// redeemed again yet.
@Suite("Redemptions on the snapshot")
struct RedemptionSnapshotTests {

    // MARK: Fixture

    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 9)

    private struct Fixture {
        var snapshot: HouseholdSnapshot
        let mary: Member
        let sam: Member
        let alex: Member
        let movieNight: Reward
        let screenTime: Reward
    }

    private func makeFixture(cooldownDays: Int? = nil) throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            timeZone: .gmt,
            createdAt: clock.advanced(byDays: -30).now
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .adult,
            avatar: Avatar(color: .purple), joinedAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child,
            avatar: Avatar(color: .amber), joinedAt: clock.now
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen,
            avatar: Avatar(color: .teal), joinedAt: clock.now
        )
        let movieNight = try Reward(
            householdID: household.id, name: "Movie night pick", cost: 25,
            cooldownDays: cooldownDays, createdAt: clock.now
        )
        let screenTime = try Reward(
            householdID: household.id, name: "30 minutes of screen time", cost: 10,
            createdAt: clock.now
        )

        return Fixture(
            snapshot: HouseholdSnapshot(
                household: household,
                members: [mary, sam, alex],
                ledgerEntries: [
                    LedgerEntry.adjustment(
                        householdID: household.id, memberID: sam.id, amount: 60,
                        by: mary.id, at: clock.advanced(byDays: -20).now
                    )
                ],
                rewards: [movieNight, screenTime]
            ),
            mary: mary,
            sam: sam,
            alex: alex,
            movieNight: movieNight,
            screenTime: screenTime
        )
    }

    private func redemption(
        in fixture: Fixture,
        reward: Reward? = nil,
        by member: Member? = nil,
        cost: Int? = nil,
        daysAgo: Int = 0,
        state: Redemption.State = .owed
    ) throws -> Redemption {
        let reward = reward ?? fixture.movieNight
        return try Redemption(
            householdID: fixture.snapshot.household.id,
            rewardID: reward.id,
            memberID: (member ?? fixture.sam).id,
            cost: cost ?? reward.cost,
            redeemedAt: clock.advanced(byDays: -daysAgo).now,
            state: state
        )
    }

    // MARK: Lookups

    @Test("A redemption can be found, and a missing one names itself")
    func findsARedemption() throws {
        var fixture = try makeFixture()
        let owed = try redemption(in: fixture)
        fixture.snapshot.redemptions = [owed]

        #expect(fixture.snapshot.redemption(owed.id) == owed)
        #expect(try fixture.snapshot.requireRedemption(owed.id) == owed)
        #expect(fixture.snapshot.redemption(Identifier<Redemption>()) == nil)
        #expect(throws: DomainError.self) {
            try fixture.snapshot.requireRedemption(Identifier<Redemption>())
        }
    }

    // MARK: The queue

    @Test("The queue holds what is still owed, oldest promise first")
    func queueIsOldestFirst() throws {
        var fixture = try makeFixture()
        let old = try redemption(in: fixture, daysAgo: 9)
        let recent = try redemption(in: fixture, reward: fixture.screenTime, daysAgo: 1)
        let given = try redemption(in: fixture, daysAgo: 20)
            .given(by: fixture.mary.id, at: clock.now)
        let cancelled = try redemption(in: fixture, daysAgo: 15)
            .cancelled(by: fixture.sam.id, at: clock.now)
        fixture.snapshot.redemptions = [recent, given, old, cancelled]

        #expect(fixture.snapshot.owedRedemptions.map(\.id) == [old.id, recent.id])
    }

    @Test("Only promises left waiting a while are worth chasing")
    func overdueIsTheOlderHalfOfTheQueue() throws {
        var fixture = try makeFixture()
        let ancient = try redemption(in: fixture, daysAgo: 12)
        let today = try redemption(in: fixture, reward: fixture.screenTime, daysAgo: 0)
        fixture.snapshot.redemptions = [today, ancient]

        let chase = fixture.snapshot.overdueRedemptions(on: clock.now)

        #expect(chase.map(\.id) == [ancient.id])
    }

    @Test("A member's history is theirs alone, newest first")
    func historyIsPerMember() throws {
        var fixture = try makeFixture()
        let samsOld = try redemption(in: fixture, daysAgo: 10)
        let samsNew = try redemption(in: fixture, reward: fixture.screenTime, daysAgo: 2)
        let alexs = try redemption(in: fixture, by: fixture.alex, daysAgo: 1)
        fixture.snapshot.redemptions = [samsOld, alexs, samsNew]

        #expect(
            fixture.snapshot.redemptions(by: fixture.sam.id).map(\.id)
                == [samsNew.id, samsOld.id])
        #expect(fixture.snapshot.redemptions(by: fixture.alex.id).map(\.id) == [alexs.id])
        #expect(fixture.snapshot.redemptions(by: fixture.mary.id).isEmpty)
    }

    @Test("What a member is owed is counted apart from what they have left")
    func owedPointsAreSeparateFromTheBalance() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [
            try redemption(in: fixture, cost: 25),
            try redemption(in: fixture, reward: fixture.screenTime, cost: 10),
            try redemption(in: fixture, cost: 25, daysAgo: 5)
                .given(by: fixture.mary.id, at: clock.now),
            try redemption(in: fixture, by: fixture.alex, cost: 25),
        ]

        #expect(fixture.snapshot.owedPoints(to: fixture.sam.id) == 35)
        #expect(fixture.snapshot.owedPoints(to: fixture.alex.id) == 25)
        #expect(fixture.snapshot.owedPoints(to: fixture.mary.id) == 0)
    }

    // MARK: Availability

    @Test("A reward a member can afford is available")
    func affordableIsAvailable() throws {
        let fixture = try makeFixture()

        #expect(
            fixture.snapshot.availability(
                of: fixture.movieNight, for: fixture.sam.id, on: clock.now
            ) == .available)
    }

    @Test("A reward beyond a balance says how far beyond, rather than no")
    func shortfallIsNamed() throws {
        var fixture = try makeFixture()
        let dear = try Reward(
            householdID: fixture.snapshot.household.id,
            name: "Day out", cost: 100, createdAt: clock.now
        )
        fixture.snapshot.rewards.append(dear)

        #expect(
            fixture.snapshot.availability(of: dear, for: fixture.sam.id, on: clock.now)
                == .tooExpensive(shortBy: 40))
    }

    @Test("A cooldown counts a redemption somebody kept")
    func cooldownHoldsAfterAKeptRedemption() throws {
        var fixture = try makeFixture(cooldownDays: 7)
        fixture.snapshot.redemptions = [try redemption(in: fixture, daysAgo: 1)]

        let availability = fixture.snapshot.availability(
            of: fixture.movieNight, for: fixture.sam.id, on: clock.now
        )

        #expect(availability != .available)
        if case .cooling(let until) = availability {
            #expect(until > clock.now)
        } else {
            Issue.record("Expected the reward to be cooling, got \(availability)")
        }
    }

    @Test("A cooldown ignores a redemption that was called off and refunded")
    func cooldownIgnoresACancelledRedemption() throws {
        var fixture = try makeFixture(cooldownDays: 7)
        fixture.snapshot.redemptions = [
            try redemption(in: fixture, daysAgo: 1)
                .cancelled(by: fixture.sam.id, at: clock.now)
        ]

        #expect(
            fixture.snapshot.availability(
                of: fixture.movieNight, for: fixture.sam.id, on: clock.now
            ) == .available)
    }

    @Test("Another child's redemption does not cool this one's reward")
    func cooldownIsPerMember() throws {
        var fixture = try makeFixture(cooldownDays: 7)
        fixture.snapshot.redemptions = [
            try redemption(in: fixture, by: fixture.alex, daysAgo: 1)
        ]

        #expect(
            fixture.snapshot.availability(
                of: fixture.movieNight, for: fixture.sam.id, on: clock.now
            ) == .available)
    }

    // MARK: Decoding

    @Test("A backup written before redemptions existed still restores")
    func decodesWithoutRedemptions() throws {
        let fixture = try makeFixture()
        var json =
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(fixture.snapshot)
            ) as? [String: Any] ?? [:]
        json.removeValue(forKey: "redemptions")

        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(HouseholdSnapshot.self, from: data)

        #expect(decoded.redemptions.isEmpty)
        #expect(decoded.members.count == 3)
    }

    @Test("A household's redemptions survive a round trip")
    func roundTripsThroughJSON() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [
            try redemption(in: fixture),
            try redemption(in: fixture, daysAgo: 4).given(by: fixture.mary.id, at: clock.now),
        ]

        let data = try JSONEncoder().encode(fixture.snapshot)
        let decoded = try JSONDecoder().decode(HouseholdSnapshot.self, from: data)

        #expect(decoded.redemptions.count == 2)
        #expect(decoded.owedRedemptions.count == 1)
        #expect(decoded.redemptions == fixture.snapshot.redemptions)
    }
}
