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
// Measured: how far `foldEquityForRange` sits from α. That measurement is what drove the
// table to be re-anchored — fold equity is now α times a constant per range, so the
// multiple is a property of the opponent rather than of the bet size, and the test below
// asserts exactly that rather than pinning the six constants as targets.

@Suite("Fold equity against the balanced-defence baseline")
struct FoldEquityIdentityTests {

    /// The fraction of their range a defender must fold for a zero-equity bet of
    /// `bet` into a pot of `pot` to break even.
    static func alpha(bet: Double, pot: Double) -> Double {
        bet / (pot + bet)
    }

    /// The fold frequency the model credits for this spot, reassembled from its parts.
    ///
    /// Deliberately built from `foldEquityForRange` and `foldFrequencyMultiplier`
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
        let premium = base * Position.foldFrequencyMultiplier(actingLast: actsLast)
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
            * Position.foldFrequencyMultiplier(actingLast: actsLast)
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
                        + "\(String(format: "%.2f", largestBet)) of the pot, which is too "
                        + "narrow to say anything about how fold equity tracks bet size"))
    }

    // MARK: - Measurement

    /// The six rates, at the one bet size they are stated for.
    ///
    /// Anchoring fold equity to α moved *how the table extrapolates*, deliberately not
    /// *what it says*: at three-quarters of the pot — the size at which the old step
    /// function applied no adjustment at all — every range must still fold exactly what it
    /// folded before. Without this, re-reading the table at some other reference size
    /// would rescale all six constants at once and leave every proportionality and
    /// ordering assertion happy.
    ///
    /// This is the one place in the suite that states a strategic constant as a number,
    /// and it is here so that changing one is a deliberate act with a failing test in
    /// front of it.
    @Test("The table folds what it says it folds, at three-quarters of the pot",
          arguments: [(range: OpponentRange.RangeType.veryTight, rate: 0.25),
                      (range: .tight, rate: 0.35),
                      (range: .standard, rate: 0.45),
                      (range: .wide, rate: 0.55),
                      (range: .veryWide, rate: 0.65),
                      (range: .random, rate: 0.70)])
    func theTableStatesItsOwnRates(range: OpponentRange.RangeType, rate: Double) {
        let credited = ExploitativeSolver.foldEquityForRange(range, betSizeRelativeToPot: 0.75)
        #expect(abs(credited - rate) < 1e-12,
                Comment(rawValue: "\(range) folds \(credited) at three-quarters of the pot, "
                        + "where the table says \(rate)"))
    }

    /// Nobody folds everything, however large the bet and however loose the range. The
    /// ceiling is the only place the model stops being proportional to α, so it is the
    /// only other number worth stating.
    @Test("Credited fold equity is capped below certainty")
    func creditedFoldEquityIsCapped() {
        for range in Self.allRanges {
            for b in [2.0, 5.0, 50.0] {
                let credited = ExploitativeSolver.foldEquityForRange(range, betSizeRelativeToPot: b)
                #expect(credited <= 0.85 + 1e-12,
                        Comment(rawValue: "\(range) folds \(credited) to a \(b)-pot bet"))
            }
        }
        // …and the cap is reached rather than merely respected, or it is not being tested.
        #expect(abs(ExploitativeSolver.foldEquityForRange(.random, betSizeRelativeToPot: 3.0) - 0.85) < 1e-12)
    }

    /// What `foldEquityForRange` credits, as a multiple of α. Since fold equity was
    /// anchored to α the multiple is a property of the *range* and nothing else, which is
    /// the whole content of that change and is what this asserts:
    ///
    /// | range       | multiple | reading                                    |
    /// |-------------|----------|--------------------------------------------|
    /// | `.veryTight`| 0.583    | defends far more than a balanced opponent  |
    /// | `.tight`    | 0.817    | defends more                               |
    /// | `.standard` | 1.050    | almost exactly balanced                    |
    /// | `.wide`     | 1.283    | over-folds                                 |
    /// | `.veryWide` | 1.517    | over-folds badly                           |
    /// | `.random`   | 1.633    | folds anything it cannot use               |
    ///
    /// Those six numbers are not new. Each is the old table's rate at three-quarters of
    /// the pot divided by α there, so every range folds exactly what it folded before at
    /// the reference size. What changed is that the figure no longer wanders with bet
    /// size: it used to run from 2.80× at a quarter-pot bet down to 0.50× at 1.75 pot,
    /// crossing the balanced line in the middle, which is how bluff profitability ended up
    /// flipping back and forth.
    ///
    /// The one place proportionality stops is the 0.85 ceiling — nobody folds everything —
    /// and that binds only above about a 1.1-pot bet against the two loosest ranges.
    @Test("Credited fold equity is a fixed multiple of α, whatever the bet size")
    func creditedFoldEquityIsProportionalToAlpha() {
        let sizes = [0.25, 0.30, 0.40, 0.50, 0.60, 0.75, 0.85, 1.00, 1.10, 1.50, 1.75]

        for range in Self.allRanges {
            var multiples: [(size: Double, multiple: Double)] = []
            for b in sizes {
                let alpha = b / (1 + b)
                let credited = ExploitativeSolver.foldEquityForRange(range, betSizeRelativeToPot: b)
                // Above the ceiling the model is deliberately not proportional any more.
                guard credited < 0.85 - 1e-12 else { continue }
                multiples.append((b, credited / alpha))
            }

            #expect(multiples.count >= 8,
                    Comment(rawValue: "\(range): only \(multiples.count) of \(sizes.count) "
                            + "sizes sit below the ceiling, so this proves little"))

            let reference = multiples[0].multiple
            for (size, multiple) in multiples {
                #expect(abs(multiple - reference) < 1e-9,
                        Comment(rawValue: "\(range) folds \(multiple)× α at \(size) pot but "
                                + "\(reference)× at \(multiples[0].size) — the multiple is "
                                + "supposed to be a property of the range, not of the bet"))
            }

            // The envelope stays as a sanity bound on the six constants themselves: no
            // range may credit or deny fold equity by more than a factor of three against
            // a balanced defender. Under the step function the worst case was 2.80 and
            // this had almost no slack left.
            #expect(reference > 1.0 / 3.0 && reference < 3.0,
                    Comment(rawValue: "\(range) sits at \(reference)× a balanced defender"))
        }
    }

    /// Whether a pure bluff can ever be profitable is now a twelve-entry table, and this
    /// is it.
    ///
    /// It follows from the two changes above rather than from anything anyone chose. Once
    /// fold equity is α(b) · k(range) · m(position), the EV of a bet with no showdown
    /// value into a pot of P is
    ///
    ///     EV = f·(P + R) − R = R · (k·m − 1)
    ///
    /// — exactly linear in the bet, so the *sign* does not depend on the size, the pot or
    /// the stack at all. A bluff is either always profitable against a given opponent from
    /// a given seat, or never.
    ///
    /// | range       |  in position |  out of position |
    /// |-------------|--------------|------------------|
    /// | `.veryTight`| 0.758        | 0.350            |
    /// | `.tight`    | 1.062        | 0.490            |
    /// | `.standard` | 1.365        | 0.630            |
    /// | `.wide`     | 1.668        | 0.770            |
    /// | `.veryWide` | 1.972        | 0.910            |
    /// | `.random`   | 2.123        | 0.980            |
    ///
    /// **Every out-of-position entry is below one**, including `.random` at 0.980 — the
    /// range the model describes as folding anything it cannot use. So the solver will
    /// never bet a hand with no showdown value out of position, against anyone, at any
    /// size. Under the step function it would, because that function's floor kept small
    /// bets cheap relative to α.
    ///
    /// This test asserts the table rather than approving of it. Whether 1.3 and 0.6 are
    /// the right position multiples is unmeasured — they are the last hand-authored
    /// constants in the fold-equity path — and the point of pinning the product is that
    /// their most consequential effect is now visible in the suite instead of emerging
    /// from three multiplications in two files.
    @Test("Whether a pure bluff can profit is a property of range and seat alone")
    func bluffabilityIsATwelveEntryTable() {
        for range in Self.allRanges {
            for actsLast in [true, false] {
                let multiple = ExploitativeSolver.creditedFoldEquity(
                    range: range, betSizeRelativeToPot: 0.75, actsLast: actsLast) / (0.75 / 1.75)

                var signs = Set<Bool>()
                for step in 5...200 {
                    let b = Double(step) / 100.0
                    let f = ExploitativeSolver.creditedFoldEquity(
                        range: range, betSizeRelativeToPot: b, actsLast: actsLast)
                    signs.insert(f > b / (1 + b))
                }
                #expect(signs.count == 1,
                        Comment(rawValue: "\(range) \(actsLast ? "IP" : "OOP") is bluffable at "
                                + "some sizes and not others, which the α anchor is supposed "
                                + "to have ruled out"))
                #expect(signs.first == (multiple > 1),
                        Comment(rawValue: "\(range) \(actsLast ? "IP" : "OOP") folds "
                                + "\(String(format: "%.3f", multiple))× a balanced defender "
                                + "but bluffing it is \(signs.first == true ? "" : "un")profitable"))
            }
        }

        // The finding this table exists to keep visible.
        for range in Self.allRanges {
            let outOfPosition = ExploitativeSolver.creditedFoldEquity(
                range: range, betSizeRelativeToPot: 0.75, actsLast: false) / (0.75 / 1.75)
            #expect(outOfPosition < 1.0,
                    Comment(rawValue: "\(range) out of position now folds "
                            + "\(String(format: "%.3f", outOfPosition))× a balanced defender — "
                            + "if this is above 1 the position multiples have been "
                            + "recalibrated, which is exactly the change this test is here "
                            + "to make deliberate"))
        }
    }

    /// Bluff profitability must not flip back and forth as the bet grows.
    ///
    /// This shipped `.disabled` alongside the α identity, as an executable statement of a
    /// defect rather than a passing test: `foldEquityForRange` multiplied a base rate by a
    /// *step* function of bet size while α rises smoothly, so the gap between them jumped
    /// at every step boundary. `.standard` changed sign four times over this sweep —
    /// profitable to 0.82 pot, unprofitable from 0.82, profitable again from 0.85,
    /// unprofitable from 0.99, profitable at 1.10, unprofitable from 1.11 — which in a
    /// $100 pot means an $82 bluff priced as losing where an $85 bluff won, against the
    /// same opponent holding the same cards.
    ///
    /// Enabling it is what drove the fix. Zero sign changes, not "at most one": since fold
    /// equity became α times a constant, profitability is a property of the range alone
    /// over this whole sweep. The 0.85 ceiling does eventually let α catch up — around a
    /// 5.7-pot bet for `.random` — but that is far outside anything the solver can size to,
    /// and allowing a flip the sweep cannot reach would only be slack.
    @Test("Bluff profitability does not flip back and forth as the bet grows")
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
            #expect(flips.isEmpty,
                    Comment(rawValue: "\(range) changes sign \(flips.count) times: \(flips.joined(separator: ", "))"))
        }
    }
}
