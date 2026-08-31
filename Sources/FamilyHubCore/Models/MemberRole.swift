import Foundation

/// What a person is allowed to do in the household.
///
/// Roles are deliberately coarse. A household is not an enterprise, and a
/// permission matrix with twenty toggles is a support burden, not a feature.
/// Four roles cover the real cases: the parent who set the app up, the other
/// adult, a teenager who can be trusted with the shopping list, and a younger
/// child who should only ever tick off their own chores.
public enum MemberRole: String, Codable, Sendable, CaseIterable, Comparable {
    /// Created the household. Can do everything, including billing and deleting
    /// the household itself. There is always at least one.
    case owner

    /// A parent or guardian. Everything except deleting the household.
    case adult

    /// An older child. Manages shared lists and their own chores, and can see
    /// the whole family calendar, but cannot change points or approve work.
    case teen

    /// A younger child. Sees and completes their own chores, redeems rewards
    /// they have earned, and adds to the shopping list.
    case child

    /// Ordered most to least privileged, so `sorted()` puts parents first in a
    /// member list and `max()` finds the most privileged remaining member.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.privilegeRank < rhs.privilegeRank
    }

    private var privilegeRank: Int {
        switch self {
        case .child: 0
        case .teen: 1
        case .adult: 2
        case .owner: 3
        }
    }

    /// Whether this role counts as an adult for the purposes of the rule that
    /// every household must retain someone who can manage it.
    public var isAdult: Bool {
        self == .owner || self == .adult
    }

    /// A display name for the role.
    public var label: String {
        switch self {
        case .owner: "Owner"
        case .adult: "Adult"
        case .teen: "Teen"
        case .child: "Child"
        }
    }

    /// The role in the plural, for the sentence a refusal is written into.
    ///
    /// Spelled out per case rather than by appending an "s" to ``label``,
    /// because exactly one of the four does not take one — and "Childs can't
    /// redeem rewards" is a message a six year old reads, in an app whose whole
    /// job is to be trusted by them about what they are and are not allowed to
    /// do.
    public var pluralLabel: String {
        switch self {
        case .owner: "Owners"
        case .adult: "Adults"
        case .teen: "Teens"
        case .child: "Children"
        }
    }

    /// A one-line explanation shown beneath the role when inviting someone, so
    /// the person choosing understands what they are granting.
    public var summary: String {
        switch self {
        case .owner:
            "Full access, including billing and deleting the household."
        case .adult:
            "Can manage chores, points, rewards, and everyone's schedules."
        case .teen:
            "Can complete their own chores and manage shared lists."
        case .child:
            "Can complete their own chores and redeem rewards they've earned."
        }
    }

    /// The SF Symbol shown alongside the role.
    public var symbolName: String {
        switch self {
        case .owner: "crown.fill"
        case .adult: "person.fill"
        case .teen: "figure.wave"
        case .child: "figure.child"
        }
    }

    /// Roles that `self` is allowed to assign to someone else.
    ///
    /// An adult can promote a teen but cannot mint another owner — ownership
    /// transfers through an explicit, separate flow so it cannot happen by
    /// mis-tapping a picker.
    public var assignableRoles: [MemberRole] {
        switch self {
        case .owner: [.adult, .teen, .child]
        case .adult: [.teen, .child]
        case .teen, .child: []
        }
    }
}
