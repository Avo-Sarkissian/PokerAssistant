import Foundation
@testable import PokerAssistant

/// An independent, deliberately slow, definition-based 7-card hand evaluator.
///
/// This exists to be an *oracle*: it is written straight from the rules of poker
/// (enumerate all C(7,5) five-card subsets, classify each, take the best) with no
/// reference to how the production evaluators encode their scores. If a production
/// evaluator ever disagrees with this, the production evaluator is wrong.
///
/// Correctness here matters more than speed, so nothing is optimised.
struct ReferenceHandValue: Comparable {

    /// 8 straight flush · 7 quads · 6 full house · 5 flush
    /// 4 straight · 3 trips · 2 two pair · 1 pair · 0 high card
    let category: Int

    /// Rank values in descending order of significance, already resolved for the category.
    let tiebreak: [Int]

    static func == (l: ReferenceHandValue, r: ReferenceHandValue) -> Bool {
        l.category == r.category && l.tiebreak == r.tiebreak
    }

    static func < (l: ReferenceHandValue, r: ReferenceHandValue) -> Bool {
        if l.category != r.category { return l.category < r.category }
        for (a, b) in zip(l.tiebreak, r.tiebreak) where a != b { return a < b }
        return false
    }
}

enum ReferenceEvaluator {

    /// Classify exactly five cards.
    static func classify5(_ cards: [Card]) -> ReferenceHandValue {
        precondition(cards.count == 5)

        let ranks = cards.map { $0.rank.rawValue }
        let isFlush = Set(cards.map { $0.suit }).count == 1

        var counts: [Int: Int] = [:]
        for r in ranks { counts[r, default: 0] += 1 }

        // Rank groups ordered by size first, then by rank — this is exactly how a
        // human compares hands: trips before the pair, pair before the kicker.
        let groups = counts
            .map { (rank: $0.key, n: $0.value) }
            .sorted { $0.n != $1.n ? $0.n > $1.n : $0.rank > $1.rank }

        let distinct = Set(ranks).sorted(by: >)

        // A straight needs five distinct ranks spanning exactly four, or the wheel.
        var straightHigh: Int? = nil
        if distinct.count == 5 {
            if distinct[0] - distinct[4] == 4 {
                straightHigh = distinct[0]
            } else if distinct == [14, 5, 4, 3, 2] {
                straightHigh = 5           // the ace plays low; the hand is five-high
            }
        }

        if isFlush, let high = straightHigh {
            return ReferenceHandValue(category: 8, tiebreak: [high])
        }
        if groups[0].n == 4 {
            return ReferenceHandValue(category: 7, tiebreak: [groups[0].rank, groups[1].rank])
        }
        if groups[0].n == 3 && groups[1].n == 2 {
            return ReferenceHandValue(category: 6, tiebreak: [groups[0].rank, groups[1].rank])
        }
        if isFlush {
            return ReferenceHandValue(category: 5, tiebreak: distinct)
        }
        if let high = straightHigh {
            return ReferenceHandValue(category: 4, tiebreak: [high])
        }
        if groups[0].n == 3 {
            return ReferenceHandValue(category: 3, tiebreak: [groups[0].rank, groups[1].rank, groups[2].rank])
        }
        if groups[0].n == 2 && groups[1].n == 2 {
            return ReferenceHandValue(category: 2, tiebreak: [groups[0].rank, groups[1].rank, groups[2].rank])
        }
        if groups[0].n == 2 {
            return ReferenceHandValue(category: 1,
                                      tiebreak: [groups[0].rank, groups[1].rank, groups[2].rank, groups[3].rank])
        }
        return ReferenceHandValue(category: 0, tiebreak: distinct)
    }

    /// Best five-card value available from seven cards.
    static func evaluate7(_ cards: [Card]) -> ReferenceHandValue {
        precondition(cards.count == 7)
        var best: ReferenceHandValue? = nil
        for skipA in 0..<6 {
            for skipB in (skipA + 1)..<7 {
                var five: [Card] = []
                five.reserveCapacity(5)
                for i in 0..<7 where i != skipA && i != skipB { five.append(cards[i]) }
                let value = classify5(five)
                if best == nil || value > best! { best = value }
            }
        }
        return best!
    }
}

// MARK: - Test card helpers

/// Parse a card from the compact "As", "Th", "2c" notation used throughout these tests.
func card(_ text: String) -> Card {
    let rankMap: [Character: Rank] = [
        "2": .two, "3": .three, "4": .four, "5": .five, "6": .six, "7": .seven,
        "8": .eight, "9": .nine, "T": .ten, "J": .jack, "Q": .queen, "K": .king, "A": .ace
    ]
    let suitMap: [Character: Suit] = ["s": .spades, "h": .hearts, "d": .diamonds, "c": .clubs]
    let chars = Array(text)
    guard chars.count == 2,
          let rank = rankMap[chars[0]],
          let suit = suitMap[chars[1]] else {
        preconditionFailure("Unparseable card: \(text)")
    }
    return Card(rank: rank, suit: suit)
}

/// Parse a space-separated list of cards, e.g. `cards("As Kh 2c")`.
func cards(_ text: String) -> [Card] {
    text.split(separator: " ").map { card(String($0)) }
}

/// A small, seedable generator so evaluator tests are reproducible run to run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
