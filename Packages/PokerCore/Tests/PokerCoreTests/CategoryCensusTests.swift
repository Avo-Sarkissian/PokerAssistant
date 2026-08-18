import Testing
import Foundation
import PokerCore
import PokerTestSupport

// MARK: - The seven-card category census
//
// The first assertion in this repository against a number this repository did not
// produce. Every other test here compares one in-repo implementation to another —
// `FastHandEvaluator` against `ReferenceEvaluator`, the GPU against exact enumeration —
// which proves consistency and nothing about correctness. Two evaluators written from
// the same misunderstanding agree perfectly.
//
// The census closes that. Deal every one of the C(52,7) = 133,784,560 seven-card hands,
// ask `FastHandEvaluator` which category each one is, and compare the nine totals with
// the published frequencies of seven-card poker hands. The reference data is nine
// integers, needs no network, no solver and no opponent model, and it self-checks: the
// nine published counts sum to exactly C(52,7), so a transcription error in the table
// cannot hide.
//
// The census is decisive about *classification* and says nothing about *ordering*. It
// buckets on `evaluate(...) / 1_000_000`, which throws away every bit below the category,
// so any misclassification moves at least two of the nine totals and cannot be absorbed
// anywhere — but a flush that loses to a flush it beats moves nothing at all. That half
// of the evaluator is `SharedBoardShowdownTests`'s job, and the division of labour is not
// academic: dropping the fifth card from `top5Value` leaves all nine totals exact.

@Suite("Seven-card category census")
struct CategoryCensusTests {

    /// Published frequencies of the nine categories over all seven-card hands, indexed
    /// by the category `FastHandEvaluator` encodes in the millions place of its score.
    ///
    /// These are the standard published counts (Wikipedia "Poker probability", and every
    /// combinatorics text that tabulates seven-card hands). They are *not* derived from
    /// anything in this repository.
    static let published: [Int] = [
        23_294_460,   // 0  high card
        58_627_800,   // 1  one pair
        31_433_400,   // 2  two pair
         6_461_620,   // 3  three of a kind
         6_180_020,   // 4  straight
         4_047_644,   // 5  flush
         3_473_184,   // 6  full house
           224_848,   // 7  four of a kind
            41_584,   // 8  straight flush
    ]

    static let names = ["high card", "one pair", "two pair", "three of a kind", "straight",
                        "flush", "full house", "four of a kind", "straight flush"]

    /// C(52,7).
    static let totalHands = 133_784_560

    /// Set `POKER_EXTERNAL_ANCHORS=1` to run the exhaustive pass. It is ~21s in release
    /// and ~7 minutes in debug, which is why it is not in the fast loop:
    /// `./scripts/test anchors` builds release and sets this. The same gate covers the
    /// exhaustive head-to-head matchups in `PublishedEquityTests`, because they are the
    /// same kind of thing bought at the same kind of price.
    static var exhaustiveEnabled: Bool {
        ProcessInfo.processInfo.environment["POKER_EXTERNAL_ANCHORS"] == "1"
    }

    // MARK: - The reference table checks itself

    /// If the nine numbers above were mistyped, the census would compare the evaluator
    /// against a fiction and could "fail" for a reason that has nothing to do with the
    /// evaluator. They sum to C(52,7) and to nothing else, so this catches that.
    @Test("The published counts sum to C(52,7)")
    func publishedTableSumsToTheNumberOfSevenCardHands() {
        #expect(Self.published.reduce(0, +) == Self.totalHands)
        #expect(Self.choose(52, 7) == Self.totalHands)
        #expect(Self.published.count == 9)
    }

    /// Four of the nine are cheap to derive from scratch, so they are derived rather than
    /// trusted. The sum check above only says the nine numbers are mutually consistent;
    /// two compensating transcription errors would survive it. These four cannot be
    /// wrong and still agree with a count made here from the combinatorics.
    @Test("Four of the nine published counts derive from first principles")
    func publishedCountsDeriveFromFirstPrinciples() {
        // Quads: choose the rank, take all four of it, take any three of the other 48.
        // A second quad would need an eighth card, so nothing is counted twice.
        #expect(Self.published[7] == 13 * Self.choose(48, 3),
                Comment(rawValue: "quads: 13·C(48,3) = \(13 * Self.choose(48, 3))"))

        // Full house: no seven-card hand holds both a full house and a flush — a flush
        // spends five cards on one suit, and the two that are left cannot supply a rank
        // three times *and* another rank twice. So every rank pattern with a three and a
        // two is a full house and nothing better, and the three patterns can just be
        // counted: (3,3,1), (3,2,2), (3,2,1,1).
        let threeThreeOne = Self.choose(13, 2) * 4 * 4 * 11 * 4
        let threeTwoTwo   = 13 * 4 * Self.choose(12, 2) * 6 * 6
        let threeTwoOneOne = 13 * 4 * 12 * 6 * Self.choose(11, 2) * 16
        let fullHouses = threeThreeOne + threeTwoTwo + threeTwoOneOne
        #expect(Self.published[6] == fullHouses,
                Comment(rawValue: "full house: \(threeThreeOne) + \(threeTwoTwo) "
                        + "+ \(threeTwoOneOne) = \(fullHouses)"))

        // Five or more of one suit is a flush or a straight flush and never both, and
        // never twice in one hand, because two suits with five each would need ten cards.
        let atLeastFiveOfOneSuit = 4 * (Self.choose(13, 5) * Self.choose(39, 2)
                                        + Self.choose(13, 6) * 39
                                        + Self.choose(13, 7))
        #expect(Self.published[5] + Self.published[8] == atLeastFiveOfOneSuit,
                Comment(rawValue: "flush + straight flush: \(atLeastFiveOfOneSuit)"))

        // Straight flushes on their own: count the rank subsets of a single suit that
        // contain five in a row, fill the rest of the hand from the other 39 cards, and
        // multiply by the four suits. With the previous check this pins the flush count
        // individually as well.
        var runs: [Int] = (6...14).map { top in
            (0..<5).reduce(0) { mask, offset in mask | (1 << (top - 4 + offset - 2)) }
        }
        runs.append((1 << 12) | (1 << 3) | (1 << 2) | (1 << 1) | (1 << 0))   // the wheel
        var straightFlushesInOneSuit = 0
        for subset in 0..<(1 << 13) {
            let held = subset.nonzeroBitCount
            guard (5...7).contains(held) else { continue }
            guard runs.contains(where: { subset & $0 == $0 }) else { continue }
            straightFlushesInOneSuit += Self.choose(39, 7 - held)
        }
        #expect(Self.published[8] == 4 * straightFlushesInOneSuit,
                Comment(rawValue: "straight flush: 4·\(straightFlushesInOneSuit)"))
    }

    // MARK: - Exhaustive

    @Test("Every C(52,7) hand lands in its published category",
          .enabled(if: CategoryCensusTests.exhaustiveEnabled,
                   "set POKER_EXTERNAL_ANCHORS=1 (see ./scripts/test anchors)"),
          .timeLimit(.minutes(30)))
    func exhaustiveCensusMatchesPublishedCounts() {
        let counts = Self.exhaustiveCensus()

        #expect(counts.reduce(0, +) == Self.totalHands,
                Comment(rawValue: "enumerated \(counts.reduce(0, +)) hands, expected \(Self.totalHands)"))

        for category in 0..<9 {
            #expect(counts[category] == Self.published[category],
                    Comment(rawValue: "\(Self.names[category]): counted \(counts[category]), "
                            + "published \(Self.published[category]) "
                            + "(off by \(counts[category] - Self.published[category]))"))
        }
    }

    // MARK: - Sampled

    /// The exhaustive pass is gated, so the fast loop keeps a cheap version of the same
    /// external check: draw a seeded sample and compare each category's frequency with
    /// the published proportion, in units of its own sampling standard deviation.
    ///
    /// **This bounds the error; it does not pin it at zero, and the bound is loose where
    /// the category is rare.** At this sample size five sigma is 1.0% of the one-pair
    /// count, 2.0% of high card, 4–6% of the middle categories, 22% of four of a kind and
    /// **52% of straight flushes** — so a defect confined to the rare categories, or one
    /// misclassifying fewer than roughly 0.05% of all hands, passes here. Dropping the
    /// two-trips case from the full house is exactly such a defect: 54,912 hands
    /// reclassify, the exhaustive census fails by that exact margin, and this test sees
    /// 1.4 sigma. It is a smoke alarm, not the proof. The proof is the exhaustive pass,
    /// which is why CI runs it rather than relying on someone remembering to.
    @Test("A seeded sample reproduces the published category frequencies")
    func sampledCensusMatchesPublishedFrequencies() {
        let sampleSize = 300_000
        let counts = Self.sampledCensus(sampleSize: sampleSize, seed: 0x5EA5_0CEB)

        #expect(counts.reduce(0, +) == sampleSize)

        for category in 0..<9 {
            let p = Double(Self.published[category]) / Double(Self.totalHands)
            let expected = p * Double(sampleSize)
            let sigma = (p * (1 - p) * Double(sampleSize)).squareRoot()
            let z = (Double(counts[category]) - expected) / sigma

            #expect(abs(z) < 5,
                    Comment(rawValue: "\(Self.names[category]): saw \(counts[category]), "
                            + "expected \(String(format: "%.1f", expected)) ± "
                            + "\(String(format: "%.1f", sigma)) — that is "
                            + "\(String(format: "%.1f", z))σ"))
        }
    }

    // MARK: - Enumeration

    /// Buckets every seven-card hand by `evaluate(...) / 1_000_000`.
    ///
    /// One seven-element buffer is reused for the whole enumeration. `Card` carries a
    /// `UUID`, so building a fresh array per hand allocates 133,784,560 times and
    /// dominates the run; with the buffer reused the evaluator itself is the cost.
    static func exhaustiveCensus() -> [Int] {
        let deck = Card.deck()
        let evaluator = FastHandEvaluator()
        var counts = [Int](repeating: 0, count: 9)
        var hand = Array(repeating: deck[0], count: 7)

        for a in 0..<46 {
            hand[0] = deck[a]
            for b in (a + 1)..<47 {
                hand[1] = deck[b]
                for c in (b + 1)..<48 {
                    hand[2] = deck[c]
                    for d in (c + 1)..<49 {
                        hand[3] = deck[d]
                        for e in (d + 1)..<50 {
                            hand[4] = deck[e]
                            for f in (e + 1)..<51 {
                                hand[5] = deck[f]
                                for g in (f + 1)..<52 {
                                    hand[6] = deck[g]
                                    counts[Int(evaluator.evaluate(hand)) / 1_000_000] += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        return counts
    }

    /// The same buckets over a seeded uniform sample of seven-card hands.
    static func sampledCensus(sampleSize: Int, seed: UInt64) -> [Int] {
        let evaluator = FastHandEvaluator()
        var rng = SeededGenerator(seed: seed)
        var deck = Card.deck()
        var counts = [Int](repeating: 0, count: 9)
        var hand = Array(repeating: deck[0], count: 7)

        for _ in 0..<sampleSize {
            // Partial Fisher–Yates: the first seven slots become a uniform 7-subset.
            for i in 0..<7 {
                deck.swapAt(i, Int.random(in: i..<52, using: &rng))
            }
            for i in 0..<7 { hand[i] = deck[i] }
            counts[Int(evaluator.evaluate(hand)) / 1_000_000] += 1
        }
        return counts
    }

    /// Computed rather than written down, so the table's self-check has two independent
    /// sides to it.
    static func choose(_ n: Int, _ k: Int) -> Int {
        guard k >= 0, k <= n else { return 0 }
        var result = 1
        for i in 0..<min(k, n - k) {
            result = result * (n - i) / (i + 1)
        }
        return result
    }
}
