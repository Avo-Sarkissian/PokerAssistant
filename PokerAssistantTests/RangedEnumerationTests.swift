import Testing
import Foundation
import PokerCore
import PokerTestSupport
@testable import PokerAssistant

// The range-conditioned enumeration itself is tested in `PokerCoreTests`, where it
// needs no simulator. What stays here is the routing: which engine `EquityCalculator`
// actually picks, and with what range — that lives in the app target.

@Suite("Range reaches the recommendation", .timeLimit(.minutes(3)))
struct RangeRoutingTests {

    /// Deliberately gated. `OpponentRange` is a preflop starting-hand chart with no
    /// continuation model, so applying it to a postflop showdown keeps hands that would
    /// have folded and drops the ones that bet. Measured on 3c3d / 8s7h6d2c4h it inverts
    /// the relationship — 35.4% vs a random hand, 68.4% vs "tight" — which would make a
    /// larger villain bet increase hero's reported equity.
    ///
    /// The enumerators still take a range and are tested in the package; only the
    /// routing waits for a board-conditioned continuation model.
    @Test("Postflop equity is not conditioned on the preflop range chart")
    func postflopEquityIgnoresThePreflopChart() async {
        let calculator = EquityCalculator()
        let hand = Hand(holeCards: cards("Kd Jc"), communityCards: cards("Ks 7h 2d"))

        let versusRandom = await calculator.calculateDeep(
            hand: hand, opponents: 1, deadCards: [], iterations: 100_000,
            opponentRange: .random)
        let versusTight = await calculator.calculateDeep(
            hand: hand, opponents: 1, deadCards: [], iterations: 100_000,
            opponentRange: .tight)

        #expect(abs(versusTight - versusRandom) < 1e-9,
                "postflop routing applied a preflop range chart: tight \(versusTight) vs random \(versusRandom)")
    }
}
