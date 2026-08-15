import Foundation

/// How a member is represented visually throughout the app.
///
/// Stored as a palette entry and an optional glyph rather than as image data.
/// A household organizer is glanced at dozens of times a day, so identity has
/// to be readable at 24 points on a widget — a colour and a symbol do that far
/// better than a cropped photograph, and they cost nothing to sync.
public struct Avatar: Hashable, Sendable, Codable {
    /// The member's colour, chosen from a fixed accessible palette.
    public var color: AvatarColor

    /// An optional emoji shown instead of the member's initials.
    public var emoji: String?

    /// Creates an avatar.
    ///
    /// - Parameter emoji: Trimmed to a single grapheme cluster if supplied, so
    ///   a pasted string can never blow out the layout of an avatar circle.
    public init(color: AvatarColor, emoji: String? = nil) {
        self.color = color
        self.emoji = emoji
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(\.first)
            .map(String.init)
    }

    /// A random avatar, used when adding a member before they have chosen one.
    public static func random() -> Avatar {
        Avatar(color: AvatarColor.allCases.randomElement() ?? .blue)
    }

    /// The avatar colour least used by the given members, so a newly added
    /// family member is visually distinct from everyone already present rather
    /// than randomly colliding with a sibling.
    public static func distinct(from members: some Collection<Member>) -> Avatar {
        var usage: [AvatarColor: Int] = [:]
        for color in AvatarColor.allCases {
            usage[color] = 0
        }
        for member in members {
            usage[member.avatar.color, default: 0] += 1
        }
        // Ties break by palette order rather than randomly, so adding three
        // members in a row yields three predictable, well-spaced colours.
        let leastUsed = AvatarColor.allCases.min { lhs, rhs in
            let lhsCount = usage[lhs] ?? 0
            let rhsCount = usage[rhs] ?? 0
            if lhsCount != rhsCount { return lhsCount < rhsCount }
            return lhs.paletteIndex < rhs.paletteIndex
        }
        return Avatar(color: leastUsed ?? .blue)
    }
}

/// The fixed avatar palette.
///
/// A closed set rather than a free colour picker. Every entry is checked to
/// hold a contrast ratio of at least 4.5:1 against white text in both light and
/// dark appearance, which a user-chosen colour cannot be. Names map to asset
/// catalog colours so the exact values live with the design system.
public enum AvatarColor: String, Codable, Sendable, CaseIterable {
    case blue
    case teal
    case green
    case lime
    case amber
    case orange
    case red
    case pink
    case purple
    case indigo

    /// Position in the palette, used to break ties deterministically.
    public var paletteIndex: Int {
        AvatarColor.allCases.firstIndex(of: self) ?? 0
    }

    /// The asset catalog name for this colour.
    public var assetName: String {
        "Avatar/\(rawValue.capitalized)"
    }

    /// A display name, for the colour picker's accessibility label.
    public var label: String {
        rawValue.capitalized
    }
}
