import Foundation

/// A recurring piece of household work.
///
/// A chore is a *template*, not a to-do item. It describes what needs doing and
/// how often; the individual days it lands on are derived by
/// ``RecurrenceEngine`` rather than stored. That distinction keeps the database
/// small — a daily chore is one row, not 3,650 — and it means editing "every
/// Monday" to "every Tuesday" is a single write instead of a migration across
/// every future row.
public struct Chore: Entity {
    public let id: Identifier<Chore>

    /// The household this chore belongs to.
    public let householdID: Identifier<Household>

    /// What needs doing.
    public private(set) var title: ValidatedText

    /// Optional detail — "use the blue cloth, not the sponge".
    public private(set) var notes: ValidatedText?

    /// Who is responsible.
    public private(set) var assignment: Assignment

    /// Points earned for completing one occurrence.
    public private(set) var points: Int

    /// The first day the chore can occur.
    public private(set) var startDate: Date

    /// How often it comes around.
    public private(set) var recurrence: RecurrenceRule

    /// Days the family explicitly skipped — a holiday, a week away.
    ///
    /// Stored as exceptions to the rule rather than by editing the rule, so
    /// "we skipped bin day that once" does not permanently change the schedule.
    public private(set) var skippedDays: Set<Date>

    /// A grouping used for filtering and for the icon shown on the row.
    public private(set) var category: Category

    /// Set when the chore is retired.
    ///
    /// Archived rather than deleted, because completions reference the chore
    /// and a family's history should survive a spring clean of the chore list.
    public private(set) var archivedAt: Date?

    /// Who created it, for the audit trail.
    public let createdBy: Identifier<Member>

    /// When it was created.
    public let createdAt: Date

    /// Whether the chore is still in rotation.
    public var isActive: Bool { archivedAt == nil }

    /// Creates a chore.
    ///
    /// - Throws: ``DomainError/blank(field:)``,
    ///   ``DomainError/tooLong(field:limit:)``, or
    ///   ``DomainError/outOfRange(field:allowed:)`` if the points are unreasonable.
    public init(
        id: Identifier<Chore> = Identifier(),
        householdID: Identifier<Household>,
        title: String,
        notes: String? = nil,
        assignment: Assignment = .anyone,
        points: Int = 10,
        startDate: Date,
        recurrence: RecurrenceRule = .daily,
        skippedDays: Set<Date> = [],
        category: Category = .other,
        archivedAt: Date? = nil,
        createdBy: Identifier<Member>,
        createdAt: Date
    ) throws {
        self.id = id
        self.householdID = householdID
        self.title = try ValidatedText(
            title,
            field: .choreTitle,
            limit: Limits.choreTitleLength
        )
        self.notes = try ValidatedText.optional(
            notes,
            field: .choreNotes,
            limit: Limits.notesLength
        )
        self.assignment = assignment
        self.points = try points.validated(in: Limits.pointsPerChore, field: .points)
        self.startDate = startDate
        self.recurrence = recurrence
        self.skippedDays = skippedDays
        self.category = category
        self.archivedAt = archivedAt
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

// MARK: - Assignment

extension Chore {
    /// Who is responsible for a chore.
    public enum Assignment: Hashable, Sendable, Codable {
        /// Anyone in the household may claim it. Useful for shared work like
        /// "empty the dishwasher" where whoever gets there first should do it.
        case anyone

        /// One specific person, every time.
        case member(Identifier<Member>)

        /// Taken in turn, advancing one person per occurrence.
        ///
        /// This is the feature that stops the weekly argument. The rota is
        /// derived from the occurrence's position in the sequence rather than
        /// from a stored "whose turn is it" counter, so it cannot drift out of
        /// step when a device syncs late or a completion is deleted.
        case rotating([Identifier<Member>])

        /// The members this assignment can ever fall to.
        public var candidateMemberIDs: [Identifier<Member>] {
            switch self {
            case .anyone: []
            case .member(let id): [id]
            case .rotating(let ids): ids
            }
        }

        /// Whether the assignment names a specific person.
        public var isSpecific: Bool {
            switch self {
            case .anyone: false
            case .member, .rotating: true
                }
        }
    }

    /// Who owns the occurrence at `index` in the chore's sequence.
    ///
    /// - Parameter index: The zero-based position of the occurrence, as
    ///   produced by ``RecurrenceEngine``.
    /// - Returns: The responsible member, or `nil` when the chore is open to
    ///   anyone.
    public func assignee(forOccurrenceIndex index: Int) -> Identifier<Member>? {
        switch assignment {
        case .anyone:
            return nil
        case .member(let id):
            return id
        case .rotating(let ids):
            guard !ids.isEmpty else { return nil }
            // Modulo on a non-negative index; the engine never produces
            // negative positions, and clamping here keeps a corrupt index from
            // trapping in a list row.
            return ids[max(0, index) % ids.count]
        }
    }

    /// Whether `memberID` may be the one to tick this occurrence off.
    public func isAssigned(_ memberID: Identifier<Member>, occurrenceIndex: Int) -> Bool {
        switch assignment {
        case .anyone:
            return true
        case .member, .rotating:
            return assignee(forOccurrenceIndex: occurrenceIndex) == memberID
        }
    }
}

// MARK: - Category

extension Chore {
    /// A grouping for filtering and iconography.
    ///
    /// A fixed set rather than free-form tags. Households do not maintain
    /// taxonomies, and a fixed set means every chore gets a sensible icon and
    /// colour without anyone configuring anything.
    public enum Category: String, Codable, Sendable, CaseIterable, Identifiable {
        case kitchen
        case cleaning
        case laundry
        case outdoor
        case pets
        case shopping
        case homework
        case selfCare
        case other

        public var id: String { rawValue }

        /// The display name.
        public var label: String {
            switch self {
            case .kitchen: "Kitchen"
            case .cleaning: "Cleaning"
            case .laundry: "Laundry"
            case .outdoor: "Outdoor"
            case .pets: "Pets"
            case .shopping: "Shopping"
            case .homework: "Homework"
            case .selfCare: "Self-care"
            case .other: "Other"
            }
        }

        /// The SF Symbol shown on the chore row.
        public var symbolName: String {
            switch self {
            case .kitchen: "fork.knife"
            case .cleaning: "bubbles.and.sparkles"
            case .laundry: "washer"
            case .outdoor: "leaf"
            case .pets: "pawprint"
            case .shopping: "cart"
            case .homework: "book"
            case .selfCare: "heart"
            case .other: "checkmark.circle"
            }
        }
    }
}

// MARK: - Scheduling

extension Chore {
    /// The days this chore falls on inside `range`.
    public func occurrences(
        in range: ClosedRange<Date>,
        using engine: RecurrenceEngine,
        maximum: Int = 500
    ) -> [Date] {
        guard isActive else { return [] }
        return engine.occurrences(
            of: recurrence,
            startingOn: startDate,
            in: range,
            skipping: skippedDays,
            maximum: maximum
        )
    }

    /// The next day this chore falls on after `date`, if any.
    public func nextOccurrence(after date: Date, using engine: RecurrenceEngine) -> Date? {
        guard isActive else { return nil }
        return engine.nextOccurrence(
            of: recurrence,
            startingOn: startDate,
            after: date,
            skipping: skippedDays
        )
    }

    /// Whether the chore falls on `date`.
    public func occurs(on date: Date, using engine: RecurrenceEngine) -> Bool {
        guard isActive else { return false }
        return engine.occurs(
            recurrence,
            startingOn: startDate,
            on: date,
            skipping: skippedDays
        )
    }

    /// The zero-based position of `date` in the chore's sequence, used to
    /// resolve a rotating assignment.
    ///
    /// Counts from the chore's start rather than from the visible window, so
    /// the rota is identical on every device no matter what each is displaying.
    /// Exceptions are included in the count, because skipping a week should
    /// advance the rota — otherwise the person whose turn was skipped is
    /// silently made to do it again.
    public func occurrenceIndex(of date: Date, using engine: RecurrenceEngine) -> Int? {
        let target = engine.calendar.startOfDay(for: date)
        guard target >= engine.calendar.startOfDay(for: startDate) else { return nil }

        let all = engine.occurrences(
            of: recurrence,
            startingOn: startDate,
            in: startDate...target,
            maximum: Int.max
        )
        guard let position = all.lastIndex(of: target) else { return nil }
        return position
    }
}

// MARK: - Mutation

extension Chore {
    /// Returns a copy with a new title.
    public func retitled(to newTitle: String) throws -> Chore {
        var copy = self
        copy.title = try ValidatedText(
            newTitle,
            field: .choreTitle,
            limit: Limits.choreTitleLength
        )
        return copy
    }

    /// Returns a copy with different notes, or none.
    public func withNotes(_ newNotes: String?) throws -> Chore {
        var copy = self
        copy.notes = try ValidatedText.optional(
            newNotes,
            field: .choreNotes,
            limit: Limits.notesLength
        )
        return copy
    }

    /// Returns a copy assigned differently.
    public func assigned(_ newAssignment: Assignment) -> Chore {
        var copy = self
        copy.assignment = newAssignment
        return copy
    }

    /// Returns a copy worth a different number of points.
    public func worth(_ newPoints: Int) throws -> Chore {
        var copy = self
        copy.points = try newPoints.validated(in: Limits.pointsPerChore, field: .points)
        return copy
    }

    /// Returns a copy on a different schedule.
    public func rescheduled(
        startingOn newStart: Date? = nil,
        recurrence newRecurrence: RecurrenceRule? = nil
    ) -> Chore {
        var copy = self
        if let newStart { copy.startDate = newStart }
        if let newRecurrence { copy.recurrence = newRecurrence }
        return copy
    }

    /// Returns a copy in a different category.
    public func inCategory(_ newCategory: Category) -> Chore {
        var copy = self
        copy.category = newCategory
        return copy
    }

    /// Returns a copy with `date` skipped.
    public func skipping(_ date: Date, calendar: Calendar) -> Chore {
        var copy = self
        copy.skippedDays.insert(calendar.startOfDay(for: date))
        return copy
    }

    /// Returns a copy with `date` no longer skipped.
    public func unskipping(_ date: Date, calendar: Calendar) -> Chore {
        var copy = self
        copy.skippedDays.remove(calendar.startOfDay(for: date))
        return copy
    }

    /// Returns a copy retired from the rotation.
    public func archived(at date: Date) -> Chore {
        var copy = self
        copy.archivedAt = date
        return copy
    }

    /// Returns a copy restored to the rotation.
    public func unarchived() -> Chore {
        var copy = self
        copy.archivedAt = nil
        return copy
    }
}
