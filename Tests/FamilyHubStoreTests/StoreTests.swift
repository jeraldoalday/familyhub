import Foundation
import Testing

@testable import FamilyHubStore

@Suite("Store metadata")
struct StoreTests {

    @Test("Schema version is recorded")
    func schemaVersionIsSet() {
        // Guards against the version constant being lost in a refactor: every
        // exported backup carries it, and a file written without one cannot be
        // migrated later.
        #expect(FamilyHubStore.schemaVersion >= 1)
    }
}
