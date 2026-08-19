import Foundation

/// A notification the app intends to deliver.
///
/// Deliberately not a `UNNotificationRequest`. Deciding *what is worth saying*
/// is a domain question — it depends on the schedule, the streaks, and who is
/// an adult — while scheduling a local notification is a platform detail. Split
/// this way, the entire notification strategy is testable in microseconds and
/// the app layer's job shrinks to a loop that translates these into requests.
public struct Reminder: Sendable, Hashable, Identifiable {

    /// Why the reminder exists.
    public enum Kind: Hashable, Sendable {
        /// Work is due today. Raised once for the whole day rather than once
        /// per chore.
        case choresDue(count: Int)

        /// A run is about to end tonight.
        case streakAtRisk(choreID: Identifier<Chore>, length: Int)

        /// Completions are waiting on an adult.
        case approvalsWaiting(count: Int)

        /// It is somebody's birthday.
        case birthday(memberID: Identifier<Member>)

        /// How disruptive this kind is allowed to be, lowest first.
        ///
        /// Used to decide what survives the per-person daily cap. A streak
        /// about to break outranks a morning list because it is time-critical
        /// and cannot be acted on tomorrow.
        public var priority: Int {
            switch self {
            case .streakAtRisk: 3
            case .approvalsWaiting: 2
            case .birthday: 1
            case .choresDue: 0
            }
        }
    }

    /// A stable identity for this reminder.
    ///
    /// Derived from the recipient, the day, and the kind rather than randomly
    /// generated, so re-planning — which happens on every launch and every
    /// edit — replaces the pending request instead of stacking a second copy
    /// of it. A family that opens the app four times before dinner should not
    /// get four identical nudges at seven.
    public let id: String

    /// Who it is for.
    public let recipientID: Identifier<Member>

    /// When it should be delivered.
    public let fireDate: Date

    /// The notification's title.
    public let title: String

    /// The notification's body.
    public let body: String

    /// Why it exists.
    public let kind: Kind

    /// Creates a reminder.
    public init(
        id: String,
        recipientID: Identifier<Member>,
        fireDate: Date,
        title: String,
        body: String,
        kind: Kind
    ) {
        self.id = id
        self.recipientID = recipientID
        self.fireDate = fireDate
        self.title = title
        self.body = body
        self.kind = kind
    }
}

/// When a household wants to be interrupted, and how often.
public struct ReminderSchedule: Hashable, Sendable, Codable {
    /// The hour the morning digest is delivered, in the household's timezone.
    public var morningHour: Int

    /// The hour the evening nudge is delivered.
    ///
    /// Late enough that most of the day's work has had its chance, early enough
    /// that a child can still act on it before bed. A reminder at eleven that a
    /// streak is about to break is a reminder that it has broken.
    public var eveningHour: Int

    /// The most reminders any one person receives in a day.
    ///
    /// The single most important number here. An app that sends six
    /// notifications a day gets its notifications switched off within a week,
    /// and then it sends none — so the cap is not a limitation, it is what
    /// keeps the channel alive.
    public var maximumPerPersonPerDay: Int

    /// Whether the morning digest is sent at all.
    public var sendsMorningDigest: Bool

    /// Whether streak nudges are sent.
    public var sendsStreakNudges: Bool

    /// Creates a schedule.
    public init(
        morningHour: Int = 8,
        eveningHour: Int = 19,
        maximumPerPersonPerDay: Int = 2,
        sendsMorningDigest: Bool = true,
        sendsStreakNudges: Bool = true
    ) {
        self.morningHour = min(23, max(0, morningHour))
        self.eveningHour = min(23, max(0, eveningHour))
        self.maximumPerPersonPerDay = max(0, maximumPerPersonPerDay)
        self.sendsMorningDigest = sendsMorningDigest
        self.sendsStreakNudges = sendsStreakNudges
    }

    /// The default schedule: a morning list and, at most, one evening nudge.
    public static let standard = ReminderSchedule()
}

/// Decides what the household should be told, and when.
///
/// Pure, like everything else in this layer. It is handed a snapshot, a
/// schedule, and the current moment, and returns the reminders to register. It
/// registers nothing itself and knows nothing about notification permission,
/// which means the whole strategy — including the parts that are judgement
/// calls rather than rules — can be argued about in a test rather than by
/// installing a build and waiting until seven o'clock.
public struct ReminderPlanner: Sendable {

    private let snapshot: HouseholdSnapshot
    private let schedule: ReminderSchedule

    /// Creates a planner over a household.
    public init(snapshot: HouseholdSnapshot, schedule: ReminderSchedule = .standard) {
        self.snapshot = snapshot
        self.schedule = schedule
    }

    /// The reminders to register for a single day.
    ///
    /// - Parameters:
    ///   - day: The day to plan.
    ///   - now: The current moment. Anything that would have fired already is
    ///     dropped — a notification scheduled for eight in the morning at half
    ///     past nine either arrives instantly, which is startling, or silently
    ///     never arrives, which looks like a bug.
    /// - Returns: Reminders in delivery order, capped per person.
    public func reminders(for day: Date, now: Date) -> [Reminder] {
        let calendar = snapshot.household.calendar()
        let today = calendar.startOfDay(for: day)
        let streaks = snapshot.streaks

        var planned: [Reminder] = []
        planned.append(contentsOf: morningReminders(on: today, calendar: calendar))
        planned.append(
            contentsOf: eveningReminders(on: today, calendar: calendar, streaks: streaks)
        )

        return capped(planned.filter { $0.fireDate > now })
    }

    /// The reminders to register across the next several days.
    ///
    /// iOS allows a limited number of pending local notifications, and a
    /// household with five members burns through them quickly, so the horizon
    /// is short by default. Re-planning happens on every launch anyway.
    ///
    /// - Parameters:
    ///   - now: The current moment.
    ///   - days: How many days ahead to plan, including today.
    /// - Returns: Reminders in delivery order.
    public func upcomingReminders(from now: Date, days: Int = 3) -> [Reminder] {
        let calendar = snapshot.household.calendar()
        let today = calendar.startOfDay(for: now)

        return (0..<max(1, days)).flatMap { offset -> [Reminder] in
            guard let target = calendar.date(byAdding: .day, value: offset, to: today) else {
                return []
            }
            return reminders(for: target, now: now)
        }
        .sorted(by: Reminder.deliveryOrder)
    }

    // MARK: - Morning

    /// The morning digest, one per person with work to do, plus the approval
    /// queue for adults.
    private func morningReminders(on day: Date, calendar: Calendar) -> [Reminder] {
        guard let fireDate = time(schedule.morningHour, on: day, calendar: calendar) else {
            return []
        }

        var planned: [Reminder] = []

        if schedule.sendsMorningDigest {
            for member in snapshot.activeMembers {
                let outstanding = snapshot.agenda(for: day, memberID: member.id)
                    .filter { !$0.isDone }
                // Nothing to do is not news. A daily notification that says
                // "you have 0 chores" is precisely the sort of thing people
                // switch off, taking the useful ones with it.
                guard !outstanding.isEmpty else { continue }

                planned.append(
                    Reminder(
                        id: identity(member.id, day, "chores-due", calendar: calendar),
                        recipientID: member.id,
                        fireDate: fireDate,
                        title: "Today's chores",
                        body: Self.choresDueBody(count: outstanding.count),
                        kind: .choresDue(count: outstanding.count)
                    )
                )
            }
        }

        planned.append(contentsOf: birthdayReminders(on: day, at: fireDate, calendar: calendar))
        planned.append(contentsOf: approvalReminders(on: day, at: fireDate, calendar: calendar))
        return planned
    }

    /// One reminder per adult when completions are waiting.
    ///
    /// Sent to adults only, and never for their own work — a queue a parent
    /// cannot act on is noise, and the approval rule already forbids signing
    /// off your own chore.
    private func approvalReminders(
        on day: Date,
        at fireDate: Date,
        calendar: Calendar
    ) -> [Reminder] {
        let queue = snapshot.reviewQueue
        guard !queue.isEmpty else { return [] }

        return snapshot.activeMembers
            .filter { $0.role.isAdult }
            .compactMap { adult in
                let actionable = queue.filter { $0.completedBy != adult.id }
                guard !actionable.isEmpty else { return nil }

                return Reminder(
                    id: identity(adult.id, day, "approvals", calendar: calendar),
                    recipientID: adult.id,
                    fireDate: fireDate,
                    title: "Waiting on you",
                    body: Self.approvalsBody(count: actionable.count),
                    kind: .approvalsWaiting(count: actionable.count)
                )
            }
    }

    /// A birthday note to everyone except the person having it.
    private func birthdayReminders(
        on day: Date,
        at fireDate: Date,
        calendar: Calendar
    ) -> [Reminder] {
        let celebrants = snapshot.activeMembers.filter {
            $0.hasBirthday(on: day, calendar: calendar)
        }
        guard !celebrants.isEmpty else { return [] }

        return celebrants.flatMap { celebrant in
            snapshot.activeMembers
                .filter { $0.id != celebrant.id }
                .map { recipient in
                    Reminder(
                        id: identity(
                            recipient.id,
                            day,
                            "birthday-\(celebrant.id)",
                            calendar: calendar
                        ),
                        recipientID: recipient.id,
                        fireDate: fireDate,
                        title: "It's \(celebrant.name.value)'s birthday",
                        body: "Today is \(celebrant.name.value)'s birthday. 🎂",
                        kind: .birthday(memberID: celebrant.id)
                    )
                }
        }
    }

    // MARK: - Evening

    /// The evening nudge: one per person, naming the streak with most at stake.
    ///
    /// One, not one per chore. A person with four streaks in danger who gets
    /// four notifications learns to dismiss the lot; a person who gets one
    /// naming the biggest reads it.
    private func eveningReminders(
        on day: Date,
        calendar: Calendar,
        streaks: StreakCalculator
    ) -> [Reminder] {
        guard schedule.sendsStreakNudges,
            let fireDate = time(schedule.eveningHour, on: day, calendar: calendar)
        else { return [] }

        return snapshot.activeMembers.compactMap { member in
            guard let biggest = streaks.streaksAtRisk(on: day, for: member.id).first else {
                return nil
            }
            return Reminder(
                id: identity(member.id, day, "streak-\(biggest.chore.id)", calendar: calendar),
                recipientID: member.id,
                fireDate: fireDate,
                title: "Don't break the streak",
                body: Self.streakBody(
                    chore: biggest.chore.title.value,
                    length: biggest.streak.length
                ),
                kind: .streakAtRisk(choreID: biggest.chore.id, length: biggest.streak.length)
            )
        }
    }

    // MARK: - Trimming

    /// Applies the per-person daily cap, keeping the most useful reminders.
    ///
    /// Sorted by priority to decide *what survives*, then re-sorted into
    /// delivery order so the caller registers them in the sequence they will
    /// actually arrive.
    private func capped(_ reminders: [Reminder]) -> [Reminder] {
        guard schedule.maximumPerPersonPerDay > 0 else { return [] }

        var keptPerPerson: [Identifier<Member>: Int] = [:]
        var kept: [Reminder] = []

        for reminder in reminders.sorted(by: Reminder.importanceOrder) {
            let count = keptPerPerson[reminder.recipientID, default: 0]
            guard count < schedule.maximumPerPersonPerDay else { continue }
            keptPerPerson[reminder.recipientID] = count + 1
            kept.append(reminder)
        }

        return kept.sorted(by: Reminder.deliveryOrder)
    }

    // MARK: - Helpers

    /// The given hour on the given day, in the household's calendar.
    private func time(_ hour: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: calendar.startOfDay(for: day)
        )
    }

    /// A stable identity for a reminder.
    ///
    /// The day is written as `yyyy-MM-dd` in the household calendar rather than
    /// as a timestamp, so the identity is the same whichever moment of the day
    /// the plan happened to be built at.
    private func identity(
        _ recipientID: Identifier<Member>,
        _ day: Date,
        _ suffix: String,
        calendar: Calendar
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let stamp = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        return "\(recipientID.rawValue.uuidString)|\(stamp)|\(suffix)"
    }
}

// MARK: - Ordering

extension Reminder {
    /// The order reminders arrive in: by time, then by importance, then by
    /// identity so the sequence never depends on how the array was assembled.
    public static func deliveryOrder(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
        if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority > rhs.kind.priority }
        return lhs.id < rhs.id
    }

    /// The order reminders are trimmed in when a person is over their cap:
    /// most important first.
    public static func importanceOrder(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority > rhs.kind.priority }
        if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
        return lhs.id < rhs.id
    }
}

// MARK: - Copy

extension ReminderPlanner {
    /// "3 chores today." — plural handled rather than papered over with "(s)".
    static func choresDueBody(count: Int) -> String {
        count == 1 ? "1 chore today." : "\(count) chores today."
    }

    static func approvalsBody(count: Int) -> String {
        count == 1
            ? "1 completed chore needs your approval."
            : "\(count) completed chores need your approval."
    }

    /// Names the chore and the number, because that is the whole reason this
    /// notification works where a count of outstanding chores does not.
    static func streakBody(chore: String, length: Int) -> String {
        "\(length) days on \(chore). Finish it today to keep it going."
    }
}
