import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Members")
struct MemberTests {

    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2)
    private let householdID = Identifier<Household>()

    private func makeMember(
        name: String = "Jerald",
        role: MemberRole = .owner,
        birthday: Date? = nil
    ) throws -> Member {
        try Member(
            householdID: householdID,
            name: name,
            role: role,
            birthday: birthday,
            joinedAt: clock.now
        )
    }

    // MARK: Initials

    @Test("Takes initials from the first and last word")
    func initialsFromTwoNames() throws {
        let member = try makeMember(name: "Mary Jane Alday")
        #expect(member.initials == "MA")
    }

    @Test("A single name yields one initial")
    func initialsFromOneName() throws {
        #expect(try makeMember(name: "Jerald").initials == "J")
    }

    @Test("An emoji-only name yields its first grapheme, not an empty string")
    func initialsFromEmojiName() throws {
        // Names are validated as non-blank, but non-blank does not mean it
        // contains letters. Slicing a multi-code-point emoji by UTF-16 offset
        // would produce a broken glyph, so this walks graphemes.
        let member = try makeMember(name: "👩‍🚀")
        #expect(member.initials == "👩‍🚀")
    }

    @Test("Initials are uppercased")
    func initialsAreUppercased() throws {
        #expect(try makeMember(name: "ana lopez").initials == "AL")
    }

    // MARK: Roles

    @Test("Owners and adults count as adults; teens and children do not")
    func adultRoles() {
        #expect(MemberRole.owner.isAdult)
        #expect(MemberRole.adult.isAdult)
        #expect(!MemberRole.teen.isAdult)
        #expect(!MemberRole.child.isAdult)
    }

    @Test("Roles order from least to most privileged")
    func rolesAreOrdered() {
        #expect(MemberRole.child < MemberRole.teen)
        #expect(MemberRole.teen < MemberRole.adult)
        #expect(MemberRole.adult < MemberRole.owner)
    }

    @Test("An adult cannot mint another owner")
    func adultsCannotCreateOwners() {
        // Ownership transfer is a deliberate, separate flow. It must not be
        // possible to hand over billing rights by mis-tapping a role picker.
        #expect(!MemberRole.adult.assignableRoles.contains(.owner))
        #expect(!MemberRole.owner.assignableRoles.contains(.owner))
        #expect(MemberRole.teen.assignableRoles.isEmpty)
        #expect(MemberRole.child.assignableRoles.isEmpty)
    }

    // MARK: Removal

    @Test("Removal is a tombstone, not a delete")
    func removalKeepsTheRecord() throws {
        // Past completions and ledger entries point at this member. Erasing
        // them would silently rewrite every other member's history.
        let member = try makeMember()
        let removed = member.removed(at: clock.now)
        #expect(!removed.isActive)
        #expect(removed.id == member.id)
        #expect(removed.name == member.name)

        let reinstated = removed.reinstated()
        #expect(reinstated.isActive)
    }

    // MARK: Birthdays

    @Test("Computes age in whole years")
    func computesAge() throws {
        let birthday = FixedDateProvider(year: 1990, month: 3, day: 1).now
        let member = try makeMember(birthday: birthday)
        #expect(member.age(on: clock.now, calendar: clock.calendar) == 36)
    }

    @Test("Age is nil when no birthday was shared")
    func ageIsOptional() throws {
        #expect(try makeMember().age(on: clock.now, calendar: clock.calendar) == nil)
    }

    @Test("Recognises a birthday in a different year")
    func recognisesBirthday() throws {
        let birthday = FixedDateProvider(year: 1990, month: 3, day: 2).now
        let member = try makeMember(birthday: birthday)
        #expect(member.hasBirthday(on: clock.now, calendar: clock.calendar))

        let notToday = try makeMember(
            birthday: FixedDateProvider(year: 1990, month: 3, day: 3).now
        )
        #expect(!notToday.hasBirthday(on: clock.now, calendar: clock.calendar))
    }

    @Test("A leap-year birthday lands on the last day of February in other years")
    func leapYearBirthdayFallsBack() throws {
        // 2026 is not a leap year. Matching the month and day exactly would
        // give a child born on 29 February a birthday every fourth year, which
        // is a charming joke exactly once and then a bug report from a seven
        // year old.
        let member = try makeMember(
            birthday: FixedDateProvider(year: 2016, month: 2, day: 29).now
        )
        let calendar = Calendar.testDefault

        let lastDayOfFebruary = FixedDateProvider(year: 2026, month: 2, day: 28).now
        #expect(member.hasBirthday(on: lastDayOfFebruary, calendar: calendar))

        // February is kept rather than spilling into March, because a family
        // asked when the birthday is says 'the end of February'.
        let firstOfMarch = FixedDateProvider(year: 2026, month: 3, day: 1).now
        #expect(!member.hasBirthday(on: firstOfMarch, calendar: calendar))

        let anyOtherDay = FixedDateProvider(year: 2026, month: 2, day: 27).now
        #expect(!member.hasBirthday(on: anyOtherDay, calendar: calendar))
    }

    @Test("A leap-year birthday still lands on the 29th in a leap year")
    func leapYearBirthdayIsExactWhenItCanBe() throws {
        let member = try makeMember(
            birthday: FixedDateProvider(year: 2016, month: 2, day: 29).now
        )
        let calendar = Calendar.testDefault

        #expect(
            member.hasBirthday(
                on: FixedDateProvider(year: 2028, month: 2, day: 29).now, calendar: calendar
            )
        )
        // And not twice in the same week.
        #expect(
            !member.hasBirthday(
                on: FixedDateProvider(year: 2028, month: 2, day: 28).now, calendar: calendar
            )
        )
    }

    @Test("The last day of February is not everyone's birthday")
    func nonLeapBirthdaysAreUnaffected() throws {
        // The fallback must not catch a child genuinely born on the 28th, nor
        // one born on the 29th of a different month.
        let calendar = Calendar.testDefault
        let born28 = try makeMember(
            birthday: FixedDateProvider(year: 2016, month: 2, day: 28).now
        )
        let born29March = try makeMember(
            birthday: FixedDateProvider(year: 2016, month: 3, day: 29).now
        )
        let lastDayOfFebruary = FixedDateProvider(year: 2026, month: 2, day: 28).now

        #expect(born28.hasBirthday(on: lastDayOfFebruary, calendar: calendar))
        #expect(!born29March.hasBirthday(on: lastDayOfFebruary, calendar: calendar))
    }

    // MARK: Ordering

    @Test("Display order puts adults first, then alphabetical")
    func displayOrder() throws {
        let members = [
            try makeMember(name: "Zoe", role: .child),
            try makeMember(name: "Adam", role: .child),
            try makeMember(name: "Beth", role: .owner),
            try makeMember(name: "Carl", role: .adult),
        ]
        let sorted = members.sorted(by: Member.displayOrder)
        #expect(sorted.map(\.name.value) == ["Beth", "Carl", "Adam", "Zoe"])
    }

    @Test("Identical names still sort deterministically")
    func orderingIsStableForDuplicateNames() throws {
        // Two children called Sam is not a hypothetical in a blended family.
        // Without the identifier tiebreaker the list order would flicker
        // between launches and the diffable data source would animate rows for
        // no reason.
        let a = try makeMember(name: "Sam", role: .child)
        let b = try makeMember(name: "Sam", role: .child)
        let forward = [a, b].sorted(by: Member.displayOrder).map(\.id)
        let backward = [b, a].sorted(by: Member.displayOrder).map(\.id)
        #expect(forward == backward)
    }

    // MARK: Avatars

    @Test("Distinct avatar picks the least-used colour")
    func distinctAvatarAvoidsCollisions() throws {
        var members: [Member] = []
        for _ in 0..<3 {
            let avatar = Avatar.distinct(from: members)
            members.append(
                try Member(
                    householdID: householdID,
                    name: "Member",
                    role: .child,
                    avatar: avatar,
                    joinedAt: clock.now
                )
            )
        }
        let colors = members.map(\.avatar.color)
        #expect(Set(colors).count == 3)
    }

    @Test("Avatar emoji is clamped to a single grapheme")
    func avatarEmojiIsClamped() {
        // A pasted string would otherwise blow out the layout of every avatar
        // circle in the app.
        let avatar = Avatar(color: .blue, emoji: "🦊🐻🐼")
        #expect(avatar.emoji == "🦊")
        #expect(Avatar(color: .blue, emoji: "   ").emoji == nil)
    }
}
