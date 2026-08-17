import Testing
import Foundation
import PokerCore
import PokerTestSupport

/// Every entry point on `ExactEnumerator` builds its reusable hand buffer from
/// `available[0]` before it checks that there is an `available[0]` to read, so a deep
/// dead-card list takes the app down rather than falling back to the Monte Carlo path.
/// `MonteCarloEngine` guards exactly this with `availableCount >= neededCards`.
///
/// Returning nil is the contract: `EquityCalculator` reads nil as "this engine cannot
/// answer" and routes elsewhere. Returning 0.0 would be indistinguishable from a real
/// equity of zero.
@Suite("Exact enumeration guards")
struct EnumeratorGuardTests {

    private let enumerator = ExactEnumerator()

    /// Kill every card that is not already in the hand.
    private func everythingElseDead(_ hand: Hand) -> Set<Card> {
        let used = hand.allCards
        return Set(Card.deck().filter { card in !used.contains(card) })
    }

    /// Leave exactly `count` cards live.
    private func allButLiveCards(_ hand: Hand, live count: Int) -> Set<Card> {
        let used = hand.allCards
        let rest = Card.deck().filter { card in !used.contains(card) }
        return Set(rest.dropLast(count))
    }

    @Test("River with one opponent survives an empty deck")
    func riverOneOpponentWithNoCardsLeft() {
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s"))
        #expect(enumerator.calculateRiver(hand: hand, opponents: 1,
                                          deadCards: everythingElseDead(hand)) == nil)
    }

    @Test("River with two opponents survives an empty deck")
    func riverTwoOpponentsWithNoCardsLeft() {
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s"))
        #expect(enumerator.calculateRiver(hand: hand, opponents: 2,
                                          deadCards: everythingElseDead(hand)) == nil)
    }

    @Test("Turn survives an empty deck")
    func turnWithNoCardsLeft() {
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c"))
        #expect(enumerator.calculateTurn(hand: hand, opponents: 1,
                                         deadCards: everythingElseDead(hand)) == nil)
    }

    @Test("Flop survives an empty deck")
    func flopWithNoCardsLeft() {
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d"))
        #expect(enumerator.calculateFlop(hand: hand, opponents: 1,
                                         deadCards: everythingElseDead(hand)) == nil)
    }

    /// One card short of what the street needs.
    ///
    /// Honest about what this does and does not cover: these four cases were already
    /// declining before the count guards were added, via the older
    /// `guard total > 0 else { return nil }` at the bottom of each method — every
    /// combination is eliminated by the loop bounds, so `total` reaches zero without
    /// anything trapping. Deleting the four new guards leaves this test green. It is a
    /// characterisation test for the boundary, not the regression test for the guards;
    /// `everythingElseDead` above is what actually fails without them.
    @Test("Each street declines when the deck is one card short",
          arguments: [
            (board: "Ks 7h 2d 9c 4s", opponents: 1, live: 1),   // needs 2 for a hand
            (board: "Ks 7h 2d 9c 4s", opponents: 2, live: 3),   // needs 4 for two hands
            (board: "Ks 7h 2d 9c",    opponents: 1, live: 2),   // needs a river + 2
            (board: "Ks 7h 2d",       opponents: 1, live: 3),   // needs turn + river + 2
          ])
    func streetDeclinesJustBelowTheMinimum(board: String, opponents: Int, live: Int) {
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards(board))
        let dead = allButLiveCards(hand, live: live)

        let produced: Double?
        switch hand.communityCards.count {
        case 5: produced = enumerator.calculateRiver(hand: hand, opponents: opponents, deadCards: dead)
        case 4: produced = enumerator.calculateTurn(hand: hand, opponents: opponents, deadCards: dead)
        default: produced = enumerator.calculateFlop(hand: hand, opponents: opponents, deadCards: dead)
        }

        #expect(produced == nil,
                "\(board) with \(live) cards live and \(opponents) opponent(s) returned \(produced ?? -1)")
    }

    /// The guard must not swallow spots the enumerator can genuinely answer: one card
    /// more than the minimum still produces an equity.
    @Test("Each street still answers at its minimum deck",
          arguments: [
            (board: "Ks 7h 2d 9c 4s", opponents: 1, live: 2),
            (board: "Ks 7h 2d 9c 4s", opponents: 2, live: 4),
            (board: "Ks 7h 2d 9c",    opponents: 1, live: 3),
            (board: "Ks 7h 2d",       opponents: 1, live: 4),
          ])
    func streetAnswersAtTheMinimum(board: String, opponents: Int, live: Int) {
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards(board))
        let dead = allButLiveCards(hand, live: live)

        let produced: Double?
        switch hand.communityCards.count {
        case 5: produced = enumerator.calculateRiver(hand: hand, opponents: opponents, deadCards: dead)
        case 4: produced = enumerator.calculateTurn(hand: hand, opponents: opponents, deadCards: dead)
        default: produced = enumerator.calculateFlop(hand: hand, opponents: opponents, deadCards: dead)
        }

        let equity = try! #require(produced,
                                   Comment(rawValue: "\(board), \(live) live, \(opponents) opp declined a spot it can answer"))
        #expect(equity >= 0 && equity <= 1)
    }
}
