import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

/// Backlog #24: the solver knew three seats, so a nine-handed table's other six were
/// priced as buttons. This suite is the guard on the fix — every seat has to reach a
/// different answer, and the answers have to be ordered the way the seats are.
@Suite("Seats reach the solver")
struct SeatPricingTests {

    private let solver = ExploitativeSolver()

    /// Bluffing is the adjustment position drives, so a bluff is where two seats being
    /// treated as one shows up. Before the fix, UTG through BTN — and any unrecognised
    /// string — produced a raise EV of 29.2432 to four decimal places.
    @Test("No two seats price the same bluff identically")
    func everySeatPricesABluffDifferently() {
        let tableSize = 6
        let priced = Position.seats(tableSize: tableSize).map { seat -> (Position, Double) in
            let result = solver.solve(
                gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 0, stack: 400,
                                villainStack: 400, position: seat, tableSize: tableSize),
                myEquity: 0.30, settings: makeSettings())
            return (seat, result.evRaise)
        }

        let report = priced.map { "\($0.0.rawValue) \(String(format: "%.4f", $0.1))" }
            .joined(separator: ", ")
        #expect(Set(priced.map { ($0.1 * 1e6).rounded() }).count == tableSize,
                Comment(rawValue: "seats collapsed onto each other: \(report)"))
    }

    /// And they are ordered: acting later is worth more to a bluff. Compared among the
    /// five seats that are out of position, which share a bet size — the button bets a
    /// different amount, so it is not a like-for-like comparison and is checked
    /// separately below.
    @Test("A bluff is worth more from a later seat")
    func laterSeatsPriceBluffsHigher() {
        let tableSize = 6
        func bluffEV(_ seat: Position) -> Double {
            solver.solve(gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 0, stack: 400,
                                         villainStack: 400, position: seat, tableSize: tableSize),
                         myEquity: 0.30, settings: makeSettings()).evRaise
        }

        let outOfPosition = Position.postflopOrder(tableSize: tableSize)
            .filter { !$0.isInPosition(tableSize: tableSize) }
        let evs = outOfPosition.map { ($0, bluffEV($0)) }
        for (earlier, later) in zip(evs, evs.dropFirst()) {
            #expect(later.1 > earlier.1,
                    Comment(rawValue: "\(later.0.rawValue) \(later.1) is not above " +
                            "\(earlier.0.rawValue) \(earlier.1)"))
        }

        #expect(bluffEV(.btn) > evs.last!.1,
                "the button priced a bluff at \(bluffEV(.btn)), below the cutoff's \(evs.last!.1)")
    }

    /// The seat only changes the *size* of a preflop open through whether hero posted a
    /// blind. A cutoff opens the same 2.5bb a button does, by convention; keying the size
    /// on "acts last after the flop" would have made every seat but the button open like
    /// a small blind.
    @Test("Only the blinds open larger", arguments: 2...9)
    func onlyBlindsOpenLarger(tableSize: Int) {
        func openTo(_ seat: Position) -> Double {
            let entry = PotEntry.blindsOnly(heroPosition: seat, smallBlind: 0.5, bigBlind: 1.0)
            let heroBlind = seat == .sb ? 0.5 : (seat == .bb ? 1.0 : 0.0)
            let state = spot(pot: entry.totalPot, toCall: entry.toCall, stack: 100,
                             villainStack: 100, position: seat, tableSize: tableSize,
                             heroWagerThisStreet: heroBlind)
            let result = solver.solve(gameState: state, myEquity: 0.55, settings: makeSettings())
            return heroBlind + entry.toCall + result.raiseAmount
        }

        for seat in Position.seats(tableSize: tableSize) {
            let expected = seat.postsABlind ? 3.0 : 2.5
            #expect(abs(openTo(seat) - expected) < 1e-9,
                    Comment(rawValue: "\(tableSize)-handed \(seat.rawValue) opened to " +
                            "\(openTo(seat))bb, expected \(expected)bb"))
        }
    }

    /// Heads-up the small blind is the button. The explanation the app prints beneath the
    /// recommendation used to call it out of position at every table size.
    @Test("Heads-up, the small blind is explained as in position")
    func headsUpSmallBlindIsInPosition() {
        func reasoning(tableSize: Int) -> String {
            solver.solve(gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 20, stack: 400,
                                         villainStack: 400, position: .sb, tableSize: tableSize),
                         myEquity: 0.62, settings: makeSettings()).reasoning
        }

        #expect(reasoning(tableSize: 2).contains("in position"))
        #expect(!reasoning(tableSize: 2).contains("out of position"))
        #expect(reasoning(tableSize: 6).contains("out of position"))
    }

    /// A cutoff is not a button, and the explanation must not claim it is. This is the
    /// banner half of #24: the app named a seat the picker could not even select.
    @Test("A cutoff is explained as out of position")
    func cutoffIsNotDescribedAsTheButton() {
        let result = solver.solve(
            gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 20, stack: 400,
                            villainStack: 400, position: .co, tableSize: 6),
            myEquity: 0.62, settings: makeSettings())
        #expect(result.reasoning.contains("out of position"), Comment(rawValue: result.reasoning))
    }
}
