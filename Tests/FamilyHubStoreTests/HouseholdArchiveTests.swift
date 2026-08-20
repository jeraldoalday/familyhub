import FamilyHubCore
import Foundation
import Testing

@testable import FamilyHubStore

@Suite("Household archive")
struct HouseholdArchiveTests {

    private let clock = FixedDateProvider(
        year: 2026, month: 3, day: 2, hour: 9, calendar: .testDefault
    )

    private func demoSnapshot() throws -> HouseholdSnapshot {
        try DemoHousehold.snapshot(asOf: clock)
    }

    // MARK: Round trip

    @Test("An archive survives a round trip through JSON unchanged")
    func roundTripPreservesEverything() throws {
        // The demo household exists precisely because it exercises the awkward
        // cases — a rotating chore mid-rotation, a pending approval, a reward
        // nobody can afford yet — which makes it the right thing to serialise.
        let original = try demoSnapshot()
        let archive = HouseholdArchive(snapshot: original, exportedAt: clock.now)

        let restored = try HouseholdArchive.decoded(from: try archive.encoded())
        let after = restored.snapshot

        #expect(restored.schemaVersion == FamilyHubStore.schemaVersion)
        #expect(restored.exportedAt == clock.now)
        #expect(after.household == original.household)
        #expect(after.members == original.members)
        #expect(after.chores == original.chores)
        #expect(after.completions == original.completions)
        #expect(after.ledgerEntries == original.ledgerEntries)
        #expect(after.rewards == original.rewards)
        #expect(after.shoppingLists == original.shoppingLists)
        #expect(after.shoppingItems == original.shoppingItems)
    }

    @Test("Completion timestamps survive to the sub-second")
    func timestampsAreExact() throws {
        // Conflict resolution compares these. Rounding them to the nearest
        // second on the way through a backup could change which of two
        // completions wins, which is a silently different household.
        let household = try Household(name: "The Aldays", timeZone: .gmt, createdAt: clock.now)
        let parent = try Member(
            householdID: household.id, name: "Jerald", role: .owner, joinedAt: clock.now
        )
        let chore = try Chore(
            householdID: household.id, title: "Bins", startDate: clock.today,
            createdBy: parent.id, createdAt: clock.now
        )
        let awkward = clock.now.addingTimeInterval(0.123_456)
        let completion = ChoreCompletion(
            householdID: household.id,
            choreID: chore.id,
            occurrenceDay: clock.today,
            completedBy: parent.id,
            completedAt: awkward,
            pointsAwarded: 10,
            calendar: .testDefault
        )
        let archive = HouseholdArchive(
            snapshot: HouseholdSnapshot(
                household: household, members: [parent], chores: [chore],
                completions: [completion]
            ),
            exportedAt: clock.now
        )

        let restored = try HouseholdArchive.decoded(from: try archive.encoded())
        #expect(restored.snapshot.completions.first?.completedAt == awkward)
    }

    @Test("The same household exports byte-identically twice")
    func exportIsReproducible() throws {
        // What makes a backup diffable: 'what changed between Tuesday and
        // Friday' should be answerable with `diff`, not by reading the file.
        let archive = HouseholdArchive(snapshot: try demoSnapshot(), exportedAt: clock.now)
        #expect(try archive.encoded() == (try archive.encoded()))
    }

    @Test("Every archive carries the schema version that wrote it")
    func schemaVersionIsRecorded() throws {
        let archive = HouseholdArchive(snapshot: try demoSnapshot(), exportedAt: clock.now)
        let json = try #require(String(data: try archive.encoded(), encoding: .utf8))
        #expect(json.contains("\"schemaVersion\" : \(FamilyHubStore.schemaVersion)"))
    }

    // MARK: Refusing what it cannot read

    @Test("A file that is not an archive is refused as such")
    func nonArchiveDataIsRefused() throws {
        let data = try #require("not a backup".data(using: .utf8))
        #expect(throws: ArchiveError.self) {
            try HouseholdArchive.decoded(from: data)
        }
    }

    @Test("An archive from a newer build is refused rather than half-read")
    func newerSchemaIsRefused() throws {
        // A newer build may have added a field this one drops on decode.
        // Restoring a partially understood household leaves a family with a
        // record that looks complete and is not.
        let archive = HouseholdArchive(
            snapshot: try demoSnapshot(),
            exportedAt: clock.now,
            schemaVersion: FamilyHubStore.schemaVersion + 1
        )
        let data = try archive.encoded()

        #expect(
            throws: ArchiveError.fromANewerBuild(
                found: FamilyHubStore.schemaVersion + 1,
                supported: FamilyHubStore.schemaVersion
            )
        ) {
            try HouseholdArchive.decoded(from: data)
        }
    }

    @Test("An unrecognised older schema is refused rather than guessed at")
    func unknownOlderSchemaIsRefused() throws {
        let archive = HouseholdArchive(
            snapshot: try demoSnapshot(), exportedAt: clock.now, schemaVersion: 0
        )
        let data = try archive.encoded()

        #expect(throws: ArchiveError.unsupportedVersion(0)) {
            try HouseholdArchive.decoded(from: data)
        }
    }

    // MARK: Reading what an older build wrote

    /// Rewrites an archive the way an older build would have: stamped with
    /// that version and with the keys it had never heard of removed entirely,
    /// rather than present and empty.
    ///
    /// Removing the keys is what makes the tests below migration tests.
    /// Encoding an empty array and reading it back only proves that the
    /// current encoder can read itself, which it could do against a migration
    /// that does not work.
    ///
    /// - Parameters:
    ///   - snapshot: The household to write out.
    ///   - version: The schema version to claim.
    ///   - missingKeys: The snapshot keys that version had never written.
    /// - Returns: The bytes that build would have produced.
    /// - Throws: Whatever encoding or re-serialising the archive throws.
    private func archiveData(
        from snapshot: HouseholdSnapshot,
        version: Int,
        missingKeys: [String]
    ) throws -> Data {
        var cleared = snapshot
        if missingKeys.contains("plannedMeals") { cleared.plannedMeals = [] }
        if missingKeys.contains("events") { cleared.events = [] }
        let archive = HouseholdArchive(
            snapshot: cleared, exportedAt: clock.now, schemaVersion: version
        )
        let object = try JSONSerialization.jsonObject(with: try archive.encoded())
        var top = try #require(object as? [String: Any])
        var inner = try #require(top["snapshot"] as? [String: Any])
        for key in missingKeys { inner.removeValue(forKey: key) }
        top["snapshot"] = inner
        return try JSONSerialization.data(withJSONObject: top)
    }

    /// An archive as the build that wrote version 1 would have produced it:
    /// before the meal plan and before the calendar.
    private func version1Data(from snapshot: HouseholdSnapshot) throws -> Data {
        try archiveData(from: snapshot, version: 1, missingKeys: ["plannedMeals", "events"])
    }

    /// An archive as the build that wrote version 2 would have produced it:
    /// with a meal plan, but before the calendar.
    private func version2Data(from snapshot: HouseholdSnapshot) throws -> Data {
        try archiveData(from: snapshot, version: 2, missingKeys: ["events"])
    }

    @Test("A backup taken before meal planning existed still restores")
    func version1ArchiveMigrates() throws {
        let original = try demoSnapshot()
        let data = try version1Data(from: original)
        #expect(!(try #require(String(data: data, encoding: .utf8))).contains("plannedMeals"))

        let restored = try HouseholdArchive.decoded(from: data)

        #expect(restored.schemaVersion == FamilyHubStore.schemaVersion)
        #expect(restored.snapshot.plannedMeals.isEmpty)
        #expect(restored.snapshot.household == original.household)
        #expect(restored.snapshot.chores == original.chores)
        #expect(restored.snapshot.ledgerEntries == original.ledgerEntries)
    }

    @Test("A version 1 backup restores into a store as a household with no plan")
    func version1ArchiveRestores() async throws {
        let original = try demoSnapshot()
        let migrated = try HouseholdArchive.decoded(from: try version1Data(from: original))

        let store = InMemoryHouseholdStore()
        try await store.restore(migrated)

        let snapshot = try await store.snapshot(of: original.household.id)
        #expect(snapshot.plannedMeals.isEmpty)
        #expect(snapshot.members.count == original.members.count)
    }

    @Test("The meal plan survives a round trip and a restore")
    func mealPlanIsArchived() async throws {
        let snapshot = try demoSnapshot()
        #expect(!snapshot.plannedMeals.isEmpty)

        let archive = HouseholdArchive(snapshot: snapshot, exportedAt: clock.now)
        let restored = try HouseholdArchive.decoded(from: try archive.encoded())
        #expect(restored.snapshot.plannedMeals == snapshot.plannedMeals)

        let store = InMemoryHouseholdStore()
        try await store.restore(restored)
        let reloaded = try await store.snapshot(of: snapshot.household.id)

        #expect(
            reloaded.plannedMeals.sortedForDisplay() == snapshot.plannedMeals.sortedForDisplay())
        #expect(
            reloaded.mealPlan.meal(on: clock.today, slot: .dinner)?.title.value
                == snapshot.mealPlan.meal(on: clock.today, slot: .dinner)?.title.value
        )
    }

    @Test("Every archive error explains itself to a person")
    func errorsAreReadable() {
        let errors: [ArchiveError] = [
            .unreadable(reason: "x"),
            .unwritable(reason: "x"),
            .fromANewerBuild(found: 2, supported: 1),
            .unsupportedVersion(0),
            .wouldOverwrite(existing: "The Aldays"),
        ]
        for error in errors {
            let message = error.errorDescription ?? ""
            #expect(!message.isEmpty)
            // No stringly-typed Swift error leaking through to a parent.
            #expect(!message.contains("FamilyHubStore."))
        }
    }

    // MARK: Describing

    @Test("The summary says what is about to be overwritten")
    func summaryDescribesTheHousehold() throws {
        let snapshot = try demoSnapshot()
        let summary = HouseholdArchive(snapshot: snapshot, exportedAt: clock.now).summary

        #expect(summary.contains("The Aldays"))
        #expect(summary.contains("\(snapshot.members.count) members"))
        #expect(summary.contains("\(snapshot.completions.count) completions"))
    }

    @Test("Singular and plural are both handled in the summary")
    func summaryPluralises() throws {
        let household = try Household(name: "Flat 3B", timeZone: .gmt, createdAt: clock.now)
        let solo = try Member(
            householdID: household.id, name: "Robin", role: .owner, joinedAt: clock.now
        )
        let chore = try Chore(
            householdID: household.id, title: "Bins", startDate: clock.today,
            createdBy: solo.id, createdAt: clock.now
        )
        let summary = HouseholdArchive(
            snapshot: HouseholdSnapshot(
                household: household, members: [solo], chores: [chore]
            ),
            exportedAt: clock.now
        ).summary

        #expect(summary.contains("1 member,"))
        #expect(summary.contains("1 chore,"))
    }

    @Test("The suggested filename sorts chronologically and is path-safe")
    func filenameIsUsable() throws {
        let household = try Household(
            name: "Home/Away: 2026", timeZone: .gmt, createdAt: clock.now
        )
        let archive = HouseholdArchive(
            snapshot: HouseholdSnapshot(household: household), exportedAt: clock.now
        )

        let filename = archive.suggestedFilename()
        #expect(filename == "Home-Away- 2026 2026-03-02.familyhub.json")
        #expect(!filename.contains("/"))
    }

    // MARK: Restoring

    @Test("A restored household matches the one that was archived")
    func restoreRebuildsTheHousehold() async throws {
        let original = try demoSnapshot()
        let archive = HouseholdArchive(snapshot: original, exportedAt: clock.now)

        let fresh = InMemoryHouseholdStore()
        try await fresh.restore(archive)

        let restored = try await fresh.snapshot(of: original.household.id)
        #expect(restored.members.count == original.members.count)
        #expect(restored.chores.count == original.chores.count)
        #expect(restored.completions.count == original.completions.count)
        #expect(restored.ledgerEntries.count == original.ledgerEntries.count)
        #expect(restored.shoppingItems.count == original.shoppingItems.count)

        // The point of a backup is that the numbers come back, not just the rows.
        let child = try #require(original.activeMembers.last)
        #expect(
            restored.ledger.balance(for: child.id) == original.ledger.balance(for: child.id)
        )
    }

    @Test("Restoring the same archive again leaves exactly the same records")
    func restoreIsIdempotent() async throws {
        // Every write is an upsert by identifier — the same property that makes
        // the store safe against a sync retry — so a family who taps restore
        // twice gets one household rather than two of everything.
        let archive = HouseholdArchive(snapshot: try demoSnapshot(), exportedAt: clock.now)
        let fresh = InMemoryHouseholdStore()

        try await fresh.restore(archive)
        let first = try await fresh.snapshot(of: archive.snapshot.household.id)
        try await fresh.restore(archive, replacingExisting: true)
        let second = try await fresh.snapshot(of: archive.snapshot.household.id)

        #expect(Set(second.chores.map(\.id)) == Set(first.chores.map(\.id)))
        #expect(Set(second.ledgerEntries.map(\.id)) == Set(first.ledgerEntries.map(\.id)))
        #expect(Set(second.completions.map(\.id)) == Set(first.completions.map(\.id)))
    }

    @Test("Restoring over a live household is refused by default")
    func restoreRefusesToOverwriteSilently() async throws {
        // Restoring last month's backup over a live household would resurrect
        // every chore the family has since deleted, with nothing on screen to
        // say what happened.
        let snapshot = try demoSnapshot()
        let store = InMemoryHouseholdStore(seed: snapshot)
        let archive = HouseholdArchive(snapshot: snapshot, exportedAt: clock.now)

        await #expect(throws: ArchiveError.wouldOverwrite(existing: "The Aldays")) {
            try await store.restore(archive)
        }
    }

    @Test("Replacing an existing household leaves nothing of the old one behind")
    func replacingRemovesStaleRecords() async throws {
        let snapshot = try demoSnapshot()
        let store = InMemoryHouseholdStore(seed: snapshot)
        let archive = HouseholdArchive(snapshot: snapshot, exportedAt: clock.now)

        // A chore added after the backup was taken must not survive a replace.
        let afterwards = try Chore(
            householdID: snapshot.household.id,
            title: "Something added later",
            startDate: clock.today,
            createdBy: try #require(snapshot.activeMembers.first).id,
            createdAt: clock.now
        )
        try await store.save(afterwards)

        try await store.restore(archive, replacingExisting: true)
        let restored = try await store.snapshot(of: snapshot.household.id)
        #expect(!restored.chores.contains { $0.id == afterwards.id })
        #expect(restored.chores.count == snapshot.chores.count)
    }

    @Test("A store can archive a household it holds")
    func storeExportsWhatItHolds() async throws {
        let snapshot = try demoSnapshot()
        let store = InMemoryHouseholdStore(seed: snapshot)

        let archive = try await store.archive(snapshot.household.id, exportedAt: clock.now)
        #expect(archive.snapshot.household == snapshot.household)
        #expect(archive.exportedAt == clock.now)
    }

    @Test("Archiving a household that is not there reports it as missing")
    func exportingNothingIsReported() async throws {
        let store = InMemoryHouseholdStore()
        let id = Identifier<Household>()

        await #expect(throws: DomainError.notFound(entity: "Household", id: id.description)) {
            try await store.archive(id, exportedAt: clock.now)
        }
    }

    @Test("Export and restore survive a trip through a second store")
    func fullBackupCycleWorks() async throws {
        // The path a family actually takes: export on the old phone, carry a
        // file across, restore on the new one.
        let snapshot = try demoSnapshot()
        let oldPhone = InMemoryHouseholdStore(seed: snapshot)
        let data = try await oldPhone.archive(snapshot.household.id, exportedAt: clock.now)
            .encoded()

        let newPhone = InMemoryHouseholdStore()
        try await newPhone.restore(try HouseholdArchive.decoded(from: data))

        let before = try await oldPhone.snapshot(of: snapshot.household.id)
        let after = try await newPhone.snapshot(of: snapshot.household.id)
        #expect(after.household == before.household)
        #expect(Set(after.chores.map(\.id)) == Set(before.chores.map(\.id)))
        #expect(
            after.agenda(for: clock.today).map(\.id) == before.agenda(for: clock.today).map(\.id)
        )
    }

    // MARK: The calendar

    @Test("A backup taken before the calendar existed still restores")
    func version2ArchiveMigrates() throws {
        let original = try demoSnapshot()
        let data = try version2Data(from: original)
        #expect(!(try #require(String(data: data, encoding: .utf8))).contains("\"events\""))

        let restored = try HouseholdArchive.decoded(from: data)

        #expect(restored.schemaVersion == FamilyHubStore.schemaVersion)
        #expect(restored.snapshot.events.isEmpty)
        #expect(restored.snapshot.plannedMeals == original.plannedMeals)
        #expect(restored.snapshot.household == original.household)
        #expect(restored.snapshot.chores == original.chores)
    }

    @Test("A version 2 backup restores into a store as a household with a clear calendar")
    func version2ArchiveRestores() async throws {
        let original = try demoSnapshot()
        let migrated = try HouseholdArchive.decoded(from: try version2Data(from: original))

        let store = InMemoryHouseholdStore()
        try await store.restore(migrated)

        let snapshot = try await store.snapshot(of: original.household.id)
        #expect(snapshot.events.isEmpty)
        #expect(snapshot.plannedMeals.count == original.plannedMeals.count)
    }

    @Test("A version 1 backup skips two versions in one step")
    func version1ArchiveSkipsToCurrent() throws {
        let original = try demoSnapshot()
        let restored = try HouseholdArchive.decoded(from: try version1Data(from: original))
        #expect(restored.schemaVersion == FamilyHubStore.schemaVersion)
        #expect(restored.snapshot.events.isEmpty)
        #expect(restored.snapshot.plannedMeals.isEmpty)
    }

    @Test("The calendar survives a round trip and a restore")
    func calendarIsArchived() async throws {
        var snapshot = try demoSnapshot()
        let event = try CalendarEvent(
            householdID: snapshot.household.id,
            title: "Swimming",
            location: "Leisure centre",
            kind: .activity,
            startDate: clock.today,
            timing: .at(hour: 16, lasting: 60),
            recurrence: try .weekly(on: [.monday]),
            participants: .members([try #require(snapshot.members.last).id]),
            reminderMinutesBefore: 30,
            createdBy: try #require(snapshot.members.first).id,
            createdAt: clock.now,
            calendar: snapshot.household.calendar()
        )
        snapshot.events = [event]

        let archive = HouseholdArchive(snapshot: snapshot, exportedAt: clock.now)
        let restored = try HouseholdArchive.decoded(from: try archive.encoded())
        #expect(restored.snapshot.events == [event])

        let store = InMemoryHouseholdStore()
        try await store.restore(restored)
        let reloaded = try await store.snapshot(of: snapshot.household.id)
        #expect(reloaded.events == [event])
    }
}
