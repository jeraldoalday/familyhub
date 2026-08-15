import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Date providers")
struct DateProviderTests {

    @Test("Fixed provider builds the date the components describe")
    func fixedProviderBuildsDate() {
        let clock = FixedDateProvider(year: 2026, month: 3, day: 2)
        let components = clock.calendar.dateComponents([.year, .month, .day], from: clock.now)
        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 2)
    }

    @Test("The test calendar starts weeks on Monday in UTC")
    func testCalendarIsDeterministic() {
        // Every scheduling test depends on this. If the default calendar ever
        // picked up the machine's locale, weekly recurrence tests would pass in
        // London and fail in Manila.
        let calendar = Calendar.testDefault
        #expect(calendar.firstWeekday == 2)
        #expect(calendar.timeZone.secondsFromGMT() == 0)
    }

    @Test("Advancing by days crosses month boundaries")
    func advancingCrossesMonths() {
        let clock = FixedDateProvider(year: 2026, month: 1, day: 30)
        let later = clock.advanced(byDays: 3)
        let components = later.calendar.dateComponents([.month, .day], from: later.now)
        #expect(components.month == 2)
        #expect(components.day == 2)
    }

    @Test("Advancing by days handles a leap day")
    func advancingHandlesLeapDay() {
        // 2028 is a leap year: 28 February plus one day is the 29th, not March.
        let clock = FixedDateProvider(year: 2028, month: 2, day: 28)
        let later = clock.advanced(byDays: 1)
        let components = later.calendar.dateComponents([.month, .day], from: later.now)
        #expect(components.month == 2)
        #expect(components.day == 29)
    }

    @Test("Today strips the time of day")
    func todayStripsTime() {
        let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 17, minute: 45)
        let components = clock.calendar.dateComponents(
            [.hour, .minute, .second],
            from: clock.today
        )
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    @Test("Day offsets look forwards and backwards")
    func dayOffsets() {
        let clock = FixedDateProvider(year: 2026, month: 3, day: 2)
        let yesterday = clock.day(offsetFromToday: -1)
        let tomorrow = clock.day(offsetFromToday: 1)
        #expect(clock.calendar.component(.day, from: yesterday) == 1)
        #expect(clock.calendar.component(.day, from: tomorrow) == 3)
    }

    @Test("System provider honours an explicit first weekday")
    func systemProviderHonoursWeekStart() {
        let provider = SystemDateProvider(firstWeekday: 1, timeZone: .gmt)
        #expect(provider.calendar.firstWeekday == 1)
        #expect(provider.calendar.timeZone == .gmt)
    }
}
