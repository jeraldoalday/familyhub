import Foundation

/// One person asking somebody else to take a chore off them, on one day.
///
/// The rota is the feature that stops the weekly argument, and this is the
/// feature that stops the rota causing a new one. A rotating chore assigns
/// Tuesday to Sam whether or not Sam is at football on Tuesday, and what a
/// family actually does about that is swap — usually by asking across the
/// kitchen. Until now the app knew nothing about it: the agenda still said Sam
/// owed the bins, the points still went to whoever the rota named, and Sam's
/// streak broke on a night somebody else genuinely did the work.
///
/// A request covers **one occurrence**, never the chore. Editing the rota to
/// move one Tuesday would move every Tuesday after it, which is a schedule
/// change disguised as a favour and is not what anybody meant. The chore, its
/// recurrence, and its assignment are untouched; a cover is an exception laid
/// over a single day, in the same spirit as the skipped days a chore already
/// carries.
///
/// The request is a record rather than a message. A message asks somebody to
/// remember; a record moves the chore on the other person's agenda, pays them
/// the points when they do it, and leaves the requester's streak alone.
public struct CoverRequest: Entity {
    public let id: Identifier<CoverRequest>

    /// The household this request belongs to.
    public let householdID: Identifier<Household>

    /// The chore being handed over.
    public let choreID: Identifier<Chore>

    /// Which occurrence — the start of the day the chore is due.
    public let day: Date

    /// Who is asking to be covered.
    public let requestedBy: Identifier<Member>

    /// Who was asked, or `nil` when the request is open to the whole household.
    ///
    /// Both forms matter and they are not the same ask. Naming somebody is what
    /// a child does when they have already agreed it with their sibling;
    /// leaving it open is what they do at eight in the morning when they need
    /// anybody at all, and a request that had to name a person would go
    /// unanswered because they picked the one who is also out.
    public let askedOf: Identifier<Member>?

    /// Why, in the requester's words — "I'm at football until seven".
    ///
    /// Optional, and worth having. A bare request is a chore appearing on
    /// somebody else's list for no visible reason, which is the thing families
    /// argue about; a reason is what makes it a favour rather than an
    /// instruction.
    public private(set) var note: ValidatedText?

    /// When it was asked.
    public let createdAt: Date

    /// Where the request got to.
    public private(set) var resolution: Resolution

    /// Creates a cover request.
    ///
    /// - Parameters:
    ///   - id: The record's identifier.
    ///   - householdID: The household it belongs to.
    ///   - choreID: The chore being handed over.
    ///   - day: The occurrence's day, normalised to the start of the day in
    ///     `calendar`.
    ///   - requestedBy: Who is asking.
    ///   - askedOf: Who is being asked, or `nil` for the whole household.
    ///   - note: An optional reason.
    ///   - createdAt: When the request was made.
    ///   - resolution: Where it stands. Defaults to open.
    ///   - calendar: The household's calendar, used to normalise the day.
    /// - Throws: ``DomainError/tooLong(field:limit:)`` if the note is longer
    ///   than a note should be.
    public init(
        id: Identifier<CoverRequest> = Identifier(),
        householdID: Identifier<Household>,
        choreID: Identifier<Chore>,
        day: Date,
        requestedBy: Identifier<Member>,
        askedOf: Identifier<Member>? = nil,
        note: String? = nil,
        createdAt: Date,
        resolution: Resolution = .open,
        calendar: Calendar
    ) throws {
        self.id = id
        self.householdID = householdID
        self.choreID = choreID
        // Normalised on the way in for the same reason a completion's day is:
        // two devices recording the same occurrence at different times of day
        // have to produce the same key or the agenda shows the chore twice.
        self.day = calendar.startOfDay(for: day)
        self.requestedBy = requestedBy
        self.askedOf = askedOf
        self.note = try ValidatedText.optional(
            note,
            field: .coverNote,
            limit: Limits.notesLength
        )
        self.createdAt = createdAt
        self.resolution = resolution
    }
}

// MARK: - Resolution

extension CoverRequest {
    /// What happened to a request.
    ///
    /// Four states rather than a pair of booleans, because "nobody has answered
    /// yet", "Alex said no", and "Alex said no and then Mary said yes" are
    /// three different things to show on a home screen, and a `isAccepted`
    /// flag beside a `isDeclined` flag can represent a fourth that means
    /// nothing.
    public enum Resolution: Hashable, Sendable, Codable {
        /// Nobody has answered yet.
        case open

        /// Somebody took it on, and is now responsible for the occurrence.
        case accepted(by: Identifier<Member>, at: Date)

        /// The person asked said no.
        ///
        /// A declined request is finished rather than reopened. Somebody who
        /// has been turned down needs to ask somebody else — reopening the same
        /// record would put the chore back in front of the person who has
        /// already answered, which is how an app teaches a family to ignore it.
        case declined(by: Identifier<Member>, at: Date)

        /// The requester took it back — usually because their plans changed.
        case withdrawn(at: Date)

        /// Whether the request is still waiting for an answer.
        public var isOpen: Bool { self == .open }

        /// Whether somebody has taken the chore on.
        public var isAccepted: Bool { coveringMemberID != nil }

        /// Who is covering, when somebody is.
        public var coveringMemberID: Identifier<Member>? {
            if case .accepted(let memberID, _) = self { return memberID }
            return nil
        }

        /// When the request stopped being open, if it has.
        public var settledAt: Date? {
            switch self {
            case .open: nil
            case .accepted(_, let date), .declined(_, let date), .withdrawn(let date): date
            }
        }

        /// A short phrase for the row that shows the request.
        public var label: String {
            switch self {
            case .open: "Waiting for an answer"
            case .accepted: "Covered"
            case .declined: "Declined"
            case .withdrawn: "Withdrawn"
            }
        }
    }
}

// MARK: - Derived values

extension CoverRequest {
    /// The occurrence this request is about.
    ///
    /// The same key a completion uses, deliberately: the two records describe
    /// one square on one person's agenda, and sharing the key is what lets the
    /// agenda join them without a second convention to keep in step.
    public var occurrenceKey: ChoreCompletion.OccurrenceKey {
        ChoreCompletion.OccurrenceKey(choreID: choreID, day: day)
    }

    /// Whether the request is open to anybody rather than to one named person.
    public var isOpenToAnyone: Bool { askedOf == nil }

    /// Whether `memberID` is being asked — either by name, or because the
    /// request is open to the household and they are not the one asking.
    ///
    /// - Parameter memberID: The person whose list is being built.
    /// - Returns: `true` when the request should appear as something they can
    ///   answer.
    public func isAddressed(to memberID: Identifier<Member>) -> Bool {
        guard resolution.isOpen, memberID != requestedBy else { return false }
        guard let askedOf else { return true }
        return askedOf == memberID
    }

    /// Whether the day this request covers has already gone by.
    ///
    /// - Parameters:
    ///   - date: The moment being asked about.
    ///   - calendar: The household's calendar.
    /// - Returns: `true` once `date` falls on a later day than the occurrence.
    public func hasLapsed(on date: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: date) > day
    }

    /// Whether the request still needs an answer as of `date`.
    ///
    /// An open request for yesterday is not a question anybody can usefully
    /// answer, and leaving it on a screen makes the list of things waiting on a
    /// person grow forever. It is left in the store rather than deleted —
    /// history is what tells a parent that the bins were swapped four times
    /// last month — but it stops asking.
    ///
    /// - Parameters:
    ///   - date: The moment being asked about.
    ///   - calendar: The household's calendar.
    /// - Returns: `true` when the request is open and its day has not passed.
    public func isLive(on date: Date, calendar: Calendar) -> Bool {
        resolution.isOpen && !hasLapsed(on: date, calendar: calendar)
    }
}

// MARK: - Mutation

extension CoverRequest {
    /// Returns a copy taken on by `memberID`.
    ///
    /// - Parameters:
    ///   - memberID: Who is covering.
    ///   - date: When they agreed.
    /// - Returns: The accepted request.
    /// - Throws: ``DomainError/coverAlreadySettled`` if somebody has already
    ///   answered it. Two siblings both tapping accept is the ordinary case,
    ///   not the exotic one, and the second of them has to be told rather than
    ///   silently overwriting the first.
    public func accepted(by memberID: Identifier<Member>, at date: Date) throws -> CoverRequest {
        try requireOpen()
        var copy = self
        copy.resolution = .accepted(by: memberID, at: date)
        return copy
    }

    /// Returns a copy turned down by `memberID`.
    ///
    /// - Parameters:
    ///   - memberID: Who said no.
    ///   - date: When they said it.
    /// - Returns: The declined request.
    /// - Throws: ``DomainError/coverAlreadySettled``.
    public func declined(by memberID: Identifier<Member>, at date: Date) throws -> CoverRequest {
        try requireOpen()
        var copy = self
        copy.resolution = .declined(by: memberID, at: date)
        return copy
    }

    /// Returns a copy the requester has taken back.
    ///
    /// - Parameter date: When they withdrew it.
    /// - Returns: The withdrawn request.
    /// - Throws: ``DomainError/coverAlreadySettled`` once somebody has
    ///   answered. A request that has been accepted is an arrangement between
    ///   two people, and unpicking it silently would hand the chore back to
    ///   somebody who believes it is no longer theirs.
    public func withdrawn(at date: Date) throws -> CoverRequest {
        try requireOpen()
        var copy = self
        copy.resolution = .withdrawn(at: date)
        return copy
    }

    /// Returns a copy with a different note, or none.
    public func withNote(_ newNote: String?) throws -> CoverRequest {
        var copy = self
        copy.note = try ValidatedText.optional(
            newNote,
            field: .coverNote,
            limit: Limits.notesLength
        )
        return copy
    }

    /// Throws unless the request is still open.
    private func requireOpen() throws {
        guard resolution.isOpen else {
            throw DomainError.coverAlreadySettled
        }
    }
}

// MARK: - Collections

extension Collection where Element == CoverRequest {
    /// The requests nobody has answered yet, oldest first.
    public var open: [CoverRequest] {
        filter(\.resolution.isOpen).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    /// The requests for one occurrence.
    ///
    /// - Parameter key: The occurrence to filter by.
    /// - Returns: Every request about that chore on that day, in any state.
    public func about(_ key: ChoreCompletion.OccurrenceKey) -> [CoverRequest] {
        filter { $0.occurrenceKey == key }
    }

    /// Who, if anybody, has taken on the given occurrence.
    ///
    /// A household can hold more than one request for the same square — a child
    /// asks their sibling, is turned down, and asks the household — so the
    /// question "who is doing this" cannot be answered by picking any accepted
    /// record. The earliest acceptance wins, with the identifier breaking an
    /// exact tie, so every device converges on the same answer without
    /// negotiating.
    ///
    /// - Parameter key: The occurrence being asked about.
    /// - Returns: The member covering it, or `nil` when nobody is.
    public func coverFor(_ key: ChoreCompletion.OccurrenceKey) -> Identifier<Member>? {
        acceptedCoverFor(key)?.resolution.coveringMemberID
    }

    /// The accepted request that settles the given occurrence.
    ///
    /// - Parameter key: The occurrence being asked about.
    /// - Returns: The winning request, or `nil` when none was accepted.
    public func acceptedCoverFor(_ key: ChoreCompletion.OccurrenceKey) -> CoverRequest? {
        about(key)
            .filter(\.resolution.isAccepted)
            .min { lhs, rhs in
                let left = lhs.resolution.settledAt ?? lhs.createdAt
                let right = rhs.resolution.settledAt ?? rhs.createdAt
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
    }

    /// The live requests `memberID` could answer, oldest first.
    ///
    /// - Parameters:
    ///   - memberID: The person whose list is being built.
    ///   - date: The moment being asked about, so a request for a day that has
    ///     gone by drops off.
    ///   - calendar: The household's calendar.
    /// - Returns: The requests addressed to them and still worth answering.
    public func addressedTo(
        _ memberID: Identifier<Member>,
        on date: Date,
        calendar: Calendar
    ) -> [CoverRequest] {
        open
            .filter { $0.isAddressed(to: memberID) }
            .filter { !$0.hasLapsed(on: date, calendar: calendar) }
    }
}
