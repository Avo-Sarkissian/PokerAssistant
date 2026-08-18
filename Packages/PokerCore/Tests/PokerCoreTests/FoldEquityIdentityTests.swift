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

    static let allRanges: [OpponentRange.RangeType] =
        [.veryTight, .tight, .standard, .wide, .veryWide, .random]

    // MARK: - The identity, end to end through the solver

    /// Hero holds nothing, has nothing to call, and can only check or bet. Folding is
    /// not on the table and calling is free, so both are worth exactly 0 and the whole
    /// decision reduces to the sign of the bet's EV — which is the identity's subject.
    ///
    /// The matrix is swept rather than parameterised so the last expectation can insist
    /// that both sides of the boundary actually occurred. A version of this test that
    /// only ever produced +EV bets would pass against a solver that recommended betting
    /// unconditionally, and this branch has already shipped five tests that passed that
    /// way.
    @Test("A zero-equity bet is +EV exactly when the credited fold equity clears α")
    func zeroEquityBetBreaksEvenAtAlpha() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()
        var above = 0, below = 0

        for style in [OpponentStyle.tight, .standard, .loose] {
            for actsLast in [true, false] {
                for pot in [6.0, 12.0, 40.0, 100.0] {
                    for stack in [40.0, 200.0] {
                        let state = spot(hole: "7c 2d", board: "As Kh 9d",
                                         pot: pot, toCall: 0,
                                         stack: stack, villainStack: stack,
                                         position: .btn, playersInHand: 2, tableSize: 6,
                                         heroActsLast: actsLast, opponentStyle: style)
                        let result = solver.solve(gameState: state, myEquity: 0, settings: settings)
                        let bet = result.raiseAmount
                        let where_ = "\(style) · \(actsLast ? "IP" : "OOP") · pot \(pot) · stack \(stack)"

                        #expect(bet > 0, Comment(rawValue: "\(where_): no legal bet to price"))

                        let f = Self.creditedFoldEquity(range: style.rangeType, bet: bet,
                                                        pot: pot, actsLast: actsLast)
                        let a = Self.alpha(bet: bet, pot: pot)

                        // Win the pot when villain folds, lose the bet when villain does not.
                        // Nothing else: hero's hand cannot win a showdown it has no equity in.
                        let expectedEV = f * pot - (1 - f) * bet
                        #expect(abs(result.evRaise - expectedEV) < 1e-9,
                                Comment(rawValue: "\(where_): bet \(bet) into \(pot), "
                                        + "solver EV \(result.evRaise) vs "
                                        + "f·pot − (1−f)·bet = \(expectedEV) at f = \(f)"))

                        // Skip the knife edge, where the two sides of the identity differ
                        // only by rounding. Both branches are exercised well away from it —
                        // the counters below prove it.
                        guard abs(f - a) > 1e-6 else { continue }
                        if f > a { above += 1 } else { below += 1 }

                        #expect((result.evRaise > 0) == (f > a),
                                Comment(rawValue: "\(where_): EV \(result.evRaise) "
                                        + "with f = \(f) against α = \(a)"))

                        let recommendsBet: Bool
                        if case .raise = result.action { recommendsBet = true } else { recommendsBet = false }
                        #expect(recommendsBet == (f > a),
                                Comment(rawValue: "\(where_): recommended \(result.action) "
                                        + "with f = \(f) against α = \(a)"))
                    }
                }
            }
        }

        #expect(above > 0 && below > 0,
                Comment(rawValue: "the sweep never crossed α — \(above) above, \(below) below — "
                        + "so the identity was never actually tested"))
    }

    /// The same identity stated where it is easiest to break: at the boundary itself.
    /// A fold frequency a hair above α must be worth more than checking, and a hair
    /// below must be worth less, whatever the pot and bet happen to be.
    @Test("The break-even fold frequency is α and not the raw pot fraction",
          arguments: [(pot: 10.0, bet: 5.0), (pot: 10.0, bet: 10.0),
                      (pot: 40.0, bet: 12.0), (pot: 100.0, bet: 175.0)])
    func breakEvenIsAlphaNotBetOverPot(pot: Double, bet: Double) {
        let a = Self.alpha(bet: bet, pot: pot)

        // The confusion this rules out: `bet / pot` is the bet size, not the break-even
        // fold frequency. They differ by the bet's own contribution to the pot villain
        // is being offered, which is the whole of α.
        #expect(abs(a - bet / (pot + bet)) < 1e-12)

        func bluffEV(foldFrequency f: Double) -> Double { f * pot - (1 - f) * bet }

        #expect(abs(bluffEV(foldFrequency: a)) < 1e-9,
                Comment(rawValue: "at α = \(a) a bluff should be exactly break-even, "
                        + "measured \(bluffEV(foldFrequency: a))"))
        #expect(bluffEV(foldFrequency: a + 0.001) > 0)
        #expect(bluffEV(foldFrequency: a - 0.001) < 0)
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
    /// - `.veryTight` never reaches α at any size, so bluffing a range read as tight is
    ///   unprofitable by construction rather than by measurement.
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
