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

// MARK: - The preflop cache and the routing behind it

/// Saves and restores every preflop-cache key, so these tests can force a miss without
/// leaving the shipping app's cache emptied. The app test host shares one `UserDefaults`
/// with the app itself — see `DefaultsSnapshot` in `GameStateTests` for the same problem
/// with blind levels.
struct PreflopCacheSnapshot {
    private let saved: [(String, Any?)]

    init() {
        let keys = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("PreflopEq_") }
        saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func restore() {
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) }
        }
    }
}

/// `PreflopEquityTable` used to compute its own misses and return the result, so the
/// fall-through beneath it in `EquityCalculator` was unreachable and the Calculation Depth
/// setting never applied to a preflop spot. The table is now a cache and the calculator
/// fills it.
@Suite("Preflop routing", .serialized, .timeLimit(.minutes(5)))
struct PreflopRoutingTests {

    /// If the calculator did not write the number it computed, nothing would: the table no
    /// longer populates itself, so a missing `store` means every preflop request is a full
    /// simulation forever.
    @Test("A preflop calculation caches the number it returned")
    func preflopCalculationPopulatesTheCache() async {
        let snapshot = PreflopCacheSnapshot()
        defer { snapshot.restore() }

        let hand = Hand(holeCards: cards("9d 3c"), communityCards: [])
        let calculator = EquityCalculator()
        let equity = await calculator.calculateDeep(
            hand: hand, opponents: 3, deadCards: [],
            iterations: 200_000, confidenceThreshold: 0.005, opponentRange: .veryWide)

        #expect(equity > 0.01, Comment(rawValue: "93o against three opponents priced at \(equity)"))

        let cached = PreflopEquityTable.shared.cachedEquity(
            hand: hand, opponents: 3, range: .veryWide)
        #expect(cached == equity,
                Comment(rawValue: "the calculator returned \(equity) and the cache holds "
                        + "\(String(describing: cached))"))
    }

    /// A cached preflop equity is permanent and its key is (hand, opponents, range) —
    /// dead cards are not in it. So an equity computed with cards struck out of the deck
    /// must never be filed under that key, and the cache must not answer a question it was
    /// not asked. Dead Cards is a toolbar button available preflop, so this is one tap
    /// away: mark the other two aces dead once holding A-K, and without this every A-K
    /// calculation afterwards — this session and every future one — returns the inflated
    /// number.
    @Test("A calculation with dead cards neither reads nor writes the preflop cache")
    func deadCardsStayOutOfTheCache() async {
        let snapshot = PreflopCacheSnapshot()
        defer { snapshot.restore() }

        let hand = Hand(holeCards: cards("Ad Kc"), communityCards: [])
        let dead: Set<Card> = [card("As"), card("Ah"), card("Ks"), card("Kh")]
        let calculator = EquityCalculator()

        let withDeadCards = await calculator.calculateDeep(
            hand: hand, opponents: 1, deadCards: dead,
            iterations: 200_000, confidenceThreshold: 0.005, opponentRange: .random)
        #expect(withDeadCards > 0.01)

        #expect(PreflopEquityTable.shared.cachedEquity(hand: hand, opponents: 1, range: .random) == nil,
                Comment(rawValue: "an equity computed with four cards removed from the "
                        + "deck was filed under a key that says nothing about them"))

        // …and in the other direction: once a clean value is cached, a dead-card request
        // must not be answered with it. Removing both remaining aces and kings from
        // villain's possible holdings moves the number well beyond sampling noise, so an
        // exact match means the cache was consulted.
        let clean = await calculator.calculateDeep(
            hand: hand, opponents: 1, deadCards: [],
            iterations: 200_000, confidenceThreshold: 0.005, opponentRange: .random)
        let againWithDeadCards = await calculator.calculateDeep(
            hand: hand, opponents: 1, deadCards: dead,
            iterations: 200_000, confidenceThreshold: 0.005, opponentRange: .random)

        #expect(againWithDeadCards != clean,
                Comment(rawValue: "the cached clean equity \(clean) was returned for a "
                        + "dead-card question"))
    }

    /// The routing fix this test exists for: the GPU kernel has no range filter, so a
    /// range-conditioned request must not reach it. That condition used to also require a
    /// single opponent, which was invisible only because the table absorbed every multiway
    /// preflop request before the routing ran. With the fall-through live it would have
    /// sent this spot to a kernel that ignores the range and answered a different
    /// question — the same answer for both ranges below.
    ///
    /// KJo rather than a premium hand, for the reason `tighterRangeLowersEquity` gives:
    /// aces are the one holding a tight range helps.
    @Test("A ranged multiway preflop spot is not answered by the GPU")
    func preflopMultiwayHonoursTheRange() async {
        let snapshot = PreflopCacheSnapshot()
        defer { snapshot.restore() }

        let hand = Hand(holeCards: cards("Kd Jc"), communityCards: [])
        let calculator = EquityCalculator()

        func equity(range: OpponentRange.RangeType) async -> Double {
            await calculator.calculateDeep(
                hand: hand, opponents: 2, deadCards: [],
                iterations: 200_000, confidenceThreshold: 0.005, opponentRange: range)
        }

        let againstAnything = await equity(range: .random)
        let againstPremiums = await equity(range: .veryTight)

        #expect(againstPremiums < againstAnything - 0.05,
                Comment(rawValue: "KJo reads \(againstPremiums) against two premium ranges "
                        + "and \(againstAnything) against two random hands — the range was "
                        + "discarded"))
    }
}
