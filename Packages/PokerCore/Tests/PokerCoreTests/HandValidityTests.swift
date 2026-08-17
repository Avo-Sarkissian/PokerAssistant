import Testing
import Foundation
import PokerCore
import PokerTestSupport

/// One card cannot be in two places. Nothing checked, so a hand holding the same card
/// twice was enumerated as if it were a pair and answered with a confident equity —
/// measured at 76.82% for duplicate hole cards. Every engine here dedupes by 0–51 index
/// when building the remaining deck, which quietly hides the duplicate rather than
/// rejecting it.
@Suite("Hand validity")
struct HandValidityTests {

    @Test("A legal hand has no duplicates")
    func legalHandIsClean() {
        let preflop = Hand(holeCards: cards("Ad Ac"), communityCards: [])
        let river = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s"))

        #expect(!preflop.hasDuplicateCards)
        #expect(!river.hasDuplicateCards)
    }

    @Test("The same hole card twice is a duplicate")
    func duplicateHoleCards() {
        #expect(Hand(holeCards: cards("Ad Ad"), communityCards: []).hasDuplicateCards)
    }

    @Test("A hole card that is also on the board is a duplicate")
    func holeCardRepeatedOnTheBoard() {
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h Ad"))
        #expect(hand.hasDuplicateCards)
    }

    @Test("The same card twice on the board is a duplicate")
    func boardRepeatsACard() {
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h Ks"))
        #expect(hand.hasDuplicateCards)
    }

    /// Same rank in different suits is a perfectly ordinary hand.
    @Test("Matching ranks in different suits are not duplicates")
    func matchingRanksAreFine() {
        #expect(!Hand(holeCards: cards("Ad Ah"), communityCards: cards("As Ac 2d")).hasDuplicateCards)
    }

    /// `isValid` is the name a caller reaches for, so it has to mean what the engines
    /// enforce — otherwise the two definitions drift and the engines are the only ones
    /// that are right.
    @Test("isValid rejects exactly what the engines reject")
    func isValidAgreesWithTheEngines() {
        #expect(Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d")).isValid)
        #expect(!Hand(holeCards: cards("Ad Ad"), communityCards: []).isValid, "duplicate hole cards")
        #expect(!Hand(holeCards: cards("Ad"), communityCards: []).isValid, "one hole card")
        #expect(!Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s 3h")).isValid,
                "six community cards")
    }
}

/// A3 put the duplicate-card check in the app's routing layer only, which left every
/// engine underneath it still willing to answer an impossible deal — and answer it
/// differently from the layer above. The guard belongs where the invariant is owned.
@Suite("Engines refuse impossible deals")
struct EngineValidationTests {

    @Test("Exact enumeration declines a duplicated card on every street")
    func exactEnumerationDeclinesDuplicates() {
        let enumerator = ExactEnumerator()

        let river = Hand(holeCards: cards("Ad Ad"), communityCards: cards("Ks 7h 2d 9c 4s"))
        #expect(enumerator.calculateRiver(hand: river, opponents: 1, deadCards: []) == nil)
        #expect(enumerator.calculateRiver(hand: river, opponents: 2, deadCards: []) == nil)

        let turn = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d Ad"))
        #expect(enumerator.calculateTurn(hand: turn, opponents: 1, deadCards: []) == nil)

        let flop = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks Ks 2d"))
        #expect(enumerator.calculateFlop(hand: flop, opponents: 1, deadCards: []) == nil)
    }

    /// The symptom that gives the duplicate away: the deck it builds is one card too big,
    /// because the duplicate collapses when the remaining deck is computed but is still
    /// scored twice in hero's own hand.
    @Test("A duplicated card no longer produces an over-sized deck's worth of equity")
    func duplicateDoesNotSilentlyEnlargeTheDeck() {
        let enumerator = ExactEnumerator()
        let legal = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s"))
        let illegal = Hand(holeCards: cards("Ad Ad"), communityCards: cards("Ks 7h 2d 9c 4s"))

        #expect(enumerator.calculateRiver(hand: legal, opponents: 1, deadCards: []) != nil)
        #expect(enumerator.calculateRiver(hand: illegal, opponents: 1, deadCards: []) == nil)
    }

    @Test("Monte Carlo declines a duplicated card")
    func monteCarloDeclinesDuplicates() async {
        let engine = MonteCarloEngine()
        let equity = await engine.simulate(
            hand: Hand(holeCards: cards("Ad Ad"), communityCards: []),
            opponents: 1, deadCards: [], iterations: 5_000,
            opponentRange: .random, confidenceThreshold: 0.01, maxTimeSeconds: 10)

        #expect(equity == 0, "an impossible deal was simulated to \(equity)")
    }

    /// Legitimate spots must still be answered — the guard is a filter, not a wall.
    @Test("A legal hand is still answered by both engines")
    func legalHandsStillAnswered() async {
        let hand = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s"))
        #expect(ExactEnumerator().calculateRiver(hand: hand, opponents: 1, deadCards: []) != nil)

        let equity = await MonteCarloEngine().simulate(
            hand: hand, opponents: 1, deadCards: [], iterations: 5_000,
            opponentRange: .random, confidenceThreshold: 0.01, maxTimeSeconds: 10)
        #expect(equity > 0.5)
    }
}
