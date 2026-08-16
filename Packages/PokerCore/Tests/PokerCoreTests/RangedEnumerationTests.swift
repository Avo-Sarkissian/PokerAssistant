import Testing
import Foundation
import PokerCore
import PokerTestSupport

@Suite("Range-conditioned enumeration")
struct RangedEnumerationTests {

    private let enumerator = ExactEnumerator()

    private func river(_ hole: String, _ board: String,
                       _ range: OpponentRange.RangeType,
                       opponents: Int = 1) -> Double? {
        enumerator.calculateRiver(hand: Hand(holeCards: cards(hole), communityCards: cards(board)),
                                  opponents: opponents, deadCards: [], opponentRange: range)
    }

    /// Asking for a random opponent must still enumerate every hand, so the existing
    /// exact results are unchanged.
    @Test("A random range enumerates the whole deck, as before")
    func randomRangeIsUnfiltered() {
        let hole = cards("Ad Ac")
        let board = cards("Ks 7h 2d 9c 4s")
        let produced = river("Ad Ac", "Ks 7h 2d 9c 4s", .random)

        func index(_ c: Card) -> Int { (c.rank.rawValue - 2) * 4 + c.suit.suitIndex }
        let used = Set((hole + board).map(index))
        let available = Card.deck().filter { !used.contains(index($0)) }
        let mine = ReferenceEvaluator.evaluate7(hole + board)

        var share = 0.0
        var total = 0
        for i in 0..<(available.count - 1) {
            for j in (i + 1)..<available.count {
                let theirs = ReferenceEvaluator.evaluate7([available[i], available[j]] + board)
                if mine > theirs { share += 1 } else if mine == theirs { share += 0.5 }
                total += 1
            }
        }

        #expect(produced != nil)
        #expect(abs((produced ?? -1) - share / Double(total)) < 1e-12)
    }

    /// The whole point of the range model. A hand that a tight range dominates must be
    /// worth less against that range than against a random hand — the app infers the
    /// range from villain's bet, so discarding it postflop threw the inference away.
    @Test("A dominated hand loses equity against a narrower range")
    func dominatedHandLosesEquityVersusTightRange() {
        let versusRandom = river("Kd Jc", "Ks 7h 2d 9c 4s", .random)
        let versusTight = river("Kd Jc", "Ks 7h 2d 9c 4s", .tight)

        let random = try! #require(versusRandom)
        let tight = try! #require(versusTight)

        #expect(tight < random,
                "top pair is worth \(tight) vs a tight range and \(random) vs random")
    }

    /// The full ladder, on the street where the enumeration is exact.
    @Test("River equity falls monotonically as the range narrows")
    func riverEquityFallsWithRange() {
        let ladder: [OpponentRange.RangeType] = [.random, .veryWide, .wide, .standard, .tight, .veryTight]
        var measured: [(OpponentRange.RangeType, Double)] = []
        for range in ladder {
            measured.append((range, try! #require(river("Kd Jc", "Ks 7h 2d 9c 4s", range))))
        }

        for (wider, tighter) in zip(measured, measured.dropFirst()) {
            #expect(tighter.1 < wider.1,
                    "\(tighter.0) \(tighter.1) should be below \(wider.0) \(wider.1)")
        }
    }

    /// Filtering changes the answer on the turn and flop too, not just the river.
    @Test("Turn and flop honour the range")
    func turnAndFlopHonourTheRange() {
        let turn = Hand(holeCards: cards("Kd Jc"), communityCards: cards("Ks 7h 2d 9c"))
        let turnRandom = try! #require(enumerator.calculateTurn(hand: turn, opponents: 1,
                                                               deadCards: [], opponentRange: .random))
        let turnTight = try! #require(enumerator.calculateTurn(hand: turn, opponents: 1,
                                                              deadCards: [], opponentRange: .tight))
        #expect(turnTight < turnRandom, "turn: tight \(turnTight) vs random \(turnRandom)")

        let flop = Hand(holeCards: cards("Kd Jc"), communityCards: cards("Ks 7h 2d"))
        let flopRandom = try! #require(enumerator.calculateFlop(hand: flop, opponents: 1,
                                                               deadCards: [], opponentRange: .random))
        let flopTight = try! #require(enumerator.calculateFlop(hand: flop, opponents: 1,
                                                              deadCards: [], opponentRange: .tight))
        #expect(flopTight < flopRandom, "flop: tight \(flopTight) vs random \(flopRandom)")
    }

    /// Two opponents both have to be in range.
    @Test("Two-opponent river filters both hands")
    func twoOpponentRiverFiltersBoth() {
        let random = try! #require(river("Kd Jc", "Ks 7h 2d 9c 4s", .random, opponents: 2))
        let tight = try! #require(river("Kd Jc", "Ks 7h 2d 9c 4s", .tight, opponents: 2))
        #expect(tight < random, "2-opp: tight \(tight) vs random \(random)")
    }
}
