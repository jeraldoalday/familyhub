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

        /// This person is down to cook tonight.
        case cookingTonight(mealID: Identifier<PlannedMeal>)

        /// The coming week still has dinners nobody has decided on.
        case mealPlanGaps(count: Int)

        /// Something on the calendar is about to start.
        case eventSoon(eventID: Identifier<CalendarEvent>)

        /// Somebody has asked this person to take a chore off them today.
        case coverRequested(requestID: Identifier<CoverRequest>, others: Int)

        /// How disruptive this kind is allowed to be, lowest first.
        ///
        /// Used to decide what survives the per-person daily cap. The ladder is
        /// ordered by how badly the day goes if the reminder is missed rather
        /// than by how interesting it is. An appointment outranks everything,
        /// because it is the only thing here whose deadline was set by somebody
        /// outside the household — a missed dentist appointment costs money and
        /// cannot be made up this evening, which is true of nothing else on the
        /// list. A streak about to break comes next: time-critical, but the
        /// household set the stakes itself. Being down to cook follows, because
        /// a cook who finds out at seven is a household ordering takeaway; and a
        /// week with holes in it can be planned any evening, so it sits below a
        /// birthday and above a list of chores that is also visible on the home
        /// screen.
        ///
        /// A cover request sits just under a streak because it is the only kind
        /// here that another person is waiting on. Unanswered, it is not one
        /// evening that goes wrong but two: the chore does not get done, and
        /// the person who asked finds out too late to do it themselves.
        public var priority: Int {
            switch self {
            case .eventSoon: 7
            case .streakAtRisk: 6
            case .coverRequested: 5
            case .cookingTonight: 4
            case .approvalsWaiting: 3
            case .birthday: 2
            case .mealPlanGaps: 1
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

    /// The hour the cook is reminded that they are cooking.
    ///
    /// Mid-afternoon, deliberately. A cook told at seven that they are cooking
    /// is a household ordering takeaway; told at four, they can still buy
    /// something on the way home or start the slow bit.
    public var cookingHour: Int

    /// Whether anything about the meal plan is sent at all.
    public var sendsMealReminders: Bool

    /// Whether a person is told when somebody has asked them to cover a chore.
    ///
    /// The one switch here a household should think twice about. Every other
    /// kind of reminder is the app noticing something; this one is a person
    /// asking another person a question, and a question that never arrives is
    /// answered by the chore not being done.
    public var sendsCoverRequests: Bool

    /// Whether calendar events are allowed to interrupt anybody.
    ///
    /// Only events that asked to are sent regardless — an event's reminder
    /// lead is `nil` unless somebody set one — so this switch is for the
    /// household that wants the calendar to be a thing they look at rather
    /// than a thing that speaks.
    public var sendsEventReminders: Bool

    /// Creates a schedule.
    public init(
        morningHour: Int = 8,
        eveningHour: Int = 19,
        maximumPerPersonPerDay: Int = 2,
        sendsMorningDigest: Bool = true,
        sendsStreakNudges: Bool = true,
        cookingHour: Int = 16,
        sendsMealReminders: Bool = true,
        sendsEventReminders: Bool = true,
        sendsCoverRequests: Bool = true
    ) {
        self.morningHour = min(23, max(0, morningHour))
        self.eveningHour = min(23, max(0, eveningHour))
        self.maximumPerPersonPerDay = max(0, maximumPerPersonPerDay)
        self.sendsMorningDigest = sendsMorningDigest
        self.sendsStreakNudges = sendsStreakNudges
        self.cookingHour = min(23, max(0, cookingHour))
        self.sendsMealReminders = sendsMealReminders
        self.sendsEventReminders = sendsEventReminders
        self.sendsCoverRequests = sendsCoverRequests
    }

    /// Decodes a schedule saved by an older build.
    ///
    /// A settings record is written once and read for years, so a field added
    /// today is absent from every copy already on a device. Decoding it as
    /// missing-means-default keeps a family's notification preferences intact
    /// across the update instead of throwing them away — or, worse, failing to
    /// decode and leaving the app with no schedule at all.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = ReminderSchedule.standard
        self.init(
            morningHour: try container.decodeIfPresent(Int.self, forKey: .morningHour)
                ?? standard.morningHour,
            eveningHour: try container.decodeIfPresent(Int.self, forKey: .eveningHour)
                ?? standard.eveningHour,
            maximumPerPersonPerDay: try container.decodeIfPresent(
                Int.self, forKey: .maximumPerPersonPerDay
            ) ?? standard.maximumPerPersonPerDay,
            sendsMorningDigest: try container.decodeIfPresent(
                Bool.self, forKey: .sendsMorningDigest
            ) ?? standard.sendsMorningDigest,
            sendsStreakNudges: try container.decodeIfPresent(
                Bool.self, forKey: .sendsStreakNudges
            ) ?? standard.sendsStreakNudges,
            cookingHour: try container.decodeIfPresent(Int.self, forKey: .cookingHour)
                ?? standard.cookingHour,
            sendsMealReminders: try container.decodeIfPresent(
                Bool.self, forKey: .sendsMealReminders
            ) ?? standard.sendsMealReminders,
            sendsEventReminders: try container.decodeIfPresent(
                Bool.self, forKey: .sendsEventReminders
            ) ?? standard.sendsEventReminders,
            sendsCoverRequests: try container.decodeIfPresent(
                Bool.self, forKey: .sendsCoverRequests
            ) ?? standard.sendsCoverRequests
        )
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
        planned.append(contentsOf: mealReminders(on: today, calendar: calendar))
        planned.append(contentsOf: eventReminders(on: today, calendar: calendar))
        planned.append(contentsOf: coverReminders(on: today, now: now, calendar: calendar))
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

    // MARK: - Meals

    /// What the meal plan is worth saying: who is cooking tonight, and what is
    /// still undecided for the coming week.
    ///
    /// Silent on a plan that does not include meal planning. Nudging a family
    /// about a feature they have not bought is an advertisement wearing a
    /// notification's clothes, and it costs the whole channel.
    private func mealReminders(on day: Date, calendar: Calendar) -> [Reminder] {
        guard schedule.sendsMealReminders,
            snapshot.household.tier.includesMealPlanning
        else { return [] }

        let plan = snapshot.mealPlan
        var planned: [Reminder] = []

        // Tonight's cook, told while they can still do something about it.
        if let dinner = plan.meal(on: day, slot: .dinner),
            let cookID = dinner.cookID,
            let cook = snapshot.member(cookID),
            cook.isActive,
            let fireDate = time(schedule.cookingHour, on: day, calendar: calendar)
        {
            planned.append(
                Reminder(
                    id: identity(cook.id, day, "cooking-\(dinner.id)", calendar: calendar),
                    recipientID: cook.id,
                    fireDate: fireDate,
                    title: "You're cooking tonight",
                    body: Self.cookingBody(meal: dinner.title.value),
                    kind: .cookingTonight(mealID: dinner.id)
                )
            )
        }

        planned.append(contentsOf: planningReminders(on: day, calendar: calendar, plan: plan))
        return planned
    }

    /// A nudge, on the household's last day of the week, about the week ahead.
    ///
    /// Sent on that day and no other. A prompt about next week's holes is
    /// useful once, on the evening a family is in a position to sit down and
    /// fill them; the same prompt on a Wednesday is nagging about something
    /// they have already decided to do later.
    ///
    /// It goes to whoever may actually change the plan, which is a teen or
    /// above — the same rule the command layer applies. A reminder a child
    /// cannot act on is noise addressed to the wrong person.
    private func planningReminders(
        on day: Date,
        calendar: Calendar,
        plan: MealPlan
    ) -> [Reminder] {
        let thisWeek = plan.week(containing: day)
        guard day == thisWeek.end,
            let firstOfNext = calendar.date(byAdding: .day, value: 1, to: day),
            let fireDate = time(schedule.eveningHour, on: day, calendar: calendar)
        else { return [] }

        let nextWeek = plan.week(containing: firstOfNext)
        let undecidedDinners = nextWeek.days.filter { $0.dinner == nil }.count
        guard undecidedDinners > 0 else { return [] }

        return snapshot.activeMembers
            .filter { Permissions.allows(.manageMealPlan, for: $0.role) }
            .map { planner in
                Reminder(
                    id: identity(planner.id, day, "meal-plan", calendar: calendar),
                    recipientID: planner.id,
                    fireDate: fireDate,
                    title: "Next week's meals",
                    body: Self.mealPlanBody(count: undecidedDinners),
                    kind: .mealPlanGaps(count: undecidedDinners)
                )
            }
    }

    // MARK: - The calendar

    /// How far ahead an event's reminder may be asked to fire, in days.
    ///
    /// The bound ``Limits/eventReminderLead`` already enforces, restated in
    /// days because that is the unit the scan below has to look ahead in.
    private static var maximumLeadDays: Int {
        Limits.eventReminderLead.upperBound / (24 * 60)
    }

    /// Reminders for the things on the calendar that asked to be reminded
    /// about.
    ///
    /// Only events carrying a lead are considered. A calendar that notifies
    /// for everything on it is a calendar nobody puts anything on, so the
    /// default is silence and the family opts each entry in.
    ///
    /// The scan looks a week past the day being planned and then keeps only
    /// the reminders whose fire time lands on it. That is the awkward-looking
    /// half of this, and it is deliberate: a reminder is planned on the day it
    /// *fires* rather than the day the event happens, which is what makes a
    /// seven-day lead work against a three-day planning horizon and what makes
    /// the per-person cap count each reminder against the day it will actually
    /// interrupt somebody.
    private func eventReminders(on day: Date, calendar: Calendar) -> [Reminder] {
        guard schedule.sendsEventReminders else { return [] }

        let horizon =
            calendar.date(byAdding: .day, value: Self.maximumLeadDays, to: day) ?? day
        let familyCalendar = snapshot.familyCalendar
        let members = snapshot.activeMembers

        return familyCalendar.occurrences(from: day, to: horizon)
            .flatMap { occurrence -> [Reminder] in
                guard let lead = occurrence.event.reminderMinutesBefore,
                    let fireDate = fireDate(for: occurrence, lead: lead, calendar: calendar),
                    calendar.isDate(fireDate, inSameDayAs: day)
                else { return [] }

                return occurrence.event.participants
                    .resolved(against: members)
                    .map { recipient in
                        Reminder(
                            id: identity(
                                recipient.id,
                                occurrence.day,
                                "event-\(occurrence.event.id)",
                                calendar: calendar
                            ),
                            recipientID: recipient.id,
                            fireDate: fireDate,
                            title: occurrence.event.title.value,
                            body: Self.eventBody(
                                when: occurrence.event.timeSummary(
                                    on: occurrence.day, calendar: calendar
                                ),
                                location: occurrence.event.location?.value
                            ),
                            kind: .eventSoon(eventID: occurrence.event.id)
                        )
                    }
            }
    }

    /// When to speak up about an occurrence.
    ///
    /// A timed event counts back from the minute it starts. An all-day one
    /// counts back from the morning digest hour rather than from midnight,
    /// because a lead of zero on a half term means "tell me this morning" and
    /// not "wake the household at twelve".
    private func fireDate(
        for occurrence: FamilyCalendar.Occurrence,
        lead: Int,
        calendar: Calendar
    ) -> Date? {
        let anchor =
            occurrence.isAllDay
            ? time(schedule.morningHour, on: occurrence.day, calendar: calendar)
            : occurrence.start
        guard let anchor else { return nil }
        return calendar.date(byAdding: .minute, value: -lead, to: anchor)
    }

    // MARK: - Cover

    /// One reminder per person who has been asked to take a chore off somebody
    /// today.
    ///
    /// One, not one per request. A person asked to cover three chores who gets
    /// three notifications answers none of them, and the cap would in any case
    /// throw two away — so the reminder names the oldest ask and says how many
    /// others are behind it, which is the same argument the evening streak
    /// nudge is built on.
    ///
    /// Only requests for chores falling *today* are considered. A request for
    /// Wednesday, planned on Monday, would otherwise interrupt somebody two
    /// days before there is anything to decide.
    private func coverReminders(on day: Date, now: Date, calendar: Calendar) -> [Reminder] {
        guard schedule.sendsCoverRequests else { return [] }

        let today = calendar.startOfDay(for: day)
        let todaysAsks = snapshot.coverRequests.open.filter { $0.day == today }
        guard !todaysAsks.isEmpty else { return [] }

        return snapshot.activeMembers.compactMap { member in
            let inbox = todaysAsks.filter { $0.isAddressed(to: member.id) }
            guard let oldest = inbox.first,
                let requester = snapshot.member(oldest.requestedBy),
                let chore = snapshot.chore(oldest.choreID),
                let fireDate = nextInterruption(on: today, after: now, calendar: calendar)
            else { return nil }

            return Reminder(
                id: identity(member.id, today, "cover-\(oldest.id)", calendar: calendar),
                recipientID: member.id,
                fireDate: fireDate,
                title: "Can you cover?",
                body: Self.coverBody(
                    requester: requester.name.value,
                    chore: chore.title.value,
                    note: oldest.note?.value,
                    others: inbox.count - 1
                ),
                kind: .coverRequested(requestID: oldest.id, others: inbox.count - 1)
            )
        }
    }

    /// The household's next scheduled interruption on `day`, or `nil` if both
    /// have gone by.
    ///
    /// A cover request is the one thing here that is not planned the evening
    /// before — it is asked at eight in the morning when somebody realises
    /// they are out — so pinning it to the morning digest would mean most
    /// requests never produced a reminder at all. Falling through to the
    /// evening hour gets the person one interruption on the day it matters
    /// without inventing a third time the app is allowed to speak.
    private func nextInterruption(on day: Date, after now: Date, calendar: Calendar) -> Date? {
        let candidates = [
            time(schedule.morningHour, on: day, calendar: calendar),
            time(schedule.eveningHour, on: day, calendar: calendar),
        ]
        return candidates.compactMap { $0 }.sorted().first { $0 > now }
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

    /// Names the meal, so the reminder answers the question it raises. "You're
    /// cooking tonight" without saying what is a reminder that sends somebody
    /// to the app to find out.
    static func cookingBody(meal: String) -> String {
        "\(meal) is on the plan for tonight."
    }

    static func mealPlanBody(count: Int) -> String {
        count == 1
            ? "1 dinner next week still needs deciding."
            : "\(count) dinners next week still need deciding."
    }

    /// Says when, and where when there is a where. A notification that names
    /// an appointment without saying what time it is sends the person to the
    /// app to find out, which is the work the notification was meant to save.
    static func eventBody(when: String, location: String?) -> String {
        guard let location, !location.isEmpty else { return when }
        return "\(when) · \(location)"
    }

    /// Names who asked and what for, and carries their reason when they gave
    /// one — a bare "can you cover?" is a notification that has to be opened
    /// before it can be answered, which is most of the work it was meant to
    /// save.
    static func coverBody(requester: String, chore: String, note: String?, others: Int) -> String {
        // "needs cover for" rather than "asked you to", because a request left
        // open to the household reaches everybody in it and telling four people
        // they were each asked personally is four small untruths.
        var sentence = "\(requester) needs cover for \(chore) today"
        if let note, !note.isEmpty {
            sentence += " — \(note)"
        }
        sentence += "."
        guard others > 0 else { return sentence }
        return sentence
            + (others == 1
                ? " There's 1 more ask waiting."
                : " There are \(others) more asks waiting.")
    }

    /// Names the chore and the number, because that is the whole reason this
    /// notification works where a count of outstanding chores does not.
    static func streakBody(chore: String, length: Int) -> String {
        "\(length) days on \(chore). Finish it today to keep it going."
    }
}
