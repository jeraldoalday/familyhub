import Foundation

/// Turns a shopping list into text somebody can paste somewhere else.
///
/// The other half of ``ShoppingListParser``, and it exists for the same reason.
/// A family's shopping does not live in one app: somebody is in the shop
/// without the phone that has the list, a grandparent is picking a few things
/// up and is not going to be invited into the household, and a partner asks
/// "what do we need?" in a chat window. Answering any of those by reading
/// twenty items aloud is how a shared list stops being shared.
///
/// Two decisions shape the output. It is plain text with no formatting, because
/// the destination is a message box and anything cleverer arrives as literal
/// asterisks. And the flat style is deliberately written in the dialect the
/// parser reads, so a list sent to somebody who *does* have the app can be
/// pasted straight back in — the same items, the same quantities, in the same
/// aisles.
public enum ShoppingListText {

    /// What to include, and how to lay it out.
    public struct Options: Sendable, Hashable {
        /// Whether to print aisle headings and group the items under them.
        public var groupsByAisle: Bool

        /// Whether items already in the trolley appear, struck through with a
        /// tick rather than silently dropped.
        public var includesPurchased: Bool

        /// Whether an item's note travels with it.
        public var includesNotes: Bool

        /// Whether the list's own name appears at the top.
        public var includesHeading: Bool

        /// Creates a set of options.
        public init(
            groupsByAisle: Bool = true,
            includesPurchased: Bool = false,
            includesNotes: Bool = true,
            includesHeading: Bool = true
        ) {
            self.groupsByAisle = groupsByAisle
            self.includesPurchased = includesPurchased
            self.includesNotes = includesNotes
            self.includesHeading = includesHeading
        }

        /// What somebody sends to a person: headings, notes, and only the
        /// things still to buy.
        ///
        /// Bought items are left out rather than shown ticked, because the
        /// recipient is standing in a shop and a list of things they do not
        /// need is a list they have to read anyway.
        public static let message = Options()

        /// The form that survives being pasted back into the app.
        ///
        /// Flat, un-annotated, one item per line. Aisle headings would be read
        /// as items — the parser has no way to tell "Bakery" the section from
        /// "bakery" the thing somebody wants — and a note in brackets becomes
        /// part of the name it was describing.
        public static let interchange = Options(
            groupsByAisle: false,
            includesPurchased: false,
            includesNotes: false,
            includesHeading: false
        )
    }

    /// Renders a list as text.
    ///
    /// - Parameters:
    ///   - items: The items to render. Items belonging to other lists are the
    ///     caller's business to filter; this renders what it is given.
    ///   - list: The list they came from, for the heading. Optional, because a
    ///     "here's what we need" message does not always want one.
    ///   - options: What to include.
    /// - Returns: The text, or an empty string when there is nothing to say.
    ///   Empty rather than "Nothing to buy", because only the caller knows
    ///   whether this is going into a message that needs a sentence or a
    ///   pasteboard that should stay untouched.
    public static func render(
        _ items: some Collection<ShoppingItem>,
        from list: ShoppingList? = nil,
        options: Options = .message
    ) -> String {
        let wanted = options.includesPurchased ? Array(items) : items.pending
        guard !wanted.isEmpty else { return "" }

        var lines: [String] = []
        if options.includesHeading, let list {
            lines.append(heading(of: list))
            lines.append("")
        }

        if options.groupsByAisle {
            // The same grouping the shopping screen uses, so the message and
            // the app agree about which aisle a thing is in. A person reading
            // one and shopping from the other is the whole audience.
            for (category, sectioned) in wanted.groupedByAisle() {
                lines.append(category.label)
                lines.append(contentsOf: sectioned.map { line(for: $0, options: options) })
                lines.append("")
            }
            // The trailing separator after the last section is one blank line
            // too many; every other one is doing real work.
            if lines.last?.isEmpty == true { lines.removeLast() }
        } else {
            lines.append(
                contentsOf:
                    wanted
                    .sorted(by: ShoppingItem.displayOrder)
                    .map { line(for: $0, options: options) }
            )
        }

        return lines.joined(separator: "\n")
    }

    /// One item as a line.
    ///
    /// The quantity leads and the unit follows it, which is both how a person
    /// writes a list and what ``ShoppingListParser`` reads back. A quantity of
    /// one is left off unless a unit names it — "Milk" rather than "1 Milk",
    /// but "1 kg Potatoes" rather than "kg Potatoes", which is not a sentence.
    private static func line(for item: ShoppingItem, options: Options) -> String {
        var parts: [String] = []
        if !item.isPending { parts.append("✓") }
        if item.quantity > 1 || item.unit != nil { parts.append("\(item.quantity)") }
        if let unit = item.unit { parts.append(unit) }
        parts.append(item.name.value)

        var line = parts.joined(separator: " ")
        if options.includesNotes, let note = item.note {
            line += " (\(note.value))"
        }
        return line
    }

    /// The list's name, with its emoji when it has one.
    private static func heading(of list: ShoppingList) -> String {
        guard let emoji = list.emoji else { return list.name.value }
        return "\(emoji) \(list.name.value)"
    }
}

// MARK: - Snapshot convenience

extension HouseholdSnapshot {
    /// One of the household's lists, as text to send somebody.
    ///
    /// - Parameters:
    ///   - listID: The list to render.
    ///   - options: What to include.
    /// - Returns: The text, or an empty string when the list is empty or gone.
    ///   A missing list is not an error here: the message being composed is
    ///   about shopping, and throwing at the point somebody taps share would
    ///   turn another device's tidy-up into an alert.
    public func shoppingListText(
        for listID: Identifier<ShoppingList>,
        options: ShoppingListText.Options = .message
    ) -> String {
        ShoppingListText.render(
            items(on: listID),
            from: shoppingLists.first { $0.id == listID },
            options: options
        )
    }
}
