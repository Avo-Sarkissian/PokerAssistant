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

    /// The sampler and the enumerator must answer the same question. Where both can run,
    /// the enumerator is the oracle — it is pinned above to a brute-force count made with
    /// the independent reference evaluator, so it has no opinions of its own.
    ///
    /// Two opponents *and* a range filter, deliberately, because that is the only
    /// configuration in which the order the sampler deals its seats can matter. Each seat
    /// is dealt from the part of the deck the earlier seats have not taken, and is
    /// re-dealt until it holds a hand inside the range. Draw the first card from the
    /// whole deck instead — the classic naive-shuffle slip, one token wide — and the swap
    /// reaches back into a seat that has already passed the range check and quietly
    /// replaces one of its cards. No card is duplicated and no player disappears, so
    /// nothing looks wrong: the seats simply stop being interchangeable and some of them
    /// end up holding hands the range excludes.
    ///
    /// Measured, that slip moves this spot from 0.0006 above the enumerator to 0.0083
    /// above it, while leaving every published anchor on this branch inside tolerance —
    /// the aces ladder shifts by two thousandths, because the mean of a biased sample is
    /// still close to right when the range is the whole deck. It survived the entire
    /// suite until this test existed.
    @Test("Sampling agrees with enumeration when the opponents are ranged", .timeLimit(.minutes(5)))
    func samplingAgreesWithEnumerationForRangedOpponents() async {
        let hand = Hand(holeCards: cards("Kd Jc"), communityCards: cards("As 9h 4d 7c 2s"))
        let enumerated = ExactEnumerator().calculateRiver(
            hand: hand, opponents: 2, deadCards: [], opponentRange: .tight)
        let sampled = await MonteCarloEngine().simulate(
            hand: hand,
            opponents: 2,
            deadCards: [],
            iterations: 150_000,
            opponentRange: .tight,
            confidenceThreshold: 0.0,
            maxTimeSeconds: 900,
            seed: 0xA11CE          // seeded: the tolerance is small enough to want it
        )

        #expect(enumerated != nil)
        // Five standard errors at this sample size, and a fifth of the gap the dealing
        // slip opens up.
        #expect(abs(sampled - (enumerated ?? -1)) < 0.004,
                Comment(rawValue: "enumerated \(enumerated ?? -1), sampled \(sampled) "
                        + "(off by \(String(format: "%+.5f", sampled - (enumerated ?? 0))))"))
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

    /// Asking for three times the samples must actually draw them.
    ///
    /// Two independent one-line defects reduce to the same symptom, and neither moves any
    /// equity far enough for a published anchor to notice — the aces ladder shifts by
    /// nothing at all, because the *mean* of a smaller sample is still unbiased. What
    /// changes is the precision the caller was promised, silently.
    ///
    /// - The convergence check runs `standardError < confidenceThreshold`. Inverted, it
    ///   fires after the first 50,000-hand batch on every call, whatever was requested —
    ///   which is the defect `PreflopEquityTable` already hit once from the other side.
    /// - Each batch derives its seed from the batch index. Drop that and every batch
    ///   re-deals the identical 50,000 hands, so a 150,000-iteration run carries a third
    ///   of the information while reporting the full count to the convergence check.
    ///
    /// Both make a longer run return the shorter run's answer *exactly*, which is
    /// something no honest sampler ever does.
    @Test("A longer run is a different run")
    func moreSamplesMeansMoreSamples() async {
        let engine = MonteCarloEngine()
        func run(iterations: Int) async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
                opponents: 2,
                deadCards: [],
                iterations: iterations,
                opponentRange: .random,
                confidenceThreshold: 0.0,   // never terminate early
                maxTimeSeconds: 900,
                seed: 0xB16_5A11
            )
        }
        let short = await run(iterations: 50_000)
        let long = await run(iterations: 150_000)

        #expect(short != long,
                Comment(rawValue: "50,000 and 150,000 samples returned the identical "
                        + "\(long) — the extra 100,000 hands were never dealt"))
        // …and the extra samples refine the answer rather than replacing it.
        #expect(abs(short - long) < 0.01,
                Comment(rawValue: "50,000 gave \(short), 150,000 gave \(long)"))
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
