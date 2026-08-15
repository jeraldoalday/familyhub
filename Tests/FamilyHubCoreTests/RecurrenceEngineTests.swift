import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Recurrence engine")
struct RecurrenceEngineTests {

    private let calendar = Calendar.testDefault
    private var engine: RecurrenceEngine { RecurrenceEngine(calendar: calendar) }

    /// 2 March 2026 is a Monday. Every date in this suite is expressed relative
    /// to it so the assertions can be checked against a wall calendar.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        FixedDateProvider(year: year, month: month, day: day, calendar: calendar).now
    }

    private func days(_ dates: [Date]) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return dates.map(formatter.string(from:))
    }

    // MARK: - Once

    @Test("A one-off produces exactly its start date")
    func onceProducesStartDate() {
        let start = date(2026, 3, 2)
        let result = engine.occurrences(
            of: .once,
            startingOn: start,
            in: date(2026, 3, 1)...date(2026, 3, 31)
        )
        #expect(days(result) == ["2026-03-02"])
    }

    @Test("A one-off outside the window produces nothing")
    func onceOutsideWindow() {
        let result = engine.occurrences(
            of: .once,
            startingOn: date(2026, 2, 1),
            in: date(2026, 3, 1)...date(2026, 3, 31)
        )
        #expect(result.isEmpty)
    }

    // MARK: - Daily

    @Test("Daily produces every day in the window")
    func dailyProducesEveryDay() {
        let result = engine.occurrences(
            of: .daily,
            startingOn: date(2026, 3, 2),
            in: date(2026, 3, 2)...date(2026, 3, 6)
        )
        #expect(
            days(result) == [
                "2026-03-02", "2026-03-03", "2026-03-04", "2026-03-05", "2026-03-06",
            ])
    }

    @Test("Every-N-days keeps its phase from the start date")
    func everyThreeDaysKeepsPhase() {
        // The window opens after the start, so a naive implementation that
        // generated from the window would produce the 5th, 8th, 11th — the
        // wrong days entirely.
        let result = engine.occurrences(
            of: .everyDays(3),
            startingOn: date(2026, 3, 2),
            in: date(2026, 3, 5)...date(2026, 3, 15)
        )
        #expect(days(result) == ["2026-03-05", "2026-03-08", "2026-03-11", "2026-03-14"])
    }

    @Test("Daily never produces dates before the start")
    func dailyRespectsStart() {
        let result = engine.occurrences(
            of: .daily,
            startingOn: date(2026, 3, 10),
            in: date(2026, 3, 1)...date(2026, 3, 12)
        )
        #expect(days(result) == ["2026-03-10", "2026-03-11", "2026-03-12"])
    }

    @Test("Daily crosses a month boundary")
    func dailyCrossesMonths() {
        let result = engine.occurrences(
            of: .daily,
            startingOn: date(2026, 3, 30),
            in: date(2026, 3, 30)...date(2026, 4, 2)
        )
        #expect(days(result) == ["2026-03-30", "2026-03-31", "2026-04-01", "2026-04-02"])
    }

    // MARK: - Weekly

    @Test("Weekly produces only the selected weekdays")
    func weeklySelectedDays() throws {
        let rule = try RecurrenceRule.weekly(on: [.monday, .thursday])
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 3, 2),
            in: date(2026, 3, 2)...date(2026, 3, 15)
        )
        #expect(
            days(result) == [
                "2026-03-02",  // Mon
                "2026-03-05",  // Thu
                "2026-03-09",  // Mon
                "2026-03-12",  // Thu
            ])
    }

    @Test("Weekly emits days in the order they occur in the week")
    func weeklyIsAscendingWithinAWeek() throws {
        // The set is unordered; the output must not be. A Set iterated in hash
        // order would produce Thursday before Monday roughly half the time,
        // which would render a list view in a different order on each launch.
        let rule = try RecurrenceRule.weekly(on: [.saturday, .tuesday, .thursday])
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 3, 2),
            in: date(2026, 3, 2)...date(2026, 3, 8)
        )
        #expect(days(result) == ["2026-03-03", "2026-03-05", "2026-03-07"])
        #expect(result == result.sorted())
    }

    @Test("Fortnightly keeps its phase across a window that opens mid-cycle")
    func fortnightlyKeepsPhase() throws {
        // Anchored to the week of the start date. Asking for April must not
        // reset the alternation and flip the chore onto the wrong week.
        let rule = try RecurrenceRule.weekly(on: [.monday], everyWeeks: 2)
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 3, 2),
            in: date(2026, 4, 1)...date(2026, 4, 30)
        )
        #expect(days(result) == ["2026-04-13", "2026-04-27"])
    }

    @Test("A weekly rule starting mid-week skips days already past")
    func weeklySkipsDaysBeforeStart() throws {
        // Starting Wednesday, a Mon/Wed/Fri chore should not retroactively
        // produce that week's Monday.
        let rule = try RecurrenceRule.weekly(on: [.monday, .wednesday, .friday])
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 3, 4),
            in: date(2026, 3, 1)...date(2026, 3, 10)
        )
        #expect(days(result) == ["2026-03-04", "2026-03-06", "2026-03-09"])
    }

    @Test("Weekly with every day is equivalent to daily")
    func weeklyEveryDayMatchesDaily() throws {
        let rule = try RecurrenceRule.weekly(on: Weekday.everyDay)
        let window = date(2026, 3, 2)...date(2026, 3, 20)
        let weekly = engine.occurrences(of: rule, startingOn: date(2026, 3, 2), in: window)
        let daily = engine.occurrences(of: .daily, startingOn: date(2026, 3, 2), in: window)
        #expect(days(weekly) == days(daily))
    }

    // MARK: - Monthly

    @Test("Monthly produces the selected days")
    func monthlySelectedDays() throws {
        let rule = try RecurrenceRule.monthly(on: [1, 15])
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 3, 1),
            in: date(2026, 3, 1)...date(2026, 4, 30)
        )
        #expect(days(result) == ["2026-03-01", "2026-03-15", "2026-04-01", "2026-04-15"])
    }

    @Test("A day that does not exist in a month is skipped, not clamped")
    func monthlySkipsMissingDays() throws {
        // Clamping the 31st onto 28 February would make the chore arrive three
        // days early and collide with any rule that also asks for the 28th.
        let rule = try RecurrenceRule.monthly(on: [31])
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 1, 31),
            in: date(2026, 1, 1)...date(2026, 5, 31)
        )
        #expect(days(result) == ["2026-01-31", "2026-03-31", "2026-05-31"])
    }

    @Test("The last-day sentinel tracks each month's real length")
    func lastDayOfMonthTracksMonthLength() {
        let result = engine.occurrences(
            of: .lastDayOfEveryMonth,
            startingOn: date(2026, 1, 1),
            in: date(2026, 1, 1)...date(2026, 4, 30)
        )
        #expect(days(result) == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"])
    }

    @Test("The last-day sentinel handles a leap February")
    func lastDayHandlesLeapYear() {
        let result = engine.occurrences(
            of: .lastDayOfEveryMonth,
            startingOn: date(2028, 2, 1),
            in: date(2028, 2, 1)...date(2028, 2, 29)
        )
        #expect(days(result) == ["2028-02-29"])
    }

    @Test("Requesting both the 28th and the last day never duplicates a date")
    func monthlyDeduplicates() throws {
        // In a non-leap February these resolve to the same day. Emitting it
        // twice would award points twice for one chore.
        let rule = try RecurrenceRule.monthly(on: [28, RecurrenceRule.lastDayOfMonth])
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 2, 1),
            in: date(2026, 2, 1)...date(2026, 2, 28)
        )
        #expect(days(result) == ["2026-02-28"])
    }

    @Test("Every-N-months keeps its phase")
    func quarterlyKeepsPhase() throws {
        let rule = try RecurrenceRule.monthly(on: [1], everyMonths: 3)
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 1, 1),
            in: date(2026, 1, 1)...date(2026, 12, 31)
        )
        #expect(days(result) == ["2026-01-01", "2026-04-01", "2026-07-01", "2026-10-01"])
    }

    // MARK: - Bounds

    @Test("An end date stops the sequence")
    func endDateStopsSequence() throws {
        let rule = try RecurrenceRule.daily.ending(on: date(2026, 3, 5))
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 3, 2),
            in: date(2026, 3, 1)...date(2026, 3, 31)
        )
        #expect(days(result) == ["2026-03-02", "2026-03-03", "2026-03-04", "2026-03-05"])
    }

    @Test("An occurrence limit counts from the start, not from the window")
    func occurrenceLimitCountsFromStart() throws {
        // "Happens 5 times" must mean five times ever. Counting within the
        // requested window would let a chore recur forever, five per screen.
        let rule = try RecurrenceRule.daily.limited(to: 5)
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 3, 2),
            in: date(2026, 3, 4)...date(2026, 3, 31)
        )
        #expect(days(result) == ["2026-03-04", "2026-03-05", "2026-03-06"])
    }

    @Test("Skipped days are excluded but still consume the occurrence limit")
    func exceptionsConsumeTheLimit() throws {
        // Skipping a week must not silently extend a "5 times" chore to six.
        let rule = try RecurrenceRule.daily.limited(to: 5)
        let result = engine.occurrences(
            of: rule,
            startingOn: date(2026, 3, 2),
            in: date(2026, 3, 1)...date(2026, 3, 31),
            skipping: [date(2026, 3, 3)]
        )
        #expect(days(result) == ["2026-03-02", "2026-03-04", "2026-03-05", "2026-03-06"])
    }

    @Test("The maximum caps the returned count")
    func maximumCapsResults() {
        let result = engine.occurrences(
            of: .daily,
            startingOn: date(2026, 3, 2),
            in: date(2026, 3, 2)...date(2026, 12, 31),
            maximum: 3
        )
        #expect(result.count == 3)
    }

    @Test("A far-future window terminates instead of exhausting memory")
    func farFutureWindowTerminates() {
        // Guards the period ceiling. Without it this call would try to
        // materialise every day until the heat death of the universe.
        let result = engine.occurrences(
            of: .daily,
            startingOn: date(2026, 3, 2),
            in: date(2026, 3, 2)...Date.distantFuture,
            maximum: 10
        )
        #expect(result.count == 10)
    }

    // MARK: - Next occurrence

    @Test("Next occurrence is strictly after the given day")
    func nextOccurrenceIsStrictlyAfter() {
        let next = engine.nextOccurrence(
            of: .daily,
            startingOn: date(2026, 3, 2),
            after: date(2026, 3, 5)
        )
        #expect(days([next].compactMap { $0 }) == ["2026-03-06"])
    }

    @Test("Next occurrence skips exception days")
    func nextOccurrenceSkipsExceptions() {
        let next = engine.nextOccurrence(
            of: .daily,
            startingOn: date(2026, 3, 2),
            after: date(2026, 3, 5),
            skipping: [date(2026, 3, 6), date(2026, 3, 7)]
        )
        #expect(days([next].compactMap { $0 }) == ["2026-03-08"])
    }

    @Test("An exhausted one-off has no next occurrence")
    func exhaustedRuleHasNoNext() {
        let next = engine.nextOccurrence(
            of: .once,
            startingOn: date(2026, 3, 2),
            after: date(2026, 3, 5)
        )
        #expect(next == nil)
    }

    @Test("A rule past its end date has no next occurrence")
    func endedRuleHasNoNext() throws {
        let rule = try RecurrenceRule.daily.ending(on: date(2026, 3, 5))
        let next = engine.nextOccurrence(
            of: rule,
            startingOn: date(2026, 3, 2),
            after: date(2026, 3, 10)
        )
        #expect(next == nil)
    }

    // MARK: - Occurs on a day

    @Test("Occurs answers a single day without expanding the range")
    func occursOnDay() throws {
        let rule = try RecurrenceRule.weekly(on: [.monday])
        let start = date(2026, 3, 2)
        #expect(engine.occurs(rule, startingOn: start, on: date(2026, 3, 9)))
        #expect(!engine.occurs(rule, startingOn: start, on: date(2026, 3, 10)))
    }

    // MARK: - Calendar sensitivity

    @Test("Week start does not change which days a weekly rule produces")
    func weekStartDoesNotChangeResults() throws {
        // The household's first weekday affects ordering within a week and the
        // fortnightly anchor, but a Monday chore must land on Monday in a
        // household that starts its week on Sunday too.
        var sundayFirst = Calendar.testDefault
        sundayFirst.firstWeekday = 1
        let rule = try RecurrenceRule.weekly(on: [.monday, .friday])
        let window = date(2026, 3, 2)...date(2026, 3, 15)

        let mondayEngine = RecurrenceEngine(calendar: calendar)
        let sundayEngine = RecurrenceEngine(calendar: sundayFirst)
        let fromMonday = mondayEngine.occurrences(
            of: rule, startingOn: date(2026, 3, 2), in: window)
        let fromSunday = sundayEngine.occurrences(
            of: rule, startingOn: date(2026, 3, 2), in: window)
        #expect(days(fromMonday) == days(fromSunday))
    }
}
