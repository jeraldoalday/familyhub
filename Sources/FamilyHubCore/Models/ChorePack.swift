import Foundation

/// A chore a household might want, described without belonging to one yet.
///
/// The gap this fills is the first five minutes. A family that has just made a
/// household is looking at an empty chore list and a "New chore" button, and
/// the first thing the app asks them to do is invent a rota, price it in
/// points, and choose a recurrence — three decisions before they have seen the
/// app do anything. Most of them will add one chore, or none, and the empty
/// list is what they will remember.
///
/// A template is not a chore. It has no household, no author, no start date and
/// no assignee, because those are exactly the things that only exist once a
/// particular family picks it. What it does carry is the part that took
/// somebody's judgement — how often the thing genuinely needs doing, what it is
/// worth relative to the others, and who in a house can realistically do it.
public struct ChoreTemplate: Sendable, Hashable, Identifiable {

    /// A stable key, unchanging across releases.
    ///
    /// Not the title. Titles get reworded — "Empty the dishwasher" becomes
    /// "Unload the dishwasher" — and a household that installed the pack last
    /// year would then be offered the same chore a second time, as a new one,
    /// beside the one they already have.
    public let id: String

    /// What needs doing.
    public let title: String

    /// The detail that makes it unambiguous, where there is one. Deliberately
    /// sparse: a template that explains every obvious chore reads as
    /// condescending, and the notes field is where a family puts what is
    /// specific to their house.
    public let notes: String?

    /// The grouping, which decides the icon on the row.
    public let category: Chore.Category

    /// What it is worth.
    ///
    /// The numbers across the catalogue are relative to each other rather than
    /// absolute: five for something that takes a minute, ten for the everyday,
    /// twenty and up for work a child will notice doing. A family that wants
    /// bigger numbers changes them, and the ratios still hold.
    public let points: Int

    /// How often it comes around.
    public let recurrence: RecurrenceRule

    /// The youngest role that can reasonably be given this.
    ///
    /// Used to keep the suggestions honest rather than to enforce anything: a
    /// household with a five year old should not be shown "Take the bins out"
    /// as a starting point, and one with no children at all should not be shown
    /// a pack built around pocket money.
    public let suitableFrom: MemberRole

    /// Creates a template.
    public init(
        id: String,
        title: String,
        notes: String? = nil,
        category: Chore.Category,
        points: Int,
        recurrence: RecurrenceRule,
        suitableFrom: MemberRole = .child
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.category = category
        self.points = points
        self.recurrence = recurrence
        self.suitableFrom = suitableFrom
    }

    /// Whether somebody in this role could be given the chore.
    ///
    /// Roles compare by privilege, and an adult can do anything a child can —
    /// so this is "at least as capable as", not equality.
    public func suits(_ role: MemberRole) -> Bool {
        role >= suitableFrom
    }

    /// The key used to decide whether a household already has this chore.
    ///
    /// Folded, so a family that typed "bins" by hand is not offered "Bins"
    /// again by a pack. Matching on the title rather than on the template's
    /// identifier is deliberate: the identifier only exists on chores that came
    /// from a pack, and the duplicate a household actually minds is the one
    /// they created themselves.
    public var duplicateKey: String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

// MARK: - Packs

/// A themed set of templates offered together.
///
/// Grouped rather than presented as one long catalogue because the choice being
/// made is "what is this household like", not "which of forty chores do you
/// want" — and a list of forty is a list nobody reads to the end of.
public struct ChorePack: Sendable, Hashable, Identifiable {

    /// A stable key, unchanging across releases.
    public let id: String

    /// What the pack is called.
    public let name: String

    /// One line about who it is for.
    public let summary: String

    /// The SF Symbol shown on the pack's card.
    public let symbolName: String

    /// What installing it would add.
    public let templates: [ChoreTemplate]

    /// Creates a pack.
    public init(
        id: String,
        name: String,
        summary: String,
        symbolName: String,
        templates: [ChoreTemplate]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.templates = templates
    }

    /// The templates in this pack that suit at least one of the roles given.
    ///
    /// - Parameter roles: The roles actually present in the household.
    /// - Returns: The templates worth offering, in the pack's own order.
    public func templates(for roles: some Collection<MemberRole>) -> [ChoreTemplate] {
        guard let best = roles.max() else { return [] }
        return templates.filter { $0.suits(best) }
    }

    /// How much the pack would be worth per week if everything in it were done.
    ///
    /// Shown on the pack's card so a household can see that one pack is a
    /// gentle start and another is a fortnight's worth of work before they
    /// install it and have to delete half of it.
    public func weeklyPoints(calendar: Calendar = .current) -> Int {
        let engine = RecurrenceEngine(calendar: calendar)
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        guard let end = calendar.date(byAdding: .day, value: 27, to: start) else { return 0 }

        // Measured over four weeks and divided, so a fortnightly chore counts
        // as half of itself rather than as nothing or as everything depending
        // on which week the sample happened to land on.
        return
            templates
            .map { template in
                let count = engine.occurrences(
                    of: template.recurrence,
                    startingOn: start,
                    in: start...end,
                    maximum: 64
                ).count
                return template.points * count
            }
            .reduce(0, +) / 4
    }
}

// MARK: - The catalogue

extension ChorePack {

    /// Every pack on offer, in the order they are shown.
    public static let all: [ChorePack] = [.everyday, .kitchen, .weekendReset, .pets, .school]

    /// The pack a household with nothing at all is offered first.
    ///
    /// Five chores, all daily or near enough, none of them contentious. The
    /// point is a list with something on it by tomorrow morning, not a complete
    /// description of running a house.
    public static let everyday = ChorePack(
        id: "everyday",
        name: "Everyday basics",
        summary: "Five small things, most days. A good first list.",
        symbolName: "sun.max",
        templates: [
            ChoreTemplate(
                id: "everyday.beds",
                title: "Make your bed",
                category: .cleaning,
                points: 5,
                recurrence: .daily
            ),
            ChoreTemplate(
                id: "everyday.dishwasher",
                title: "Empty the dishwasher",
                category: .kitchen,
                points: 10,
                recurrence: .daily
            ),
            ChoreTemplate(
                id: "everyday.table",
                title: "Clear the table",
                category: .kitchen,
                points: 5,
                recurrence: .daily
            ),
            ChoreTemplate(
                id: "everyday.tidy",
                title: "Tidy your room",
                notes: "Floor clear, clothes away.",
                category: .cleaning,
                points: 10,
                recurrence: .weeklyOn([.saturday])
            ),
            ChoreTemplate(
                id: "everyday.laundry",
                title: "Put your washing in the basket",
                category: .laundry,
                points: 5,
                recurrence: .daily
            ),
        ]
    )

    /// The work a kitchen generates whether anybody planned for it or not.
    public static let kitchen = ChorePack(
        id: "kitchen",
        name: "Kitchen",
        summary: "The jobs that come round whether anyone planned them or not.",
        symbolName: "fork.knife",
        templates: [
            ChoreTemplate(
                id: "kitchen.wash",
                title: "Wash up after dinner",
                category: .kitchen,
                points: 15,
                recurrence: .daily,
                suitableFrom: .teen
            ),
            ChoreTemplate(
                id: "kitchen.surfaces",
                title: "Wipe the kitchen surfaces",
                category: .kitchen,
                points: 10,
                recurrence: .daily
            ),
            ChoreTemplate(
                id: "kitchen.bins",
                title: "Take the bins out",
                notes: "Check which one is due before you drag it down.",
                category: .kitchen,
                points: 15,
                recurrence: .weeklyOn([.wednesday]),
                suitableFrom: .teen
            ),
            ChoreTemplate(
                id: "kitchen.recycling",
                title: "Sort the recycling",
                category: .kitchen,
                points: 10,
                recurrence: .weeklyOn([.sunday])
            ),
            ChoreTemplate(
                id: "kitchen.fridge",
                title: "Clear out the fridge",
                notes: "Before the shop, not after.",
                category: .kitchen,
                points: 20,
                recurrence: .weeklyOn([.friday]),
                suitableFrom: .adult
            ),
        ]
    )

    /// The hour on a Saturday that keeps the rest of the week survivable.
    public static let weekendReset = ChorePack(
        id: "weekend-reset",
        name: "Weekend reset",
        summary: "An hour on Saturday that buys back the week.",
        symbolName: "arrow.clockwise",
        templates: [
            ChoreTemplate(
                id: "reset.hoover",
                title: "Hoover downstairs",
                category: .cleaning,
                points: 20,
                recurrence: .weeklyOn([.saturday]),
                suitableFrom: .teen
            ),
            ChoreTemplate(
                id: "reset.bathroom",
                title: "Clean the bathroom",
                category: .cleaning,
                points: 25,
                recurrence: .weeklyOn([.saturday]),
                suitableFrom: .teen
            ),
            ChoreTemplate(
                id: "reset.sheets",
                title: "Change the bed sheets",
                category: .laundry,
                points: 15,
                recurrence: .fortnightlyOn([.saturday])
            ),
            ChoreTemplate(
                id: "reset.washing",
                title: "Put a wash on",
                category: .laundry,
                points: 10,
                recurrence: .weeklyOn([.saturday])
            ),
            ChoreTemplate(
                id: "reset.plants",
                title: "Water the plants",
                category: .outdoor,
                points: 5,
                recurrence: .weeklyOn([.sunday])
            ),
        ]
    )

    /// For a household with something that has to be fed whether or not anyone
    /// feels like it.
    public static let pets = ChorePack(
        id: "pets",
        name: "Pets",
        summary: "For the member of the family who can't do their own chores.",
        symbolName: "pawprint",
        templates: [
            ChoreTemplate(
                id: "pets.feed.morning",
                title: "Feed the pets",
                category: .pets,
                points: 10,
                recurrence: .daily
            ),
            ChoreTemplate(
                id: "pets.water",
                title: "Fresh water for the pets",
                category: .pets,
                points: 5,
                recurrence: .daily
            ),
            ChoreTemplate(
                id: "pets.walk",
                title: "Walk the dog",
                category: .pets,
                points: 15,
                recurrence: .daily,
                suitableFrom: .teen
            ),
            ChoreTemplate(
                id: "pets.litter",
                title: "Change the litter tray",
                category: .pets,
                points: 15,
                recurrence: .everyOtherDay,
                suitableFrom: .teen
            ),
            ChoreTemplate(
                id: "pets.brush",
                title: "Brush the dog",
                category: .pets,
                points: 10,
                recurrence: .weeklyOn([.sunday])
            ),
        ]
    )

    /// Term-time chores, which are mostly about the night before.
    public static let school = ChorePack(
        id: "school",
        name: "School week",
        summary: "The things that go wrong at eight in the morning.",
        symbolName: "backpack",
        templates: [
            ChoreTemplate(
                id: "school.bag",
                title: "Pack your school bag",
                notes: "The night before. That is the whole point.",
                category: .homework,
                points: 10,
                recurrence: .weeklyOn([.sunday, .monday, .tuesday, .wednesday, .thursday])
            ),
            ChoreTemplate(
                id: "school.homework",
                title: "Homework",
                category: .homework,
                points: 15,
                recurrence: .weeklyOn([.monday, .tuesday, .wednesday, .thursday])
            ),
            ChoreTemplate(
                id: "school.uniform",
                title: "Uniform out for tomorrow",
                category: .laundry,
                points: 5,
                recurrence: .weeklyOn([.sunday, .monday, .tuesday, .wednesday, .thursday])
            ),
            ChoreTemplate(
                id: "school.reading",
                title: "Reading practice",
                category: .homework,
                points: 10,
                recurrence: .daily
            ),
            ChoreTemplate(
                id: "school.kit",
                title: "PE kit in the wash",
                category: .laundry,
                points: 5,
                recurrence: .weeklyOn([.friday])
            ),
        ]
    )

    /// The packs worth offering a household, given who is in it.
    ///
    /// A pack with nothing left in it after the roles are applied is dropped
    /// rather than shown empty, because a card that installs nothing is a card
    /// that will be tapped once and never trusted again.
    ///
    /// - Parameter roles: The roles present in the household.
    /// - Returns: The packs with at least one usable template.
    public static func suggested(for roles: some Collection<MemberRole>) -> [ChorePack] {
        all.filter { !$0.templates(for: roles).isEmpty }
    }

    /// Finds a pack by its identifier.
    public static func pack(_ id: String) -> ChorePack? {
        all.first { $0.id == id }
    }
}

// MARK: - Recurrences the catalogue needs

extension RecurrenceRule {
    /// Weekly on the given days.
    ///
    /// Non-throwing, unlike ``weekly(on:everyWeeks:)``, because the catalogue
    /// is a compile-time constant: a static list that could throw would have to
    /// be built lazily and force-tried at every use, which trades a rule that
    /// cannot be wrong for a crash that can happen anywhere.
    fileprivate static func weeklyOn(_ weekdays: Set<Weekday>) -> RecurrenceRule {
        // Force-tried against a non-empty literal set, which is the one thing
        // weekly validation checks.
        try! RecurrenceRule(frequency: .weekly, weekdays: weekdays)
    }

    /// Every other week on the given days.
    fileprivate static func fortnightlyOn(_ weekdays: Set<Weekday>) -> RecurrenceRule {
        try! RecurrenceRule(frequency: .weekly, interval: 2, weekdays: weekdays)
    }

    /// Every second day.
    fileprivate static var everyOtherDay: RecurrenceRule {
        try! RecurrenceRule(frequency: .daily, interval: 2)
    }
}
