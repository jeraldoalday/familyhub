import Foundation

/// One search box over everything a household has.
///
/// A family does not think in tabs. Somebody who remembers the word "swimming"
/// wants the lesson on Thursday, the kit bag on the shopping list, and the
/// chore about the wet towels — and asking them which of six screens that word
/// lives on is asking them to know how the app is built. Six per-screen
/// filters, each written slightly differently, is also six places for the same
/// folding bug to be fixed five times.
///
/// So matching is answered once, here, over the snapshot the app already holds.
/// There is no index to keep fresh: a household is a dozen members, a few dozen
/// chores, and a year of records, which is small enough that scanning it is
/// faster than any structure that would have to be invalidated on every write.
///
/// What it does not do is rank by cleverness. The order is: exact name, then
/// name starting with what was typed, then a word inside the name starting with
/// it, then anything else containing it. That ordering is predictable, which
/// matters more than being right on the margins — a search box whose top result
/// moves for reasons the person cannot see is one they stop trusting.
public struct HouseholdSearch: Sendable {

    private let snapshot: HouseholdSnapshot

    /// Creates a search over a household.
    public init(snapshot: HouseholdSnapshot) {
        self.snapshot = snapshot
    }

    // MARK: - What a hit is

    /// The kinds of record a search can turn up.
    ///
    /// The order of the cases is the order equally-good hits are shown in, so
    /// it is the priority a household actually has: people first, then the work
    /// and the plan, then the things on lists.
    public enum Kind: Int, Sendable, CaseIterable, Comparable {
        case member
        case chore
        case event
        case meal
        case reward
        case shoppingItem

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// The section heading a result appears under.
        public var label: String {
            switch self {
            case .member: "People"
            case .chore: "Chores"
            case .event: "Calendar"
            case .meal: "Meals"
            case .reward: "Rewards"
            case .shoppingItem: "Shopping"
            }
        }
    }

    /// The record a result points at.
    ///
    /// Carries the whole value rather than an identifier, because the caller
    /// already has the snapshot this came from and a second lookup is a second
    /// chance to look the wrong thing up.
    public enum Subject: Sendable, Hashable {
        case member(Member)
        case chore(Chore)
        case event(CalendarEvent)
        case meal(PlannedMeal)
        case reward(Reward)
        case shoppingItem(ShoppingItem)

        /// Which kind of record this is.
        public var kind: Kind {
            switch self {
            case .member: .member
            case .chore: .chore
            case .event: .event
            case .meal: .meal
            case .reward: .reward
            case .shoppingItem: .shoppingItem
            }
        }
    }

    /// How well a hit matched, best first.
    ///
    /// A closed set rather than a score. A number invites tuning that nobody
    /// can explain afterwards; four named strengths can be reasoned about by
    /// whoever next wonders why the dentist came above the dishes.
    public enum Strength: Int, Sendable, Comparable {
        /// The whole name is what was typed.
        case exact = 0
        /// The name begins with what was typed.
        case prefix = 1
        /// A word inside the name begins with what was typed.
        case wordPrefix = 2
        /// It appears somewhere — in the name, or in notes or a location.
        case contains = 3

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One thing the household has that matched.
    public struct Result: Sendable, Identifiable {
        /// The record itself.
        public let subject: Subject

        /// How it matched.
        public let strength: Strength

        /// The line to show.
        public let title: String

        /// The second line, when there is something worth saying.
        public let detail: String?

        /// Whether the record has been archived, cancelled, withdrawn, or
        /// otherwise put away. Kept rather than filtered so a household can
        /// find the chore it retired in March, and reported so a row can say
        /// as much rather than pretending it is live.
        public let isRetired: Bool

        /// Which kind of record this is.
        public var kind: Kind { subject.kind }

        /// A stable identity across searches, so a results list animates
        /// rather than rebuilding.
        public var id: String {
            switch subject {
            case .member(let value): "member:\(value.id)"
            case .chore(let value): "chore:\(value.id)"
            case .event(let value): "event:\(value.id)"
            case .meal(let value): "meal:\(value.id)"
            case .reward(let value): "reward:\(value.id)"
            case .shoppingItem(let value): "item:\(value.id)"
            }
        }
    }

    /// How much of the household to look at.
    public enum Scope: Sendable {
        /// Only what is still in use. What a search box should do by default:
        /// a family looking for "bins" wants the chore they have, not the four
        /// they tried and archived.
        case active
        /// Everything, including archived chores, cancelled events, withdrawn
        /// rewards, members who have left, and things already bought.
        case everything
    }

    // MARK: - Searching

    /// Everything matching `query`, best match first.
    ///
    /// - Parameters:
    ///   - query: What was typed. Folded for case and accents, so "banh mi"
    ///     finds "Bánh mì" and vice versa.
    ///   - scope: Whether to look at retired records too.
    ///   - limit: The most results to return. A search box shows a handful;
    ///     assembling four hundred to display eight is work nobody sees.
    /// - Returns: Results ordered by how well they matched, then by kind, then
    ///   alphabetically. A query of fewer than two characters returns nothing,
    ///   because one letter matches most of a household and answering it is
    ///   slower and less useful than waiting for the second keystroke.
    public func results(
        for query: String,
        scope: Scope = .active,
        limit: Int = 25
    ) -> [Result] {
        let needle = HouseholdSearch.fold(query)
        guard needle.count >= HouseholdSearch.minimumQueryLength, limit > 0 else { return [] }

        var results: [Result] = []
        results.reserveCapacity(limit)

        for member in snapshot.members where scope == .everything || member.isActive {
            guard let strength = HouseholdSearch.match(needle, in: member.name.value) else {
                continue
            }
            results.append(
                Result(
                    subject: .member(member),
                    strength: strength,
                    title: member.name.value,
                    detail: member.role.label,
                    isRetired: !member.isActive
                )
            )
        }

        for chore in snapshot.chores where scope == .everything || chore.isActive {
            guard
                let strength = HouseholdSearch.match(
                    needle, in: chore.title.value, alsoIn: [chore.notes?.value]
                )
            else { continue }
            results.append(
                Result(
                    subject: .chore(chore),
                    strength: strength,
                    title: chore.title.value,
                    detail: snapshot.scheduleSummary(of: chore),
                    isRetired: !chore.isActive
                )
            )
        }

        for event in snapshot.events where scope == .everything || event.isActive {
            guard
                let strength = HouseholdSearch.match(
                    needle,
                    in: event.title.value,
                    alsoIn: [event.notes?.value, event.location?.value]
                )
            else { continue }
            results.append(
                Result(
                    subject: .event(event),
                    strength: strength,
                    title: event.title.value,
                    detail: event.summary(members: snapshot.members),
                    isRetired: !event.isActive
                )
            )
        }

        for meal in snapshot.plannedMeals {
            // An ingredient counts as a match, which is the whole point of a
            // search that crosses screens: "what were we doing with the
            // aubergine" is a question about the meal plan that nobody would
            // think to ask the meal plan.
            guard
                let strength = HouseholdSearch.match(
                    needle,
                    in: meal.title.value,
                    alsoIn: meal.ingredientNames.map { $0 } + [meal.notes?.value]
                )
            else { continue }
            results.append(
                Result(
                    subject: .meal(meal),
                    strength: strength,
                    title: meal.title.value,
                    detail: meal.summary,
                    isRetired: false
                )
            )
        }

        for reward in snapshot.rewards where scope == .everything || reward.isActive {
            guard let strength = HouseholdSearch.match(needle, in: reward.name.value) else {
                continue
            }
            results.append(
                Result(
                    subject: .reward(reward),
                    strength: strength,
                    title: reward.name.value,
                    detail: "\(reward.cost) points",
                    isRetired: !reward.isActive
                )
            )
        }

        for item in snapshot.shoppingItems where scope == .everything || item.isPending {
            guard
                let strength = HouseholdSearch.match(
                    needle, in: item.name.value, alsoIn: [item.note?.value]
                )
            else { continue }
            results.append(
                Result(
                    subject: .shoppingItem(item),
                    strength: strength,
                    title: item.name.value,
                    detail: item.category.label,
                    isRetired: !item.isPending
                )
            )
        }

        return Array(results.sorted(by: HouseholdSearch.order).prefix(limit))
    }

    /// The results grouped into the sections a results screen shows, in kind
    /// order, each section keeping the ranking the flat list gave it.
    ///
    /// Grouped here rather than in the view because the alternative is every
    /// screen inventing its own section order, and two screens ordering the
    /// same six sections differently is a bug nobody reports and everybody
    /// notices.
    public func sections(
        for query: String,
        scope: Scope = .active,
        limit: Int = 25
    ) -> [(kind: Kind, results: [Result])] {
        Dictionary(grouping: results(for: query, scope: scope, limit: limit), by: \.kind)
            .sorted { $0.key < $1.key }
            .map { (kind: $0, results: $1) }
    }

    // MARK: - Matching

    /// The shortest query worth answering.
    public static let minimumQueryLength = 2

    /// How `needle` matches `name`, or `nil` if it does not.
    ///
    /// - Parameters:
    ///   - needle: An already-folded query.
    ///   - name: The record's own name, which is what the strong matches are
    ///     measured against.
    ///   - secondary: Secondary text — notes, a location, an ingredient list.
    ///     These can only ever produce a ``Strength/contains`` hit: a chore
    ///     whose *notes* happen to start with the query is not a better answer
    ///     than one actually called that.
    /// - Returns: The strength, or `nil` when nothing matched.
    static func match(
        _ needle: String,
        in name: String,
        alsoIn secondary: [String?] = []
    ) -> Strength? {
        let folded = fold(name)
        if folded == needle { return .exact }
        if folded.hasPrefix(needle) { return .prefix }
        if folded.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
            return .wordPrefix
        }
        if folded.contains(needle) { return .contains }
        for text in secondary.compactMap({ $0 }) where fold(text).contains(needle) {
            return .contains
        }
        return nil
    }

    /// The comparable form of a piece of text: folded for case and accents,
    /// trimmed, with runs of whitespace collapsed so "  bin   day " and
    /// "bin day" are the same query.
    static func fold(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The order results are shown in: strongest match, then kind, then live
    /// records before retired ones, then alphabetically, then by identity.
    ///
    /// The last of those looks redundant and is not. Two chores can share a
    /// title — households really do have "Tidy your room" once per child — and
    /// without a final tiebreak the pair swap places between reads of the same
    /// query, which reads as the list flickering.
    private static func order(_ lhs: Result, _ rhs: Result) -> Bool {
        if lhs.strength != rhs.strength { return lhs.strength < rhs.strength }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.isRetired != rhs.isRetired { return !lhs.isRetired }
        let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }
}

// MARK: - Snapshot convenience

extension HouseholdSnapshot {
    /// Search over this household, ready to query.
    public var search: HouseholdSearch {
        HouseholdSearch(snapshot: self)
    }
}
