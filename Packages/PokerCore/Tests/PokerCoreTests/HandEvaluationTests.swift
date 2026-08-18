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
                rankingsSeen[key] = OpponentRange.openingRangeRank(deck[i], deck[j])
            }
        }

        #expect(rankingsSeen.count == 169)

        // 72o is legitimately the worst hand; nothing else may share its ranking.
        let bottomRanked = rankingsSeen.filter { $0.value == 168 }.keys.sorted()
        #expect(bottomRanked == ["72o"])
    }

    @Test("Pocket tens rank as a premium starting hand")
    func pocketTensAreStrong() {
        let strength = OpponentRange.openingRangeRank(card("Ts"), card("Th"))
        #expect(strength < 20)
    }

    @Test("Hands containing a ten appear in a standard opponent range")
    func tenHighHandsAppearInRanges() {
        #expect(OpponentRange.isHandInRange(card("Ts"), card("Th"), range: .veryTight))
        #expect(OpponentRange.isHandInRange(card("As"), card("Ts"), range: .standard))
        #expect(OpponentRange.isHandInRange(card("Js"), card("Ts"), range: .standard))
    }
}

// MARK: - Showdowns over a shared board

/// Every other evaluator test in this file compares two hands drawn from *different*
/// decks — `fastHandEvaluatorMatchesReference` deals `deck[0..<7]` against
/// `deck[7..<14]`, which is not a showdown anyone has ever played. Real opponents share
/// five community cards, and that is exactly the case where the low kickers decide:
/// both players are mostly playing the board, so their best fives agree down to the last
/// card or two.
///
/// The gap that showed: dropping the fifth card from `top5Value` — one character, `n == 5`
/// to `n == 4` — left every one of the 144 tests on this branch green, *including* the
/// exhaustive C(52,7) census and the published head-to-head matchups. It has to: the
/// category counts do not move, because a hand is still a flush or still a high card, and
/// hand-versus-hand equities barely move, because it takes a shared board to make two
/// players' top four cards agree. What it breaks is a real pot — board A♠K♦Q♥J♣5♠, one
/// player holding a nine and the other an eight, chopped instead of won.
@Suite("Showdowns over a shared board")
struct SharedBoardShowdownTests {

    /// The rules of poker, not this repository's encoding of them: five cards play, and
    /// the fifth is as binding as the first.
    @Test("The fifth card decides",
          arguments: [
            (board: "As Kd Qh Jc 5s", winner: "9d 3c", loser: "8d 2c",
             what: "high card, A-K-Q-J and the kicker"),
            (board: "As Ks Qs Js 7d", winner: "9s 3c", loser: "8s 2c",
             what: "flush, A-K-Q-J and the fifth spade"),
            (board: "As Kd 9h 5c 2d", winner: "Ac 7s", loser: "Ad 6s",
             what: "one pair, aces with K-9 and the third kicker"),
          ])
    func theFifthCardDecides(board: String, winner: String, loser: String, what: String) {
        let evaluator = FastHandEvaluator()
        let community = cards(board)
        let won = evaluator.evaluate(cards(winner) + community)
        let lost = evaluator.evaluate(cards(loser) + community)

        #expect(won > lost, Comment(rawValue: "\(what): \(winner) scored \(won), "
                                    + "\(loser) scored \(lost) on \(board)"))

        // Stated separately because a broken encoding usually produces a tie rather than
        // an inversion, and `won > lost` failing tells you which only if you go looking.
        #expect(won != lost, Comment(rawValue: "\(what): chopped a pot the winner won"))
    }

    /// A score is a single integer, so every tie-break is packed into one number by
    /// multipliers — pair × 10,000, second pair × 100, kicker × 1. Those multipliers have
    /// to be large enough that a lower term can never carry into a higher one, and
    /// nothing in the suite checked that: the category census is blind to it by
    /// construction, and two hands only collide when they agree on the pair *and* differ
    /// widely on the rest, which needs a shared board to arrange.
    ///
    /// Both cases below are real pots. Both are chops under a multiplier one decimal
    /// place too small, and both are wins for the player who is behind under a multiplier
    /// one place too large.
    @Test("The tie-break multipliers do not carry into each other",
          arguments: [
            (board: "9s 9h 2d 4c 2c", winner: "3d 3h", loser: "Ad 5s",
             what: "two pair: nines and threes with a four beats nines and twos with an ace"),
            (board: "2s 2h 2d 3s 3h", winner: "3d 7c", loser: "Ac Ad",
             what: "full house: threes full of twos beats twos full of aces"),
          ])
    func tieBreakMultipliersDoNotCarry(board: String, winner: String, loser: String, what: String) {
        let evaluator = FastHandEvaluator()
        let community = cards(board)
        let won = evaluator.evaluate(cards(winner) + community)
        let lost = evaluator.evaluate(cards(loser) + community)

        #expect(won > lost, Comment(rawValue: "\(what): \(winner) scored \(won), "
                                    + "\(loser) scored \(lost) on \(board)"))
        #expect(won != lost, Comment(rawValue: "\(what): the two scores collided at \(won)"))
    }

    /// The general net: deal a real showdown — five shared community cards and two hole
    /// cards each — and require the production evaluator to order it exactly as the
    /// independent oracle does. Seeded, so a disagreement can be reproduced.
    @Test("The evaluator orders real showdowns exactly like the reference")
    func sharedBoardShowdownsMatchTheReference() {
        let evaluator = FastHandEvaluator()
        var rng = SeededGenerator(seed: 0x5B0A_4D50)
        var deck = Card.deck()
        var disagreements: [String] = []

        for _ in 0..<6_000 {
            for i in 0..<9 {
                deck.swapAt(i, Int.random(in: i..<52, using: &rng))
            }
            let board = Array(deck[4..<9])
            let hero = Array(deck[0..<2]) + board
            let villain = Array(deck[2..<4]) + board

            let fastHero = evaluator.evaluate(hero)
            let fastVillain = evaluator.evaluate(villain)
            let referenceHero = ReferenceEvaluator.evaluate7(hero)
            let referenceVillain = ReferenceEvaluator.evaluate7(villain)

            let fastOrder = fastHero == fastVillain ? 0 : (fastHero > fastVillain ? 1 : -1)
            let referenceOrder = referenceHero == referenceVillain
                ? 0 : (referenceHero > referenceVillain ? 1 : -1)

            if fastOrder != referenceOrder, disagreements.count < 5 {
                disagreements.append(
                    "\(hero.map(\.displayString).joined(separator: " ")) vs "
                    + "\(villain.map(\.displayString).joined(separator: " ")): "
                    + "evaluator says \(fastOrder), reference says \(referenceOrder)")
            }
        }

        #expect(disagreements.isEmpty,
                Comment(rawValue: disagreements.joined(separator: "\n")))
    }
}
