import Testing
import Foundation
import PokerCore
import PokerTestSupport

// MARK: - Hand ranking

@Suite("Hand ranking")
struct HandRankingTests {

    /// Locks FastHandEvaluator against the independent oracle. This is a regression
    /// guard, not a bug hunt: it protects the evaluator while the Metal kernel and the
    /// CPU engine are consolidated onto it.
    @Test("FastHandEvaluator orders random showdowns exactly like the reference")
    func fastHandEvaluatorMatchesReference() {
        let evaluator = FastHandEvaluator()
        var rng = SeededGenerator(seed: 0xC0FFEE)
        var deck = Card.deck()
        var disagreements = 0

        for _ in 0..<3_000 {
            for i in 0..<14 {
                let j = Int.random(in: i..<52, using: &rng)
                deck.swapAt(i, j)
            }
            let left = Array(deck[0..<7])
            let right = Array(deck[7..<14])

            let fastLeft = evaluator.evaluate(left)
            let fastRight = evaluator.evaluate(right)
            let refLeft = ReferenceEvaluator.evaluate7(left)
            let refRight = ReferenceEvaluator.evaluate7(right)

            let fastOrder = fastLeft == fastRight ? 0 : (fastLeft > fastRight ? 1 : -1)
            let refOrder = refLeft == refRight ? 0 : (refLeft > refRight ? 1 : -1)
            if fastOrder != refOrder { disagreements += 1 }
        }

        #expect(disagreements == 0)
    }

    /// The specific encoding bug that shipped in two of the three evaluators: a
    /// one-pair score large enough to land inside the two-pair band.
    @Test("Two pair beats one pair, whatever the pair is")
    func twoPairBeatsOnePair() {
        let evaluator = FastHandEvaluator()
        let acesOnly = evaluator.evaluate(cards("As Ah Kd Qc Jh 7s 3d"))
        let kingsAndQueens = evaluator.evaluate(cards("Ks Kh Qs Qh 2d 7c 3d"))
        let threesAndTwos = evaluator.evaluate(cards("3s 3h 2s 2h Ad 9c 5d"))

        #expect(kingsAndQueens > acesOnly)
        #expect(threesAndTwos > acesOnly)
    }

    /// The other shipped bug: a rank span of four with a duplicate rank is not a straight.
    @Test("A paired hand spanning four ranks is not a straight")
    func pairedHandIsNotAStraight() {
        let evaluator = FastHandEvaluator()
        let pairedSixes = evaluator.evaluate(cards("6s 6h 5d 4c 2h Kd Qc"))
        let realStraight = evaluator.evaluate(cards("6s 5h 4d 3c 2h Kd Qc"))

        #expect(realStraight > pairedSixes)
    }

    @Test("The wheel is a five-high straight and loses to a six-high straight")
    func wheelIsTheLowestStraight() {
        let evaluator = FastHandEvaluator()
        let wheel = evaluator.evaluate(cards("As 2h 3d 4c 5s Kd Qc"))
        let sixHigh = evaluator.evaluate(cards("2h 3d 4c 5s 6d Kd Qc"))

        #expect(sixHigh > wheel)
    }

    @Test("Identical made hands from the same board tie exactly")
    func boardPlayingProducesAnExactTie() {
        let evaluator = FastHandEvaluator()
        // Both players miss entirely; the royal flush on board plays for both.
        let left = evaluator.evaluate(cards("As Ks Qs Js Ts 2h 3d"))
        let right = evaluator.evaluate(cards("As Ks Qs Js Ts 4c 7d"))

        #expect(left == right)
    }
}

// MARK: - Starting hand rankings

@Suite("Starting hand rankings")
struct StartingHandRankingTests {

    /// Every one of the 169 starting hands must resolve to a real entry. Anything that
    /// misses the table silently becomes rank 168 — the worst hand in the deck.
    @Test("All 169 starting hands resolve to a distinct ranking")
    func allStartingHandsResolve() {
        let deck = Card.deck()
        var rankingsSeen: [String: Int] = [:]

        for i in 0..<deck.count {
            for j in (i + 1)..<deck.count {
                let key = OpponentRange.canonicalHand(deck[i], deck[j])
                rankingsSeen[key] = OpponentRange.handStrength(deck[i], deck[j])
            }
        }

        #expect(rankingsSeen.count == 169)

        // 72o is legitimately the worst hand; nothing else may share its ranking.
        let bottomRanked = rankingsSeen.filter { $0.value == 168 }.keys.sorted()
        #expect(bottomRanked == ["72o"])
    }

    @Test("Pocket tens rank as a premium starting hand")
    func pocketTensAreStrong() {
        let strength = OpponentRange.handStrength(card("Ts"), card("Th"))
        #expect(strength < 20)
    }

    @Test("Hands containing a ten appear in a standard opponent range")
    func tenHighHandsAppearInRanges() {
        #expect(OpponentRange.isHandInRange(card("Ts"), card("Th"), range: .veryTight))
        #expect(OpponentRange.isHandInRange(card("As"), card("Ts"), range: .standard))
        #expect(OpponentRange.isHandInRange(card("Js"), card("Ts"), range: .standard))
    }
}
