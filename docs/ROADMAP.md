# FamilyHub — road to production

Two weeks, from a tested domain core to something submittable to App Review.

## Where things stand

**Day 1 is done.** The domain and store layers are complete and tested: 208
tests covering recurrence, chore rotation, permissions, the points ledger,
shopping lists, and the command layer that ties them together. `make check`
builds and tests in under a second.

What does **not** exist yet is the app itself. That is deliberate — the
business rules were worth getting right first, because they are the part that
is expensive to change once views depend on them — but it does mean roughly
half the remaining work is user interface.

## A note on measuring this

The commit and line-count targets that framed this plan are worth naming
plainly: they measure typing, not progress. Day 6 below deletes more code than
it adds, and it is one of the more valuable days here. Days 9 and 10 are almost
entirely reading — profiling, accessibility auditing, fixing what the audit
finds — and will show up as small diffs.

The plan is sequenced by what has to be true before the next thing can start.
Where that produces a large day it says so, and where it produces a small one
it says that too.

## Milestone 1 — the app shell (days 2–4)

Nothing here can start without Xcode installed; the SwiftData `@Model` macro
and SwiftUI previews ship inside Xcode, not the Command Line Tools.

**Day 2 — persistence.** Create the Xcode project and the `FamilyHubData`
target: `@Model` entities mirroring the domain types, mapping in both
directions, and a `SwiftDataHouseholdStore` conforming to `HouseholdStore`. The
contract already exists and is already tested, so this is adapter work with a
clear target: the store test suite should pass against SwiftData exactly as it
passes against the in-memory implementation. Write that shared conformance
suite first.

**Day 3 — the three main screens.** Today, Chores, and Rewards, driven by
`HouseholdSnapshot` and `HouseholdCommands`. Previews run against
`DemoHousehold`, which already exists, so every screen has real data from the
first build. Expect this to be the largest day of the fortnight.

**Day 4 — the rest of the surface.** Shopping, family settings, member
management, the approvals queue, and the points history. Same pattern as day 3,
so it should move faster.

## Milestone 2 — making it feel finished (days 5–8)

**Day 5 — onboarding.** Create-household, add-members, and pick-first-chores.
This is the flow that decides whether a family ever reaches the value, and it
is worth more attention than its size suggests. Includes the guided tour
running against `DemoHousehold`.

**Day 6 — consolidation.** Three days of view code will have produced
duplicated modifiers, near-identical rows, and at least one piece of business
logic that leaked into a view and belongs in `FamilyHubCore`. This day pulls
that back. It will be net-negative on lines and is not optional: it is far
cheaper now than after notifications and widgets depend on the mess.

**Day 7 — notifications.** Local reminders for chores due today, approvals
waiting on a parent, and a nudge when a streak is about to break. All derived
from the recurrence engine, which already knows every future occurrence.

**Day 8 — widgets and Shortcuts.** A home-screen widget for today's chores and
a Lock Screen widget for the point balance. App Intents for "add to the
shopping list" and "mark my chore done", which is also what makes Siri work.

## Milestone 3 — shippable (days 9–12)

**Day 9 — accessibility.** VoiceOver labels on every control, Dynamic Type up
to the accessibility sizes, contrast checks, reduced-motion honoured. Mostly
auditing and fixing; a small diff and a genuinely non-optional day. An app a
child with low vision cannot use is not finished.

**Day 10 — performance and edge cases.** Profile the agenda against a household
with two years of history. Empty states, error states, and the offline paths.
Fix what Instruments finds.

**Day 11 — monetisation.** StoreKit 2 for FamilyHub Plus, the paywall, and
restore-purchases. The tier limits are already enforced in the domain, so this
is the purchase flow rather than a re-plumbing.

**Day 12 — App Store preparation.** Icon, screenshots (from `DemoHousehold`,
which is deterministic precisely so these reproduce), description, keywords,
privacy nutrition label, and the support page App Review requires.

## Milestone 4 — release (days 13–14)

**Day 13 — TestFlight.** Ship to real families and watch what they do. Reserve
the day for fixing what they hit; something always surfaces.

**Day 14 — submission.** Final fixes, archive, submit.

## Deliberately out of scope

Cutting these is what makes the rest fit:

- **iCloud sync.** Chosen against for v1. The store abstraction and the
  append-only ledger are built so it can be added without touching business
  logic, but sync brings conflict resolution, account states, and a support
  burden that does not fit two weeks.
- **Meal planning.** Modelled in the category enum, not built. It is a
  reasonable 1.1.
- **A family calendar.** Overlaps heavily with the system Calendar app; needs
  its own thinking rather than a fortnight's leftovers.
- **Android or web.** The domain layer is portable Swift with no Apple
  dependency beyond Foundation, so this stays open. It is not v1.

## The main risk

Days 3 and 4 are the ones that can overrun, because interface work expands to
fill whatever it is given and there are two screens on day 4 (approvals,
history) that could each swallow a day on their own.

If the schedule slips, the honest cut is the widgets on day 8 rather than
accessibility on day 9 or consolidation on day 6. Widgets are a feature the
next release can add. The other two are things that get more expensive every
day they are deferred.
