# Architecture

FamilyHub is layered inward. Each layer knows only about the ones inside it.

```
┌─────────────────────────────────────────────┐
│  FamilyHub (app target)          SwiftUI    │  views, navigation, previews
├─────────────────────────────────────────────┤
│  FamilyHubData                  SwiftData   │  @Model entities, mapping
├─────────────────────────────────────────────┤
│  FamilyHubStore                 Foundation  │  store contract, commands
├─────────────────────────────────────────────┤
│  FamilyHubCore                  Foundation  │  entities, rules, scheduling
└─────────────────────────────────────────────┘
```

`FamilyHubCore` imports nothing but Foundation. `FamilyHubStore` imports Core.
The two outer layers are the only ones that touch an Apple framework with a
runtime dependency, and they are the only ones that need Xcode to compile.

## Why this shape

The obvious way to build this app is `@Model` classes with business logic on
them and SwiftUI views reading them directly. It is faster for about a fortnight
and then it stops being faster, for three specific reasons.

**Testability.** Every rule in this app is about time — recurrence, streaks,
overdue states, cooldowns. Rules that live on a `@Model` need a container to
test, which means tests that take seconds instead of microseconds, which in
practice means tests that do not get written. The 208 tests here run in about
fifteen milliseconds because none of them touch a database.

**Replaceability.** Local-only storage today, iCloud sync later. With rules in
the persistence layer that is a rewrite. With rules in a layer that has never
heard of persistence, it is a new conformance to an existing protocol.

**One source of truth per rule.** "Is this chore mine?" has a subtle answer
involving rotation, open assignment, and role. Answered once in Core, it cannot
be answered differently by the chore row, the widget, and the notification
scheduler — which is exactly what happens when the logic lives in views.

## Rules that hold everywhere

**Domain types are values, not references.** Members, chores, and completions
are structs with `private(set)` properties and `with…` methods returning
copies. They cross actor boundaries during sync without locking, and a
background write cannot mutate what the UI is currently rendering.

**Time is injected.** Nothing in Core calls `Date()`. Everything takes a
`DateProvider`. Production passes `SystemDateProvider`; tests pass
`FixedDateProvider` and move time deliberately.

**Identifiers are typed.** `Identifier<Member>` and `Identifier<Chore>` are
distinct types. Passing one where the other belongs fails to compile.

**Validation happens at construction.** `ValidatedText` cannot hold blank or
over-long text, so no layer downstream defends against it.

**The ledger is append-only.** Balances are summed, never stored. Entries are
immutable, which is what lets two devices merge by union instead of by
last-write-wins — and last-write-wins on a balance silently discards chores a
child actually did.

**Writes go through commands.** Views never assemble a record and save it.
Almost every operation is two or three writes that must agree, and scattering
those pairs across view models is how a points total ends up disagreeing with
its own history.

## Where the tricky parts are

**`RecurrenceEngine`** is the piece most likely to grow a subtle bug. Its tests
are correspondingly the most thorough in the suite. If you change it, the
cases that matter are: phase preservation when the requested window opens
mid-cycle, months that lack the requested day, and the interaction between
skipped days and an occurrence limit.

**`HouseholdSnapshot.agenda(for:memberID:)`** is the hottest read path — it runs
on every home-screen render. It indexes completions once rather than searching
per chore, which is the difference between linear and quadratic on a household
with a year of history.

**Conflict resolution** currently lives in
`Collection<ChoreCompletion>.deduplicatedByOccurrence()`. It resolves by
earliest completion with the identifier as tiebreaker, so every device
converges on the same winner without negotiating. When sync arrives, this is
the function to revisit first.

## What would need to change for sync

The design leaves four seams:

1. `HouseholdStore` gains a CloudKit-backed conformance. No caller changes.
2. Every entity is already `Codable` with stable identifiers.
3. The ledger already merges by union.
4. Completions already carry a deterministic conflict resolution.

What is genuinely missing is a change feed — the store contract returns whole
snapshots, with no way to observe deltas. That is the first thing to add.
