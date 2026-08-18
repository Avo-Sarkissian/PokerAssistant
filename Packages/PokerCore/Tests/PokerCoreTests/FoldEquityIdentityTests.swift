import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

// MARK: - Fold equity against the balanced-defence baseline
//
// The second external anchor. The first — the C(52,7) census — checks the evaluator
// against published counts; this one checks the solver's bluff arithmetic against a
// theorem, which is the only kind of reference data available for strategy.
//
// **α.** A player facing a bet of `b` pots is being laid `b : 1 + b`, so a bet with no
// showdown value breaks even exactly when the defender folds
//
//     α = b / (1 + b)
//
// of the range they hold. Fold less and the bluff loses; fold more and it wins. This is
// arithmetic, not a strategy opinion: it does not depend on the board, the stack, the
// opponent's tendencies, or anything else this repository hand-authored. It is the one
// place a hand-authored constant can be *measured* rather than argued about.
//
// Two things are asserted here and one is only measured, deliberately.
//
// Asserted: the solver's own EV algebra satisfies the identity — a zero-equity bet is
// +EV exactly when the fold frequency the model credits exceeds α — and the
// recommendation follows the arithmetic rather than diverging from it.
//
// Measured: how far `foldEquityForRange` sits from α. Those numbers are what a
// re-calibration would have to change, and pinning them as targets would only freeze
// today's guesses. The envelope test below bounds them instead, so the constants cannot
// drift silently, and the table is reproduced in a comment where it can be read.

@Suite("Fold equity against the balanced-defence baseline")
struct FoldEquityIdentityTests {

    /// The fraction of their range a defender must fold for a zero-equity bet of
    /// `bet` into a pot of `pot` to break even.
    static func alpha(bet: Double, pot: Double) -> Double {
        bet / (pot + bet)
    }

    /// The fold frequency the model credits for this spot, reassembled from its parts.
    ///
    /// Deliberately built from `foldEquityForRange` and `bluffFrequencyMultiplier`
    /// rather than from a number written here: the identity being tested is a
    /// relationship between whatever the model credits and α, so re-calibrating the
    /// table must leave these tests passing. What must never change is that the EV
    /// crosses zero in the right place.
    static func creditedFoldEquity(range: OpponentRange.RangeType,
                                   bet: Double,
                                   pot: Double,
                                   actsLast: Bool) -> Double {
        let base = ExploitativeSolver.foldEquityForRange(
            range, betSizeRelativeToPot: bet / max(pot, 1))
        let premium = base * Position.bluffFrequencyMultiplier(actingLast: actsLast)
        return min(max(premium, 0), 0.80)
    }

    /// Whether the 0.80 ceiling in `calculateRaiseEV` actually binds in this spot. The
    /// ceiling is unreachable after the flop — the widest range an explicit style can
    /// produce tops out at 0.55, and no postflop bet can be more than the pot — so
    /// without a preflop spot in the sweep it is untested code that a test would happily
    /// claim to cover.
    static func creditedFoldEquityWasCapped(range: OpponentRange.RangeType,
                                            bet: Double,
                                            pot: Double,
                                            actsLast: Bool) -> Bool {
        let uncapped = ExploitativeSolver.foldEquityForRange(
            range, betSizeRelativeToPot: bet / max(pot, 1))
            * Position.bluffFrequencyMultiplier(actingLast: actsLast)
        return uncapped > 0.80
    }

    static let allRanges: [OpponentRange.RangeType] =
        [.veryTight, .tight, .standard, .wide, .veryWide, .random]

    // MARK: - The identity, end to end through the solver

    /// One spot in the sweep. Everything here changes something the identity has to
    /// survive: whether hero is betting or raising, how many players have to fold, how
    /// the bet is sized, and whether chips risked are worth more than chips won.
    struct BluffSpot {
        let board: String
        let pot: Double
        let toCall: Double
        let stack: Double
        let villainStack: Double
        let style: OpponentStyle
        let actsLast: Bool
        let playersInHand: Int
        let icmPressure: Double

        var label: String {
            "\(style) · \(actsLast ? "IP" : "OOP") · pot \(pot) · to call \(toCall) "
            + "· stack \(stack) · \(playersInHand) players · icm \(icmPressure)"
        }
    }

    /// Hero holds nothing on a board that cannot have improved it, so every dollar the
    /// bet returns comes from villain folding. Where there is nothing to call, folding is
    /// not on the table and checking is free, so both are worth 0 and the decision is the
    /// sign of the bet's EV. Where there *is* something to call, calling on zero equity
    /// costs money, so folding at 0 is the thing to beat — and the identity has the same
    /// shape either way, with hero's whole outlay in place of the bet.
    ///
    /// Writing `f` for the fold frequency the model credits per opponent, `n` for the
    /// opponents who all have to fold, `P` for the pot, `C` for what the aggression costs
    /// hero and `r` for the tournament risk premium:
    ///
    ///     EV  =  fⁿ·P − (1 − fⁿ)·C·r        and      EV > 0  ⟺  fⁿ > C·r / (P + C·r)
    ///
    /// The right-hand side is α, evaluated at hero's *risked* chips rather than at the
    /// headline bet — ICM pressure raises the fold frequency a bluff needs exactly as if
    /// the bet had been r times larger, which is the identity doing real work rather than
    /// restating itself.
    ///
    /// The matrix is swept rather than parameterised so the coverage guards at the end
    /// can insist the sweep stayed broad. An earlier version of this test ran 48 spots
    /// that between them reached one street, one board, one opponent, one risk premium
    /// and two of the five bet-size tiers, with every below-α case produced by a single
    /// constant — and it passed, which is exactly what a sweep that has quietly collapsed
    /// looks like.
    @Test("A zero-equity bluff is +EV exactly when the credited fold equity clears α")
    func zeroEquityBluffBreaksEvenAtAlpha() {
        let solver = ExploitativeSolver()
        var above = 0, below = 0
        var aboveInPosition = 0, belowInPosition = 0
        var multiwayCases = 0, riskPremiumCases = 0, facingABetCases = 0
        var ceilingCases = 0
        var smallestBet = Double.infinity, largestBet = 0.0

        var spots: [BluffSpot] = []
        for style in [OpponentStyle.tight, .standard, .loose] {
            for actsLast in [true, false] {
                for board in ["",                         // preflop: sized in blinds, and the
                                                          // only place a bet reaches the
                                                          // top bet-size tier and the 0.80
                                                          // ceiling on credited folds
                              "As Kh 9d",                 // dry, rainbow, disconnected
                              "9h 8h 7c",                 // wet and connected
                              "As Kh 9d 4c",              // turn
                              "As Kh 9d 4c 2s"] {         // river
                    for (pot, toCall) in [(6.0, 0.0), (40.0, 0.0), (100.0, 0.0),
                                          (25.0, 10.0), (14.0, 8.0), (120.0, 30.0)] {
                        for (stack, players, icm) in [(200.0, 2, 0.0),
                                                      (40.0, 2, 0.0),
                                                      (200.0, 3, 0.0),
                                                      (200.0, 4, 0.0),
                                                      (200.0, 2, 0.3)] {
                            spots.append(BluffSpot(board: board, pot: pot, toCall: toCall,
                                                   stack: stack, villainStack: stack,
                                                   style: style, actsLast: actsLast,
                                                   playersInHand: players, icmPressure: icm))
                        }
                    }
                }
            }
        }

        for s in spots {
            let state = spot(hole: "7c 2d", board: s.board,
                             pot: s.pot, toCall: s.toCall,
                             stack: s.stack, villainStack: s.villainStack,
                             position: .btn, playersInHand: s.playersInHand, tableSize: 6,
                             heroActsLast: s.actsLast, opponentStyle: s.style)
            let settings = SolverSettings(smallBlind: 0.5, bigBlind: 1.0,
                                          icmPressure: s.icmPressure)
            let result = solver.solve(gameState: state, myEquity: 0, settings: settings)

            let bet = result.raiseAmount
            #expect(bet > 0, Comment(rawValue: "\(s.label): no legal bet to price"))
            guard bet > 0 else { continue }

            let opponents = max(1, s.playersInHand - 1)
            let effectiveStack = min(s.stack, s.villainStack)
            let cost = min(s.toCall + bet, effectiveStack)
            let riskPremium = 1 + s.icmPressure
            let perOpponent = Self.creditedFoldEquity(range: s.style.rangeType,
                                                      bet: bet,
                                                      pot: s.pot + s.toCall,
                                                      actsLast: s.actsLast)
            if Self.creditedFoldEquityWasCapped(range: s.style.rangeType, bet: bet,
                                                pot: s.pot + s.toCall, actsLast: s.actsLast) {
                ceilingCases += 1
            }
            let everyoneFolds = pow(perOpponent, Double(opponents))
            let alpha = (cost * riskPremium) / (s.pot + cost * riskPremium)

            let expectedEV = everyoneFolds * s.pot - (1 - everyoneFolds) * cost * riskPremium
            #expect(abs(result.evRaise - expectedEV) < 1e-9,
                    Comment(rawValue: "\(s.label): bet \(bet), solver EV \(result.evRaise) "
                            + "vs fⁿ·P − (1−fⁿ)·C·r = \(expectedEV) at fⁿ = \(everyoneFolds)"))

            let betRelativeToPot = bet / max(s.pot + s.toCall, 1)
            smallestBet = min(smallestBet, betRelativeToPot)
            largestBet = max(largestBet, betRelativeToPot)
            if opponents > 1 { multiwayCases += 1 }
            if riskPremium > 1 { riskPremiumCases += 1 }
            if s.toCall > 0 { facingABetCases += 1 }

            // Skip the knife edge, where the two sides differ only by rounding. Both
            // branches are exercised far from it — the guards below prove it.
            guard abs(everyoneFolds - alpha) > 1e-6 else { continue }
            if everyoneFolds > alpha {
                above += 1
                if s.actsLast { aboveInPosition += 1 }
            } else {
                below += 1
                if s.actsLast { belowInPosition += 1 }
            }

            #expect((result.evRaise > 0) == (everyoneFolds > alpha),
                    Comment(rawValue: "\(s.label): EV \(result.evRaise) with "
                            + "fⁿ = \(everyoneFolds) against α = \(alpha)"))

            // …and the recommendation follows the arithmetic rather than diverging from
            // it. Naming the *whole* action, not just "is it a raise", is deliberate:
            // where checking is free the alternative to betting is a check, and a solver
            // that folded a free option would satisfy "did not bet" perfectly well.
            let bluffing = everyoneFolds > alpha
            let expectedAction: CalculationResult.RecommendedAction =
                bluffing ? .raise(amount: bet) : (s.toCall > 0 ? .fold : .call)
            #expect(result.action == expectedAction,
                    Comment(rawValue: "\(s.label): recommended \(result.action), "
                            + "expected \(expectedAction) at fⁿ = \(everyoneFolds) "
                            + "against α = \(alpha)"))
        }

        // MARK: Coverage
        //
        // Every one of these is a way the sweep could quietly stop testing what it says
        // it tests. They are assertions rather than comments because a narrowed sweep
        // still passes every assertion above it.
        #expect(above > 0 && below > 0,
                Comment(rawValue: "never crossed α — \(above) above, \(below) below"))
        #expect(aboveInPosition > 0 && belowInPosition > 0,
                Comment(rawValue: "both sides of α must occur with hero acting last, or the "
                        + "split is a test of the position multiplier and nothing else — "
                        + "\(aboveInPosition) above, \(belowInPosition) below"))
        #expect(multiwayCases > 0, "no multiway spot, so fⁿ was never tested for n > 1")
        #expect(riskPremiumCases > 0, "no ICM pressure, so r was pinned at 1 throughout")
        #expect(facingABetCases > 0, "never faced a bet, so C was always just the bet")
        #expect(ceilingCases > 0,
                Comment(rawValue: "the 0.80 ceiling on credited fold equity was never reached, "
                        + "so the sweep cannot tell whether the solver applies it at all"))
        #expect(smallestBet < 0.4 && largestBet >= 0.6,
                Comment(rawValue: "bet sizes spanned only "
                        + "\(String(format: "%.2f", smallestBet))–"
                        + "\(String(format: "%.2f", largestBet)) of the pot, which does not "
                        + "reach three of `foldEquityForRange`'s five bet-size tiers"))
    }

    // MARK: - Measurement

    /// What `foldEquityForRange` credits, as a multiple of α, over the bet sizes the
    /// solver can actually produce. Measured 2026-08-17:
    ///
    /// | b    | α     | veryTight | tight | standard | wide | veryWide | random |
    /// |------|-------|-----------|-------|----------|------|----------|--------|
    /// | 0.25 | 0.200 | 1.00      | 1.40  | 1.80     | 2.20 | 2.60     | 2.80   |
    /// | 0.50 | 0.333 | 0.68      | 0.95  | 1.22     | 1.49 | 1.76     | 1.89   |
    /// | 0.75 | 0.429 | 0.58      | 0.82  | 1.05     | 1.28 | 1.52     | 1.63   |
    /// | 1.00 | 0.500 | 0.55      | 0.77  | 0.99     | 1.21 | 1.43     | 1.54   |
    /// | 1.75 | 0.636 | 0.50      | 0.69  | 0.89     | 1.09 | 1.29     | 1.34   |
    ///
    /// Two things are visible in that table and neither is asserted here, because both
    /// are calibration questions rather than arithmetic ones:
    ///
    /// - The multiple *falls* as the bet grows, which is backwards. Real opponents
    ///   over-fold to large bets and call small ones down too wide, so an exploitative
    ///   model should credit more than α at the top of the range and less at the bottom.
    ///   This one does the opposite.
    /// - `.veryTight` clears α only for bets under a quarter of the pot, which the solver
    ///   reaches only when hero is nearly all in relative to the pot. At every size it
    ///   normally chooses, bluffing a range read as tight is unprofitable by construction
    ///   rather than by measurement.
    ///
    /// The envelope below is a sanity bound, not a target: it says the model may not
    /// credit or deny fold equity by more than a factor of three against the balanced
    /// baseline. It exists so a re-calibration is a deliberate act with a failing test
    /// in front of it, which is more than any strategic constant in this repository has
    /// had until now.
    @Test("Credited fold equity stays within a factor of three of α")
    func creditedFoldEquityStaysNearTheBalancedBaseline() {
        let sizes = [0.25, 0.30, 0.40, 0.50, 0.60, 0.75, 0.85, 1.00, 1.10, 1.50, 1.75]
        var worstLow = (multiple: Double.infinity, label: "")
        var worstHigh = (multiple: 0.0, label: "")

        for range in Self.allRanges {
            for b in sizes {
                let f = ExploitativeSolver.foldEquityForRange(range, betSizeRelativeToPot: b)
                let multiple = f / (b / (1 + b))
                let label = "\(range) at \(b) pot: \(String(format: "%.3f", f)) "
                          + "vs α \(String(format: "%.3f", b / (1 + b))) = \(String(format: "%.2f", multiple))×"
                if multiple < worstLow.multiple { worstLow = (multiple, label) }
                if multiple > worstHigh.multiple { worstHigh = (multiple, label) }
            }
        }

        #expect(worstLow.multiple > 1.0 / 3.0, Comment(rawValue: "denies too much — \(worstLow.label)"))
        #expect(worstHigh.multiple < 3.0, Comment(rawValue: "credits too much — \(worstHigh.label)"))
    }

    /// **Disabled: this is a defect, not a passing invariant.** It states the property
    /// the fold-equity model should have and does not; it is left executable so the fix
    /// has a specification to be measured against.
    ///
    /// α rises smoothly with the bet, but `foldEquityForRange` multiplies its base rate
    /// by a *step* function of bet size, so the difference between them jumps at each
    /// step boundary. Whether a zero-equity bluff is profitable therefore flips back and
    /// forth as the bet grows. Measured over a 0.01-pot sweep:
    ///
    /// - `.standard` is profitable to 0.82 pot, unprofitable from 0.82, profitable again
    ///   from 0.85, unprofitable from 0.99, profitable again at 1.10, unprofitable from
    ///   1.11. Four sign changes.
    /// - `.tight` flips at 0.39, back at 0.40, and away again at 0.46.
    ///
    /// In a $100 pot that means an $82 bluff is priced as losing and an $85 bluff as
    /// winning, against the same opponent with the same cards. The solver's own sizing
    /// lands inside that band routinely: a medium hand out of position on a wet board at
    /// SPR under 4 sizes to 0.87 pot.
    ///
    /// The contained fix keeps the model's own numbers and removes the steps by anchoring
    /// the whole table to α: `f(range, b) = min(α(b) · k(range), 0.85)` with
    /// `k(range) = foldEquityForRange(range, 0.75) / α(0.75)`. That reproduces today's
    /// values exactly at the model's default size, introduces no constant that is not
    /// already there, makes the multiple constant in bet size, and makes this test pass.
    /// It also changes every raise EV in the app, which is why it is not in this commit.
    @Test("Bluff profitability does not flip back and forth as the bet grows",
          .disabled("known defect: the bet-size multiplier is a step function — see the note above"))
    func bluffProfitabilityIsMonotoneInBetSize() {
        for range in Self.allRanges {
            var flips: [String] = []
            var previous: Bool? = nil
            for step in 10...300 {
                let b = Double(step) / 100.0
                let profitable = ExploitativeSolver.foldEquityForRange(range, betSizeRelativeToPot: b)
                                 > b / (1 + b)
                if let previous, previous != profitable {
                    flips.append("\(String(format: "%.2f", b)): \(previous ? "+EV→−EV" : "−EV→+EV")")
                }
                previous = profitable
            }
            #expect(flips.count <= 1,
                    Comment(rawValue: "\(range) changes sign \(flips.count) times: \(flips.joined(separator: ", "))"))
        }
    }
}
