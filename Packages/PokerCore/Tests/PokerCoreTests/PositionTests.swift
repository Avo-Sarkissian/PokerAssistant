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

    /// The full seat list at every table size, written out. Everything else here checks a
    /// property, and properties missed the defect that matters most: transposing LJ and HJ
    /// at a seven-handed table — the wrong convention, and the order the fold-frequency term is
    /// ranked by — left every test in the suite green. Golden arrays are the only thing
    /// that pins the middle seats.
    @Test("The seats at each table size are exactly these", arguments: [
        (2, [Position.sb, .bb]),
        (3, [Position.btn, .sb, .bb]),
        (4, [Position.co, .btn, .sb, .bb]),
        (5, [Position.utg, .co, .btn, .sb, .bb]),
        (6, [Position.utg, .hj, .co, .btn, .sb, .bb]),
        (7, [Position.utg, .lj, .hj, .co, .btn, .sb, .bb]),
        (8, [Position.utg, .utg1, .lj, .hj, .co, .btn, .sb, .bb]),
        (9, [Position.utg, .utg1, .utg2, .lj, .hj, .co, .btn, .sb, .bb]),
    ])
    func seatsAreExactlyThese(tableSize: Int, expected: [Position]) {
        let seats = Position.seats(tableSize: tableSize)
        #expect(seats == expected,
                Comment(rawValue: "\(tableSize)-handed is \(seats.map(\.rawValue)) " +
                        "but should be \(expected.map(\.rawValue))"))
    }

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
    /// seats off the button, nine-handed UTG is seven. That is why every positional read
    /// takes the table size rather than treating position as a property of the seat.
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

    /// No orphaned increments, stated as when each numbered seat appears rather than as a
    /// conditional. The conditional form asserted nothing at six of its eight table sizes,
    /// and Swift Testing reports an expectation-free case as passing.
    @Test("Numbered seats appear only once the table is big enough", arguments: 2...9)
    func numberedSeatsAppearOnlyWhenSeated(tableSize: Int) {
        let seats = Set(Position.seats(tableSize: tableSize))
        #expect(seats.contains(.utg1) == (tableSize >= 8),
                "\(tableSize)-handed \(seats.contains(.utg1) ? "has" : "lacks") a UTG+1")
        #expect(seats.contains(.utg2) == (tableSize >= 9),
                "\(tableSize)-handed \(seats.contains(.utg2) ? "has" : "lacks") a UTG+2")
        if seats.contains(.utg2) { #expect(seats.contains(.utg1) && seats.contains(.utg)) }
    }

    /// Clamped to the *nearest* supported size, which a range check cannot tell from a
    /// clamp in the wrong direction: making `clamped` return 9 for everything satisfied
    /// `count >= 2 && count <= 9` at every input, so a request for a one-handed table
    /// answered with nine seats.
    @Test("A table size outside 2–9 clamps to the nearest supported size",
          arguments: [(-3, 2), (0, 2), (1, 2), (2, 2), (9, 9), (10, 9), (99, 9)])
    func tableSizeClampsToTheNearestSupportedSize(tableSize: Int, expected: Int) {
        let seats = Position.seats(tableSize: tableSize)
        #expect(seats.count == expected,
                "\(tableSize) players produced \(seats.count) seats, expected \(expected)")
        #expect(seats == Position.seats(tableSize: expected),
                "\(tableSize) produced a different seat list from \(expected)")
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

    /// The fold-frequency term is the two values the three-seat version used, and it takes the
    /// *fact* rather than a seat, because the seat cannot settle it — see
    /// `GameStateCopy.heroActsLast`.
    @Test("The fold-frequency term is 1.3 acting last and 0.6 otherwise")
    func bluffPremiumIsTwoValued() {
        #expect(abs(Position.foldFrequencyMultiplier(actingLast: true) - 1.3) < 1e-9)
        #expect(abs(Position.foldFrequencyMultiplier(actingLast: false) - 0.6) < 1e-9)
    }

    /// And the seat-derived default, which is what the app seeds the control with: exactly
    /// the button, or the small blind heads-up, at every table size — no drift.
    @Test("The seat's default position does not drift with the table size")
    func seatDefaultDoesNotDriftWithTableSize() {
        for seat in Position.allCases {
            let sizes = (3...9).filter { seat.exists(tableSize: $0) }
            let defaults = sizes.map { seat.isInPosition(tableSize: $0) }
            #expect(Set(defaults).count == 1,
                    Comment(rawValue: "\(seat.rawValue) changes its default across " +
                            zip(sizes, defaults).map { "\($0.0)p \($0.1)" }.joined(separator: " ")))
        }
        // Heads-up is the one genuine exception: the small blind holds the button.
        #expect(Position.sb.isInPosition(tableSize: 2))
        #expect(!Position.sb.isInPosition(tableSize: 3))
    }

    /// A seat the table does not deal is not in position at that table. Widening it until
    /// it exists — which `postflopActionIndex` does, so that a cutoff is never read as
    /// some *other* seat — would otherwise report a button as last to act at a two-handed
    /// table that has no button, which is where the ramp's own test could not see it: that
    /// test filtered by `seats(tableSize:)` first and so excluded the offending pair.
    @Test("A seat the table does not deal is not in position at that table")
    func unseatedSeatIsNotInPosition() {
        #expect(!Position.btn.exists(tableSize: 2))
        #expect(!Position.btn.isInPosition(tableSize: 2),
                "a two-handed table with no button reported one as last to act")
        #expect(!Position.btn.isInPosition(tableSize: 2),
                "an unseated button would default to the in-position fold-frequency term")

        // Three-handed has no cutoff either, and reading one must not make it the button.
        #expect(!Position.co.isInPosition(tableSize: 3))

        // Across every seat and table size, exactly the dealt seats can be in position.
        for tableSize in 2...9 {
            for seat in Position.allCases where !seat.exists(tableSize: tableSize) {
                #expect(!seat.isInPosition(tableSize: tableSize),
                        "\(seat.rawValue) is not dealt \(tableSize)-handed but reads as in position")
            }
        }
    }

    /// The widening still holds where it is meant to: a seat absent from a small table is
    /// read at the smallest table that seats it, never remapped onto a different seat.
    @Test("An absent seat keeps its own identity in the action order")
    func absentSeatKeepsItsIdentity() {
        #expect(Position.co.postflopActionIndex(tableSize: 3)
                == Position.co.postflopActionIndex(tableSize: 4),
                "the cutoff at a table too small to seat it should read as a four-handed cutoff")
        #expect(Position.utg2.postflopActionIndex(tableSize: 2)
                == Position.utg2.postflopActionIndex(tableSize: 9))
    }
}

// MARK: - Parsing

@Suite("Seat parsing")
struct SeatParsingTests {

    /// The seat names the app has already written into stored hand history must still
    /// parse. Hand history keeps the seat as text, and while nothing currently reads one
    /// back into a `Position`, anything that starts to must not silently fail on records
    /// written before this type existed.
    ///
    /// A round trip through `Position(rawValue: seat.rawValue)` over `allCases` was tried
    /// here first and is worthless: `init?(rawValue:)` is compiler-synthesised for a
    /// `String`-raw enum and duplicate raw values will not compile, so no production edit
    /// can make it fail while the file still builds.
    @Test("The seat names already in stored hand history still parse",
          arguments: ["BTN", "SB", "BB"])
    func previouslyPersistedSeatsStillParse(stored: String) {
        #expect(Position(rawValue: stored) != nil, "a stored \(stored) no longer parses")
    }

    /// And every seat's stored form is the label the picker shows, so a record reads the
    /// way the app read when it was written.
    @Test("Each seat's stored name is its display label", arguments: Position.allCases)
    func storedNameIsTheDisplayLabel(seat: Position) {
        #expect(!seat.rawValue.isEmpty)
        #expect(seat.rawValue == seat.rawValue.uppercased(),
                "\(seat.rawValue) is not in the form the picker renders")
    }

    /// The old `init(from: String)` had `default: self = .btn`, so an unrecognised seat
    /// was priced as the best seat at the table rather than rejected.
    @Test("An unrecognised seat is nil, not the button", arguments: ["banana", "", "btn", "MP", "UTG+3"])
    func unknownSeatsAreRejected(text: String) {
        #expect(Position(rawValue: text) == nil, "\(text) parsed as \(String(describing: Position(rawValue: text)))")
    }
}
