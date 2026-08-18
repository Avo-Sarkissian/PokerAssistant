import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

/// Backlog #24: the solver knew three seats, so a nine-handed table's other six were
/// priced as buttons. This suite is the guard on the fix.
///
/// Note what it does **not** claim. An earlier version of this file asserted that all nine
/// seats price a bluff differently, which held only because the fold-frequency term was then a
/// ramp over the table size — and that ramp was wrong: it priced one identical spot across
/// a 40% range on nothing but how many seats had already folded. Position reaches the
/// solver through two binary facts, so two groups is all there is: whether hero acts last
/// after the flop, and whether hero posted a blind. The defect being guarded is that a
/// non-button seat was priced *as the button*, not that every seat differs.
@Suite("Seats reach the solver")
struct SeatPricingTests {

    private let solver = ExploitativeSolver()

    private func bluffEV(_ seat: Position, tableSize: Int = 6) -> Double {
        solver.solve(gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 0, stack: 400,
                                     villainStack: 400, position: seat, tableSize: tableSize),
                     myEquity: 0.30, settings: makeSettings()).evRaise
    }

    /// The defect itself: every seat from under the gun to the cutoff — and the literal
    /// string "banana", which the old string parser mapped to `.btn` — produced a raise EV
    /// of 29.2432 to four decimal places, the button's number. No seat but the button may
    /// reach it.
    @Test("No seat but the button is priced as the button", arguments: 2...9)
    func noSeatIsPricedAsTheButton(tableSize: Int) {
        let seats = Position.seats(tableSize: tableSize)
        let inPosition = seats.filter { $0.isInPosition(tableSize: tableSize) }
        #expect(inPosition.count == 1)
        let last = inPosition[0]
        let lastEV = bluffEV(last, tableSize: tableSize)

        for seat in seats where seat != last {
            #expect(bluffEV(seat, tableSize: tableSize) < lastEV - 1e-6,
                    Comment(rawValue: "\(tableSize)-handed \(seat.rawValue) prices a bluff at " +
                            "\(bluffEV(seat, tableSize: tableSize)), at or above the " +
                            "\(last.rawValue)'s \(lastEV)"))
        }
    }

    /// And the premium does not leak the table size: the same seat, the same one villain,
    /// the same board must price the same bluff identically however many chairs the table
    /// has. Measured before the fix, with one villain in every row: the big blind ran
    /// 17.67 two-handed, 24.72 three-handed, 20.49 six-handed, 19.69 eight-handed.
    ///
    /// Three-handed and up, where every seat's role is fixed. Heads-up is the one genuine
    /// exception — the small blind holds the button there and is in position, which is the
    /// inversion `headsUpSmallBlindIsInPosition` exists to pin — so including it here
    /// would assert the opposite of that.
    @Test("A seat prices a bluff the same at every table size that seats it")
    func bluffPriceDoesNotDriftWithTheTableSize() {
        for seat in Position.allCases {
            let sizes = (3...9).filter { seat.exists(tableSize: $0) }
            let evs = sizes.map { bluffEV(seat, tableSize: $0) }
            #expect(Set(evs.map { ($0 * 1e6).rounded() }).count == 1,
                    Comment(rawValue: "\(seat.rawValue) drifts with the table size: " +
                            zip(sizes, evs).map { "\($0.0)p \(String(format: "%.4f", $0.1))" }
                                .joined(separator: " ")))
        }

        // The exception, stated: the small blind is the only seat whose role changes, and
        // it changes exactly once, between heads-up and three-handed.
        #expect(bluffEV(.sb, tableSize: 2) > bluffEV(.sb, tableSize: 3),
                "heads-up the small blind holds the button and should price a bluff higher")
        #expect(abs(bluffEV(.bb, tableSize: 2) - bluffEV(.bb, tableSize: 3)) < 1e-9,
                "the big blind is out of position at every table size")
    }

    /// The seat only changes the *size* of a preflop open through whether hero posted a
    /// blind. A cutoff opens the same 2.5bb a button does, by convention; keying the size
    /// on "acts last after the flop" would have made every seat but the button open like
    /// a small blind.
    ///
    /// The expected sizes are written out per seat rather than derived from `postsABlind`.
    /// Deriving them made this test tautological on the very predicate it claims to guard:
    /// adding `.btn` to `postsABlind` — literally the bug the paragraph above describes —
    /// moved both sides of the comparison together and all eight cases passed.
    private static let expectedOpenInBlinds: [Position: Double] = [
        .utg: 2.5, .utg1: 2.5, .utg2: 2.5, .lj: 2.5, .hj: 2.5, .co: 2.5, .btn: 2.5,
        .sb: 3.0, .bb: 3.0,
    ]

    @Test("Only the blinds open larger", arguments: 2...9)
    func onlyBlindsOpenLarger(tableSize: Int) {
        func openTo(_ seat: Position) -> (size: Double, committed: Double) {
            let entry = PotEntry.blindsOnly(heroPosition: seat, smallBlind: 0.5, bigBlind: 1.0)
            let heroBlind = seat == .sb ? 0.5 : (seat == .bb ? 1.0 : 0.0)
            let state = spot(pot: entry.totalPot, toCall: entry.toCall, stack: 100,
                             villainStack: 100, position: seat, tableSize: tableSize,
                             heroWagerThisStreet: heroBlind)
            let result = solver.solve(gameState: state, myEquity: 0.55, settings: makeSettings())
            // `committed` is checked separately: the blind is fed in through
            // `heroWagerThisStreet`, which `heroCommitted` floors at `blindPosted`, so a
            // `blindPosted` returning 0 would be invisible here otherwise.
            return (heroBlind + entry.toCall + result.raiseAmount,
                    state.heroCommitted(smallBlind: 0.5))
        }

        for seat in Position.seats(tableSize: tableSize) {
            let measured = openTo(seat)
            let expected = Self.expectedOpenInBlinds[seat]!
            #expect(abs(measured.size - expected) < 1e-9,
                    Comment(rawValue: "\(tableSize)-handed \(seat.rawValue) opened to " +
                            "\(measured.size)bb, expected \(expected)bb"))

            // Pinned against `blindPosted` directly, not through `heroCommitted`. The
            // helper feeds the blind in as `heroWagerThisStreet`, and `heroCommitted`
            // takes the *max* of the two, so a `blindPosted` returning nothing is
            // invisible from either the size or the committed total.
            let blind = seat == .sb ? 0.5 : (seat == .bb ? 1.0 : 0.0)
            #expect(abs(measured.committed - blind) < 1e-9,
                    Comment(rawValue: "\(seat.rawValue) is recorded as having committed " +
                            "\(measured.committed), not its \(blind) blind"))
            let unwagered = spot(pot: 1.5, toCall: 1.0, position: seat, tableSize: tableSize)
            #expect(abs(unwagered.blindPosted(smallBlind: 0.5) - blind) < 1e-9,
                    Comment(rawValue: "\(seat.rawValue) posts " +
                            "\(unwagered.blindPosted(smallBlind: 0.5)), not \(blind)"))
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

// MARK: - Position is told, not guessed

/// Hero opens the cutoff and the big blind calls. Hero acts last on every street from the
/// flop on — but the seat cannot say so, because the app knows how many players are live
/// and never which chairs they hold. Deriving position from the seat priced that flop out
/// of position, at $18.00 into a 40 pot where $14.50 is right.
///
/// It was also a **regression**: while the picker offered only BTN/SB/BB, a cutoff player
/// selected BTN and got the correct answer. Making their real seat selectable made their
/// advice worse. So position is now a fact hero supplies, with the seat as its default.
@Suite("Position is supplied, not derived")
struct SuppliedPositionTests {

    private let solver = ExploitativeSolver()

    private func advice(_ seat: Position, actsLast: Bool?) -> ExploitativeSolver.SolverResult {
        solver.solve(gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 0, stack: 400,
                                     villainStack: 400, position: seat,
                                     playersInHand: 2, tableSize: 6, heroActsLast: actsLast),
                     myEquity: 0.62, settings: makeSettings())
    }

    /// The headline case: a cutoff who says they act last is priced exactly as a button
    /// is, because at that point the two spots are the same spot.
    @Test("A cutoff who acts last is priced as a button", arguments: [0.30, 0.62, 0.90])
    func cutoffActingLastMatchesTheButton(equity: Double) {
        func result(_ seat: Position, actsLast: Bool?) -> ExploitativeSolver.SolverResult {
            solver.solve(gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 0, stack: 400,
                                         villainStack: 400, position: seat,
                                         playersInHand: 2, tableSize: 6, heroActsLast: actsLast),
                         myEquity: equity, settings: makeSettings())
        }

        let cutoff = result(.co, actsLast: true)
        let button = result(.btn, actsLast: nil)   // the button's own default is true

        #expect(cutoff.raiseAmount == button.raiseAmount,
                Comment(rawValue: "cutoff sized \(cutoff.raiseAmount), button \(button.raiseAmount)"))
        #expect(abs(cutoff.evRaise - button.evRaise) < 1e-9,
                Comment(rawValue: "cutoff priced \(cutoff.evRaise), button \(button.evRaise)"))
        #expect(cutoff.reasoning == button.reasoning)
    }

    /// And the flag has to actually move the numbers, in the documented direction: acting
    /// last bets smaller (0.9x rather than 1.1x) and earns the higher fold-frequency term.
    @Test("Saying hero acts last changes the size and the price")
    func theFlagMovesTheAnswer() {
        let last = advice(.co, actsLast: true)
        let notLast = advice(.co, actsLast: false)

        #expect(last.raiseAmount < notLast.raiseAmount,
                Comment(rawValue: "acting last sized \(last.raiseAmount), " +
                        "not acting last \(notLast.raiseAmount)"))
        #expect(last.reasoning.contains("in position"))
        #expect(notLast.reasoning.contains("out of position"))
    }

    /// A hero who says nothing gets what the seat implies, so the default is the old
    /// behaviour and nobody has to touch the control to be no worse off.
    @Test("Unstated position falls back to the seat", arguments: 2...9)
    func unstatedPositionFallsBackToTheSeat(tableSize: Int) {
        for seat in Position.seats(tableSize: tableSize) {
            let derived = solver.solve(
                gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 0, stack: 400,
                                villainStack: 400, position: seat,
                                playersInHand: 2, tableSize: tableSize, heroActsLast: nil),
                myEquity: 0.62, settings: makeSettings())
            let stated = solver.solve(
                gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 0, stack: 400,
                                villainStack: 400, position: seat, playersInHand: 2,
                                tableSize: tableSize,
                                heroActsLast: seat.isInPosition(tableSize: tableSize)),
                myEquity: 0.62, settings: makeSettings())

            #expect(derived.raiseAmount == stated.raiseAmount,
                    Comment(rawValue: "\(tableSize)-handed \(seat.rawValue): " +
                            "\(derived.raiseAmount) derived vs \(stated.raiseAmount) stated"))
        }
    }

    /// The preflop open size must **not** follow this flag. It keys on whether hero posted
    /// a blind, and a cutoff who will act last after the flop still opens 2.5bb.
    @Test("Saying hero acts last does not change the preflop open")
    func theFlagDoesNotChangeThePreflopOpen() {
        func openTo(_ seat: Position, actsLast: Bool) -> Double {
            let entry = PotEntry.blindsOnly(heroPosition: seat, smallBlind: 0.5, bigBlind: 1.0)
            let blind = seat == .sb ? 0.5 : (seat == .bb ? 1.0 : 0.0)
            let result = solver.solve(
                gameState: spot(pot: entry.totalPot, toCall: entry.toCall, stack: 100,
                                villainStack: 100, position: seat, tableSize: 6,
                                heroActsLast: actsLast, heroWagerThisStreet: blind),
                myEquity: 0.55, settings: makeSettings())
            return blind + entry.toCall + result.raiseAmount
        }

        for seat in Position.seats(tableSize: 6) {
            #expect(abs(openTo(seat, actsLast: true) - openTo(seat, actsLast: false)) < 1e-9,
                    Comment(rawValue: "\(seat.rawValue) opened to \(openTo(seat, actsLast: true))bb " +
                            "acting last and \(openTo(seat, actsLast: false))bb not"))
        }
    }
}
