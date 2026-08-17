import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

// MARK: - Is the bluff line reachable?

/// Backlog #28 claimed the solver's bluff branch was dead code: a
/// fold-below-pot-odds guard ran before the raise was ever priced, so a hand graded
/// `.bluff` could never be told to raise and `bluffFrequencyMultiplier` could never
/// affect an answer the user saw.
///
/// `makeDecision` was rewritten to a plain EV argmax in `bd2bedf`, which removed that
/// guard, so the finding needed re-checking before anything was built on it. These
/// tests are that check, and they are worth keeping either way: a raise that is
/// **only** profitable because villain folds is the one recommendation whose whole
/// value comes from the fold-equity model, and nothing else in the suite exercises it.
@Suite("Semi-bluffing")
struct SemiBluffTests {

    /// The exact spot the backlog said could not happen: hero's equity is below the
    /// price of a call, so calling is a loss and folding is the passive answer — and a
    /// raise still wins, because villain folds often enough to pay for it.
    @Test("A raise below the price of a call is recommended when villain folds enough")
    func bluffRaiseIsReachable() {
        let solver = ExploitativeSolver()
        // Villain bet 30 into 30 on a dry flop. Hero has 20% equity and the deep stack
        // to make a real raise.
        let state = spot(board: "Ks 7h 2d", pot: 60, toCall: 30,
                         stack: 200, villainStack: 200, position: .btn)
        let result = solver.solve(gameState: state, myEquity: 0.20, settings: makeSettings())

        // The preconditions of the claim, asserted rather than assumed.
        #expect(ExploitativeSolver.HandStrength(equity: 0.20) == .bluff,
                "20% equity no longer grades as a bluff; this spot no longer tests the claim")
        #expect(result.potOdds > 0.20,
                "pot odds \(result.potOdds) are below hero's equity, so no fold guard could fire here")
        #expect(result.evCall < 0, "calling is meant to be a loss here; it priced at \(result.evCall)")

        guard case .raise(let amount) = result.action else {
            Issue.record(Comment(rawValue: "expected a bluff-raise, got \(result.action.displayString)"))
            return
        }
        #expect(amount > 0)
        #expect(result.evRaise > 0,
                "the raise was recommended at \(result.evRaise) — a losing line cannot be the argmax here")
    }

    /// The other half of the claim: that the seat's bluff treatment never reaches a
    /// decision the user sees. Bet the same bluff from the button and from the small
    /// blind — the two seats differ in both the premium (1.3 vs 0.6) and the sizing
    /// (0.9 vs 1.1), so this pins that seat matters to a bluff, not that the premium
    /// alone does. Isolating the premium is not possible through the public API, and
    /// inventing a seam for it would test the seam rather than the solver.
    @Test("A bluff prices differently from different seats")
    func bluffPremiumIsLoadBearing() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()
        // Nothing to call, so hero is choosing between checking and betting: the raise
        // is paid for by fold equity alone.
        let state = spot(board: "Ks 7h 2d", pot: 40, toCall: 0,
                         stack: 400, villainStack: 400, position: .btn)

        let asBluff = solver.solve(gameState: state, myEquity: 0.30, settings: settings)
        #expect(ExploitativeSolver.HandStrength(equity: 0.30) == .bluff)

        // Fold equity is the only thing paying for this bet, and it beats checking.
        #expect(asBluff.evRaise > asBluff.evCall,
                "betting \(asBluff.evRaise) did not beat checking \(asBluff.evCall)")
        if case .raise = asBluff.action {} else {
            Issue.record(Comment(rawValue: "expected a bet, got \(asBluff.action.displayString)"))
        }

        // Same spot from the small blind, where the premium is 0.6 rather than 1.3.
        let outOfPosition = solver.solve(
            gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 0,
                            stack: 400, villainStack: 400, position: .sb),
            myEquity: 0.30, settings: settings)

        #expect(outOfPosition.evRaise < asBluff.evRaise,
                "the seat's bluff premium changed nothing: BTN \(asBluff.evRaise) vs SB \(outOfPosition.evRaise)")
    }
}
