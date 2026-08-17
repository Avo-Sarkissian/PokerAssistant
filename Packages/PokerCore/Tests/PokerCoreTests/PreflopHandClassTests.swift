import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

// MARK: - Two consumers, two questions

/// `OpponentRange`'s 169-hand list answers two different questions in this codebase,
/// and they are not the same question:
///
/// 1. **How wide is villain's range?** — `isHandInRange` walks the list to decide which
///    holdings a "top 20%" opponent is representing. That wants the order people
///    actually *play* hands in, where suitedness and connectedness matter because they
///    make a hand playable after the flop.
/// 2. **How strong is hero's hand?** — the solver used the same list to bucket hero into
///    monster/strong/medium/weak/bluff. That wants raw showdown strength, because the
///    buckets decide whether hero is shoving a made hand or semi-bluffing.
///
/// The measurements in `openingRangeOrderIsNotAShowdownStrengthOrder` show how far the
/// two diverge, and `preflopAdviceFollowsTheEquityItIsGiven` pins the fix: only the
/// range question reads the list now, and hero's grade comes from equity, exactly as it
/// already did on every street after the flop.
@Suite("Preflop hand class", .timeLimit(.minutes(3)))
struct PreflopHandClassTests {

    /// Hero's grade must be a function of the equity the engine measured, not of a chart
    /// the engine never saw. Hold the spot and the equity fixed and move only the hole
    /// cards across the whole ordering: nothing about the answer may change.
    ///
    /// The equity is chosen to sit in the `.weak` band, which is where the old hybrid
    /// disagreed with itself — a charted hand skipped the band entirely while an
    /// uncharted one landed in it and picked up the bluff fold-equity premium. That
    /// premium is the observable: `evRaise` differed by two thirds between two hands the
    /// engine had just priced identically.
    @Test("Preflop advice follows the equity it is given, not the starting-hand chart")
    func preflopAdviceFollowsTheEquityItIsGiven() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()

        // Spread across the ordering: rank 0, 3, 59, 75, 102, 168.
        let hands = ["Ad Ac", "Ad Ks", "2h 2d", "6s 5s", "Kh 6c", "7d 2c"]

        // Villain opened to 2.5bb over 1.5bb of blinds; hero is on the button with 100bb
        // and nothing posted. SPR stays well clear of the short-stack shove branch, so
        // preflop sizing is strength-independent and any difference has to come from the
        // grade itself.
        func result(_ hole: String, equity: Double) -> ExploitativeSolver.SolverResult {
            solver.solve(gameState: spot(hole: hole, pot: 4.0, toCall: 2.5,
                                         stack: 100, villainStack: 100, position: .btn),
                         myEquity: equity, settings: settings)
        }

        for equity in [0.20, 0.40, 0.60, 0.80, 0.90] {
            let baseline = result(hands[0], equity: equity)
            for hole in hands.dropFirst() {
                let other = result(hole, equity: equity)
                #expect(other.action == baseline.action,
                        Comment(rawValue: "at equity \(equity), \(hole) advised " +
                                "\(other.action.displayString) but \(hands[0]) advised " +
                                "\(baseline.action.displayString)"))
                #expect(abs(other.evRaise - baseline.evRaise) < 1e-9,
                        Comment(rawValue: "at equity \(equity), \(hole) priced a raise at " +
                                "\(other.evRaise) and \(hands[0]) at \(baseline.evRaise)"))
                #expect(abs(other.raiseAmount - baseline.raiseAmount) < 1e-9,
                        Comment(rawValue: "at equity \(equity), \(hole) sized to " +
                                "\(other.raiseAmount) and \(hands[0]) to \(baseline.raiseAmount)"))
                #expect(other.reasoning == baseline.reasoning,
                        Comment(rawValue: "at equity \(equity), the explanations differ:\n" +
                                "\(hole): \(other.reasoning)\n\(hands[0]): \(baseline.reasoning)"))
            }
        }
    }

    /// The evidence that the list cannot serve both consumers, measured rather than
    /// asserted: 65s stands 27 places *above* K6o in the opening-range order, and holds
    /// eleven points *less* all-in equity against a random hand. Whichever question the
    /// list is right about, it is badly wrong about the other one.
    ///
    /// This is also the receipt for the list's own doc comment, which used to claim the
    /// order was by preflop all-in equity against a random hand. It is not.
    @Test("The opening-range order is not a showdown-strength order")
    func openingRangeOrderIsNotAShowdownStrengthOrder() async {
        let engine = MonteCarloEngine()
        func allInEquity(_ hole: String) async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards(hole), communityCards: []),
                opponents: 1, deadCards: [], iterations: 600_000,
                opponentRange: .random, confidenceThreshold: 0.0,
                maxTimeSeconds: 120, seed: 0xC0FFEE)
        }

        let suitedConnector = cards("6s 5s")   // 65s
        let bigCardOffsuit = cards("Kh 6c")    // K6o

        let scRank = OpponentRange.openingRangeRank(suitedConnector[0], suitedConnector[1])
        let bcRank = OpponentRange.openingRangeRank(bigCardOffsuit[0], bigCardOffsuit[1])
        #expect(scRank == 75, "65s moved in the ordering: now \(scRank)")
        #expect(bcRank == 102, "K6o moved in the ordering: now \(bcRank)")
        #expect(bcRank - scRank == 27,
                "the gap this test is about is now \(bcRank - scRank) places, not 27")

        let scEquity = await allInEquity("6s 5s")
        let bcEquity = await allInEquity("Kh 6c")

        #expect(bcEquity > scEquity + 0.05,
                Comment(rawValue: "the worse-ranked hand no longer holds more equity: " +
                        "65s \(scEquity) vs K6o \(bcEquity) — re-derive this test's premise"))
    }

    /// What the list is still for. A hand that ranks better must be inside every range
    /// the worse-ranked hand is inside; a range that admitted a hand while excluding a
    /// better one would not be a "top X%" of anything.
    @Test("Range membership is monotone in the opening-range order")
    func rangeMembershipIsMonotoneInTheOrdering() {
        let deck = Card.deck()
        var byRank: [Int: (Card, Card)] = [:]
        for i in 0..<deck.count {
            for j in (i + 1)..<deck.count {
                byRank[OpponentRange.openingRangeRank(deck[i], deck[j])] = (deck[i], deck[j])
            }
        }
        #expect(byRank.count == 169, "the ordering covers \(byRank.count) classes, not 169")

        let ranks = byRank.keys.sorted()
        for range in [OpponentRange.RangeType.veryTight, .tight, .standard, .wide, .veryWide] {
            var sawOutsider = false
            for rank in ranks {
                let (a, b) = byRank[rank]!
                let inside = OpponentRange.isHandInRange(a, b, range: range)
                if !inside { sawOutsider = true }
                if inside && sawOutsider {
                    Issue.record(Comment(rawValue:
                        "\(range) admits rank \(rank) (\(OpponentRange.canonicalHand(a, b))) " +
                        "while excluding something ranked better"))
                    break
                }
            }
        }
    }
}
