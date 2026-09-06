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
    /// Version 2 added the meal plan, version 3 the family calendar, version 4
    /// the cover requests that let one person take a chore off another for a
    /// day, version 5 the redemption records that say whether a reward somebody
    /// spent points on was ever actually handed over, and version 6 the away
    /// periods that record the days a household was not at home. Older archives
    /// restore unchanged: a household that had no meal plan is a household with
    /// no planned meals, no calendar is no events, no cover requests is a
    /// household that swapped chores across the kitchen instead, no redemptions
    /// is a household whose rewards were settled — or not — outside the app,
    /// and no away periods is a household whose holidays are still recorded as
    /// a fortnight of missed chores. Which is exactly what the migration
    /// produces.
    ///
    /// The last of those is worth stating plainly, because it is the one a
    /// migration could plausibly be tempted to guess at. A restored version 5
    /// household has weeks in it where every chore was missed at once, and
    /// inventing a trip from that shape would rewrite a family's history on
    /// the strength of a pattern that also describes the fortnight they simply
    /// stopped using the app.
    public static let schemaVersion = 6
}
