import FamilyHubCore
import Foundation

/// A household, written out whole, with the schema version that produced it.
///
/// ``FamilyHubStore/schemaVersion`` has always documented itself as being
/// "written into every export so a backup taken today can still be understood
/// by a build shipped a year from now". This is that export.
///
/// It exists for three reasons, in ascending order of how much trouble their
/// absence causes. It gives a family a way to keep their own data, which is the
/// least the app owes them. It gives support something to ask for when a
/// household reports a balance that looks wrong, instead of asking a parent to
/// describe a screen. And it is the required answer to a data portability
/// request, which is not optional and is considerably cheaper to have built
/// before the first one arrives.
public struct HouseholdArchive: Sendable, Codable {

    /// The schema the archive was written against.
    public let schemaVersion: Int

    /// When it was taken.
    public let exportedAt: Date

    /// Everything in the household.
    public let snapshot: HouseholdSnapshot

    /// Creates an archive of a snapshot.
    ///
    /// - Parameters:
    ///   - snapshot: The household to archive.
    ///   - exportedAt: The moment to stamp it with.
    ///   - schemaVersion: The schema being written. Defaults to the current
    ///     one; overridable so that a test can produce an archive claiming to
    ///     be from another build without waiting for one to exist.
    public init(
        snapshot: HouseholdSnapshot,
        exportedAt: Date,
        schemaVersion: Int = FamilyHubStore.schemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.snapshot = snapshot
    }

    // MARK: - Encoding

    /// The encoder used for every archive.
    ///
    /// Keys are sorted and the output is pretty-printed, so two exports of the
    /// same household produce byte-identical files. That is what makes an
    /// archive diffable — "what changed between Tuesday and Friday" is a
    /// question support can answer with `diff` rather than by reading two
    /// thousand lines of JSON.
    ///
    /// Dates are left on the default strategy rather than moved to ISO 8601.
    /// A readable timestamp would be pleasant, but conflict resolution between
    /// two devices is decided by comparing `completedAt` values, and rounding
    /// them to the nearest second on the way through a backup could change
    /// which of two completions wins. Exactness beats legibility for a file
    /// whose purpose is to restore faithfully.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    /// Encodes the archive.
    ///
    /// - Throws: ``ArchiveError/unwritable(reason:)`` if encoding fails, which
    ///   in practice means a value the domain should never have permitted.
    public func encoded() throws -> Data {
        do {
            return try Self.makeEncoder().encode(self)
        } catch {
            throw ArchiveError.unwritable(reason: String(describing: error))
        }
    }

    /// Reads an archive back.
    ///
    /// - Parameter data: The file's contents.
    /// - Returns: The archive, migrated to the current schema if it was written
    ///   by an older build.
    /// - Throws: ``ArchiveError/unreadable(reason:)`` if the data is not an
    ///   archive at all, or ``ArchiveError/fromANewerBuild(found:supported:)``
    ///   if it was written by a version this build does not understand.
    public static func decoded(from data: Data) throws -> HouseholdArchive {
        let archive: HouseholdArchive
        do {
            archive = try JSONDecoder().decode(HouseholdArchive.self, from: data)
        } catch {
            throw ArchiveError.unreadable(reason: String(describing: error))
        }

        // Refused rather than attempted. A newer build may have added a field
        // this one drops on decode, and restoring a partially understood
        // household is worse than refusing: the family would be left with a
        // record that looks complete and is not.
        guard archive.schemaVersion <= FamilyHubStore.schemaVersion else {
            throw ArchiveError.fromANewerBuild(
                found: archive.schemaVersion,
                supported: FamilyHubStore.schemaVersion
            )
        }

        return try archive.migrated()
    }

    /// Brings an archive from an older schema up to the current one.
    ///
    /// The seam was built at version 1, when it was the identity, on the
    /// argument that discovering at version 2 that every restore path assumed
    /// the current shape produces a migration written under pressure. Two
    /// versions later the argument has held twice: each step is a line in a
    /// switch because the decision it needed was made before it was needed.
    ///
    /// Version 1 predates the meal plan and version 2 the family calendar. In
    /// both cases the missing collection is not a gap to be filled in but the
    /// truth about that household — there was no calendar to have — so
    /// migrating is restamping the version rather than transforming the
    /// contents. That is only true because ``HouseholdSnapshot`` decodes an
    /// absent collection as an empty one; if it threw instead, every one of
    /// these steps would have to rebuild the snapshot by hand.
    ///
    /// - Throws: ``ArchiveError/unsupportedVersion(_:)`` for a version between
    ///   zero and current that no migration step knows about, which can only
    ///   mean a hand-edited file.
    private func migrated() throws -> HouseholdArchive {
        switch schemaVersion {
        case FamilyHubStore.schemaVersion:
            return self
        case 1, 2:
            return HouseholdArchive(
                snapshot: snapshot,
                exportedAt: exportedAt,
                schemaVersion: FamilyHubStore.schemaVersion
            )
        default:
            throw ArchiveError.unsupportedVersion(schemaVersion)
        }
    }
}

// MARK: - Describing an archive

extension HouseholdArchive {
    /// A one-line summary for a restore confirmation, so a family is told what
    /// they are about to overwrite before they overwrite it.
    public var summary: String {
        let name = snapshot.household.name.value
        let members = snapshot.members.count
        let chores = snapshot.chores.count
        return
            "\(name) — \(members) \(members == 1 ? "member" : "members"), "
            + "\(chores) \(chores == 1 ? "chore" : "chores"), "
            + "\(snapshot.completions.count) completions"
    }

    /// A filename that sorts chronologically and does not collide between
    /// households.
    ///
    /// Dated with the household's own calendar, because a backup labelled with
    /// the exporting device's timezone is confusing on the one that restores it.
    public func suggestedFilename() -> String {
        let calendar = snapshot.household.calendar()
        let parts = calendar.dateComponents([.year, .month, .day], from: exportedAt)
        let stamp = String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
        let name =
            snapshot.household.name.value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name) \(stamp).familyhub.json"
    }
}

// MARK: - Errors

/// What can go wrong reading or writing a backup.
///
/// Separate from ``DomainError`` on purpose. Those are things a household did;
/// these are things a *file* did, and a family restoring a corrupt backup needs
/// to be told about the file rather than about a rule they did not break.
public enum ArchiveError: Error, Equatable, Sendable {
    /// The data is not a FamilyHub archive, or is damaged.
    case unreadable(reason: String)

    /// The archive could not be written.
    case unwritable(reason: String)

    /// The archive was written by a newer version of the app.
    case fromANewerBuild(found: Int, supported: Int)

    /// The archive claims a schema version no migration step recognises.
    case unsupportedVersion(Int)

    /// The archive is for a household that is already on this device with
    /// different contents.
    case wouldOverwrite(existing: String)
}

extension ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "That file isn't a FamilyHub backup, or it's been damaged."
        case .unwritable:
            return "The backup couldn't be written."
        case .fromANewerBuild:
            return "That backup was made by a newer version of FamilyHub. Update the app first."
        case .unsupportedVersion:
            return "That backup was made by a version of FamilyHub this one can't read."
        case .wouldOverwrite(let existing):
            return "\(existing) is already on this device. Restoring would replace it."
        }
    }
}

// MARK: - Store integration

extension HouseholdStore {
    /// Archives a household as it currently stands.
    ///
    /// - Parameters:
    ///   - householdID: The household to export.
    ///   - exportedAt: The moment to stamp the archive with. Injected rather
    ///     than read from the clock so an export is reproducible in a test.
    /// - Returns: The archive.
    /// - Throws: ``DomainError/notFound(entity:id:)`` when there is no such
    ///   household.
    public func archive(
        _ householdID: Identifier<Household>,
        exportedAt: Date
    ) async throws -> HouseholdArchive {
        HouseholdArchive(snapshot: try await snapshot(of: householdID), exportedAt: exportedAt)
    }

    /// Writes an archive's contents into this store.
    ///
    /// Every record is written by identifier, which means restoring the same
    /// archive twice converges rather than duplicating — the same property that
    /// makes the store safe against a sync retry. It also means a restore
    /// *merges* rather than replaces: records present here but absent from the
    /// archive survive.
    ///
    /// - Parameters:
    ///   - archive: What to restore.
    ///   - replacingExisting: When `true`, an existing household of the same
    ///     identifier is erased first, so the result matches the archive
    ///     exactly. When `false`, a household already on the device is refused
    ///     rather than silently merged into — a family restoring last month's
    ///     backup over a live household would otherwise resurrect every chore
    ///     they have since deleted, with no way to tell what happened.
    /// - Throws: ``ArchiveError/wouldOverwrite(existing:)``.
    public func restore(
        _ archive: HouseholdArchive,
        replacingExisting: Bool = false
    ) async throws {
        let snapshot = archive.snapshot

        if let existing = try? await self.snapshot(of: snapshot.household.id) {
            guard replacingExisting else {
                throw ArchiveError.wouldOverwrite(existing: existing.household.name.value)
            }
            try await deleteHousehold(snapshot.household.id)
        }

        // The household goes in first. Everything else refers to it, and a
        // store that fails part way through should leave a household holding
        // some of its records rather than orphans pointing at nothing.
        try await save(snapshot.household)
        try await save(members: snapshot.members)
        try await save(chores: snapshot.chores)
        for completion in snapshot.completions {
            try await save(completion)
        }
        for entry in snapshot.ledgerEntries {
            try await append(entry)
        }
        for reward in snapshot.rewards {
            try await save(reward)
        }
        for list in snapshot.shoppingLists {
            try await save(list)
        }
        try await save(items: snapshot.shoppingItems)
        try await save(meals: snapshot.plannedMeals)
        try await save(events: snapshot.events)
    }
}
