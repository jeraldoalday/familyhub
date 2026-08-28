# FamilyHub — road to production

Two weeks, from a tested domain core to something submittable to App Review.

## Where things stand

**Day 1 is done, and then some.** The domain and store layers are complete and
tested: 785 tests covering recurrence, chore rotation, permissions, the points
ledger, shopping lists, streaks, the weekly recap, workload fairness, reminder
planning, meal planning, the family calendar, household-wide search, covering
each other's chores, the command layer, the change feed, and the backup format.
`make check` builds, tests, and lints in a few seconds.

Some of that was pulled forward out of later days on purpose. Streaks,
reminders, and the recap are all decisions about *what the app should say*, and
deciding those against a test suite is faster and considerably more honest than
deciding them against a running build at seven in the evening. What they leave
for their own days is wiring rather than judgement.

Three smaller things were pulled forward on the same argument. Onboarding's
"pick your first chores" step now has a catalogue behind it rather than a
screen that will have to invent one — what a chore is worth and how often it
genuinely needs doing are judgements, and judgements are cheaper to make
against a test suite than against a half-built screen at seven in the evening.
Search was pulled forward because it is the one feature that has to know about
every other one, and writing it after six screens each have their own filter
means deleting six filters. And an item's aisle is now guessed from its name,
which turned the aisle grouping from a feature nobody would reach — it needed a
ten-item menu on the fast path — into one that works by default, including on
the list the meal plan generates without a person touching it.

Covering a chore was pulled forward on a different argument again: it is the
first thing a family will ask for once the rota exists, and every decision in it
is a judgement about what a household means by a favour. Only the person the day
falls to may ask. An accepted cover adds somebody entitled to do the work rather
than replacing whoever the rota named, so a child whose evening frees up is not
told they may not do their own chore. A covered day counts against whoever took
it on when the fairness screen adds the week up. Those are cheaper to settle
against a test suite than against four screens that have each already assumed
something different — and the alternative was shipping a rota that insists Sam
owes the bins on the one Tuesday somebody else took them out.

The calendar was pulled forward for a different reason. It was the last feature
the README promised that the domain could not answer a single question about,
and the error type had been carrying `eventTitle` and `manageCalendar` since
before there was a record for either to refer to. Building it against the
recurrence engine that already existed cost a fraction of what building it
after the views depend on a shape would have.

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
management, the approvals queue, the points history, and the two rows covering
needs: an ask on the chore that has one, and an inbox of the asks a person can
answer — `coverInbox(for:on:)` already answers the second, and sharing a
shopping list is `ShoppingListText` handed to a `UIActivityViewController`. Same
pattern as day 3, so it should move faster. The meal plan's week grid and the
calendar's are the stretch items here rather than commitments: `MealPlan` and `FamilyCalendar`
already answer everything either grid needs to render — including which of two
things a child has been double-booked into — so each is a day's view code
whenever there is a day for it.

## Milestone 2 — making it feel finished (days 5–8)

**Day 5 — onboarding.** Create-household, add-members, and pick-first-chores.
This is the flow that decides whether a family ever reaches the value, and it
is worth more attention than its size suggests. Includes the guided tour
running against `DemoHousehold`. The last step is now presentation rather than
decision: `ChorePack` holds five themed sets filtered by who is actually in the
household, and `installChorePack` handles the household that has already
written half of one down.

**Day 6 — consolidation.** Three days of view code will have produced
duplicated modifiers, near-identical rows, and at least one piece of business
logic that leaked into a view and belongs in `FamilyHubCore`. This day pulls
that back. It will be net-negative on lines and is not optional: it is far
cheaper now than after notifications and widgets depend on the mess.

**Day 7 — notifications.** `ReminderPlanner` already decides what is worth
saying and when: the morning digest, the approval queue, the streak about to
break, the afternoon nudge to whoever is cooking, the Sunday prompt about next
week's undecided dinners, the appointment that outranks all of them, the ask
from somebody who needs their chore covered today, and the per-person daily cap
that keeps the channel from being switched off. What is left is the platform
half — authorisation, translating each `Reminder` into a
`UNNotificationRequest`, and re-planning on launch and on change. Smaller than
it was.

**Day 8 — widgets and Shortcuts.** A home-screen widget for today's chores and
a Lock Screen widget for the point balance. App Intents for "add to the
shopping list" and "mark my chore done", which is also what makes Siri work.

## Milestone 3 — shippable (days 9–12)

**Day 9 — accessibility.** VoiceOver labels on every control, Dynamic Type up
to the accessibility sizes, contrast checks, reduced-motion honoured. Mostly
auditing and fixing; a small diff and a genuinely non-optional day. An app a
child with low vision cannot use is not finished.

**Day 10 — performance and edge cases.** The agenda, the recap, and the streak
calculator have already been profiled against a household with two years of
history and share one walk of each chore's schedule; `HotPathTests` keeps them
that way. What is left for this day is the part that needs a running app —
scroll performance, image and layout cost, empty states, error states, and the
offline paths.

**Day 11 — monetisation.** StoreKit 2 for FamilyHub Plus, the paywall, and
restore-purchases. The tier limits are already enforced in the domain, so this
is the purchase flow rather than a re-plumbing.

**Day 12 — App Store preparation.** Icon, screenshots (from `DemoHousehold`,
which is deterministic precisely so these reproduce), description, keywords,
privacy nutrition label, and the support page App Review requires. The data
export the privacy label has to describe already exists as `HouseholdArchive`,
so the label describes something real rather than something promised.

## Milestone 4 — release (days 13–14)

**Day 13 — TestFlight.** Ship to real families and watch what they do. Reserve
the day for fixing what they hit; something always surfaces.

**Day 14 — submission.** Final fixes, archive, submit.

## Deliberately out of scope

Cutting these is what makes the rest fit:

- **iCloud sync.** Chosen against for v1. The store abstraction, the
  append-only ledger, and now the change feed are built so it can be added
  without touching business logic, but sync brings account states, an
  invitation flow, and a support burden that does not fit two weeks. What a
  family can have today is a backup file they carry across themselves, which
  covers the new-phone case without covering the two-phones-at-once one.
- **A meal planning *interface*.** The domain is built — slots, cooks,
  ingredients, the week view, the gaps, and the command that turns a planned
  week into a shopping list — and the tier already sold it, which is why it was
  finished rather than left half-declared in an enum. What is out of scope is
  the screen: it lands with the rest of the interface work, and if the fortnight
  slips it is the first surface to cut, because a family can plan meals through
  the shopping list they already have.
- **A family calendar *interface*.** The domain is built — recurring events on
  the same engine the chores use, all-day and timed entries, who each one
  concerns, and per-person clash detection — and the error type had been
  naming `eventTitle` and `manageCalendar` since long before there was a record
  to refer to. What is out of scope is the screen, on the same terms as the
  meal plan's.

  This bullet previously said the whole feature was out of scope because it
  "overlaps heavily with the system Calendar app". That argument was wrong in a
  way worth recording. The overlap is with the *storage* of appointments, which
  is the part FamilyHub does not want; what a family cannot get from the
  Calendar app is a calendar that knows the same people the chore rota knows,
  so that "Sam is at swimming" and "Sam has the bins tonight" are two facts
  about one child rather than two apps that have never met. Clash detection per
  person is the visible form of that, and it is not something an EventKit
  import would have produced.
- **Reading the system calendar.** EventKit import stays out. It is a
  permission prompt, a sync loop, and a merge policy, all in service of a
  feature nobody asked for in the first week.
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
