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
// The census is decisive because it is exhaustive. Any misclassification at all — one
// board pattern read as a straight that is not, one wheel missed, one flush that loses
// to a hand it beats — moves at least two of the nine totals and cannot be absorbed
// anywhere. A sampled check can only bound the error; this pins it at zero.

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

    /// If the nine numbers below were mistyped, the census would compare the evaluator
    /// against a fiction and could "fail" for a reason that has nothing to do with the
    /// evaluator. They sum to C(52,7) and to nothing else, so this catches that.
    @Test("The published counts sum to C(52,7)")
    func publishedTableSumsToTheNumberOfSevenCardHands() {
        #expect(Self.published.reduce(0, +) == Self.totalHands)
        #expect(Self.choose(52, 7) == Self.totalHands)
        #expect(Self.published.count == 9)
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
    /// Five sigma per category, with nine categories and a fixed seed, is a threshold no
    /// correct evaluator will ever cross and a broken one cannot slip under: the rarest
    /// category here still expects ~93 hands, and the common ones expect tens of
    /// thousands. This is a bound on the error, not a proof it is zero — run the
    /// exhaustive census for that.
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
