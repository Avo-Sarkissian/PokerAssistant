import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

// MARK: - Postflop bet sizing

/// The postflop sizing ladder was flagged as a defect for not being monotone in hand
/// strength: `.bluff` sizes at 0.40 of the pot where `.weak` sizes at 0.33. It is not a
/// defect, and these tests exist so that nobody "fixes" it.
///
/// A monotone ladder is the thing to avoid, not the thing to aim for. The preflop sizing
/// code already says so in its own comment — sizing that tracks hand strength opens aces
/// larger than everything else every time, which is "a tell legible from across the table
/// within an orbit" — and the same argument applies after the flop. A hand with no
/// showdown value wants folds, and folds are what a larger bet buys; a weak made hand
/// wants a cheap showdown. Betting them the same size is the point.
///
/// What is genuinely open is that the four *made-hand* grades still descend in lockstep
/// with strength, which is the same tell in a smaller form. Merging them into a polarised
/// two-size scheme is a strategy design with no data behind it, so it is recorded in the
/// handoff rather than guessed at here.
@Suite("Postflop bet sizing")
struct PostflopSizingTests {

    /// Deep stacks and a dry board, so nothing clamps and only the grade moves.
    private func betSize(equity: Double) -> Double {
        let solver = ExploitativeSolver()
        let state = spot(board: "Ks 7h 2d", pot: 60, toCall: 0,
                         stack: 800, villainStack: 800, position: .btn)
        return solver.solve(gameState: state, myEquity: equity, settings: makeSettings()).raiseAmount
    }

    @Test("A hand with no showdown value bets larger than a weak made hand")
    func airBetsLargerThanAWeakMadeHand() {
        #expect(ExploitativeSolver.HandStrength(equity: 0.20) == .bluff)
        #expect(ExploitativeSolver.HandStrength(equity: 0.40) == .weak)

        let air = betSize(equity: 0.20)
        let weakMadeHand = betSize(equity: 0.40)

        #expect(air > weakMadeHand,
                Comment(rawValue: "air bet \(air) and a weak made hand bet \(weakMadeHand); "
                        + "a hand that can only win by folding villain out wants the folds"))
    }

    /// The made-hand grades do still descend with strength. Pinned so that the tell is
    /// visible in the suite rather than only in a comment — and so that a future
    /// polarised scheme has to change a test on purpose.
    @Test("The made-hand grades still size in lockstep with strength")
    func madeHandsStillDescendWithStrength() {
        let sizes = [betSize(equity: 0.90), betSize(equity: 0.75),
                     betSize(equity: 0.60), betSize(equity: 0.40)]

        for (stronger, weaker) in zip(sizes, sizes.dropFirst()) {
            #expect(stronger > weaker,
                    Comment(rawValue: "sizes \(sizes) are not descending — if this is a "
                            + "deliberate move to a polarised scheme, this test is the one "
                            + "to rewrite"))
        }
    }
}
