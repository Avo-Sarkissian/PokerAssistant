import Testing
import Foundation
import PokerCore
import PokerTestSupport
@testable import PokerAssistant

/// `Hand.hasDuplicateCards` is tested in PokerCore. What is tested here is that the
/// routing layer actually consults it: a deal that cannot happen must not be answered
/// with a number, and `calculateDeep` reports invalid input as 0 the same way its
/// existing hole-card and opponent-count guards do.
@Suite("Equity routing rejects impossible hands", .timeLimit(.minutes(3)))
struct EquityCalculatorValidationTests {

    @Test("The same hole card twice is not given an equity")
    func duplicateHoleCardsAreRejected() async {
        let calculator = EquityCalculator()
        let equity = await calculator.calculateDeep(
            hand: Hand(holeCards: cards("Ad Ad"), communityCards: []),
            opponents: 1, deadCards: [], iterations: 10_000)

        #expect(equity == 0,
                "an impossible hand was answered with \(equity * 100)% equity")
    }

    @Test("A hole card that is also on the board is not given an equity")
    func holeCardRepeatedOnBoardIsRejected() async {
        let calculator = EquityCalculator()
        let equity = await calculator.calculateDeep(
            hand: Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c Ad")),
            opponents: 1, deadCards: [], iterations: 10_000)

        #expect(equity == 0,
                "a board repeating a hole card was answered with \(equity * 100)% equity")
    }

    /// A dead card is a card someone else has folded or exposed; it cannot also be one
    /// hero is holding, and if it is, the remaining deck is built wrong.
    @Test("A dead card that hero also holds is not given an equity")
    func deadCardCollidingWithTheHandIsRejected() async {
        let calculator = EquityCalculator()
        let equity = await calculator.calculateDeep(
            hand: Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s")),
            opponents: 1, deadCards: [card("Ad")], iterations: 10_000)

        #expect(equity == 0,
                "a dead card hero is holding was answered with \(equity * 100)% equity")
    }

    /// The hole A4 opened. Guarding `ExactEnumerator` turned a crash into a `nil`, and
    /// `calculateDeep` reads `nil` as "this engine cannot answer — fall through to Monte
    /// Carlo". Nothing on that path re-checked the deck. `MonteCarloEngine` guards it and
    /// returns 0, but the GPU is tried first and its kernel does not: with no cards left
    /// the opponent loop breaks on the first seat, `bestOppValue` stays 0, and hero's real
    /// hand beats 0 for all 1000 iterations — the app reports 100% and recommends a jam
    /// for a spot that cannot be dealt. Which of the two answers you got depended on
    /// whether Metal happened to be ready.
    @Test("A deck too short to deal the hand is refused, not answered")
    func starvedDeckIsRefused() async {
        let calculator = EquityCalculator()
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s"))

        // Kill all 45 cards that are neither in hero's hand nor on the board.
        let inPlay = hand.allCards
        let dead = Set(Card.deck().filter { !inPlay.contains($0) })
        #expect(dead.count == 45, "expected 45 dead cards, built \(dead.count)")

        let equity = await calculator.calculateDeep(
            hand: hand, opponents: 1, deadCards: dead, iterations: 10_000)

        #expect(equity == 0, "a spot that cannot be dealt was answered with \(equity * 100)%")
    }

    /// One card short of dealing a single opponent is still a spot that cannot happen.
    @Test("One card short of a legal deal is refused")
    func oneCardShortIsRefused() async {
        let calculator = EquityCalculator()
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s"))
        let inPlay = hand.allCards
        let rest = Card.deck().filter { !inPlay.contains($0) }
        let dead = Set(rest.dropLast(1))     // exactly one live card, opponent needs two

        let equity = await calculator.calculateDeep(
            hand: hand, opponents: 1, deadCards: dead, iterations: 10_000)

        #expect(equity == 0, "one live card against a two-card opponent answered \(equity * 100)%")
    }

    /// Just enough deck to deal the opponent must still be answered.
    @Test("Exactly enough deck for the deal is still answered")
    func exactlyEnoughDeckIsAnswered() async {
        let calculator = EquityCalculator()
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s"))
        let inPlay = hand.allCards
        let rest = Card.deck().filter { !inPlay.contains($0) }
        let dead = Set(rest.dropLast(2))     // two live cards, exactly one opponent hand

        let equity = await calculator.calculateDeep(
            hand: hand, opponents: 1, deadCards: dead, iterations: 10_000)

        #expect(equity > 0, "a dealable spot was refused")
    }

    /// The guard must not reject legitimate spots: the same board with a genuinely
    /// dead card still answers.
    @Test("A legal hand with dead cards still gets an equity")
    func legalHandStillAnswers() async {
        let calculator = EquityCalculator()
        let equity = await calculator.calculateDeep(
            hand: Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s")),
            opponents: 1, deadCards: [card("Kh"), card("Qs")], iterations: 10_000)

        #expect(equity > 0.5, "aces on a dry river should be well ahead, got \(equity)")
    }
}
