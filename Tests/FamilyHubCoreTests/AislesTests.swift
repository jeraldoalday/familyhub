import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Aisle guessing")
struct AislesTests {

    // MARK: The straightforward cases

    @Test("Recognises an item from a single word")
    func singleWord() {
        #expect(ShoppingItem.Category.guess(for: "Milk") == .dairy)
        #expect(ShoppingItem.Category.guess(for: "Bread") == .bakery)
        #expect(ShoppingItem.Category.guess(for: "Chicken") == .meat)
        #expect(ShoppingItem.Category.guess(for: "Carrots") == .produce)
        #expect(ShoppingItem.Category.guess(for: "Toothpaste") == .personal)
    }

    @Test("Ignores case, accents, and surrounding punctuation")
    func foldsTheName() {
        #expect(ShoppingItem.Category.guess(for: "  MILK  ") == .dairy)
        #expect(ShoppingItem.Category.guess(for: "Crème fraîche") == .dairy)
        #expect(ShoppingItem.Category.guess(for: "Onion, red") == .produce)
    }

    @Test("Finds the word inside a longer name")
    func findsWordInPhrase() {
        #expect(ShoppingItem.Category.guess(for: "semi skimmed milk") == .dairy)
        #expect(ShoppingItem.Category.guess(for: "chicken thighs for tonight") == .meat)
    }

    // MARK: Quantities and units

    @Test("Sees past a quantity and a unit")
    func ignoresQuantities() {
        // The shopping list stores quantity separately, but people type it into
        // the name anyway and a recipe writes "500g beef mince" as one string.
        #expect(ShoppingItem.Category.guess(for: "2 x lemons") == .produce)
        #expect(ShoppingItem.Category.guess(for: "500g beef mince") == .meat)
        #expect(ShoppingItem.Category.guess(for: "6 free range eggs") == .dairy)
        #expect(ShoppingItem.Category.guess(for: "1kg potatoes") == .produce)
    }

    @Test("A name made only of noise is not a guess")
    func noiseOnlyIsUnknown() {
        #expect(ShoppingItem.Category.guess(for: "2 x large") == nil)
        #expect(ShoppingItem.Category.guess(for: "500g") == nil)
    }

    // MARK: Plurals

    @Test("Regular plurals match the singular in the lexicon")
    func plurals() {
        #expect(ShoppingItem.Category.guess(for: "apples") == .produce)
        #expect(ShoppingItem.Category.guess(for: "tomatoes") == .produce)
        #expect(ShoppingItem.Category.guess(for: "berries") == .produce)
        #expect(ShoppingItem.Category.guess(for: "sausages") == .meat)
    }

    // MARK: The traps

    @Test("A longer phrase beats the shorter word inside it")
    func longestPhraseWins() {
        // Each of these contains a word that would file it in the wrong aisle
        // on its own, which is the entire reason matching is longest-first.
        #expect(ShoppingItem.Category.guess(for: "butternut squash") == .produce)
        #expect(ShoppingItem.Category.guess(for: "coconut milk") == .pantry)
        #expect(ShoppingItem.Category.guess(for: "milk chocolate") == .pantry)
        #expect(ShoppingItem.Category.guess(for: "peanut butter") == .pantry)
        #expect(ShoppingItem.Category.guess(for: "sweet potato") == .produce)
        #expect(ShoppingItem.Category.guess(for: "ice cream") == .frozen)
    }

    @Test("A word is not found inside a longer word")
    func matchesWholeWordsOnly() {
        // "grape" lives inside "grapefruit" and "chips" inside "chipsticks";
        // substring matching would file a bag of crisps in the freezer.
        #expect(ShoppingItem.Category.guess(for: "grapefruit") == .produce)
        #expect(ShoppingItem.Category.guess(for: "chipsticks") == nil)
        #expect(ShoppingItem.Category.guess(for: "buttercup seeds") == nil)
    }

    @Test("Nothing recognisable stays in Other rather than guessing")
    func unknownStaysOther() {
        // A confident wrong answer is worse than an honest blank one: an item
        // filed in the wrong aisle is walked past, and one in Other is read.
        #expect(ShoppingItem.Category.guess(for: "Birthday present for Sam") == nil)
        #expect(ShoppingItem.Category.inferred(from: "Birthday present for Sam") == .other)
    }

    @Test("The fallback is what an unrecognised name becomes")
    func fallbackIsUsed() {
        #expect(ShoppingItem.Category.inferred(from: "widget", fallback: .household) == .household)
        #expect(ShoppingItem.Category.inferred(from: "milk", fallback: .household) == .dairy)
    }

    @Test("An empty name is never a guess")
    func emptyName() {
        #expect(ShoppingItem.Category.guess(for: "") == nil)
        #expect(ShoppingItem.Category.guess(for: "   ") == nil)
        #expect(ShoppingItem.Category.inferred(from: "") == .other)
    }

    // MARK: Determinism

    @Test("The same name always produces the same aisle")
    func isDeterministic() {
        // Two devices sorting the same list differently is a sync bug as far as
        // anyone using it is concerned, so the table is walked in a fixed order
        // rather than a dictionary's.
        let names = ["milk", "chicken breast", "sourdough bread", "kitchen roll", "orange juice"]
        for name in names {
            let answers = Set((0..<20).map { _ in ShoppingItem.Category.guess(for: name) })
            #expect(answers.count == 1)
        }
    }

    @Test("Every aisle except Other is reachable")
    func everyAisleIsReachable() {
        // A category nothing can ever be filed into is a section that will
        // always render empty, which reads as a bug in the grouping.
        let samples: [(String, ShoppingItem.Category)] = [
            ("apples", .produce),
            ("sourdough", .bakery),
            ("cheddar", .dairy),
            ("salmon", .meat),
            ("frozen peas", .frozen),
            ("olive oil", .pantry),
            ("orange juice", .drinks),
            ("washing up liquid", .household),
            ("shampoo", .personal),
        ]
        for (name, expected) in samples {
            #expect(ShoppingItem.Category.guess(for: name) == expected, "\(name)")
        }
    }
}
