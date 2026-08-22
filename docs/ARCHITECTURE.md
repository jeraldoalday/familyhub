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
practice means tests that do not get written. The 653 tests here run in under
half a second because none of them touch a database.

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

**Authority is checked against an active member.** Removed members are
tombstones — their record survives so a year of history still names a real
person — so `requireMember` and `requireActiveMember` are separate calls with
the difference spelled out. A command with an actor asks the second one; the
first is for the operations that are *about* somebody who has already left.

**A record's day is normalised on the way in.** A completion's occurrence day
and a planned meal's day are both stored as the start of the day, so two
devices recording the same Thursday at different times produce the same key.
Every collision that survives that is a genuine one, and is resolved rather than
prevented.

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

**`MealPlan`** makes the same trade one layer along: meals are indexed by
day-and-slot in the initialiser, so rendering a week is twenty-one lookups
rather than seven passes over every meal the household has ever planned.

**`FamilyCalendar`** faces the chore version of that problem rather than the
meal version, because an event recurs and a meal does not. It expands each
event's schedule once across the window asked for; asking each event whether it
falls on each day walks a two-year rota seven times per event to draw one week.
Its clash detection is quadratic by nature — every occurrence against every
later one — so the sort by start time and the early exit are what keep it
bounded, and `HotPathTests` covers both.

**A day and a time are different things.** A chore belongs to a day; an event
happens at four o'clock. The event's time is stored as minutes past midnight in
the household's timezone rather than as a moment, so a recurring lesson is at
four on every day it recurs — including the two days a year a stored `Date`
would move it by an hour. Spans are built by adding minutes to the start of the
day rather than by setting an hour on it, because on the morning the clocks go
forward there is no half past one and `date(bySettingHour:)` answers nil for it.

**`HouseholdSearch`** is where the layering pays off most visibly and is
also the easiest place to make a screen feel slow. One matcher over the whole
snapshot rather than a filter per screen, because six per-screen filters are
six places for the same folding bug to be fixed five times — and because a
family that remembers the word "swimming" wants the lesson, the goggles, and
the chore about the wet towels without being asked which tab that lives on.

Two things about it are load-bearing. Matching happens before describing: a
row's second line renders a schedule or resolves an event's participants, and a
query matching a thousand records to show eight must not assemble the other
nine hundred and ninety-two. And a query with no space in it is compared with
`range(of:options:)` rather than against a folded copy of each name, which is
sound rather than approximate — folding beyond case and accents only collapses
runs of whitespace, which can neither create nor destroy a match containing
none. A multi-word query takes the long way for exactly that reason. Both are
covered by `HotPathTests`, because a search box is the one screen where this is
visible as the field lagging behind the person typing.

**Guessing beats asking, where a wrong guess costs one tap.**
`ShoppingItem.Category.inferred(from:)` files an item into an aisle by its
name. The alternative is what was there before: a ten-item menu on the fast
path, which nobody uses, so everything lands in "Other" and the aisle grouping
— the whole reason the shop takes one pass instead of three — never pays off.
The rule that keeps it honest is that an unrecognised name stays in "Other"
rather than being pushed to the nearest-looking section; an item filed
confidently in the wrong aisle is walked past, and one filed honestly in no
aisle is read. `guess(for:)` and `inferred(from:fallback:)` are separate
because "we do not know" and "we think this is miscellaneous" are different
answers, and collapsing them is how a guess overwrites a choice somebody made
by hand.

**Conflict resolution** lives in
`Collection<ChoreCompletion>.deduplicatedByOccurrence()` and, in the same shape,
in `Collection<PlannedMeal>.deduplicatedBySlot()`. Both resolve by the earlier
record with the identifier as tiebreaker, so every device converges on the same
winner without negotiating. When sync arrives, these are the functions to
revisit first, and the fact that there are now two of them is the argument for
extracting the rule rather than writing it a third time.

**A completion that was sent back is not a completion that counts.**
`Approval.countsAsDone` is one case wider than `countsTowardBalance`: work
waiting on a parent is done, work an adult rejected is not, and both the agenda
and the streak calculator have to agree about that. The streak calculator
filters rejected records *before* deduplicating, because deduplication keeps the
earliest record of an occurrence and would otherwise collapse a redo onto the
rejection it replaced.

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

## Schema versions

`FamilyHubStore.schemaVersion` is stamped into every export, and
`HouseholdArchive.migrated()` is the ladder that brings an older file up to the
current shape. Version 2 added the meal plan and version 3 the family calendar; an older file
restores as a household with no planned meals and no events, which is not a gap
to be filled in but the truth about a household that predated the feature.

Two habits keep that cheap. `HouseholdSnapshot` decodes every collection as
optional-with-empty rather than required, so a backup written before a feature
existed is readable by the build that adds it — the household itself is still
required, so a file missing the part that says whose data it is is still
refused. `ReminderSchedule` does the same for the settings a family has chosen,
because a record written once and read for years should not lose a preference,
or fail to decode entirely, over a field added later.

The rule that follows: adding a collection to the snapshot means bumping the
version, adding a migration case, and testing it against a file with the key
genuinely absent. Encoding an empty array and reading it back only proves the
current encoder can read itself. The calendar followed exactly that path and
the migration step for it is one line in a switch, which is the return on
having built the ladder at version 1 when it was the identity function.

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
