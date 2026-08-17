import Testing
import Foundation
import PokerCore
import PokerTestSupport

/// A card is the ace of spades or it is not. It carries a `UUID` so SwiftUI can tell two
/// views apart, but that identifier had been allowed to decide equality, which made every
/// `Card` unequal to every other `Card` including itself-by-value. Every engine in this
/// repo works around it by hand-rolling a 0–51 integer index; the app does not, and its
/// "cards already on the table" filter has never removed anything.
@Suite("Card identity")
struct CardIdentityTests {

    @Test("Two aces of spades are the same card")
    func equalRankAndSuitMeansEqualCard() {
        #expect(card("As") == card("As"))
        #expect(card("As") != card("Ah"), "different suit")
        #expect(card("As") != card("Ks"), "different rank")
    }

    @Test("Equal cards collapse in a Set")
    func equalCardsCollapseInASet() {
        #expect(Set([card("As"), card("As")]).count == 1)
        #expect(Set([card("As"), card("Ah")]).count == 2)
    }

    /// The exact shape of the app's bug: a set of used cards filtered against a fresh
    /// deck. Every engine avoids this by comparing 0–51 indices instead.
    @Test("A used card is removed from a freshly built deck")
    func usedCardsFilterOutOfTheDeck() {
        let used: Set<Card> = [card("As"), card("Kh"), card("2c")]
        let remaining = Card.deck().filter { !used.contains($0) }

        #expect(remaining.count == 49,
                "\(52 - remaining.count) of 3 used cards were removed")
        #expect(!remaining.contains(card("As")))
    }

    /// A full deck is 52 distinct cards, and a deck built twice is the same 52.
    @Test("Two decks are the same 52 cards")
    func decksAreInterchangeable() {
        #expect(Set(Card.deck()).count == 52)
        #expect(Set(Card.deck()) == Set(Card.deck()))
    }

    /// Equality must not depend on the identifier, but `Identifiable` still needs one:
    /// two equal cards are allowed to carry different ids, and both must still hash
    /// alike or a Set lookup misses.
    @Test("Distinct identifiers do not split a card in two")
    func identifierDoesNotAffectHashing() {
        let one = Card(rank: .ace, suit: .spades)
        let other = Card(rank: .ace, suit: .spades)

        #expect(one.id != other.id, "ids are per-instance; if this fails the test is stale")
        #expect(one == other)
        #expect(one.hashValue == other.hashValue)
    }

    /// Round-tripping must not change what the card is.
    @Test("A decoded card equals the card it was encoded from")
    func codableRoundTripPreservesEquality() throws {
        let original = card("Td")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Card.self, from: data)

        #expect(decoded == original)
    }
}
