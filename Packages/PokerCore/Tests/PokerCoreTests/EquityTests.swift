import Testing
import Foundation
import PokerCore
import PokerTestSupport

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
                // Three opponents, not one. With a single opponent, dropping an
                // out-of-range player and re-dealing them are statistically
                // equivalent, so this test passed against the very bug it guards.
                opponents: 3,
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

// MARK: - Reproducibility

@Suite("Reproducibility", .timeLimit(.minutes(3)))
struct ReproducibilityTests {

    /// Without a seed the engine is free to differ run to run, but a caller that
    /// supplies one must get the same number back every time — otherwise no
    /// regression test can ever pin an equity.
    @Test("The same seed produces the same equity")
    func seededRunsAreReproducible() async {
        let engine = MonteCarloEngine()
        func run() async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
                opponents: 3,
                deadCards: [],
                iterations: 120_000,
                opponentRange: .random,
                confidenceThreshold: 0.0,   // never terminate early
                maxTimeSeconds: 60,
                seed: 0xA11CE
            )
        }
        let first = await run()
        let second = await run()

        #expect(first == second, "seeded runs diverged: \(first) vs \(second)")
    }

    /// The wall-clock cutoff exists so the UI can never hang. It must not be allowed to
    /// decide the answer: when a caller pins the seed, how busy the machine happens to
    /// be cannot change how many samples are counted, or the "same seed, same equity"
    /// contract holds only on an idle machine. This suite passed alone and failed under
    /// parallel load for exactly that reason.
    @Test("A seeded run ignores the clock")
    func seededRunsIgnoreTheTimeLimit() async {
        let engine = MonteCarloEngine()
        func run(maxTimeSeconds: Double) async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
                opponents: 3,
                deadCards: [],
                iterations: 120_000,
                opponentRange: .random,
                confidenceThreshold: 0.0,   // never terminate early on convergence
                maxTimeSeconds: maxTimeSeconds,
                seed: 0xA11CE
            )
        }

        // 0.001s cannot survive even one batch; 600s cannot expire.
        let underPressure = await run(maxTimeSeconds: 0.001)
        let unhurried = await run(maxTimeSeconds: 600)

        #expect(underPressure == unhurried,
                "the deadline changed a seeded answer: \(underPressure) vs \(unhurried)")
    }

    @Test("Different seeds explore different samples")
    func differentSeedsDiffer() async {
        let engine = MonteCarloEngine()
        func run(seed: UInt64) async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
                opponents: 3,
                deadCards: [],
                iterations: 120_000,
                opponentRange: .random,
                confidenceThreshold: 0.0,
                maxTimeSeconds: 60,
                seed: seed
            )
        }
        let a = await run(seed: 1)
        let b = await run(seed: 2)

        #expect(a != b, "two different seeds produced identical output — is the seed used at all?")
        #expect(abs(a - b) < 0.02, "seeds disagree far more than sampling error allows")
    }
}
