import Foundation

/// Turns a block of typed or pasted text into items to add.
///
/// The list a family already has is rarely in the app. It is in a note, a text
/// message, the bottom of a recipe, or read out while somebody types. Making
/// them add twenty things one text field at a time is how a shared list stops
/// being shared: one person keeps using paper, and a list that is missing half
/// the shopping is worse than no list, because the person in the shop trusts it.
///
/// So a whole list can be pasted. What comes back are *drafts* rather than
/// items: no list, no household, no author, and nothing written. Whether the
/// household actually wants twenty rows is a decision for the screen showing
/// them, and a parser that writes what it guessed is a parser that cannot be
/// reviewed before it does.
public enum ShoppingListParser {

    /// One line of a pasted list, understood.
    public struct Draft: Sendable, Hashable {
        /// What to buy, with the quantity and unit taken out of it.
        public let name: String

        /// How many, defaulting to one when the line does not say.
        public let quantity: Int

        /// The unit, when the line named one.
        public let unit: String?

        /// The aisle, guessed from the name.
        public let category: ShoppingItem.Category

        /// The line it came from, kept so a review screen can show somebody
        /// what it made of what they wrote.
        public let source: String

        /// The folded name, for merging repeats within one paste.
        var key: String {
            name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }
    }

    /// The most lines read from one paste.
    ///
    /// Generous for a week's shopping and low enough that pasting a document by
    /// accident produces a reviewable screen rather than four hundred rows.
    public static let maximumLines = 100

    /// Reads a pasted list.
    ///
    /// Lines are split on newlines and semicolons but **not** on commas, which
    /// looks like an omission and is not: "Onion, red" and "Milk, the oat one"
    /// are how people write single items, and a parser that splits them
    /// produces two rows that are each wrong. A person who wants two items
    /// presses return.
    ///
    /// Repeats inside one paste are merged rather than duplicated — a recipe
    /// pasted twice should not produce two rows of onions — and the quantities
    /// add up, because in that case the count genuinely is a measurement rather
    /// than a guess.
    ///
    /// - Parameter text: What was pasted or typed.
    /// - Returns: One draft per distinct item, in the order first mentioned.
    public static func drafts(from text: String) -> [Draft] {
        var order: [String] = []
        var byKey: [String: Draft] = [:]

        for line in lines(of: text) {
            guard let draft = draft(from: line) else { continue }
            if let existing = byKey[draft.key] {
                byKey[draft.key] = Draft(
                    name: existing.name,
                    quantity: min(
                        Limits.itemQuantity.upperBound, existing.quantity + draft.quantity
                    ),
                    unit: existing.unit ?? draft.unit,
                    category: existing.category,
                    source: existing.source
                )
            } else {
                order.append(draft.key)
                byKey[draft.key] = draft
            }
        }

        return order.compactMap { byKey[$0] }
    }

    /// Reads one line, or `nil` when there is nothing in it to buy.
    ///
    /// - Parameter line: One line of the paste.
    /// - Returns: The draft, or `nil` for a blank line, a bullet on its own, or
    ///   a line that is nothing but a number.
    public static func draft(from line: String) -> Draft? {
        let source = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = stripMarkers(from: source).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }

        var quantity: Int?
        var unit: String?

        // "2 milk", "2x milk", "2 x milk".
        if let leading = count(in: words[0]) {
            quantity = leading
            words.removeFirst()
            if let first = words.first, first == "x" || first == "×" {
                words.removeFirst()
            }
            // "2 bottles of milk" — the unit only counts when something is left
            // to buy after it, so "2 bottles" stays an item called bottles.
            if words.count > 1, isUnit(words[0]) {
                unit = words.removeFirst()
                if words.first == "of" { words.removeFirst() }
            }
        } else if let trailing = words.count > 1 ? count(in: words[words.count - 1]) : nil,
            words[words.count - 1].lowercased().hasPrefix("x")
                || words[words.count - 1].lowercased().hasPrefix("×")
        {
            // "Milk x2".
            quantity = trailing
            words.removeLast()
        }

        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return Draft(
            name: name,
            // Clamped rather than refused. Somebody who wrote a thousand
            // apples has made a typo, and rejecting the line loses the apples
            // as well as the number.
            quantity: (quantity ?? 1).clamped(to: Limits.itemQuantity),
            unit: unit,
            category: ShoppingItem.Category.inferred(from: name),
            source: source
        )
    }

    // MARK: - Reading a line

    /// The text split into candidate lines.
    private static func lines(of text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isNewline || $0 == ";" })
            .prefix(maximumLines)
            .map(String.init)
    }

    /// The line with any list marker taken off the front.
    ///
    /// Bullets and numbering survive a copy out of a notes app and mean nothing
    /// here. An ordered marker is only stripped when the number is followed by
    /// a dot or a bracket, so "1. Milk" loses its numbering while "2 milk"
    /// keeps its quantity.
    private static func stripMarkers(from line: String) -> String {
        var scalars = Substring(line)
        while let first = scalars.first, "-*•‣–—□☐▢+".contains(first) {
            scalars = scalars.dropFirst()
            scalars = Substring(scalars.drop(while: \.isWhitespace))
        }

        let digits = scalars.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let rest = scalars.dropFirst(digits.count)
            if let punctuation = rest.first, punctuation == "." || punctuation == ")" {
                scalars = Substring(rest.dropFirst().drop(while: \.isWhitespace))
            }
        }

        // Checkbox markers a notes app leaves behind.
        if scalars.hasPrefix("[ ]") || scalars.hasPrefix("[x]") || scalars.hasPrefix("[X]") {
            scalars = Substring(scalars.dropFirst(3).drop(while: \.isWhitespace))
        }

        return String(scalars)
    }

    /// The number in a token like "2", "2x", or "x2", if there is one.
    private static func count(in token: String) -> Int? {
        let stripped = token.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "x×")
        )
        guard !stripped.isEmpty, stripped.allSatisfy(\.isNumber) else { return nil }
        return Int(stripped)
    }

    /// Whether a word is a unit of quantity rather than the thing being bought.
    private static func isUnit(_ word: String) -> Bool {
        units.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    /// The units a shopping list actually uses.
    ///
    /// Short and closed. The point is to keep "2 bottles milk" from becoming an
    /// item called "bottles milk", not to model measurement — anything unusual
    /// stays part of the name, which is the harmless outcome.
    private static let units: Set<String> = [
        "kg", "kgs", "g", "gram", "grams", "mg",
        "l", "litre", "litres", "liter", "liters", "ml",
        "lb", "lbs", "oz",
        "bag", "bags", "bottle", "bottles", "box", "boxes", "bunch", "bunches",
        "can", "cans", "carton", "cartons", "dozen", "jar", "jars", "loaf", "loaves",
        "pack", "packs", "packet", "packets", "pint", "pints", "punnet", "punnets",
        "tin", "tins",
        "tub", "tubs",
    ]
}

extension Int {
    /// The value pulled inside `range`.
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
