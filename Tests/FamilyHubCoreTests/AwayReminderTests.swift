import Foundation
import Testing

@testable import FamilyHubCore

/// Covers what a trip does to the notification channel: what stops arriving
/// while somebody is away, what still arrives, and what comes back afterwards.
@Suite("Away and reminders")
struct AwayReminderTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday, at six in the morning — before the digest.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 6, calendar: .testDefault
    )

    private struct Fixture {
        var snapshot: HouseholdSnapshot
        let mary: Member
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
                household: household, members: [mary, sam], chores: [bins]
            ),
            mary: mary,
            sam: sam,
            bins: bins
        )
    }

    private func trip(
        _ f: Fixture,
        members: Set<Identifier<Member>> = [],
        from: Int = 0,
        to: Int = 6
    ) throws -> AwayPeriod {
        try AwayPeriod(
            householdID: f.snapshot.household.id,
            firstDay: clock.day(offsetFromToday: from),
            lastDay: clock.day(offsetFromToday: to),
            memberIDs: members,
            createdBy: f.mary.id,
            createdAt: clock.now,
            calendar: calendar
        )
    }

    private func reminders(_ f: Fixture, dayOffset: Int = 0) -> [Reminder] {
        ReminderPlanner(snapshot: f.snapshot)
            .reminders(for: clock.day(offsetFromToday: dayOffset), now: clock.now)
    }

    // MARK: What stops

    @Test("A child away is not told about the chores they cannot do")
    func awayChildHearsNothingAboutChores() throws {
        var fixture = try makeFixture()
        #expect(reminders(fixture).contains { $0.recipientID == fixture.sam.id })

        fixture.snapshot.awayPeriods = [try trip(fixture, members: [fixture.sam.id])]
        #expect(!reminders(fixture).contains { $0.recipientID == fixture.sam.id })
        // The rest of the household carries on as before.
        #expect(reminders(fixture).allSatisfy { $0.recipientID == fixture.mary.id })
    }

    @Test("A cook who is away is not the one told to start dinner")
    func awayCookIsNotNudged() throws {
        var fixture = try makeFixture()
        let dinner = try PlannedMeal(
            householdID: fixture.snapshot.household.id,
            day: clock.today,
            slot: .dinner,
            title: "Spaghetti",
            cookID: fixture.sam.id,
            plannedBy: fixture.mary.id,
            createdAt: clock.now,
            calendar: calendar
        )
        fixture.snapshot.plannedMeals = [dinner]

        let cooking = reminders(fixture).filter {
            if case .cookingTonight = $0.kind { return true }
            return false
        }
        #expect(cooking.map(\.recipientID) == [fixture.sam.id])

        fixture.snapshot.awayPeriods = [try trip(fixture, members: [fixture.sam.id])]
        #expect(
            !reminders(fixture).contains {
                if case .cookingTonight = $0.kind { return true }
                return false
            }
        )
    }

    @Test("An empty house is a quiet phone")
    func nobodyIsNudgedOnAFamilyHoliday() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [try trip(fixture)]
        #expect(reminders(fixture).isEmpty)
    }

    // MARK: What survives

    @Test("An appointment still arrives, because it was never the household's deadline")
    func appointmentsSurviveTheTrip() throws {
        var fixture = try makeFixture()
        let dentist = try CalendarEvent(
            householdID: fixture.snapshot.household.id,
            title: "Dentist",
            startDate: clock.today,
            timing: .at(hour: 15, minute: 0, lasting: 30),
            participants: .members([fixture.sam.id]),
            reminderMinutesBefore: 60,
            createdBy: fixture.mary.id,
            createdAt: clock.now,
            calendar: calendar
        )
        fixture.snapshot.events = [dentist]
        fixture.snapshot.awayPeriods = [try trip(fixture)]

        let kinds = reminders(fixture).map(\.kind)
        #expect(
            kinds.contains {
                if case .eventSoon(let id) = $0 { return id == dentist.id }
                return false
            }
        )
        // And nothing else did.
        #expect(kinds.allSatisfy { $0.survivesBeingAway })
    }

    @Test("Every kind states for itself whether it survives being away")
    func onlyTwoKindsSurvive() {
        #expect(Reminder.Kind.eventSoon(eventID: Identifier()).survivesBeingAway)
        #expect(Reminder.Kind.birthday(memberID: Identifier()).survivesBeingAway)
        #expect(!Reminder.Kind.choresDue(count: 3).survivesBeingAway)
        #expect(!Reminder.Kind.approvalsWaiting(count: 1).survivesBeingAway)
        #expect(!Reminder.Kind.mealPlanGaps(count: 2).survivesBeingAway)
        #expect(
            !Reminder.Kind.streakAtRisk(choreID: Identifier(), length: 9).survivesBeingAway
        )
        #expect(
            !Reminder.Kind.coverRequested(requestID: Identifier(), others: 0).survivesBeingAway
        )
        #expect(
            !Reminder.Kind.rewardOwed(redemptionID: Identifier(), others: 0).survivesBeingAway
        )
        #expect(!Reminder.Kind.cookingTonight(mealID: Identifier()).survivesBeingAway)
    }

    // MARK: What comes back

    @Test("The day after they get home, the phone starts asking again")
    func remindersResumeAfterTheTrip() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [
            try trip(fixture, members: [fixture.sam.id], from: 0, to: 2)
        ]

        #expect(!reminders(fixture, dayOffset: 2).contains { $0.recipientID == fixture.sam.id })
        #expect(reminders(fixture, dayOffset: 3).contains { $0.recipientID == fixture.sam.id })
    }

    @Test("A cancelled trip silences nothing")
    func cancelledTripsDoNotSilence() throws {
        var fixture = try makeFixture()
        fixture.snapshot.awayPeriods = [
            try trip(fixture, members: [fixture.sam.id]).cancelled(at: clock.now)
        ]
        #expect(reminders(fixture).contains { $0.recipientID == fixture.sam.id })
    }
}
