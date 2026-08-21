# FamilyHub — Household Organizer

A shared organizer for the whole household: chores that rotate fairly, a points
and rewards system that actually motivates kids, shopping lists everyone can add
to, a meal plan that turns itself into the shopping, and a family calendar — all
in one native iOS/iPadOS app.

> **Status:** in active development. The domain and store layers are complete
> and tested — chores, points, shopping, meals, and the calendar; the app itself
> is the remaining work. See
> [`docs/ROADMAP.md`](docs/ROADMAP.md) for the shipping plan.

---

## Why this architecture

The business rules of a household organizer are surprisingly subtle — recurrence
with skipped days, fair chore rotation, points that can't be gamed by a nine
year old, and permissions that stop a child from marking a sibling's chore done.
None of that should live inside a SwiftUI view or a SwiftData model.

So the codebase is layered, innermost first:

| Layer | Module | Depends on | Compiles without Xcode |
|---|---|---|---|
| Domain | `FamilyHubCore` | Foundation only | ✅ yes |
| Persistence contract | `FamilyHubStore` | `FamilyHubCore` | ✅ yes |
| Persistence adapter | `App/FamilyHubData` | SwiftData | ❌ needs Xcode |
| Presentation | `App/FamilyHub` | SwiftUI | ❌ needs Xcode |

`FamilyHubCore` holds plain Swift value types and pure functions. It has no
knowledge of SwiftData, SwiftUI, or iCloud. That means every business rule is
unit-testable in milliseconds with `swift test`, and it means swapping the
storage engine later — SwiftData today, SwiftData + CloudKit sync tomorrow — is
an adapter change, not a rewrite.

## Requirements

- **Xcode 16 or later** to build and run the app itself
- **Swift 6.0+ toolchain** to build and test the core (Command Line Tools are enough)
- iOS 17.0+ / iPadOS 17.0+ deployment target

## Building

The domain and store layers build and test with nothing but the Swift toolchain:

```bash
make check      # build + test + lint + release build — the pre-commit gate
make test       # 581 tests
make format     # reformat in place
make lint       # the exact formatting check CI runs
make release    # the optimised build CI also runs
```

`make check` runs every check CI runs, in the order that fails fastest. The
release build is the slow part of it, at around ten seconds on a warm cache, and
it is included rather than left to a target nobody remembers: optimisations
surface warnings a debug build hides, and a local gate that agrees with CI
except in one place is a gate people learn to skip.

### Formatting

`.swift-format` is the whole standard, and it is strict JSON — swift-format's
own config parser rejects a file with comments in it on some toolchains and
accepts it on others, so the reasoning behind a setting goes here rather than
inline.

The one rule turned off that would otherwise be on is
`AllPublicDeclarationsHaveDocumentation`. It cannot distinguish genuinely new
public API from a witness to an already-documented protocol requirement, so it
flags every `id`, every `now`, and every `save(_:)` conformance in the package.
Documentation is expected on new API and is checked in review; left on, the
rule produces enough noise to train people into ignoring the linter, which
costs more than it collects.

Use `make` rather than `swift test` directly when Xcode is not installed: Swift
Testing ships as a framework outside the default search path on a Command Line
Tools-only machine, and the Makefile supplies the flags to find it. With Xcode
present the Makefile gets out of the way and `swift test` works as normal.

The app itself requires Xcode, because the SwiftData `@Model` macro and SwiftUI
previews are provided by the Xcode toolchain rather than the Command Line Tools:

```bash
open FamilyHub.xcodeproj   # added in Milestone 2 — see docs/ROADMAP.md
```

## Repository layout

```
Sources/
  FamilyHubCore/
    Models/            Households, members, chores, completions, rewards,
                       lists, planned meals, calendar events
    Scheduling/        Recurrence engine, weekdays, reminder planning
    Rules/             Permissions, points ledger, streaks, insights, meal
                       plan, family calendar
    Support/           Identifiers, validation, errors, the injected clock
  FamilyHubStore/      Store contract, in-memory store, commands, change feed,
                       backup format, demo data
Tests/
  FamilyHubCoreTests/  Business-rule tests, plus hot-path guards
  FamilyHubStoreTests/ Store, command, observation, and backup tests
docs/
  ARCHITECTURE.md      Why the layering is what it is
  ROADMAP.md           The plan to production
```

## What is built

| Area | Status |
|---|---|
| Households, members, roles, permissions | ✅ complete, tested |
| Chores, rotation, skipping, archiving | ✅ complete, tested |
| Recurrence engine (daily / weekly / monthly) | ✅ complete, tested |
| Completions, approval queue, conflict resolution | ✅ complete, tested |
| Points ledger, rewards, redemption rules | ✅ complete, tested |
| Shopping lists with aisle grouping | ✅ complete, tested |
| Meal planning, cooking rota, and the shopping it implies | ✅ complete, tested |
| Family calendar, recurring events, and clash detection | ✅ complete, tested |
| Streaks, per chore and per member | ✅ complete, tested |
| Weekly recap and workload fairness | ✅ complete, tested |
| Reminder planning (what to say, and when) | ✅ complete, tested |
| Schema versioning and backup migration | ✅ complete, tested |
| Command layer over the store | ✅ complete, tested |
| Change feed and snapshot observation | ✅ complete, tested |
| Backup, restore, and data export | ✅ complete, tested |
| SwiftData persistence | ⬜ needs Xcode — Milestone 1 |
| SwiftUI app | ⬜ needs Xcode — Milestone 1 |
| Notifications, widgets, StoreKit | ⬜ Milestones 2–3 |

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the sequencing and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for why the layers are drawn
where they are.

## License

Proprietary. All rights reserved. See [`LICENSE`](LICENSE).
