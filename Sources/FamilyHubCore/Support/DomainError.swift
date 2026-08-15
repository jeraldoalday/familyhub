import Foundation

/// Every way a domain operation can legitimately fail.
///
/// These are not programmer errors — they are the outcomes a household actually
/// produces: a blank chore title, points spent that were never earned, a chore
/// ticked off twice. Each case carries enough context for the UI to explain
/// itself without the view layer re-deriving the rule that was broken.
///
/// The enumeration grows alongside the features that raise its cases. Keeping
/// them in one type rather than one error per feature means a view can handle
/// "anything the domain rejected" in a single place, which is what an alert
/// presenter actually wants.
public enum DomainError: Error, Equatable, Sendable {

    // MARK: Validation

    /// A required piece of text was blank or only whitespace.
    case blank(field: Field)

    /// Text exceeded the maximum length for its field.
    case tooLong(field: Field, limit: Int)

    /// A number fell outside its permitted range.
    case outOfRange(field: Field, allowed: ClosedRange<Int>)

    // MARK: Membership

    /// The referenced member is not part of this household.
    case memberNotInHousehold(Member.ID)

    /// The household has no remaining seats on its current plan.
    case householdFull(limit: Int)

    /// Removing this member would leave the household with no adult, locking
    /// everyone out of settings, billing, and approvals.
    case wouldLeaveHouseholdWithoutAdult

    // MARK: Permissions

    /// The member's role does not permit this action.
    case notPermitted(action: Action, role: MemberRole)

    // MARK: Points and rewards

    /// A redemption was attempted with an insufficient balance.
    case insufficientPoints(balance: Int, required: Int)

    /// The reward is not available to redeem right now.
    case rewardUnavailable(reason: String)

    // MARK: Scheduling

    /// A recurrence rule was described in a way that can never produce a date,
    /// such as a weekly rule with no weekdays selected.
    case unsatisfiableRecurrence(reason: String)

    // MARK: Lookup

    /// The occurrence has already been completed. Completing twice would pay
    /// the points out twice.
    case alreadyCompleted

    /// The requested record does not exist, most often because another family
    /// member deleted it while this device was still showing it.
    case notFound(entity: String, id: String)
}

extension DomainError {
    /// The field a validation failure refers to, so the UI can highlight the
    /// offending text box rather than showing a banner over the whole form.
    public enum Field: String, Codable, Equatable, Sendable, CaseIterable {
        case householdName
        case memberName
        case choreTitle
        case choreNotes
        case listName
        case itemName
        case rewardName
        case eventTitle
        case points
        case quantity
    }

    /// A guarded operation, named so that permission checks and the messages
    /// they produce cannot drift apart.
    public enum Action: String, Codable, Equatable, Sendable, CaseIterable {
        case manageHousehold
        case inviteMember
        case removeMember
        case createChore
        case assignChore
        case completeOwnChore
        case completeOthersChore
        case approveCompletion
        case adjustPoints
        case createReward
        case redeemReward
        case manageShoppingList
        case manageMealPlan
        case manageCalendar
    }
}

extension DomainError: LocalizedError {
    /// A message written to be read directly by a family member, including a
    /// child: what went wrong, in plain language, and what to do about it.
    public var errorDescription: String? {
        switch self {
        case .blank(let field):
            return "\(field.label) can't be empty."
        case .tooLong(let field, let limit):
            return "\(field.label) is too long. Keep it under \(limit) characters."
        case .outOfRange(let field, let allowed):
            return "\(field.label) must be between \(allowed.lowerBound) and \(allowed.upperBound)."
        case .memberNotInHousehold:
            return "That person isn't in this household anymore."
        case .householdFull(let limit):
            return "This household is full at \(limit) members. Upgrade to add more."
        case .wouldLeaveHouseholdWithoutAdult:
            return "Every household needs at least one adult. Make someone else an adult first."
        case .notPermitted(let action, let role):
            return "\(role.label)s can't \(action.label)."
        case .insufficientPoints(let balance, let required):
            return "That costs \(required) points and you have \(balance). \(required - balance) to go!"
        case .rewardUnavailable(let reason):
            return "That reward isn't available right now — \(reason)."
        case .unsatisfiableRecurrence(let reason):
            return "This chore would never come up: \(reason)."
        case .alreadyCompleted:
            return "This one's already done."
        case .notFound(let entity, _):
            return "That \(entity.lowercased()) no longer exists."
        }
    }
}

extension DomainError.Field {
    /// The human-readable name of the field, for use inside a sentence.
    public var label: String {
        switch self {
        case .householdName: "Household name"
        case .memberName: "Name"
        case .choreTitle: "Chore title"
        case .choreNotes: "Notes"
        case .listName: "List name"
        case .itemName: "Item name"
        case .rewardName: "Reward name"
        case .eventTitle: "Event title"
        case .points: "Points"
        case .quantity: "Quantity"
        }
    }
}

extension DomainError.Action {
    /// The action as a verb phrase, so it reads correctly inside the sentence
    /// "Children can't …".
    public var label: String {
        switch self {
        case .manageHousehold: "change household settings"
        case .inviteMember: "invite people"
        case .removeMember: "remove people"
        case .createChore: "create chores"
        case .assignChore: "assign chores"
        case .completeOwnChore: "complete their own chores"
        case .completeOthersChore: "complete someone else's chore"
        case .approveCompletion: "approve completed chores"
        case .adjustPoints: "change points"
        case .createReward: "create rewards"
        case .redeemReward: "redeem rewards"
        case .manageShoppingList: "change shopping lists"
        case .manageMealPlan: "change the meal plan"
        case .manageCalendar: "change the calendar"
        }
    }
}
