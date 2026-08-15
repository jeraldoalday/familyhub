import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Identifiers")
struct IdentifierTests {

    // Marker types, so these tests exercise `Identifier` itself rather than
    // whichever domain entity happened to be convenient at the time.
    private struct Widget {}
    private struct Gadget {}

    @Test("Fresh identifiers are unique")
    func freshIdentifiersDiffer() {
        let ids = (0..<1_000).map { _ in Identifier<Widget>() }
        #expect(Set(ids).count == 1_000)
    }

    @Test("Identifiers for different subjects never compare equal")
    func phantomTypesAreDistinct() {
        // The compiler already forbids `widget == gadget`. What this pins down
        // is that two identifiers sharing a UUID stay distinguishable once
        // erased to their raw values — which is what a persistence layer sees.
        let shared = UUID()
        let widget = Identifier<Widget>(shared)
        let gadget = Identifier<Gadget>(shared)
        #expect(widget.rawValue == gadget.rawValue)
        #expect(type(of: widget) != type(of: gadget))
    }

    @Test("Round-trips through its string form")
    func roundTripsThroughString() throws {
        let original = Identifier<Widget>()
        let restored = try #require(Identifier<Widget>(uuidString: original.description))
        #expect(restored == original)
    }

    @Test("Rejects a malformed string")
    func rejectsMalformedString() {
        #expect(Identifier<Widget>(uuidString: "not-a-uuid") == nil)
    }

    @Test("Encodes as a bare string, not a keyed object")
    func encodesAsBareString() throws {
        // Sync payloads and debug logs are read by humans; a nested
        // {"rawValue": …} for every identifier makes them unreadable.
        let id = Identifier<Widget>()
        let data = try JSONEncoder().encode(id)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == "\"\(id.rawValue.uuidString)\"")

        let decoded = try JSONDecoder().decode(Identifier<Widget>.self, from: data)
        #expect(decoded == id)
    }

    @Test("Ordering is stable across sorts")
    func orderingIsStable() {
        let ids = (0..<50).map { _ in Identifier<Widget>() }
        #expect(ids.sorted() == ids.sorted().sorted())
    }
}
