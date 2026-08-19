import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Reminder planner")
struct ReminderPlannerTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 6, calendar: .testDefault
    )

    private struct Fixture {
        let snapshot: HouseholdSnapshot
        let parent: Member
        let otherParent: Member
        let sam: Member
        let chore: Chore
    }

    private func makeFixture(
        requiresApproval: Bool = false,
        recurrence: RecurrenceRule = .daily,
        assignment: Chore.Assignment? = nil,
        completions: [ChoreCompletion] = [],
        samBirthday: Date? = nil
    ) throws -> Fixture {
        let household = try Household(
            name: "The Aldays",
            tier: .plus,
            timeZone: .gmt,
            requiresApproval: requiresApproval,
            createdAt: clock.now
        )
        let parent = try Member(
            householdID: household.id, name: "Jerald", role: .owner,
            joinedAt: clock.now
        )
        let otherParent = try Member(
            householdID: household.id, name: "Robin", role: .adult,
            joinedAt: clock.now
        )
        let sam = try Member(
            householdID: household.id, name: "Sam", role: .child,
            birthday: samBirthday, joinedAt: clock.now
        )
        let chore = try Chore(
            householdID: household.id,
            title: "Feed the cat",
            assignment: assignment ?? .member(sam.id),
            startDate: clock.day(offsetFromToday: -30),
            recurrence: recurrence,
            createdBy: parent.id,
            createdAt: clock.now
        )
        let snapshot = HouseholdSnapshot(
            household: household,
            members: [parent, otherParent, sam],
            chores: [chore],
            completions: completions
        )
        return Fixture(
            snapshot: snapshot, parent: parent, otherParent: otherParent, sam: sam, chore: chore
        )
    }

    private func day(_ offset: Int) -> Date {
        clock.day(offsetFromToday: offset)
    }

    private func completion(
        of chore: Chore,
        householdID: Identifier<Household>,
        on offset: Int,
        by memberID: Identifier<Member>,
        approval: ChoreCompletion.Approval = .notRequired
    ) -> ChoreCompletion {
        ChoreCompletion(
            householdID: householdID,
            choreID: chore.id,
            occurrenceDay: day(offset),
            completedBy: memberID,
            completedAt: day(offset).addingTimeInterval(60 * 60 * 18),
            approval: approval,
            pointsAwarded: 10,
            calendar: calendar
        )
    }

    private func hour(of date: Date) -> Int {
        calendar.component(.hour, from: date)
    }

    // MARK: Morning digest

    @Test("Everyone with work to do gets a morning list")
    func morningDigestIsPlanned() throws {
        let f = try makeFixture(assignment: .anyone)
        let planned = ReminderPlanner(snapshot: f.snapshot)
            .reminders(for: clock.today, now: clock.now)

        let digests = planned.filter { if case .choresDue = $0.kind { true } else { false } }
        #expect(Set(digests.map(\.recipientID)) == [f.parent.id, f.otherParent.id, f.sam.id])
        #expect(digests.allSatisfy { hour(of: $0.fireDate) == 8 })
        #expect(digests.first?.body == "1 chore today.")
    }

    @Test("A person with nothing to do is not told so")
    func nothingToDoMeansNoReminder() throws {
        // A daily notification reading 'you have 0 chores' is exactly what gets
        // an app's notifications switched off, taking the useful ones with it.
        let f = try makeFixture()
        let planned = ReminderPlanner(snapshot: f.snapshot)
            .reminders(for: clock.today, now: clock.now)

        #expect(!planned.contains { $0.recipientID == f.parent.id })
        #expect(planned.contains { $0.recipientID == f.sam.id })
    }

    @Test("Work already done today produces no morning list")
    func completedWorkIsNotAnnounced() throws {
        let f = try makeFixture()
        var snapshot = f.snapshot
        snapshot.completions = [
            completion(
                of: f.chore, householdID: snapshot.household.id, on: 0, by: f.sam.id
            )
        ]

        let planned = ReminderPlanner(snapshot: snapshot)
            .reminders(for: clock.today, now: clock.now)
        #expect(!planned.contains { if case .choresDue = $0.kind { true } else { false } })
    }

    @Test("The morning digest can be switched off entirely")
    func morningDigestIsOptional() throws {
        let f = try makeFixture()
        let schedule = ReminderSchedule(sendsMorningDigest: false)
        let planned = ReminderPlanner(snapshot: f.snapshot, schedule: schedule)
            .reminders(for: clock.today, now: clock.now)

        #expect(!planned.contains { if case .choresDue = $0.kind { true } else { false } })
    }

    @Test("Plural is handled rather than papered over")
    func bodyTextPluralises() {
        #expect(ReminderPlanner.choresDueBody(count: 1) == "1 chore today.")
        #expect(ReminderPlanner.choresDueBody(count: 4) == "4 chores today.")
        #expect(
            ReminderPlanner.approvalsBody(count: 1) == "1 completed chore needs your approval."
        )
        #expect(
            ReminderPlanner.approvalsBody(count: 2) == "2 completed chores need your approval."
        )
    }

    // MARK: Approvals

    @Test("Adults are told when completions are waiting on them")
    func approvalsReachAdults() throws {
        let f = try makeFixture(requiresApproval: true)
        var snapshot = f.snapshot
        snapshot.completions = [
            completion(
                of: f.chore,
                householdID: snapshot.household.id,
                on: 0,
                by: f.sam.id,
                approval: .pending
            )
        ]

        let planned = ReminderPlanner(snapshot: snapshot)
            .reminders(for: clock.today, now: clock.now)
        let approvals = planned.filter {
            if case .approvalsWaiting = $0.kind { true } else { false }
        }
        #expect(Set(approvals.map(\.recipientID)) == [f.parent.id, f.otherParent.id])
        #expect(!approvals.contains { $0.recipientID == f.sam.id })
    }

    @Test("A queue of only your own work reaches nobody who cannot act on it")
    func ownWorkIsNotAnApprovalPrompt() throws {
        let f = try makeFixture(requiresApproval: true)
        var snapshot = f.snapshot
        snapshot.completions = [
            completion(
                of: f.chore,
                householdID: snapshot.household.id,
                on: 0,
                by: f.parent.id,
                approval: .pending
            )
        ]

        let planned = ReminderPlanner(snapshot: snapshot)
            .reminders(for: clock.today, now: clock.now)
        let approvals = planned.filter {
            if case .approvalsWaiting = $0.kind { true } else { false }
        }
        #expect(approvals.map(\.recipientID) == [f.otherParent.id])
    }

    @Test("No pending completions means no approval prompt")
    func emptyQueueIsSilent() throws {
        let f = try makeFixture(requiresApproval: true)
        let planned = ReminderPlanner(snapshot: f.snapshot)
            .reminders(for: clock.today, now: clock.now)

        #expect(!planned.contains { if case .approvalsWaiting = $0.kind { true } else { false } })
    }

    // MARK: Streaks

    @Test("A streak about to break earns an evening nudge naming it")
    func streakNudgeIsPlanned() throws {
        let f = try makeFixture()
        var snapshot = f.snapshot
        snapshot.completions = (-3...(-1)).map {
            completion(of: f.chore, householdID: snapshot.household.id, on: $0, by: f.sam.id)
        }

        let planned = ReminderPlanner(snapshot: snapshot)
            .reminders(for: clock.today, now: clock.now)
        let nudge = try #require(
            planned.first { if case .streakAtRisk = $0.kind { true } else { false } }
        )
        #expect(nudge.recipientID == f.sam.id)
        #expect(hour(of: nudge.fireDate) == 19)
        #expect(nudge.body == "3 days on Feed the cat. Finish it today to keep it going.")
        #expect(nudge.kind == .streakAtRisk(choreID: f.chore.id, length: 3))
    }

    @Test("One nudge per person, naming the streak with most at stake")
    func onlyTheBiggestStreakIsNudged() throws {
        // Four notifications teach a person to dismiss the lot. One naming the
        // biggest gets read.
        let f = try makeFixture()
        let second = try Chore(
            householdID: f.snapshot.household.id,
            title: "Water the plants",
            assignment: .member(f.sam.id),
            startDate: day(-30),
            recurrence: .daily,
            createdBy: f.parent.id,
            createdAt: clock.now
        )
        var snapshot = f.snapshot
        snapshot.chores.append(second)
        snapshot.completions =
            (-5...(-1)).map {
                completion(of: f.chore, householdID: snapshot.household.id, on: $0, by: f.sam.id)
            }
            + (-2...(-1)).map {
                completion(of: second, householdID: snapshot.household.id, on: $0, by: f.sam.id)
            }

        let nudges = ReminderPlanner(snapshot: snapshot)
            .reminders(for: clock.today, now: clock.now)
            .filter { if case .streakAtRisk = $0.kind { true } else { false } }
        #expect(nudges.count == 1)
        #expect(nudges.first?.kind == .streakAtRisk(choreID: f.chore.id, length: 5))
    }

    @Test("Streak nudges can be switched off")
    func streakNudgesAreOptional() throws {
        let f = try makeFixture()
        var snapshot = f.snapshot
        snapshot.completions = (-3...(-1)).map {
            completion(of: f.chore, householdID: snapshot.household.id, on: $0, by: f.sam.id)
        }

        let planned = ReminderPlanner(
            snapshot: snapshot, schedule: ReminderSchedule(sendsStreakNudges: false)
        ).reminders(for: clock.today, now: clock.now)
        #expect(!planned.contains { if case .streakAtRisk = $0.kind { true } else { false } })
    }

    // MARK: Birthdays

    @Test("A birthday is announced to everyone except the person having it")
    func birthdaysReachTheRestOfTheHousehold() throws {
        let birthday = FixedDateProvider(year: 2015, month: 3, day: 2, calendar: .testDefault).now
        let f = try makeFixture(samBirthday: birthday)

        let planned = ReminderPlanner(snapshot: f.snapshot)
            .reminders(for: clock.today, now: clock.now)
        let notes = planned.filter { if case .birthday = $0.kind { true } else { false } }
        #expect(Set(notes.map(\.recipientID)) == [f.parent.id, f.otherParent.id])
        #expect(notes.first?.title == "It's Sam's birthday")
    }

    // MARK: Timing and the cap

    @Test("A reminder whose moment has passed is not scheduled")
    func pastRemindersAreDropped() throws {
        // Registering eight o'clock at half past nine either fires instantly,
        // which is startling, or never fires, which looks like a bug.
        let f = try makeFixture()
        let midMorning = FixedDateProvider(
            year: 2026, month: 3, day: 2, hour: 9, minute: 30, calendar: .testDefault
        ).now

        let planned = ReminderPlanner(snapshot: f.snapshot)
            .reminders(for: clock.today, now: midMorning)
        #expect(!planned.contains { if case .choresDue = $0.kind { true } else { false } })
    }

    @Test("Nobody receives more than their daily cap")
    func perPersonCapIsEnforced() throws {
        let birthday = FixedDateProvider(year: 2015, month: 3, day: 2, calendar: .testDefault).now
        let f = try makeFixture(requiresApproval: true, samBirthday: birthday)
        var snapshot = f.snapshot
        snapshot.chores = snapshot.chores.map { $0.assigned(.anyone) }
        snapshot.completions = [
            completion(
                of: f.chore,
                householdID: snapshot.household.id,
                on: -1,
                by: f.sam.id,
                approval: .pending
            )
        ]

        let planned = ReminderPlanner(
            snapshot: snapshot, schedule: ReminderSchedule(maximumPerPersonPerDay: 1)
        ).reminders(for: clock.today, now: clock.now)

        for member in snapshot.activeMembers {
            #expect(planned.filter { $0.recipientID == member.id }.count <= 1)
        }
        // The approval queue outranks a morning list, so that is what survives.
        let parents = planned.filter { $0.recipientID == f.parent.id }
        #expect(parents.first?.kind == .approvalsWaiting(count: 1))
    }

    @Test("A cap of zero silences the app completely")
    func zeroCapSendsNothing() throws {
        let f = try makeFixture()
        let planned = ReminderPlanner(
            snapshot: f.snapshot, schedule: ReminderSchedule(maximumPerPersonPerDay: 0)
        ).reminders(for: clock.today, now: clock.now)
        #expect(planned.isEmpty)
    }

    @Test("Reminders come back in the order they will arrive")
    func remindersAreInDeliveryOrder() throws {
        let f = try makeFixture()
        var snapshot = f.snapshot
        snapshot.completions = (-3...(-1)).map {
            completion(of: f.chore, householdID: snapshot.household.id, on: $0, by: f.sam.id)
        }

        let planned = ReminderPlanner(snapshot: snapshot)
            .reminders(for: clock.today, now: clock.now)
        #expect(planned.map(\.fireDate) == planned.map(\.fireDate).sorted())
    }

    @Test("Identity is stable across replanning, so nudges do not stack up")
    func identitiesAreStable() throws {
        // The plan is rebuilt on every launch. Random identifiers would leave a
        // family that opens the app four times before dinner with four
        // identical notifications at seven.
        let f = try makeFixture()
        let planner = ReminderPlanner(snapshot: f.snapshot)

        let first = planner.reminders(for: clock.today, now: clock.now).map(\.id)
        let later = FixedDateProvider(
            year: 2026, month: 3, day: 2, hour: 7, minute: 45, calendar: .testDefault
        ).now
        let second = planner.reminders(for: clock.today, now: later).map(\.id)

        #expect(!first.isEmpty)
        #expect(first == second)
    }

    @Test("Planning several days ahead keeps each day's reminders distinct")
    func multiDayPlanningIsDistinct() throws {
        let f = try makeFixture()
        let planned = ReminderPlanner(snapshot: f.snapshot)
            .upcomingReminders(from: clock.now, days: 3)

        let digests = planned.filter { if case .choresDue = $0.kind { true } else { false } }
        #expect(digests.count == 3)
        #expect(Set(digests.map(\.id)).count == 3)
        #expect(planned.map(\.fireDate) == planned.map(\.fireDate).sorted())
    }
}
