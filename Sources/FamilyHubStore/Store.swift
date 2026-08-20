import FamilyHubCore
import Foundation

/// The storage layer's contract with the rest of the app.
///
/// `FamilyHubStore` defines *what* persistence must do and ships an in-memory
/// implementation that satisfies it. The SwiftData implementation lives in the
/// app target, because the `@Model` macro is provided by the Xcode toolchain
/// and would make this package unbuildable from the command line.
///
/// The split is not merely a build convenience. It means every feature can be
/// exercised in tests and SwiftUI previews against a store that needs no disk,
/// no container, and no migration — and it leaves one seam to implement when
/// iCloud sync arrives, rather than a rewrite spread across every view model.
public enum FamilyHubStore {
    /// The schema version this build of the app reads and writes.
    ///
    /// Bumped whenever the persisted shape changes. Migration steps are keyed
    /// off it, and it is written into every export so a backup taken today can
    /// still be understood by a build shipped a year from now.
    /// Version 2 added the meal plan and version 3 the family calendar. Older
    /// archives restore unchanged: a household that had no meal plan is a
    /// household with no planned meals and no calendar is no events, which is
    /// exactly what the migration produces.
    public static let schemaVersion = 3
}
