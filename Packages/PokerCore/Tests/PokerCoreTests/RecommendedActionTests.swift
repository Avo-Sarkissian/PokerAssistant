import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

// MARK: - Canonical spots
//
// Backlog #14, and the last piece of the safety net around the solver. Everything else in
// this target asserts *properties* — the action is the argmax of the EVs, no raise is an
// illegal size, no negative-EV line is taken while folding is available. Properties are
// scale-free, which is their strength and also the hole: a model that shifted every
// recommendation one notch less aggressive would satisfy every one of them. This session
// moved 6.5% of recommendations, and nothing in the suite would have noticed.
//
// **Where the expected answers come from.** A canonical-spot suite is only worth its
// maintenance if the answers are not simply what the code says today, so every case here
// rests on one of two things and says which:
//
// - **Arithmetic.** Folding forfeits a call that is priced to win; or calling loses and no
//   raise can rescue it because villain is already all in and cannot fold. These follow
//   from the definitions of the EVs and would be true of any solver.
// - **Consensus.** Aces do not fold preflop. Seventy-two offsuit does not open under the
//   gun. These are not derivable here, but no poker player of any school disputes them,
//   and a model that broke one would be broken.
//
// Nothing is asserted on the strength of being what the model currently prefers. Where the
// honest answer is "this is a judgement call", the case asserts the half that is not —
// usually `neverFold` — rather than inventing a target.

@Suite("Canonical recommendations")
struct RecommendedActionTests {

    enum Expectation: String, Sendable {
        case mustRaise, mustFold, neverFold, neverRaise
    }

    struct Spot: Sendable {
        let name: String
        let basis: String
        let expect: Expectation
        var hole = "Ad Ac"
        var board = ""
        var equity: Double
        var pot: Double
        var toCall: Double
        var stack: Double = 100
        var villainStack: Double = 100
        var position: Position = .btn
        var players: Int = 2
        var tableSize: Int = 6
        var wager: Double = 0
    }

    static let spots: [Spot] = [

        // ── Arithmetic: a fold gives up a call that is priced to win ──────────────
        Spot(name: "80% facing a fifth of the pot", basis: "arithmetic",
             expect: .neverFold, board: "Ks 7h 2d", equity: 0.80, pot: 100, toCall: 20),
        Spot(name: "45% facing a fifth of the pot", basis: "arithmetic",
             expect: .neverFold, board: "Ks 7h 2d", equity: 0.45, pot: 100, toCall: 20),
        Spot(name: "30% facing a fifth of the pot", basis: "arithmetic",
             expect: .neverFold, board: "Ks 7h 2d 4c", equity: 0.30, pot: 100, toCall: 20),
        Spot(name: "51% facing a pot-sized bet", basis: "arithmetic",
             expect: .neverFold, board: "Ks 7h 2d 4c 9s", equity: 0.51, pot: 100, toCall: 100),
        Spot(name: "85% facing a shove hero can cover", basis: "arithmetic",
             expect: .neverFold, board: "Ks 7h 2d 4c 9s", equity: 0.85,
             pot: 100, toCall: 100, stack: 100, villainStack: 100),

        // ── Arithmetic: checking is free, so folding cannot be right ──────────────
        Spot(name: "5% with nothing to call", basis: "arithmetic",
             expect: .neverFold, board: "Ks 7h 2d", equity: 0.05, pot: 40, toCall: 0),
        Spot(name: "nothing at all with nothing to call", basis: "arithmetic",
             expect: .neverFold, board: "Ks 7h 2d 4c 9s", equity: 0.0, pot: 40, toCall: 0),

        // ── Arithmetic: calling loses and villain cannot fold, so nothing rescues it ─
        Spot(name: "10% against an all-in villain", basis: "arithmetic",
             expect: .mustFold, board: "Ks 7h 2d", equity: 0.10,
             pot: 100, toCall: 60, villainStack: 60),
        Spot(name: "20% against an all-in villain", basis: "arithmetic",
             expect: .mustFold, board: "Ks 7h 2d 4c", equity: 0.20,
             pot: 60, toCall: 50, villainStack: 50),
        Spot(name: "drawing dead against an all-in villain", basis: "arithmetic",
             expect: .mustFold, board: "Ks 7h 2d 4c 9s", equity: 0.0,
             pot: 40, toCall: 40, villainStack: 40),
        Spot(name: "30% against an all-in villain laying 2:1", basis: "arithmetic",
             expect: .mustFold, board: "Ks 7h 2d 4c 9s", equity: 0.30,
             pot: 50, toCall: 50, villainStack: 50),

        // ── Arithmetic: the nuts beats checking it, and beats calling with it ──────
        Spot(name: "the nuts on the river, first to act", basis: "arithmetic",
             expect: .mustRaise, board: "Ks 7h 2d 4c 9s", equity: 1.0, pot: 60, toCall: 0),
        Spot(name: "the nuts on the river, facing a bet", basis: "arithmetic",
             expect: .mustRaise, board: "Ks 7h 2d 4c 9s", equity: 1.0, pot: 90, toCall: 30),
        Spot(name: "the nuts on the turn, deep", basis: "arithmetic",
             expect: .mustRaise, board: "Ks 7h 2d 4c", equity: 1.0,
             pot: 60, toCall: 20, stack: 400, villainStack: 400),

        // ── Consensus: preflop hands that do not fold ─────────────────────────────
        Spot(name: "aces facing a 2.5bb open", basis: "consensus",
             expect: .mustRaise, hole: "Ad Ac", equity: 0.85, pot: 4.0, toCall: 2.5,
             stack: 100, villainStack: 100, position: .btn, players: 2, tableSize: 6),
        Spot(name: "aces ten big blinds deep facing an open", basis: "consensus",
             expect: .mustRaise, hole: "Ad Ac", equity: 0.85, pot: 4.0, toCall: 2.5,
             stack: 10, villainStack: 10),
        Spot(name: "kings facing a 3-bet", basis: "consensus",
             expect: .neverFold, hole: "Kd Kc", equity: 0.82, pot: 12.0, toCall: 6.5,
             wager: 2.5),
        Spot(name: "queens facing a 2.5bb open", basis: "consensus",
             expect: .neverFold, hole: "Qd Qc", equity: 0.78, pot: 4.0, toCall: 2.5),
        Spot(name: "ace-king suited facing a 2.5bb open", basis: "consensus",
             expect: .neverFold, hole: "Ad Kd", equity: 0.67, pot: 4.0, toCall: 2.5),
        Spot(name: "aces facing a 4-bet", basis: "consensus",
             expect: .neverFold, hole: "Ad Ac", equity: 0.85, pot: 35.5, toCall: 16.0,
             wager: 9.0),

        // ── Consensus: preflop hands that do not continue ─────────────────────────
        Spot(name: "seven-deuce under the gun", basis: "consensus",
             expect: .mustFold, hole: "7d 2c", equity: 0.10, pot: 1.5, toCall: 1.0,
             position: .utg, players: 6, tableSize: 6),
        Spot(name: "seven-deuce facing a 4-bet", basis: "consensus",
             expect: .mustFold, hole: "7d 2c", equity: 0.12, pot: 35.5, toCall: 16.0,
             wager: 9.0),
        Spot(name: "nine-four offsuit facing a 3-bet", basis: "consensus",
             expect: .mustFold, hole: "9d 4c", equity: 0.15, pot: 12.0, toCall: 6.5,
             wager: 2.5),

        // ── Consensus: postflop commitment ────────────────────────────────────────
        Spot(name: "a monster with one pot-sized bet left behind", basis: "consensus",
             expect: .mustRaise, board: "Ks 7h 2d", equity: 0.92, pot: 100, toCall: 20,
             stack: 120, villainStack: 120),
        Spot(name: "a monster on the river facing a bet", basis: "consensus",
             expect: .mustRaise, board: "Ks 7h 2d 4c 9s", equity: 0.95,
             pot: 100, toCall: 25),
        Spot(name: "a monster first to act on the river", basis: "consensus",
             expect: .mustRaise, board: "Ks 7h 2d 4c 9s", equity: 0.95,
             pot: 100, toCall: 0),
        Spot(name: "air on the river against an all-in villain", basis: "arithmetic",
             expect: .mustFold, board: "Ks 7h 2d 4c 9s", equity: 0.02,
             pot: 80, toCall: 40, villainStack: 40),
        Spot(name: "a bluff-catcher priced out by an all-in villain", basis: "arithmetic",
             expect: .mustFold, board: "Ks 7h 2d 4c 9s", equity: 0.25,
             pot: 60, toCall: 60, villainStack: 60),
        Spot(name: "a bluff-catcher getting the price", basis: "arithmetic",
             expect: .neverFold, board: "Ks 7h 2d 4c 9s", equity: 0.40,
             pot: 200, toCall: 40, villainStack: 40),
        Spot(name: "a marginal hand in a limped pot", basis: "arithmetic",
             expect: .neverFold, board: "Ks 7h 2d", equity: 0.35, pot: 6, toCall: 1),
    ]

    @Test("The recommendation in a canonical spot", arguments: RecommendedActionTests.spots)
    func canonicalSpot(_ spec: Spot) {
        let solver = ExploitativeSolver()
        let state = spot(hole: spec.hole, board: spec.board,
                         pot: spec.pot, toCall: spec.toCall,
                         stack: spec.stack, villainStack: spec.villainStack,
                         position: spec.position, playersInHand: spec.players,
                         tableSize: spec.tableSize, heroWagerThisStreet: spec.wager)
        let result = solver.solve(gameState: state, myEquity: spec.equity,
                                  settings: makeSettings())

        var raised = false, folded = false
        switch result.action {
        case .raise: raised = true
        case .fold: folded = true
        case .call: break
        }

        let detail = "\(spec.name) [\(spec.basis)]: recommended \(result.action) — "
                   + "fold \(result.evFold), call \(result.evCall), raise \(result.evRaise)"

        switch spec.expect {
        case .mustRaise: #expect(raised, Comment(rawValue: detail))
        case .mustFold:  #expect(folded, Comment(rawValue: detail))
        case .neverFold: #expect(!folded, Comment(rawValue: detail))
        case .neverRaise: #expect(!raised, Comment(rawValue: detail))
        }
    }

    /// Where the app stops folding must be exactly the price it is being offered.
    ///
    /// This is the part of the suite that catches a *uniform* drift, which the spots above
    /// cannot: they are deliberately far from the boundary, so a model that shifted every
    /// recommendation slightly would still satisfy all thirty. Sweeping for the boundary
    /// finds that shift immediately, and it needs no opinion about what the answer should
    /// be — with villain already all in there is no fold equity to rescue a call, so
    /// calling is worth `equity·(pot + toCall) − toCall` and crosses zero at
    /// `toCall / (pot + toCall)`. Pot odds, and nothing else.
    @Test("The equity at which folding stops is the pot odds",
          arguments: [(pot: 100.0, toCall: 20.0), (pot: 100.0, toCall: 100.0),
                      (pot: 60.0, toCall: 50.0), (pot: 200.0, toCall: 40.0),
                      (pot: 30.0, toCall: 90.0)])
    func theFoldBoundaryIsThePotOdds(pot: Double, toCall: Double) {
        let solver = ExploitativeSolver()
        let priced = toCall / (pot + toCall)

        // Villain is all in, so no raise exists and no fold equity can pay for one.
        func folds(at equity: Double) -> Bool {
            let state = spot(board: "Ks 7h 2d 4c 9s", pot: pot, toCall: toCall,
                             stack: 1_000, villainStack: toCall)
            return solver.solve(gameState: state, myEquity: equity,
                                settings: makeSettings()).action == .fold
        }

        var low = 0.0, high = 1.0            // folds at `low`, does not at `high`
        #expect(folds(at: low), "folded nothing at zero equity")
        #expect(!folds(at: high), "folded the nuts")
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if folds(at: mid) { low = mid } else { high = mid }
        }

        #expect(abs(low - priced) < 1e-6,
                Comment(rawValue: "with \(toCall) to call into \(pot) the price is "
                        + "\(priced) and the app folds up to \(low) — a gap of "
                        + "\(low - priced) is a drift in the call arithmetic"))
    }

    /// The price the app *shows* has to be the price it *acts on*.
    ///
    /// `potOdds` is what reaches the result card as "Need X% to call", and the boundary
    /// test above is where the app actually stops folding. They are computed in different
    /// places and nothing tied them together: dropping the bet from the denominator —
    /// `toCall / potSize`, the everyday confusion between a bet's size and the price it
    /// lays — survived every test in this target. It would have told a user facing 20 into
    /// 100 that they need 20% when they need 16.7%, while the solver went on folding at
    /// 16.7%, so the displayed figure and the recommendation would have disagreed with no
    /// test able to see it.
    @Test("The price on the card is the price the solver folds at",
          arguments: [(pot: 100.0, toCall: 20.0), (pot: 100.0, toCall: 100.0),
                      (pot: 60.0, toCall: 50.0), (pot: 30.0, toCall: 90.0)])
    func displayedPriceMatchesTheDecision(pot: Double, toCall: Double) {
        let solver = ExploitativeSolver()
        let result = solver.solve(
            gameState: spot(board: "Ks 7h 2d 4c 9s", pot: pot, toCall: toCall,
                            stack: 1_000, villainStack: toCall),
            myEquity: 0.5, settings: makeSettings())

        #expect(abs(result.potOdds - toCall / (pot + toCall)) < 1e-12,
                Comment(rawValue: "\(toCall) into \(pot) is priced at "
                        + "\(toCall / (pot + toCall)) and reported as \(result.potOdds)"))
    }

    /// The same boundary with villain still holding chips can only move *down*: a raise is
    /// another way to win, so it can rescue a call that the price alone does not justify,
    /// and it can never make a priced call worse. Asserting the direction rather than a
    /// number keeps this true across any re-calibration of fold equity.
    @Test("Fold equity can only lower the point at which hero stops folding",
          arguments: [(pot: 100.0, toCall: 20.0), (pot: 60.0, toCall: 50.0),
                      (pot: 200.0, toCall: 40.0)])
    func foldEquityOnlyLowersTheBoundary(pot: Double, toCall: Double) {
        let solver = ExploitativeSolver()
        let priced = toCall / (pot + toCall)

        func folds(at equity: Double) -> Bool {
            let state = spot(board: "Ks 7h 2d 4c 9s", pot: pot, toCall: toCall,
                             stack: 1_000, villainStack: 1_000)
            return solver.solve(gameState: state, myEquity: equity,
                                settings: makeSettings()).action == .fold
        }

        var low = 0.0, high = 1.0
        if !folds(at: low) { low = 0.0; high = 0.0 }   // never folds at all: boundary is 0
        else {
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if folds(at: mid) { low = mid } else { high = mid }
            }
        }

        #expect(low <= priced + 1e-6,
                Comment(rawValue: "hero folds up to \(low) with a raise available, above "
                        + "the \(priced) the price alone demands — a raise cannot make a "
                        + "call worth less"))
    }

    /// The suite is only a drift detector if it covers both directions. A model that
    /// folded everything would satisfy every `mustFold`; one that raised everything would
    /// satisfy every `mustRaise`.
    @Test("The canonical set constrains the model in both directions")
    func theSetIsNotOneSided() {
        let expectations = Set(Self.spots.map(\.expect))
        #expect(expectations.contains(.mustRaise))
        #expect(expectations.contains(.mustFold))
        #expect(expectations.contains(.neverFold))
        #expect(Self.spots.count >= 25,
                Comment(rawValue: "only \(Self.spots.count) canonical spots"))
        #expect(Self.spots.filter { $0.basis == "arithmetic" }.count >= 12)
    }
}
