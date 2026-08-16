//
//  PokerAssistantTests.swift
//  PokerAssistantTests
//

import Testing
import Foundation
@testable import PokerAssistant

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

// MARK: - Equity

@Suite("Preflop equity", .timeLimit(.minutes(3)))
struct PreflopEquityTests {

    /// Published all-in equities against a uniformly random opponent hand.
    /// Sources agree on these to within a tenth of a point.
    @Test("CPU Monte Carlo reproduces published heads-up equities",
          arguments: [
            (hand: "Ad Ac", expected: 0.852),
            (hand: "Kd Kc", expected: 0.824),
            (hand: "Ad Kd", expected: 0.670),
            (hand: "7d 2c", expected: 0.346),
          ])
    func headsUpEquityMatchesPublishedValues(hand holeCards: String, expected: Double) async {
        let engine = MonteCarloEngine()
        let equity = await engine.simulate(
            hand: Hand(holeCards: cards(holeCards), communityCards: []),
            opponents: 1,
            deadCards: [],
            iterations: 600_000,
            opponentRange: .random,
            confidenceThreshold: 0.001,
            maxTimeSeconds: 60
        )
        #expect(abs(equity - expected) < 0.008,
                "expected ~\(expected), measured \(equity)")
    }

    @Test("Aces against five random opponents is close to a coin flip")
    func acesFiveHandedEquity() async {
        let engine = MonteCarloEngine()
        let equity = await engine.simulate(
            hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
            opponents: 5,
            deadCards: [],
            iterations: 600_000,
            opponentRange: .random,
            confidenceThreshold: 0.001,
            maxTimeSeconds: 60
        )
        #expect(abs(equity - 0.494) < 0.010, "expected ~0.494, measured \(equity)")
    }

    /// Equity must fall as opponents are added. The app currently reports roughly the
    /// same number for one, five and eight opponents.
    @Test("Equity decreases monotonically as opponents are added")
    func equityFallsWithMoreOpponents() async {
        let engine = MonteCarloEngine()
        func equity(opponents: Int) async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
                opponents: opponents,
                deadCards: [],
                iterations: 400_000,
                opponentRange: .random,
                confidenceThreshold: 0.002,
                maxTimeSeconds: 60
            )
        }
        let one = await equity(opponents: 1)
        let five = await equity(opponents: 5)
        let eight = await equity(opponents: 8)

        #expect(one > five, "1 opp \(one) should beat 5 opp \(five)")
        #expect(five > eight, "5 opp \(five) should beat 8 opp \(eight)")
    }

    /// A dominated hand loses equity as the opponent's range narrows, because the
    /// hands that survive a tight range are exactly the ones that dominate it.
    /// Removing out-of-range opponents from the pot instead of re-dealing them
    /// inverts this relationship.
    ///
    /// KJo rather than a premium hand on purpose: aces are the one holding a tight
    /// range *helps*, since such a range is concentrated in the AK/AQ that aces
    /// dominate. Measured, aces run 85.1% vs random and 84.8% vs tight — the
    /// invariant genuinely does not hold there, so asserting it would be wrong.
    @Test("Equity falls monotonically as the opponent's range narrows")
    func tighterRangeLowersEquity() async {
        let engine = MonteCarloEngine()
        func equity(range: OpponentRange.RangeType) async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards("Kd Jc"), communityCards: []),
                opponents: 1,
                deadCards: [],
                iterations: 300_000,
                opponentRange: range,
                confidenceThreshold: 0.001,
                maxTimeSeconds: 60
            )
        }

        let ladder: [OpponentRange.RangeType] = [.random, .veryWide, .wide, .standard, .tight, .veryTight]
        var measured: [(OpponentRange.RangeType, Double)] = []
        for range in ladder { measured.append((range, await equity(range: range))) }

        for (wider, tighter) in zip(measured, measured.dropFirst()) {
            #expect(tighter.1 < wider.1,
                    "\(tighter.0) \(tighter.1) should be below \(wider.0) \(wider.1)")
        }

        // The spread is large and the direction is the whole point of range modelling.
        let widest = measured.first!.1
        let narrowest = measured.last!.1
        #expect(widest - narrowest > 0.15,
                "expected a wide spread, got \(widest) → \(narrowest)")
    }
}

// MARK: - Exact enumeration

@Suite("Exact enumeration")
struct ExactEnumerationTests {

    /// Exact enumeration is the codebase's reference implementation; pin it against a
    /// brute-force count computed here with the independent oracle.
    @Test("River equity matches an independent enumeration exactly")
    func riverEquityMatchesBruteForce() {
        let holeCards = cards("Ad Ac")
        let board = cards("Ks 7h 2d 9c 4s")
        let enumerator = ExactEnumerator()

        let produced = enumerator.calculateRiver(
            hand: Hand(holeCards: holeCards, communityCards: board),
            opponents: 1,
            deadCards: []
        )

        // Independent count using the reference evaluator.
        func index(_ c: Card) -> Int { (c.rank.rawValue - 2) * 4 + c.suit.suitIndex }
        let used = Set((holeCards + board).map(index))
        let available = Card.deck().filter { !used.contains(index($0)) }
        let mine = ReferenceEvaluator.evaluate7(holeCards + board)

        var share = 0.0
        var total = 0
        for i in 0..<(available.count - 1) {
            for j in (i + 1)..<available.count {
                let theirs = ReferenceEvaluator.evaluate7([available[i], available[j]] + board)
                if mine > theirs { share += 1 } else if mine == theirs { share += 0.5 }
                total += 1
            }
        }
        let expected = share / Double(total)

        #expect(produced != nil)
        #expect(abs((produced ?? -1) - expected) < 1e-12,
                "enumerator \(produced ?? -1) vs reference \(expected)")
    }
}

// MARK: - GPU / CPU agreement

@Suite("GPU and CPU agreement", .timeLimit(.minutes(3)))
struct GPUConsistencyTests {

    /// The GPU kernel and the exact enumerator must answer the same question the same
    /// way. Exact enumeration is provably correct, so any gap here is the shader's.
    @Test("GPU Monte Carlo matches exact flop enumeration")
    func gpuMatchesExactEnumeration() async throws {
        let flop = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d"))

        guard let metal = MetalCompute() else {
            Issue.record("No Metal device available on this host")
            return
        }

        // The pipeline compiles on a background queue; give it a moment to become ready.
        var gpuEquity: Double? = nil
        for _ in 0..<60 {
            gpuEquity = await metal.simulateGPU(hand: flop, opponents: 1,
                                                deadCards: [], iterations: 2_000_000)
            if gpuEquity != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let gpu = try #require(gpuEquity, "GPU never became ready")
        let exact = try #require(ExactEnumerator().calculateFlop(hand: flop, opponents: 1,
                                                                deadCards: []))

        #expect(abs(gpu - exact) < 0.005,
                "GPU \(gpu) vs exact \(exact) — delta \(abs(gpu - exact))")
    }
}
