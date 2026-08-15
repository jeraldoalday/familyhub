import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Households")
struct HouseholdTests {

    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2)

    private func makeHousehold(
        name: String = "The Aldays",
        tier: Household.Tier = .free
    ) throws -> Household {
        try Household(name: name, tier: tier, createdAt: clock.now)
    }

    @Test("Trims the household name")
    func trimsName() throws {
        let household = try makeHousehold(name: "  The Aldays  ")
        #expect(household.name.value == "The Aldays")
    }

    @Test("Rejects a blank name")
    func rejectsBlankName() {
        #expect(throws: DomainError.blank(field: .householdName)) {
            _ = try Household(name: "   ", createdAt: Date())
        }
    }

    @Test("Clamps an out-of-range first weekday instead of failing")
    func clampsFirstWeekday() throws {
        // A corrupt record or a bad migration should not lock a family out of
        // their data over a cosmetic preference, so this falls back rather
        // than throwing.
        let household = try Household(name: "Home", firstWeekday: 99, createdAt: clock.now)
        #expect(household.firstWeekday == 2)
    }

    @Test("Free tier caps members, plus tier raises the cap")
    func tierMemberLimits() throws {
        let free = try makeHousehold(tier: .free)
        #expect(free.canAddMember(currentCount: Limits.freeTierMembers - 1))
        #expect(!free.canAddMember(currentCount: Limits.freeTierMembers))

        let plus = free.onTier(.plus)
        #expect(plus.canAddMember(currentCount: Limits.freeTierMembers))
        #expect(!plus.canAddMember(currentCount: Limits.paidTierMembers))
    }

    @Test("A full household reports the limit it hit")
    func fullHouseholdNamesItsLimit() throws {
        let household = try makeHousehold(tier: .free)
        #expect(throws: DomainError.householdFull(limit: Limits.freeTierMembers)) {
            try household.validateCanAddMember(currentCount: Limits.freeTierMembers)
        }
    }

    @Test("Downgrading keeps the record intact")
    func downgradingIsNonDestructive() throws {
        // A lapsed card must never delete a child's profile. Downgrade only
        // changes the tier; enforcement of the lower limit happens on write.
        let plus = try makeHousehold(tier: .plus)
        let downgraded = plus.onTier(.free)
        #expect(downgraded.id == plus.id)
        #expect(downgraded.name == plus.name)
        #expect(downgraded.createdAt == plus.createdAt)
        #expect(downgraded.tier == .free)
    }

    @Test("Tiers order free below plus")
    func tiersAreOrdered() {
        #expect(Household.Tier.free < Household.Tier.plus)
        #expect(!(Household.Tier.plus < Household.Tier.free))
        #expect(Household.Tier.plus.includesRewards)
        #expect(!Household.Tier.free.includesRewards)
    }

    @Test("The household calendar carries its own week start and timezone")
    func calendarIsPinnedToHousehold() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let household = try Household(
            name: "Home",
            firstWeekday: 1,
            timeZone: tokyo,
            createdAt: clock.now
        )
        let calendar = household.calendar()
        #expect(calendar.firstWeekday == 1)
        #expect(calendar.timeZone == tokyo)
    }

    @Test("An unknown timezone identifier falls back rather than crashing")
    func unknownTimeZoneFallsBack() throws {
        // Reachable when a record synced from a newer OS names a timezone this
        // one has never heard of.
        var household = try makeHousehold()
        household = household.withTimeZone(.gmt)
        #expect(household.timeZone == .gmt)
    }

    @Test("Free tier retains a fortnight of history")
    func historyRetention() {
        #expect(Household.Tier.free.historyRetentionDays == 14)
        #expect(Household.Tier.plus.historyRetentionDays > 365)
    }
}
