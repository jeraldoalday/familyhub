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
swift build
swift test
```

The app itself requires Xcode, because the SwiftData `@Model` macro and SwiftUI
previews are provided by the Xcode toolchain rather than the Command Line Tools:

```bash
open FamilyHub.xcodeproj   # added in Milestone 2 — see docs/ROADMAP.md
```

## Repository layout

```
Sources/
  FamilyHubCore/       Domain models, scheduling, rules — pure Swift
  FamilyHubStore/      Repository protocols + in-memory implementation
Tests/
  FamilyHubCoreTests/  Business-rule tests
  FamilyHubStoreTests/ Repository conformance tests
App/                   SwiftUI + SwiftData layer (opened in Xcode)
docs/                  Roadmap, architecture notes, decision records
```

## License

Proprietary. All rights reserved. See [`LICENSE`](LICENSE).
