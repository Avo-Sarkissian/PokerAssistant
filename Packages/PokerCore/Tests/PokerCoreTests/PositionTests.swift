import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

// MARK: - The seats that exist

/// The app offers tables of two to nine players, and used to offer three seats:
/// BTN, SB and BB. Everything else a nine-handed table has — under the gun through the
/// cutoff — could not be selected, and `Position(from:)` mapped any string it did not
/// recognise to `.btn`. So a cutoff was priced as a button, an under-the-gun open was
/// priced as a button, and so was the literal string "banana": raise $13.00, raise EV
/// 29.2432, "in position", identical to six decimal places.
@Suite("Seats at the table")
struct SeatTests {

    @Test("Every seat at the table is a selectable seat", arguments: 2...9)
    func seatCountMatchesTableSize(tableSize: Int) {
        let seats = Position.seats(tableSize: tableSize)
        #expect(seats.count == tableSize,
                "a \(tableSize)-handed table offers \(seats.count) seats: \(seats.map(\.rawValue))")
        #expect(Set(seats).count == tableSize, "a seat is listed twice: \(seats.map(\.rawValue))")
        #expect(seats.contains(.bb) && seats.contains(.sb),
                "both blinds are always posted; \(tableSize)-handed offers \(seats.map(\.rawValue))")
    }

    /// Heads-up, the small blind *is* the button — there is no third seat to hold it.
    /// Dealing a button at a two-handed table would put three players at it.
    @Test("Heads-up is the blinds and nothing else")
    func headsUpHasNoButtonSeat() {
        #expect(Position.seats(tableSize: 2) == [.sb, .bb])
        #expect(!Position.seats(tableSize: 2).contains(.btn))
        for tableSize in 3...9 {
            #expect(Position.seats(tableSize: tableSize).contains(.btn),
                    "\(tableSize)-handed has no button")
        }
    }

    /// Seats are listed in the order they act preflop, because that is the order the
    /// picker shows them in and the order a player reads a table in. The blinds post and
    /// act last; the button acts immediately before them.
    @Test("Seats are listed in preflop action order", arguments: 3...9)
    func seatsAreInPreflopActionOrder(tableSize: Int) {
        let seats = Position.seats(tableSize: tableSize)
        #expect(seats.suffix(3) == [.btn, .sb, .bb],
                "\(tableSize)-handed ends \(seats.suffix(3).map(\.rawValue))")
    }

    /// Shrinking the table removes the earliest seats and keeps the ones nearest the
    /// button, which is how a real table empties. The seats that are named for their
    /// distance from the button — cutoff, button, blinds — therefore sit at the end of
    /// every table that has them.
    ///
    /// Only those. The earliest seat is named for *acting first*, so which physical
    /// chair "UTG" refers to depends on how many are occupied — six-handed UTG is four
    /// seats off the button, nine-handed UTG is seven. That is why relative position is
    /// a function of the table size rather than a property of the seat.
    @Test("The seats named from the button sit at the end of every table", arguments: 4...9)
    func buttonAnchoredSeatsAreASuffix(tableSize: Int) {
        let seats = Position.seats(tableSize: tableSize)
        #expect(Array(seats.suffix(4)) == [.co, .btn, .sb, .bb],
                "\(tableSize)-handed ends \(seats.suffix(4).map(\.rawValue))")
    }

    @Test("The first seat to act is the one called under the gun", arguments: 5...9)
    func firstToActIsUnderTheGun(tableSize: Int) {
        #expect(Position.seats(tableSize: tableSize).first == .utg,
                "\(tableSize)-handed opens on \(Position.seats(tableSize: tableSize).first?.rawValue ?? "nobody")")
    }

    /// No orphaned increments: a table with a UTG+2 has a UTG+1 and a UTG.
    @Test("Numbered seats arrive in order", arguments: 2...9)
    func numberedSeatsArriveInOrder(tableSize: Int) {
        let seats = Set(Position.seats(tableSize: tableSize))
        if seats.contains(.utg2) { #expect(seats.contains(.utg1), "\(tableSize)-handed has UTG+2 but no UTG+1") }
        if seats.contains(.utg1) { #expect(seats.contains(.utg), "\(tableSize)-handed has UTG+1 but no UTG") }
    }

    @Test("A table size outside 2–9 is clamped rather than left empty", arguments: [-3, 0, 1, 10, 99])
    func tableSizeIsClamped(tableSize: Int) {
        let seats = Position.seats(tableSize: tableSize)
        #expect(seats.count >= 2 && seats.count <= 9,
                "\(tableSize) players produced \(seats.count) seats")
    }
}

// MARK: - Who acts last

@Suite("Postflop position")
struct PostflopPositionTests {

    /// Postflop the blinds act first and the button acts last — the reverse of preflop.
    /// Exactly one seat is in position, and it is the button at every table size but
    /// heads-up, where the small blind holds it.
    @Test("Exactly one seat acts last, and heads-up it is the small blind", arguments: 2...9)
    func oneSeatIsInPosition(tableSize: Int) {
        let seats = Position.seats(tableSize: tableSize)
        let inPosition = seats.filter { $0.isInPosition(tableSize: tableSize) }

        #expect(inPosition.count == 1,
                "\(tableSize)-handed: \(inPosition.map(\.rawValue)) are all in position")
        #expect(inPosition.first == (tableSize == 2 ? .sb : .btn),
                "\(tableSize)-handed reads \(inPosition.first?.rawValue ?? "nobody") as last to act")
    }

    /// The old `isInPosition` was a fixed `.btn == true` list, which is right for three
    /// or more players and wrong heads-up: there the small blind is the button and acts
    /// last on every street after the flop.
    @Test("Heads-up reverses which blind is in position")
    func headsUpReversesTheBlinds() {
        #expect(Position.sb.isInPosition(tableSize: 2))
        #expect(!Position.bb.isInPosition(tableSize: 2))
        #expect(!Position.sb.isInPosition(tableSize: 6))
        #expect(!Position.bb.isInPosition(tableSize: 6))
    }

    @Test("Postflop order starts with the blinds and ends on the button", arguments: 3...9)
    func postflopOrderPutsBlindsFirst(tableSize: Int) {
        let order = Position.postflopOrder(tableSize: tableSize)
        #expect(order.count == tableSize)
        #expect(Set(order) == Set(Position.seats(tableSize: tableSize)),
                "postflop order is a different set of seats from the table's")
        #expect(order.prefix(2) == [.sb, .bb], "\(tableSize)-handed starts \(order.prefix(2).map(\.rawValue))")
        #expect(order.last == .btn)
    }

    /// Bluffing more from later position is the one thing the seat multiplier is for, so
    /// it has to be monotone in when hero acts. Nine hand-written constants are not
    /// monotone by construction; a ramp over the postflop order is.
    @Test("The bluff premium rises monotonically with position", arguments: 2...9)
    func bluffPremiumIsMonotone(tableSize: Int) {
        let order = Position.postflopOrder(tableSize: tableSize)
        let premiums = order.map { $0.bluffFrequencyMultiplier(tableSize: tableSize) }

        let ladder = zip(order, premiums)
            .map { "\($0.0.rawValue) \(String(format: "%.3f", $0.1))" }
            .joined(separator: " ")
        for (earlier, later) in zip(premiums, premiums.dropFirst()) {
            #expect(later > earlier,
                    Comment(rawValue: "\(tableSize)-handed premiums are not increasing: \(ladder)"))
        }
        // The two ends are the values the three-seat table already used, kept so this is
        // a re-shaping of the old constants rather than a new set of them.
        #expect(abs(premiums.first! - 0.6) < 1e-9, "first to act got \(premiums.first!)")
        #expect(abs(premiums.last! - 1.3) < 1e-9, "last to act got \(premiums.last!)")
    }

    /// A seat that cannot exist at the given table size is read at the smallest table
    /// that does seat it, never remapped to another seat. The UI cannot produce this
    /// pair, but a stored hand or a test can, and silently turning a cutoff into a
    /// button is the defect this whole enum exists to remove.
    @Test("A seat absent from a small table is not remapped to another seat")
    func absentSeatIsWidenedNotRemapped() {
        // Three-handed has no cutoff. Reading one must not make it the button.
        #expect(!Position.co.isInPosition(tableSize: 3),
                "the cutoff was read as the seat that acts last at a three-handed table")
        #expect(Position.co.bluffFrequencyMultiplier(tableSize: 3)
                == Position.co.bluffFrequencyMultiplier(tableSize: 4),
                "the cutoff at a table too small to seat it should read as a four-handed cutoff")
    }
}

// MARK: - Parsing

@Suite("Seat parsing")
struct SeatParsingTests {

    /// Every seat must survive a round trip through its stored form: hand history is
    /// persisted as text, and a seat that fails to parse used to become the button.
    @Test("Every seat round-trips through its stored name", arguments: Position.allCases)
    func seatsRoundTrip(seat: Position) {
        #expect(Position(rawValue: seat.rawValue) == seat)
    }

    /// The old `init(from: String)` had `default: self = .btn`, so an unrecognised seat
    /// was priced as the best seat at the table rather than rejected.
    @Test("An unrecognised seat is nil, not the button", arguments: ["banana", "", "btn", "MP", "UTG+3"])
    func unknownSeatsAreRejected(text: String) {
        #expect(Position(rawValue: text) == nil, "\(text) parsed as \(String(describing: Position(rawValue: text)))")
    }
}
