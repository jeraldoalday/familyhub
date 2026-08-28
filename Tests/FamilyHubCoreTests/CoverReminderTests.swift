import Foundation
import Testing

@testable import FamilyHubCore

/// Covers the notification side of asking somebody to take a chore off you:
/// who hears about it, when, and what it says.
@Suite("Cover reminders")
struct CoverReminderTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday, at six in the morning — before the digest.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 6, calendar: .testDefault
    )

    private struct Fixture {
        var snapshot: HouseholdSnapshot
        let mary: Member
        let alex: Member
        let sam: Member
        let bins: Chore
    }

    private func makeFixture() throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            timeZone: .gmt,
            requiresApproval: false,
            createdAt: clock.now
        )
        let mary = try Member(
            householdID: household.id, name: "Mary", role: .adult, joinedAt: clock.now
        )
        let alex = try Member(
            householdID: household.id, name: "Alex", role: .teen, joinedAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child, joinedAt: clock.now
        )
        let bins = try Chore(
            householdID: household.id,
            title: "the bins",
            assignment: .member(sam.id),
            startDate: clock.day(offsetFromToday: -30),
            recurrence: .daily,
            createdBy: mary.id,
            createdAt: clock.now
        )
        return Fixture(
            snapshot: HouseholdSnapshot(
                household: household, members: [mary, alex, sam], chores: [bins]
            ),
            mary: mary,
            alex: alex,
            sam: sam,
            bins: bins
        )
    }

    private func request(
        _ f: Fixture,
        askedOf: Identifier<Member>? = nil,
        note: String? = nil,
        dayOffset: Int = 0,
        createdAt: Date? = nil
    ) throws -> CoverRequest {
        try CoverRequest(
            householdID: f.snapshot.household.id,
            choreID: f.bins.id,
            day: clock.day(offsetFromToday: dayOffset),
            requestedBy: f.sam.id,
            askedOf: askedOf,
            note: note,
            createdAt: createdAt ?? clock.now,
            calendar: calendar
        )
    }

    private func reminders(
        _ f: Fixture,
        schedule: ReminderSchedule = .standard,
        now: Date? = nil
    ) -> [Reminder] {
        ReminderPlanner(snapshot: f.snapshot, schedule: schedule)
            .reminders(for: clock.today, now: now ?? clock.now)
            .filter {
                if case .coverRequested = $0.kind { return true }
                return false
            }
    }

    // MARK: Who hears about it

    @Test("The person asked is told, and nobody else")
    func namedRequestReachesOnePerson() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f, askedOf: f.alex.id)]

        let planned = reminders(f)

        #expect(planned.map(\.recipientID) == [f.alex.id])
        #expect(planned.first?.title == "Can you cover?")
    }

    @Test("A request left open reaches everybody except the person asking")
    func openRequestReachesTheHousehold() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f)]

        let planned = reminders(f)

        #expect(Set(planned.map(\.recipientID)) == [f.mary.id, f.alex.id])
    }

    @Test("An answered request tells nobody anything")
    func answeredRequestIsSilent() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [
            try request(f).accepted(by: f.alex.id, at: clock.now)
        ]

        #expect(reminders(f).isEmpty)
    }

    @Test("A request for another day waits until that day")
    func futureRequestDoesNotInterruptToday() throws {
        // Interrupting somebody on Monday about Wednesday's bins asks them to
        // decide something there is no reason to decide yet.
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f, dayOffset: 2)]

        #expect(reminders(f).isEmpty)
    }

    @Test("A household that has switched cover asks off gets none")
    func scheduleCanSwitchThemOff() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f, askedOf: f.alex.id)]
        let quiet = ReminderSchedule(sendsCoverRequests: false)

        #expect(reminders(f, schedule: quiet).isEmpty)
    }

    // MARK: When

    @Test("An ask made overnight arrives with the morning digest")
    func firesAtTheMorningHour() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f, askedOf: f.alex.id)]
        let morning = calendar.date(
            bySettingHour: ReminderSchedule.standard.morningHour, minute: 0, second: 0,
            of: clock.today
        )

        #expect(reminders(f).first?.fireDate == morning)
    }

    @Test("An ask made after the digest still gets one interruption that evening")
    func fallsBackToTheEveningHour() throws {
        // Most requests are made on the morning of the day they are about, so
        // pinning them to the digest would mean most of them never arrived.
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f, askedOf: f.alex.id)]
        let midMorning = calendar.date(
            bySettingHour: 10, minute: 0, second: 0, of: clock.today
        )
        let evening = calendar.date(
            bySettingHour: ReminderSchedule.standard.eveningHour, minute: 0, second: 0,
            of: clock.today
        )

        let planned = reminders(f, now: try #require(midMorning))

        #expect(planned.first?.fireDate == evening)
    }

    @Test("An ask made after the evening hour is not shouted about at midnight")
    func lateAskIsSilent() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f, askedOf: f.alex.id)]
        let lateEvening = calendar.date(
            bySettingHour: 22, minute: 0, second: 0, of: clock.today
        )

        #expect(reminders(f, now: try #require(lateEvening)).isEmpty)
    }

    // MARK: What it says

    @Test("The reminder names who needs cover and what for")
    func bodyNamesTheAskAndTheChore() throws {
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f, askedOf: f.alex.id)]

        #expect(reminders(f).first?.body == "Sam needs cover for the bins today.")
    }

    @Test("A reason travels with the ask")
    func bodyCarriesTheReason() throws {
        // A bare "can you cover?" has to be opened before it can be answered,
        // which is most of the work the notification was meant to save.
        var f = try makeFixture()
        f.snapshot.coverRequests = [
            try request(f, askedOf: f.alex.id, note: "At football until seven")
        ]

        #expect(
            reminders(f).first?.body
                == "Sam needs cover for the bins today — At football until seven."
        )
    }

    @Test("Several asks become one reminder naming the oldest")
    func severalAsksBecomeOneReminder() throws {
        // Three notifications get none of them answered, and the per-person cap
        // would throw two away in any case.
        var f = try makeFixture()
        let hoover = try Chore(
            householdID: f.snapshot.household.id,
            title: "the hoovering",
            assignment: .member(f.sam.id),
            startDate: clock.day(offsetFromToday: -30),
            recurrence: .daily,
            createdBy: f.mary.id,
            createdAt: clock.now
        )
        f.snapshot.chores.append(hoover)
        let first = try request(f, askedOf: f.alex.id)
        let second = try CoverRequest(
            householdID: f.snapshot.household.id,
            choreID: hoover.id,
            day: clock.today,
            requestedBy: f.sam.id,
            askedOf: f.alex.id,
            createdAt: clock.now.addingTimeInterval(600),
            calendar: calendar
        )
        f.snapshot.coverRequests = [second, first]

        let planned = reminders(f)

        #expect(planned.count == 1)
        #expect(planned.first?.kind == .coverRequested(requestID: first.id, others: 1))
        #expect(
            planned.first?.body
                == "Sam needs cover for the bins today. There's 1 more ask waiting."
        )
    }

    // MARK: Priority

    @Test("An unanswered ask outranks the chores that are merely due")
    func coverOutranksTheDigest() throws {
        // It is the only kind here another person is waiting on: unanswered,
        // the chore goes undone and the person who asked finds out too late to
        // do it themselves.
        var f = try makeFixture()
        f.snapshot.coverRequests = [try request(f, askedOf: f.alex.id)]
        let capped = ReminderSchedule(maximumPerPersonPerDay: 1)

        let alexes = ReminderPlanner(snapshot: f.snapshot, schedule: capped)
            .reminders(for: clock.today, now: clock.now)
            .filter { $0.recipientID == f.alex.id }

        #expect(alexes.count == 1)
        #expect(
            alexes.first?.kind
                == .coverRequested(requestID: f.snapshot.coverRequests[0].id, others: 0))
    }

    @Test("A schedule saved before cover asks existed still decodes")
    func scheduleDecodesWithoutTheNewSwitch() throws {
        // A settings record is written once and read for years, so the field
        // added today is absent from every copy already on a device.
        let json = Data(#"{"morningHour":7,"eveningHour":20}"#.utf8)

        let decoded = try JSONDecoder().decode(ReminderSchedule.self, from: json)

        #expect(decoded.morningHour == 7)
        #expect(decoded.sendsCoverRequests)
    }
}
