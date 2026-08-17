import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

/// A range's name is a promise about how much of the deck it contains, and everything
/// downstream reads it that way — fold equity, the enumerators' filtering, the equity the
/// user is shown.
///
/// The promise is about *combinations*, not hand classes. There are 169 classes but 1326
/// combinations, and they are not evenly spread: a pair is 6 combos, a suited hand 4, an
/// offsuit hand 12. Taking the top 10% of classes takes mostly pairs and suited hands —
/// the combo-poor ones — so the range that calls itself "top 10%" holds far less than a
/// tenth of the deck.
@Suite("Range width")
struct RangeWidthTests {

    /// Fraction of the 1326 starting combinations a range actually admits.
    private func comboFraction(_ range: OpponentRange.RangeType) -> Double {
        let deck = Card.deck()
        var admitted = 0
        var total = 0
        for i in 0..<deck.count {
            for j in (i + 1)..<deck.count {
                total += 1
                if OpponentRange.isHandInRange(deck[i], deck[j], range: range) { admitted += 1 }
            }
        }
        #expect(total == 1326, "expected 1326 combinations, counted \(total)")
        return Double(admitted) / Double(total)
    }

    @Test("Each range holds about as much of the deck as its name claims",
          arguments: [
            OpponentRange.RangeType.veryTight,
            .tight,
            .standard,
            .wide,
            .veryWide,
          ])
    func rangeWidthMatchesItsLabel(range: OpponentRange.RangeType) {
        let actual = comboFraction(range)
        let claimed = range.percentile

        #expect(abs(actual - claimed) <= 0.04,
                Comment(rawValue: "\(range) claims \(claimed) of the deck but holds "
                        + String(format: "%.3f", actual)))
    }

    @Test("A random range is the whole deck")
    func randomRangeIsEverything() {
        #expect(comboFraction(.random) == 1.0)
    }

    /// Widening the label must widen the range — the ordering is what fold equity and
    /// every range-conditioned equity depend on.
    @Test("Wider labels admit strictly more of the deck")
    func widerLabelsAdmitMore() {
        let ladder: [OpponentRange.RangeType] = [.veryTight, .tight, .standard, .wide, .veryWide, .random]
        let widths = ladder.map { ($0, comboFraction($0)) }

        for (tighter, wider) in zip(widths, widths.dropFirst()) {
            #expect(wider.1 > tighter.1,
                    "\(wider.0) holds \(wider.1), no more than \(tighter.0)'s \(tighter.1)")
        }
    }

    /// The tightest range must still be the premium hands — widening the thresholds must
    /// not let trash in at the top.
    @Test("The tightest range is still premium hands")
    func tightestRangeIsStillPremium() {
        #expect(OpponentRange.isHandInRange(card("Ad"), card("Ac"), range: .veryTight), "AA")
        #expect(OpponentRange.isHandInRange(card("Kd"), card("Kc"), range: .veryTight), "KK")
        #expect(OpponentRange.isHandInRange(card("Ad"), card("Kd"), range: .veryTight), "AKs")
        #expect(!OpponentRange.isHandInRange(card("7d"), card("2c"), range: .veryTight), "72o")
        #expect(!OpponentRange.isHandInRange(card("9d"), card("4c"), range: .veryTight), "94o")
    }
}

/// Fold equity is a table of constants whose one real invariant is that it tracks how much
/// of the deck villain's range holds: a wider range folds more often. `.random` broke that
/// ordering, sitting below `.wide` and `.veryWide` — harmless while nothing produced
/// `.random`, and not harmless once unopened preflop pots began reading it.
@Suite("Fold equity ordering")
struct FoldEquityOrderingTests {

    @Test("A wider range folds more often")
    func foldEquityTracksRangeWidth() {
        let ladder: [OpponentRange.RangeType] = [.veryTight, .tight, .standard, .wide, .veryWide, .random]
        let equities = ladder.map { ($0, ExploitativeSolver.foldEquityForRange($0)) }

        for (tighter, wider) in zip(equities, equities.dropFirst()) {
            #expect(wider.1 > tighter.1,
                    Comment(rawValue: "\(wider.0) folds \(wider.1), "
                            + "no more than \(tighter.0)'s \(tighter.1)"))
        }
    }

    /// The ordering has to survive the bet-size multiplier too, at both extremes.
    @Test("The ordering holds at every bet size", arguments: [0.25, 0.75, 1.5])
    func orderingHoldsAcrossBetSizes(betSize: Double) {
        let ladder: [OpponentRange.RangeType] = [.veryTight, .tight, .standard, .wide, .veryWide, .random]
        let equities = ladder.map { ExploitativeSolver.foldEquityForRange($0, betSizeRelativeToPot: betSize) }

        for (tighter, wider) in zip(equities, equities.dropFirst()) {
            #expect(wider >= tighter, Comment(rawValue: "at \(betSize) pot: \(wider) after \(tighter)"))
        }
    }
}
