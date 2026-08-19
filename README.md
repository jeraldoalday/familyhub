# FamilyHub — Household Organizer

A shared organizer for the whole household: chores that rotate fairly, a points
and rewards system that actually motivates kids, shopping lists everyone can add
to, meal planning, and a family calendar — all in one native iOS/iPadOS app.

> **Status:** in active development. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for
> the shipping plan.

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
make check      # build + test + lint — the pre-commit gate
make test       # 344 tests
make format     # reformat in place
make lint       # the exact formatting check CI runs
```

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
  FamilyHubCore/       Domain models, scheduling, rules — pure Swift
  FamilyHubStore/      Store contract, in-memory store, commands, demo data
Tests/
  FamilyHubCoreTests/  Business-rule tests
  FamilyHubStoreTests/ Store and command tests
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
| Command layer over the store | ✅ complete, tested |
| SwiftData persistence | ⬜ needs Xcode — Milestone 1 |
| SwiftUI app | ⬜ needs Xcode — Milestone 1 |
| Notifications, widgets, StoreKit | ⬜ Milestones 2–3 |

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the sequencing and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for why the layers are drawn
where they are.

## License

Proprietary. All rights reserved. See [`LICENSE`](LICENSE).
