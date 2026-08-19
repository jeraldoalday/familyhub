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

**Backups are exact, not readable.** `HouseholdArchive` writes sorted,
pretty-printed JSON so two exports of the same household are byte-identical and
a diff means something — but leaves dates on the default encoding rather than
ISO 8601. Conflict resolution compares `completedAt`, and rounding those to the
nearest second on the way through a backup could change which of two
completions wins.

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

**Occurrence positions** are the other easy place to make something quadratic.
A rotating chore's assignee is derived from the occurrence's position counted
from the chore's start date, so anything that resolves a rota has to walk the
schedule. `RecurrenceEngine.indexedOccurrences` returns days and positions from
one pass; asking for the days and then asking per day for the positions walks
the household's entire history once per row, which is what the agenda, the
recap, and the streak calculator all used to do. `HotPathTests` fails if that
comes back.

## Observation

The store reports its own writes. `changes(for:)` is part of the contract
rather than an optional extra, because a store that cannot say what it just did
leaves every screen either polling or reloading on appearance — and a chore
ticked off on a second device then stays invisible until somebody navigates
away and back, which is indistinguishable from a sync bug.

A `HouseholdChange` says which kind of record moved and which one, never what
it now contains. Carrying the value would let the feed and the snapshot
disagree, which is the class of bug that loading whole snapshots was chosen to
avoid, so the only correct reaction to a change is to reload.

`snapshots(of:where:)` builds the reload loop once, here, rather than once per
screen. It subscribes to the feed *before* reading the first snapshot: a change
landing in that gap costs one redundant render, whereas reading first would
drop the write entirely.

## What would need to change for sync

The design leaves five seams:

1. `HouseholdStore` gains a CloudKit-backed conformance. No caller changes.
2. Every entity is already `Codable` with stable identifiers.
3. The ledger already merges by union.
4. Completions already carry a deterministic conflict resolution.
5. The change feed already exists, so a remote write reaches the UI by the same
   path a local one does.

What remains is not domain work. Account states, the shared-zone invitation
flow, and what the app says when a device has been offline long enough to
matter are all questions about the network and about what a family is shown
while it is unavailable — which is why sync is out of scope for v1 rather than
half-built into it.
