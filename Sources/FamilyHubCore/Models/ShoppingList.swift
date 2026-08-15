import Foundation

/// A shared list the whole household can add to.
///
/// The list and its items are separate entities rather than one document with a
/// nested array. Two people standing in different aisles both tick things off,
/// and item-level records merge cleanly where a whole-list document would make
/// each save clobber the other's.
public struct ShoppingList: Entity {
    public let id: Identifier<ShoppingList>

    /// The household this list belongs to.
    public let householdID: Identifier<Household>

    /// What the list is for — "Groceries", "Hardware store", "Party".
    public private(set) var name: ValidatedText

    /// An emoji shown on the list card.
    public private(set) var emoji: String?

    /// Whether the list is the household's default, receiving items added from
    /// the home screen and from Siri without a list being named.
    public private(set) var isDefault: Bool

    /// Set when the list is put away.
    public private(set) var archivedAt: Date?

    /// Who created it.
    public let createdBy: Identifier<Member>

    /// When it was created.
    public let createdAt: Date

    /// Whether the list is still in use.
    public var isActive: Bool { archivedAt == nil }

    /// Creates a shopping list.
    ///
    /// - Throws: ``DomainError/blank(field:)`` or
    ///   ``DomainError/tooLong(field:limit:)``.
    public init(
        id: Identifier<ShoppingList> = Identifier(),
        householdID: Identifier<Household>,
        name: String,
        emoji: String? = nil,
        isDefault: Bool = false,
        archivedAt: Date? = nil,
        createdBy: Identifier<Member>,
        createdAt: Date
    ) throws {
        self.id = id
        self.householdID = householdID
        self.name = try ValidatedText(name, field: .listName, limit: Limits.choreTitleLength)
        self.emoji = emoji
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(\.first)
            .map(String.init)
        self.isDefault = isDefault
        self.archivedAt = archivedAt
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

extension ShoppingList {
    /// Returns a copy with a new name.
    public func renamed(to newName: String) throws -> ShoppingList {
        var copy = self
        copy.name = try ValidatedText(newName, field: .listName, limit: Limits.choreTitleLength)
        return copy
    }

    /// Returns a copy marked as the household's default list.
    public func asDefault(_ newValue: Bool) -> ShoppingList {
        var copy = self
        copy.isDefault = newValue
        return copy
    }

    /// Returns a copy put away.
    public func archived(at date: Date) -> ShoppingList {
        var copy = self
        copy.archivedAt = date
        return copy
    }

    /// Returns a copy brought back into use.
    public func unarchived() -> ShoppingList {
        var copy = self
        copy.archivedAt = nil
        return copy
    }
}

// MARK: - Items

/// One thing to buy.
public struct ShoppingItem: Entity {
    public let id: Identifier<ShoppingItem>

    /// The list it sits on.
    public let listID: Identifier<ShoppingList>

    /// The household, denormalised so a household's items can be counted
    /// without walking every list.
    public let householdID: Identifier<Household>

    /// What to buy.
    public private(set) var name: ValidatedText

    /// How many.
    public private(set) var quantity: Int

    /// An optional unit — "kg", "packs", "bottles".
    public private(set) var unit: String?

    /// The aisle grouping, which determines the section it appears under.
    public private(set) var category: Category

    /// Free-text detail — "the oat one, not the almond".
    public private(set) var note: ValidatedText?

    /// Who added it, so the person in the shop knows who to ask.
    public let addedBy: Identifier<Member>

    /// When it was added.
    public let addedAt: Date

    /// Who ticked it off, and when.
    public private(set) var purchase: Purchase?

    /// Whether the item is still needed.
    public var isPending: Bool { purchase == nil }

    /// Creates an item.
    ///
    /// - Throws: ``DomainError/blank(field:)``,
    ///   ``DomainError/tooLong(field:limit:)``, or
    ///   ``DomainError/outOfRange(field:allowed:)``.
    public init(
        id: Identifier<ShoppingItem> = Identifier(),
        listID: Identifier<ShoppingList>,
        householdID: Identifier<Household>,
        name: String,
        quantity: Int = 1,
        unit: String? = nil,
        category: Category = .other,
        note: String? = nil,
        addedBy: Identifier<Member>,
        addedAt: Date,
        purchase: Purchase? = nil
    ) throws {
        self.id = id
        self.listID = listID
        self.householdID = householdID
        self.name = try ValidatedText(name, field: .itemName, limit: Limits.choreTitleLength)
        self.quantity = try quantity.validated(in: Limits.itemQuantity, field: .quantity)
        let trimmedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.unit = (trimmedUnit?.isEmpty ?? true) ? nil : trimmedUnit
        self.category = category
        self.note = try ValidatedText.optional(note, field: .choreNotes, limit: Limits.notesLength)
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.purchase = purchase
    }

    /// Who bought an item and when.
    public struct Purchase: Hashable, Sendable, Codable {
        public let by: Identifier<Member>
        public let at: Date

        public init(by: Identifier<Member>, at: Date) {
            self.by = by
            self.at = at
        }
    }
}

// MARK: - Item category

extension ShoppingItem {
    /// The aisle an item belongs to.
    ///
    /// Grouping by aisle rather than by the order things were added is the
    /// difference between one pass through a shop and three. The set is fixed
    /// and ordered to match a typical supermarket layout.
    public enum Category: String, Codable, Sendable, CaseIterable, Identifiable, Comparable {
        case produce
        case bakery
        case dairy
        case meat
        case frozen
        case pantry
        case drinks
        case household
        case personal
        case other

        public var id: String { rawValue }

        /// Position in the aisle order, used to sort sections.
        public var aisleOrder: Int {
            Category.allCases.firstIndex(of: self) ?? Category.allCases.count
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.aisleOrder < rhs.aisleOrder
        }

        public var label: String {
            switch self {
            case .produce: "Fruit & veg"
            case .bakery: "Bakery"
            case .dairy: "Dairy"
            case .meat: "Meat & fish"
            case .frozen: "Frozen"
            case .pantry: "Pantry"
            case .drinks: "Drinks"
            case .household: "Household"
            case .personal: "Personal care"
            case .other: "Other"
            }
        }

        public var symbolName: String {
            switch self {
            case .produce: "carrot"
            case .bakery: "birthday.cake"
            case .dairy: "waterbottle"
            case .meat: "fish"
            case .frozen: "snowflake"
            case .pantry: "shippingbox"
            case .drinks: "cup.and.saucer"
            case .household: "house"
            case .personal: "shower"
            case .other: "bag"
            }
        }
    }
}

// MARK: - Item derived values and mutation

extension ShoppingItem {
    /// The quantity and unit as one string: "2 kg", "3", "1 bottle".
    public var quantityDescription: String {
        guard let unit else { return "\(quantity)" }
        return "\(quantity) \(unit)"
    }

    /// A key for spotting duplicates, folded for case and diacritics so
    /// "Milk", "milk", and "  MILK " collapse to one.
    public var duplicateKey: String { name.searchKey }

    /// Returns a copy marked bought.
    public func purchased(by memberID: Identifier<Member>, at date: Date) -> ShoppingItem {
        var copy = self
        copy.purchase = Purchase(by: memberID, at: date)
        return copy
    }

    /// Returns a copy put back on the list.
    public func unpurchased() -> ShoppingItem {
        var copy = self
        copy.purchase = nil
        return copy
    }

    /// Returns a copy with a different quantity.
    public func withQuantity(_ newQuantity: Int) throws -> ShoppingItem {
        var copy = self
        copy.quantity = try newQuantity.validated(in: Limits.itemQuantity, field: .quantity)
        return copy
    }

    /// Returns a copy in a different aisle.
    public func inCategory(_ newCategory: Category) -> ShoppingItem {
        var copy = self
        copy.category = newCategory
        return copy
    }

    /// Returns a copy with its quantity increased, clamped to the maximum.
    ///
    /// Used when someone adds an item already on the list: the quantity goes up
    /// rather than a second identical row appearing, which is what a person
    /// standing in the shop actually wants to see.
    public func incremented(by amount: Int = 1) -> ShoppingItem {
        var copy = self
        copy.quantity = min(Limits.itemQuantity.upperBound, quantity + max(0, amount))
        return copy
    }
}

// MARK: - Collections

extension Collection where Element == ShoppingItem {
    /// The items still to buy.
    public var pending: [ShoppingItem] { filter(\.isPending) }

    /// The items already in the trolley.
    public var purchased: [ShoppingItem] { filter { !$0.isPending } }

    /// Items grouped by aisle and sorted into shop order, with each section's
    /// items alphabetical.
    public func groupedByAisle() -> [(category: ShoppingItem.Category, items: [ShoppingItem])] {
        Dictionary(grouping: self, by: \.category)
            .sorted { $0.key < $1.key }
            .map { category, items in
                (
                    category: category,
                    items: items.sorted {
                        $0.name.value.localizedCaseInsensitiveCompare($1.name.value)
                            == .orderedAscending
                    }
                )
            }
    }

    /// The first pending item matching `name`, ignoring case and accents.
    ///
    /// Used before inserting, so adding "milk" to a list that already has
    /// "Milk" bumps the quantity instead of producing two rows that the person
    /// in the shop has to reconcile.
    public func pendingMatch(for name: String) -> ShoppingItem? {
        let key = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !key.isEmpty else { return nil }
        return first { $0.isPending && $0.duplicateKey == key }
    }
}
