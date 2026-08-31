import Foundation
import Testing

@testable import FamilyHubCore

/// Covers the notification that tells an adult the household has taken a
/// child's points and not yet handed over what they bought.
@Suite("Owed reward reminders")
struct RewardReminderTests {

    // MARK: Fixture

    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 6)

    private struct Fixture {
        var snapshot: HouseholdSnapshot
        let mary: Member
        let jerald: Member
        let alex: Member
        let sam: Member
        let movieNight: Reward
        let screenTime: Reward
    }

    private func makeFixture(tier: Household.Tier = .plus) throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: tier,
            timeZone: .gmt,
            createdAt: clock.advanced(byDays: -60).now
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .adult, joinedAt: clock.now
        )
        let jerald = try Member(
            householdID: household.id, name: "Jerald", role: .owner, joinedAt: clock.now
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
        let screenTime = try Reward(
            householdID: household.id, name: "Extra screen time", cost: 10, createdAt: clock.now
        )

        return Fixture(
            snapshot: HouseholdSnapshot(
                household: household,
                members: [mary, jerald, alex, sam],
                rewards: [movieNight, screenTime]
            ),
            mary: mary,
            jerald: jerald,
            alex: alex,
            sam: sam,
            movieNight: movieNight,
            screenTime: screenTime
        )
    }

    private func redemption(
        in fixture: Fixture,
        reward: Reward? = nil,
        by member: Member? = nil,
        daysAgo: Int,
        state: Redemption.State = .owed
    ) throws -> Redemption {
        try Redemption(
            householdID: fixture.snapshot.household.id,
            rewardID: (reward ?? fixture.movieNight).id,
            memberID: (member ?? fixture.sam).id,
            cost: (reward ?? fixture.movieNight).cost,
            redeemedAt: clock.advanced(byDays: -daysAgo).now,
            state: state
        )
    }

    private func rewardReminders(
        in fixture: Fixture,
        schedule: ReminderSchedule = .standard
    ) -> [Reminder] {
        ReminderPlanner(snapshot: fixture.snapshot, schedule: schedule)
            .reminders(for: clock.today, now: clock.now)
            .filter {
                if case .rewardOwed = $0.kind { return true }
                return false
            }
    }

    // MARK: When it is sent

    @Test("Every adult is told about a promise the household has forgotten")
    func adultsAreTold() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [try redemption(in: fixture, daysAgo: 9)]

        let reminders = rewardReminders(in: fixture)

        #expect(
            Set(reminders.map(\.recipientID)) == Set([fixture.mary.id, fixture.jerald.id]))
        #expect(reminders.allSatisfy { $0.title == "Still owed" })
    }

    @Test("A teenager is not asked to settle the household's promises")
    func teensAndChildrenAreNotTold() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [try redemption(in: fixture, daysAgo: 9)]

        let recipients = Set(rewardReminders(in: fixture).map(\.recipientID))

        #expect(!recipients.contains(fixture.alex.id))
        #expect(!recipients.contains(fixture.sam.id))
    }

    @Test("A reward redeemed this morning is not a broken promise yet")
    func nothingIsSentTooSoon() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [
            try redemption(in: fixture, daysAgo: 0),
            try redemption(in: fixture, reward: fixture.screenTime, daysAgo: 1),
        ]

        #expect(rewardReminders(in: fixture).isEmpty)
    }

    @Test("A reward that was handed over is not chased")
    func settledPromisesAreNotChased() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [
            try redemption(in: fixture, daysAgo: 12)
                .given(by: fixture.mary.id, at: clock.advanced(byDays: -1).now),
            try redemption(in: fixture, reward: fixture.screenTime, daysAgo: 20)
                .cancelled(by: fixture.sam.id, at: clock.advanced(byDays: -19).now),
        ]

        #expect(rewardReminders(in: fixture).isEmpty)
    }

    @Test("A household with no rewards on its plan is never nagged about them")
    func silentOnTheFreeTier() throws {
        var fixture = try makeFixture(tier: .free)
        fixture.snapshot.redemptions = [try redemption(in: fixture, daysAgo: 9)]

        #expect(rewardReminders(in: fixture).isEmpty)
    }

    @Test("A household that would rather track its own promises can say so")
    func switchTurnsItOff() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [try redemption(in: fixture, daysAgo: 9)]
        let quiet = ReminderSchedule(sendsRewardReminders: false)

        #expect(rewardReminders(in: fixture, schedule: quiet).isEmpty)
        #expect(!rewardReminders(in: fixture).isEmpty)
    }

    // MARK: What it says

    @Test("The reminder names the child, the reward, and how long they waited")
    func bodyNamesEverythingNeeded() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [try redemption(in: fixture, daysAgo: 9)]

        let body = rewardReminders(in: fixture).first?.body

        #expect(body == "Sam has been waiting for 9 days for Movie night pick.")
    }

    @Test("One day's wait reads as a day rather than as a number")
    func bodyReadsWellAtOneDay() {
        #expect(
            ReminderPlanner.rewardOwedBody(
                child: "Sam", reward: "Movie night pick", days: 1, others: 0
            ) == "Sam has been waiting since yesterday for Movie night pick.")
    }

    @Test("Other promises are counted rather than sent as more notifications")
    func othersAreCountedInOneReminder() throws {
        var fixture = try makeFixture()
        fixture.snapshot.redemptions = [
            try redemption(in: fixture, daysAgo: 9),
            try redemption(in: fixture, reward: fixture.screenTime, daysAgo: 4),
            try redemption(in: fixture, by: fixture.alex, daysAgo: 3),
        ]

        let forMary = rewardReminders(in: fixture).filter { $0.recipientID == fixture.mary.id }

        #expect(forMary.count == 1)
        #expect(forMary.first?.body.hasSuffix("2 other rewards are owed too.") == true)
        #expect(
            forMary.first?.kind
                == .rewardOwed(
                    redemptionID: fixture.snapshot.redemptions[0].id, others: 2))
    }

    @Test("A single other promise is counted in the singular")
    func oneOtherReadsAsOne() {
        #expect(
            ReminderPlanner.rewardOwedBody(
                child: "Sam", reward: "Movie night pick", days: 4, others: 1
            ).hasSuffix("1 other reward is owed too."))
    }

    @Test("The oldest promise is the one named")
    func oldestPromiseIsNamed() throws {
        var fixture = try makeFixture()
        let recent = try redemption(in: fixture, daysAgo: 3)
        let oldest = try redemption(in: fixture, reward: fixture.screenTime, daysAgo: 30)
        fixture.snapshot.redemptions = [recent, oldest]

        let reminder = rewardReminders(in: fixture).first

        #expect(reminder?.kind == .rewardOwed(redemptionID: oldest.id, others: 1))
        #expect(reminder?.body.contains("Extra screen time") == true)
    }

    // MARK: The cap

    @Test("An owed reward outranks a birthday but yields to the approval queue")
    func sitsBetweenApprovalsAndBirthdays() {
        let owed = Reminder.Kind.rewardOwed(redemptionID: Identifier<Redemption>(), others: 0)

        #expect(owed.priority < Reminder.Kind.approvalsWaiting(count: 1).priority)
        #expect(owed.priority > Reminder.Kind.birthday(memberID: Identifier<Member>()).priority)
        #expect(owed.priority > Reminder.Kind.choresDue(count: 3).priority)
    }

    @Test("A schedule saved before this switch existed keeps sending them")
    func decodesFromAnOlderSchedule() throws {
        let json = Data(#"{"morningHour":7,"eveningHour":20}"#.utf8)

        let schedule = try JSONDecoder().decode(ReminderSchedule.self, from: json)

        #expect(schedule.sendsRewardReminders)
        #expect(schedule.morningHour == 7)
    }
}
