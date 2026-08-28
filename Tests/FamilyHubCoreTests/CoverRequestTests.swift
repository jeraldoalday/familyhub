import Foundation
import Testing

@testable import FamilyHubCore

/// Covers the record one person leaves when they ask somebody else to take a
/// chore off them for a day: what it can say, who it is addressed to, how it
/// settles, and how the household reads it back afterwards.
@Suite("Cover requests")
struct CoverRequestTests {

    // MARK: Fixture

    private let calendar = Calendar.testDefault
    /// 2 March 2026, a Monday.
    private let clock = FixedDateProvider(year: 2026, month: 3, day: 2, hour: 9)

    private let householdID = Identifier<Household>()
    private let choreID = Identifier<Chore>()
    private let sam = Identifier<Member>()
    private let alex = Identifier<Member>()
    private let mary = Identifier<Member>()

    private func makeRequest(
        askedOf: Identifier<Member>? = nil,
        note: String? = nil,
        day: Date? = nil,
        createdAt: Date? = nil,
        resolution: CoverRequest.Resolution = .open
    ) throws -> CoverRequest {
        try CoverRequest(
            householdID: householdID,
            choreID: choreID,
            day: day ?? clock.today,
            requestedBy: sam,
            askedOf: askedOf,
            note: note,
            createdAt: createdAt ?? clock.now,
            resolution: resolution,
            calendar: calendar
        )
    }

    // MARK: Construction

    @Test("A request normalises its day, so two devices agree on the occurrence")
    func normalisesDay() throws {
        let lateEvening = calendar.date(byAdding: .hour, value: 22, to: clock.today) ?? clock.now
        let request = try makeRequest(day: lateEvening)

        #expect(request.day == clock.today)
        #expect(
            request.occurrenceKey
                == ChoreCompletion.OccurrenceKey(choreID: choreID, day: clock.today))
    }

    @Test("A blank reason is no reason rather than an error")
    func blankNoteBecomesNil() throws {
        #expect(try makeRequest(note: "   \n ").note == nil)
        #expect(try makeRequest(note: nil).note == nil)
        #expect(
            try makeRequest(note: "  At football until seven ").note?.value
                == "At football until seven")
    }

    @Test("A reason longer than a notes field is refused")
    func longNoteIsRefused() {
        #expect(throws: DomainError.tooLong(field: .coverNote, limit: Limits.notesLength)) {
            try makeRequest(note: String(repeating: "a", count: Limits.notesLength + 1))
        }
    }

    @Test("A fresh request is open and unanswered")
    func startsOpen() throws {
        let request = try makeRequest()

        #expect(request.resolution == .open)
        #expect(request.resolution.isOpen)
        #expect(!request.resolution.isAccepted)
        #expect(request.resolution.coveringMemberID == nil)
        #expect(request.resolution.settledAt == nil)
        #expect(request.isOpenToAnyone)
    }

    // MARK: Who it is addressed to

    @Test("An open request reaches everybody except the person asking")
    func openRequestAddressesTheHousehold() throws {
        let request = try makeRequest()

        #expect(request.isAddressed(to: alex))
        #expect(request.isAddressed(to: mary))
        // Covering for yourself is not covering; it is doing your own chore.
        #expect(!request.isAddressed(to: sam))
    }

    @Test("A named request reaches only the person named")
    func namedRequestAddressesOnePerson() throws {
        let request = try makeRequest(askedOf: alex)

        #expect(!request.isOpenToAnyone)
        #expect(request.isAddressed(to: alex))
        #expect(!request.isAddressed(to: mary))
    }

    @Test("A settled request is addressed to nobody")
    func settledRequestAddressesNobody() throws {
        let request = try makeRequest().accepted(by: alex, at: clock.now)

        #expect(!request.isAddressed(to: alex))
        #expect(!request.isAddressed(to: mary))
    }

    // MARK: Settling

    @Test("Accepting records who took it on and when")
    func acceptingRecordsTheCover() throws {
        let accepted = try makeRequest().accepted(by: alex, at: clock.now)

        #expect(accepted.resolution == .accepted(by: alex, at: clock.now))
        #expect(accepted.resolution.isAccepted)
        #expect(accepted.resolution.coveringMemberID == alex)
        #expect(accepted.resolution.settledAt == clock.now)
        #expect(accepted.resolution.label == "Covered")
    }

    @Test("Declining closes the request rather than reopening it")
    func decliningClosesTheRequest() throws {
        // Reopening would put the chore back in front of the person who has
        // already said no, which is how a family learns to ignore the app.
        let declined = try makeRequest(askedOf: alex).declined(by: alex, at: clock.now)

        #expect(!declined.resolution.isOpen)
        #expect(!declined.resolution.isAccepted)
        #expect(declined.resolution.settledAt == clock.now)
    }

    @Test("Withdrawing is only possible while nobody has answered")
    func withdrawingAfterAnAnswerIsRefused() throws {
        let accepted = try makeRequest().accepted(by: alex, at: clock.now)

        #expect(throws: DomainError.coverAlreadySettled) {
            try accepted.withdrawn(at: clock.now)
        }
    }

    @Test("The second person to accept is told, not silently ignored")
    func secondAcceptanceIsRefused() throws {
        let accepted = try makeRequest().accepted(by: alex, at: clock.now)

        #expect(throws: DomainError.coverAlreadySettled) {
            try accepted.accepted(by: mary, at: clock.now)
        }
        #expect(throws: DomainError.coverAlreadySettled) {
            try accepted.declined(by: mary, at: clock.now)
        }
    }

    @Test("A note can be changed while the request stands")
    func noteCanBeChanged() throws {
        let request = try makeRequest(note: "Football")
        #expect(try request.withNote("Football until seven").note?.value == "Football until seven")
        #expect(try request.withNote(nil).note == nil)
    }

    // MARK: Lapsing

    @Test("A request stops asking once its day has gone by")
    func requestLapsesAfterItsDay() throws {
        let request = try makeRequest()
        let tomorrow = clock.day(offsetFromToday: 1)

        #expect(request.isLive(on: clock.now, calendar: calendar))
        #expect(!request.hasLapsed(on: clock.now, calendar: calendar))
        // Still the same day, however late it is: a chore can be done at
        // eleven at night, so the ask is still worth answering at ten.
        #expect(request.isLive(on: clock.now.addingTimeInterval(12 * 3600), calendar: calendar))

        #expect(request.hasLapsed(on: tomorrow, calendar: calendar))
        #expect(!request.isLive(on: tomorrow, calendar: calendar))
    }

    @Test("A settled request is never live, whatever the day")
    func settledRequestIsNotLive() throws {
        let withdrawn = try makeRequest().withdrawn(at: clock.now)

        #expect(!withdrawn.isLive(on: clock.now, calendar: calendar))
    }

    // MARK: Reading a household's requests back

    @Test("Open requests come back oldest first")
    func openRequestsAreOrdered() throws {
        let first = try makeRequest(createdAt: clock.now)
        let second = try makeRequest(createdAt: clock.now.addingTimeInterval(60))
        let answered = try makeRequest(createdAt: clock.now.addingTimeInterval(30))
            .accepted(by: alex, at: clock.now)

        let open = [second, answered, first].open

        #expect(open.map(\.id) == [first.id, second.id])
    }

    @Test("The earliest acceptance decides who is covering an occurrence")
    func earliestAcceptanceWins() throws {
        // A household really can hold two accepted requests for one square: a
        // child asks their sibling, hears nothing, asks the household, and
        // both answer while one device is offline. Every device has to pick
        // the same winner without negotiating.
        let key = ChoreCompletion.OccurrenceKey(choreID: choreID, day: clock.today)
        let early = try makeRequest().accepted(by: alex, at: clock.now)
        let late = try makeRequest().accepted(by: mary, at: clock.now.addingTimeInterval(120))

        #expect([late, early].coverFor(key) == alex)
        #expect([late, early].acceptedCoverFor(key)?.id == early.id)
    }

    @Test("An occurrence nobody accepted has no cover")
    func noAcceptanceMeansNoCover() throws {
        let key = ChoreCompletion.OccurrenceKey(choreID: choreID, day: clock.today)
        let declined = try makeRequest(askedOf: alex).declined(by: alex, at: clock.now)

        #expect([declined].coverFor(key) == nil)
        #expect([declined].about(key).count == 1)
    }

    @Test("Requests for another occurrence are not confused with this one")
    func requestsAreScopedToTheirOccurrence() throws {
        let today = ChoreCompletion.OccurrenceKey(choreID: choreID, day: clock.today)
        let tomorrow = try makeRequest(day: clock.day(offsetFromToday: 1))
            .accepted(by: alex, at: clock.now)

        #expect([tomorrow].coverFor(today) == nil)
    }

    @Test("A person's inbox holds the live requests they can answer")
    func inboxHoldsAnswerableRequests() throws {
        let toAlex = try makeRequest(askedOf: alex)
        let toMary = try makeRequest(askedOf: mary, createdAt: clock.now.addingTimeInterval(60))
        let toAnyone = try makeRequest(createdAt: clock.now.addingTimeInterval(120))
        let yesterday = try makeRequest(
            day: clock.day(offsetFromToday: -1),
            createdAt: clock.now.addingTimeInterval(180)
        )
        let all = [toAlex, toMary, toAnyone, yesterday]

        let inbox = all.addressedTo(alex, on: clock.now, calendar: calendar)

        #expect(inbox.map(\.id) == [toAlex.id, toAnyone.id])
        // Sam asked for all of these; none of them is Sam's to answer.
        #expect(all.addressedTo(sam, on: clock.now, calendar: calendar).isEmpty)
    }

    // MARK: Codable

    @Test("A request round-trips through JSON with its resolution intact")
    func roundTripsThroughJSON() throws {
        let original = try makeRequest(askedOf: alex, note: "Away at Gran's")
            .accepted(by: alex, at: clock.now)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CoverRequest.self, from: data)

        #expect(decoded == original)
        #expect(decoded.resolution.coveringMemberID == alex)
        #expect(decoded.note?.value == "Away at Gran's")
    }
}
