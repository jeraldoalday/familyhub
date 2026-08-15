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

    // MARK: Lookup

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
