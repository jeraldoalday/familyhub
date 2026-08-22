import Foundation

/// Works out which aisle something belongs in from what it is called.
///
/// Aisle grouping is the feature that turns a shopping list into one pass
/// through a shop instead of three, and it only pays off if things are actually
/// in the right section. Asking the person adding "chicken thighs" at half past
/// seven to also pick a category from a ten-item menu is how a list ends up
/// entirely in "Other" — which is the same list, unsorted, with an extra tap.
///
/// So the aisle is guessed and the person can correct it. A wrong guess costs
/// one tap; a missing guess costs the whole feature. The guess is deliberately
/// conservative: anything it does not recognise stays in ``ShoppingItem/Category/other``
/// rather than being forced into the nearest-looking section, because an item
/// filed confidently in the wrong aisle is worse than one filed honestly in no
/// aisle at all.
///
/// This lives in the domain rather than in the view for the usual reason: the
/// meal plan turns a week of recipes into a shopping list without a person
/// touching it, and a guess made only in a text field would leave every
/// generated item uncategorised — which is precisely the list that most needs
/// sorting, because nobody typed it and nobody has read it.
extension ShoppingItem.Category {

    /// The aisle `name` most likely belongs to.
    ///
    /// Matching is on whole words, longest phrase first, over a folded form of
    /// the name — so "Bánh mì rolls" finds "banh mi", "2 x Chicken Breast"
    /// finds "chicken breast" rather than stopping at "chicken", and
    /// "butternut squash" does not come back as dairy because it contains the
    /// letters of "butter".
    ///
    /// - Parameters:
    ///   - name: What the person wrote, or what a recipe called an ingredient.
    ///   - fallback: What to answer when nothing matches.
    /// - Returns: The best guess, or `fallback` when there is no evidence.
    public static func inferred(
        from name: String,
        fallback: ShoppingItem.Category = .other
    ) -> ShoppingItem.Category {
        guess(for: name) ?? fallback
    }

    /// The aisle `name` belongs to, or `nil` when nothing in it is recognised.
    ///
    /// Separate from ``inferred(from:fallback:)`` because "we do not know" and
    /// "we think this is miscellaneous" are different answers to a caller: the
    /// first is a reason to show a picker or leave an existing choice alone,
    /// the second is a decision. Collapsing them is how a guess quietly
    /// overwrites the aisle somebody had already corrected by hand.
    public static func guess(for name: String) -> ShoppingItem.Category? {
        let words = tokens(of: name)
        guard !words.isEmpty else { return nil }

        // The table is walked in order and the longest matching phrase wins, so
        // a two-word entry always beats the one-word entry it contains. Ties
        // fall to whichever appears first in the table, which is a fixed order
        // rather than a dictionary's — the same name has to produce the same
        // aisle on every device or two people's lists sort differently.
        var best: (category: ShoppingItem.Category, length: Int)?
        for entry in lexicon {
            for phrase in entry.phrases {
                guard phrase.count > (best?.length ?? 0) else { continue }
                guard words.contains(phrase: phrase) else { continue }
                best = (entry.category, phrase.count)
            }
        }
        return best?.category
    }

    // MARK: - Normalisation

    /// The name reduced to comparable words.
    ///
    /// Folded for case and accents, with digits, punctuation, and units of
    /// quantity removed — a list says "2kg potatoes" and "potatoes x2" and both
    /// are the same vegetable.
    private static func tokens(of name: String) -> [String] {
        let folded = name.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: .current
        )
        return
            folded
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { !$0.isEmpty && !noiseWords.contains($0) }
    }

    /// Words that carry no aisle information and would otherwise have to be
    /// excluded from every phrase in the table.
    private static let noiseWords: Set<String> = [
        "a", "an", "and", "of", "the", "x", "pack", "packs", "packet", "packets",
        "bag", "bags", "box", "boxes", "tin", "tins", "can", "cans", "jar", "jars",
        "bottle", "bottles", "kg", "g", "grams", "gram", "ml", "l", "litre", "litres",
        "lb", "lbs", "oz", "large", "small", "fresh", "organic", "free", "range",
    ]

    // MARK: - The lexicon

    /// One aisle and the words that put something in it.
    private struct Entry {
        let category: ShoppingItem.Category

        /// Each phrase already split into words, so matching does not re-split
        /// the same constants on every lookup.
        let phrases: [[String]]

        init(_ category: ShoppingItem.Category, _ phrases: [String]) {
            self.category = category
            self.phrases = phrases.map { $0.split(separator: " ").map(String.init) }
        }
    }

    /// What each aisle is made of.
    ///
    /// Kept short on purpose. This is a heuristic that has to be readable by
    /// whoever next argues that oat milk is not dairy, not a food ontology —
    /// and every word added is a word that can misfire on a name nobody
    /// anticipated. The multi-word entries exist where a single word would
    /// otherwise pull an item into the wrong section: "butternut" away from
    /// butter, "milk chocolate" away from milk, "coconut milk" away from dairy.
    private static let lexicon: [Entry] = [
        Entry(
            .produce,
            [
                "apple", "avocado", "banana", "basil", "berries", "blueberry", "broccoli",
                "butternut", "butternut squash", "cabbage", "carrot", "cauliflower", "celery",
                "coriander", "cucumber", "garlic", "ginger", "grape", "grapefruit", "kale",
                "leek", "lemon", "lettuce", "lime", "mango", "melon", "mushroom", "onion",
                "orange", "parsley", "parsnip", "pear", "pepper", "potato", "raspberry",
                "rocket", "salad", "spinach", "spring onion", "strawberry", "sweet potato",
                "tomato", "courgette", "aubergine",
            ]
        ),
        Entry(
            .bakery,
            [
                "bagel", "baguette", "bread", "brioche", "bun", "cake", "ciabatta", "croissant",
                "crumpet", "doughnut", "flatbread", "muffin", "naan", "pastry", "pitta", "roll",
                "scone", "sourdough", "tortilla", "wrap",
            ]
        ),
        Entry(
            .dairy,
            [
                "brie", "butter", "cheddar", "cheese", "cream", "creme fraiche", "custard",
                "egg", "feta", "halloumi", "milk", "mozzarella", "parmesan", "yoghurt", "yogurt",
            ]
        ),
        Entry(
            .meat,
            [
                "bacon", "beef", "chicken", "chorizo", "cod", "duck", "fish", "ham", "haddock",
                "lamb", "mince", "pork", "prawn", "salmon", "sausage", "steak", "tuna", "turkey",
            ]
        ),
        Entry(
            .frozen,
            [
                "frozen", "ice cream", "ice lolly", "lolly", "peas", "fish fingers", "chips",
                "sorbet",
            ]
        ),
        Entry(
            .pantry,
            [
                "beans", "chickpeas", "chocolate", "cinnamon", "cocoa", "coconut milk", "coffee",
                "cornflour", "couscous", "curry paste", "flour", "honey", "jam", "ketchup",
                "lentils", "mayonnaise", "milk chocolate", "mustard", "noodles", "oats", "oil",
                "olive oil", "pasta", "peanut butter", "pesto", "rice", "salt", "soy sauce",
                "spaghetti", "stock", "sugar", "tea", "vinegar", "yeast",
            ]
        ),
        Entry(
            .drinks,
            [
                "apple juice", "beer", "cola", "cordial", "juice", "lemonade", "orange juice",
                "squash", "water", "wine",
            ]
        ),
        Entry(
            .household,
            [
                "batteries", "battery", "bin", "bleach", "bulb", "candle", "cling film",
                "detergent", "dishwasher", "foil", "kitchen roll", "lightbulb", "matches",
                "sponge", "washing up liquid", "washing powder",
            ]
        ),
        Entry(
            .personal,
            [
                "conditioner", "deodorant", "floss", "moisturiser", "nappies", "plasters",
                "razor", "shampoo", "shower gel", "soap", "sunscreen", "toothbrush",
                "toothpaste", "toilet roll",
            ]
        ),
    ]
}

// MARK: - Phrase matching

extension [String] {
    /// Whether these words contain `phrase` as a run of consecutive words.
    ///
    /// Word-wise rather than by substring, which is the whole reason a guess
    /// can be trusted: "grape" must not match "grapefruit" into the wrong
    /// section, and "chips" must not be found inside "chipsticks".
    ///
    /// A word matches a phrase's word if it is that word or a regular plural of
    /// it. Households write "2 lemons" and recipes write "lemon", and a lexicon
    /// carrying both spellings of every noun is a lexicon that will disagree
    /// with itself the first time somebody adds only one.
    fileprivate func contains(phrase: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= count else { return false }
        for start in 0...(count - phrase.count) {
            var matched = true
            for offset in phrase.indices {
                if !String.matchesRoot(self[start + offset], phrase[offset]) {
                    matched = false
                    break
                }
            }
            if matched { return true }
        }
        return false
    }
}

extension String {
    /// Whether `word` is `root` or a regular English plural of it.
    fileprivate static func matchesRoot(_ word: String, _ root: String) -> Bool {
        if word == root { return true }
        if word == root + "s" { return true }
        if word == root + "es" { return true }
        if root.hasSuffix("y"), word == root.dropLast() + "ies" { return true }
        return false
    }
}
