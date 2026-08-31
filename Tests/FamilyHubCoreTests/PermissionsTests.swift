import Foundation
import Testing

@testable import FamilyHubCore

@Suite("Permissions")
struct PermissionsTests {

    private let calendar = Calendar.testDefault
    private var engine: RecurrenceEngine { RecurrenceEngine(calendar: calendar) }
    private let householdID = Identifier<Household>()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        FixedDateProvider(year: y, month: m, day: d, calendar: calendar).now
    }

    private func member(_ role: MemberRole, name: String = "Person") throws -> Member {
        try Member(
            householdID: householdID,
            name: name,
            role: role,
            joinedAt: date(2026, 1, 1)
        )
    }

    // MARK: The table

    @Test("Only the owner manages the household")
    func onlyOwnerManagesHousehold() {
        #expect(Permissions.allows(.manageHousehold, for: .owner))
        #expect(!Permissions.allows(.manageHousehold, for: .adult))
        #expect(!Permissions.allows(.manageHousehold, for: .teen))
        #expect(!Permissions.allows(.manageHousehold, for: .child))
    }

    @Test("Children cannot mint or adjust the currency")
    func childrenCannotTouchTheEconomy() {
        // If a child can create rewards or adjust points, the whole mechanic is
        // worth nothing.
        for action in [DomainError.Action.createReward, .adjustPoints, .approveCompletion] {
            #expect(!Permissions.allows(action, for: .child))
            #expect(!Permissions.allows(action, for: .teen))
            #expect(Permissions.allows(action, for: .adult))
            #expect(Permissions.allows(action, for: .owner))
        }
    }

    @Test("Everyone completes their own chores and spends what they earned")
    func everyoneCanDoTheirOwnWork() {
        for role in MemberRole.allCases {
            #expect(Permissions.allows(.completeOwnChore, for: role))
            #expect(Permissions.allows(.redeemReward, for: role))
            #expect(Permissions.allows(.manageShoppingList, for: role))
        }
    }

    @Test("Teens can create chores but not assign them")
    func teensCreateButDoNotAssign() {
        #expect(Permissions.allows(.createChore, for: .teen))
        #expect(!Permissions.allows(.assignChore, for: .teen))
        #expect(!Permissions.allows(.createChore, for: .child))
    }

    @Test("Check throws with the action and role attached")
    func checkThrowsWithContext() {
        #expect(throws: DomainError.notPermitted(action: .adjustPoints, role: .child)) {
            try Permissions.check(.adjustPoints, for: .child)
        }
    }

    @Test("Actions for a role are a subset of those for a more senior role")
    func seniorRolesAreSupersets() {
        // Not an invariant the table is forced to satisfy, but a violation
        // would almost certainly be a typo rather than a deliberate design.
        let child = Set(Permissions.actions(for: .child))
        let teen = Set(Permissions.actions(for: .teen))
        let adult = Set(Permissions.actions(for: .adult))
        let owner = Set(Permissions.actions(for: .owner))
        #expect(child.isSubset(of: teen))
        #expect(teen.isSubset(of: adult))
        #expect(adult.isSubset(of: owner))
    }

    // MARK: Household invariants

    @Test("Removing the last adult is refused")
    func cannotRemoveLastAdult() throws {
        // Two taps must not be able to lock a family out of their own settings,
        // billing, and approval queue with no way back that avoids support.
        let owner = try member(.owner, name: "Jerald")
        let child = try member(.child, name: "Sam")

        #expect(throws: DomainError.wouldLeaveHouseholdWithoutAdult) {
            try Permissions.checkRemoval(of: owner, from: [owner, child])
        }
    }

    @Test("Removing an adult is allowed when another remains")
    func canRemoveAdultWhenAnotherRemains() throws {
        let owner = try member(.owner, name: "Jerald")
        let adult = try member(.adult, name: "Mary")
        try Permissions.checkRemoval(of: adult, from: [owner, adult])
    }

    @Test("A removed member does not count as a remaining adult")
    func removedAdultsDoNotCount() throws {
        let owner = try member(.owner, name: "Jerald")
        let departed = try member(.adult, name: "Mary").removed(at: date(2026, 2, 1))

        #expect(throws: DomainError.wouldLeaveHouseholdWithoutAdult) {
            try Permissions.checkRemoval(of: owner, from: [owner, departed])
        }
    }

    @Test("Removing a child is always fine")
    func removingChildIsFine() throws {
        let owner = try member(.owner)
        let child = try member(.child)
        try Permissions.checkRemoval(of: child, from: [owner, child])
    }

    @Test("Demoting the last adult is refused, promoting is not")
    func demotionGuardsTheLastAdult() throws {
        let owner = try member(.owner, name: "Jerald")
        let child = try member(.child, name: "Sam")

        #expect(throws: DomainError.wouldLeaveHouseholdWithoutAdult) {
            try Permissions.checkRoleChange(of: owner, to: .teen, in: [owner, child])
        }
        try Permissions.checkRoleChange(of: child, to: .adult, in: [owner, child])
    }

    // MARK: Chore authorization

    @Test("A child may complete their own chore")
    func childCompletesOwnChore() throws {
        let child = try member(.child)
        let chore = try Chore(
            householdID: householdID,
            title: "Tidy room",
            assignment: .member(child.id),
            startDate: date(2026, 3, 2),
            createdBy: child.id,
            createdAt: date(2026, 3, 1)
        )
        try Permissions.authorizeCompletion(
            of: chore,
            on: date(2026, 3, 2),
            by: child,
            engine: engine
        )
    }

    @Test("A child may not complete a sibling's chore")
    func childCannotCompleteSiblingsChore() throws {
        // Ticking off someone else's chore moves points into their balance,
        // so it is an adult action.
        let sibling = try member(.child, name: "Sam")
        let child = try member(.child, name: "Alex")
        let chore = try Chore(
            householdID: householdID,
            title: "Tidy room",
            assignment: .member(sibling.id),
            startDate: date(2026, 3, 2),
            createdBy: sibling.id,
            createdAt: date(2026, 3, 1)
        )

        #expect(throws: DomainError.notPermitted(action: .completeOthersChore, role: .child)) {
            try Permissions.authorizeCompletion(
                of: chore,
                on: date(2026, 3, 2),
                by: child,
                engine: engine
            )
        }
    }

    @Test("An open chore is anyone's to claim")
    func openChoreIsAnyones() throws {
        let child = try member(.child)
        let chore = try Chore(
            householdID: householdID,
            title: "Empty the dishwasher",
            assignment: .anyone,
            startDate: date(2026, 3, 2),
            createdBy: child.id,
            createdAt: date(2026, 3, 1)
        )
        try Permissions.authorizeCompletion(
            of: chore,
            on: date(2026, 3, 2),
            by: child,
            engine: engine
        )
    }

    @Test("A removed member cannot complete anything")
    func removedMemberCannotComplete() throws {
        let departed = try member(.adult).removed(at: date(2026, 2, 1))
        let chore = try Chore(
            householdID: householdID,
            title: "Bins",
            startDate: date(2026, 3, 2),
            createdBy: departed.id,
            createdAt: date(2026, 3, 1)
        )

        #expect(throws: DomainError.memberNotInHousehold(departed.id)) {
            try Permissions.authorizeCompletion(
                of: chore,
                on: date(2026, 3, 2),
                by: departed,
                engine: engine
            )
        }
    }

    // MARK: Approval

    @Test("An adult may approve someone else's completion")
    func adultApprovesOthersWork() throws {
        let parent = try member(.adult, name: "Mary")
        let child = try member(.child, name: "Sam")
        let completion = ChoreCompletion(
            householdID: householdID,
            choreID: Identifier(),
            occurrenceDay: date(2026, 3, 2),
            completedBy: child.id,
            completedAt: date(2026, 3, 2),
            approval: .pending,
            pointsAwarded: 10,
            calendar: calendar
        )
        try Permissions.authorizeApproval(of: completion, by: parent)
    }

    @Test("Nobody approves their own work")
    func selfApprovalIsRefused() throws {
        // Self-approval makes the review step ceremonial; an adult whose chores
        // need no sign-off should turn approval off rather than rubber-stamp.
        let parent = try member(.adult, name: "Mary")
        let completion = ChoreCompletion(
            householdID: householdID,
            choreID: Identifier(),
            occurrenceDay: date(2026, 3, 2),
            completedBy: parent.id,
            completedAt: date(2026, 3, 2),
            approval: .pending,
            pointsAwarded: 10,
            calendar: calendar
        )

        #expect(throws: DomainError.notPermitted(action: .approveCompletion, role: .adult)) {
            try Permissions.authorizeApproval(of: completion, by: parent)
        }
    }

    @Test("A child may not approve anything")
    func childCannotApprove() throws {
        let child = try member(.child, name: "Sam")
        let completion = ChoreCompletion(
            householdID: householdID,
            choreID: Identifier(),
            occurrenceDay: date(2026, 3, 2),
            completedBy: Identifier(),
            completedAt: date(2026, 3, 2),
            approval: .pending,
            pointsAwarded: 10,
            calendar: calendar
        )

        #expect(throws: DomainError.notPermitted(action: .approveCompletion, role: .child)) {
            try Permissions.authorizeApproval(of: completion, by: child)
        }
    }

    // MARK: Calendar authorisation

    @Test("An adult may put something on the whole household's calendar")
    func adultMayScheduleForEveryone() throws {
        let parent = try member(.adult, name: "Mary")
        #expect(throws: Never.self) {
            try Permissions.authorizeEvent(for: .everyone, by: parent, in: [parent])
        }
    }

    @Test("A teen may book only themselves in")
    func teenMayScheduleOnlyThemselves() throws {
        let teen = try member(.teen, name: "Alex")
        let child = try member(.child, name: "Sam")
        let household = [teen, child]

        #expect(throws: Never.self) {
            try Permissions.authorizeEvent(
                for: .members([teen.id]), by: teen, in: household
            )
        }
        #expect(throws: DomainError.notPermitted(action: .manageCalendar, role: .teen)) {
            try Permissions.authorizeEvent(
                for: .members([child.id]), by: teen, in: household
            )
        }
        #expect(throws: DomainError.notPermitted(action: .manageCalendar, role: .teen)) {
            try Permissions.authorizeEvent(
                for: .members([teen.id, child.id]), by: teen, in: household
            )
        }
        #expect(throws: DomainError.notPermitted(action: .manageCalendar, role: .teen)) {
            try Permissions.authorizeEvent(for: .everyone, by: teen, in: household)
        }
    }

    @Test("A child may not change the calendar even for themselves")
    func childMayNotSchedule() throws {
        let child = try member(.child, name: "Sam")
        #expect(throws: DomainError.notPermitted(action: .manageCalendar, role: .child)) {
            try Permissions.authorizeEvent(
                for: .members([child.id]), by: child, in: [child]
            )
        }
    }

    @Test("An event may not name somebody who has left, or somebody who was never here")
    func participantsMustBeInTheHousehold() throws {
        let parent = try member(.adult, name: "Mary")
        let gone = try member(.child, name: "Sam").removed(at: date(2026, 2, 1))

        #expect(throws: DomainError.memberNotInHousehold(gone.id)) {
            try Permissions.authorizeEvent(
                for: .members([gone.id]), by: parent, in: [parent, gone]
            )
        }
        #expect(throws: DomainError.self) {
            try Permissions.authorizeEvent(
                for: .members([Identifier<Member>()]), by: parent, in: [parent]
            )
        }
    }

    // MARK: The refusal itself

    @Test("A refusal names the role the way a person would say it")
    func refusalsPluraliseTheRole() {
        #expect(
            DomainError.notPermitted(action: .redeemReward, role: .child).errorDescription
                == "Children can't redeem rewards.")
        #expect(
            DomainError.notPermitted(action: .createChore, role: .teen).errorDescription
                == "Teens can't create chores.")
        #expect(
            DomainError.notPermitted(action: .manageHousehold, role: .adult).errorDescription
                == "Adults can't change household settings.")
    }

    @Test("No role is refused in a sentence that misspells what it is")
    func noRefusalMisspellsARole() {
        for role in MemberRole.allCases {
            for action in DomainError.Action.allCases {
                let message = DomainError.notPermitted(action: action, role: role).errorDescription
                #expect(message?.hasPrefix(role.pluralLabel) == true)
                #expect(message?.contains("Childs") == false)
            }
        }
    }
}
