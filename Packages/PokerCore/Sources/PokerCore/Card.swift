import Foundation

public enum Suit: String, CaseIterable, Codable, Sendable {
    case spades = "♠"
    case hearts = "♥"
    case diamonds = "♦"
    case clubs = "♣"

    public var symbol: String { rawValue }
    public var color: String {
        switch self {
        case .hearts, .diamonds: return "red"
        case .spades, .clubs: return "black"
        }
    }

    /// Reliable suit index for card encoding (0–3).
    ///
    /// This used to live in `Utils/Extensions.swift` beside the SwiftUI colour
    /// helpers, which meant every engine that encoded a card pulled in SwiftUI. It
    /// belongs with the card.
    public var suitIndex: Int {
        switch self {
        case .spades: return 0
        case .hearts: return 1
        case .diamonds: return 2
        case .clubs: return 3
        }
    }
}

public enum Rank: Int, CaseIterable, Codable, Sendable {
    case two = 2, three, four, five, six, seven, eight, nine, ten
    case jack = 11, queen = 12, king = 13, ace = 14

    public var symbol: String {
        switch self {
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .ten: return "10"
        case .jack: return "J"
        case .queen: return "Q"
        case .king: return "K"
        case .ace: return "A"
        }
    }

    /// Single-character key used by the starting-hand ranking tables.
    /// `symbol` renders the ten as "10" for the UI, which does not match the "T"
    /// the tables are keyed on — keep the two uses separate.
    public var tableSymbol: String {
        self == .ten ? "T" : symbol
    }
}

public struct Card: Identifiable, Hashable, Codable, Sendable {
    /// Distinguishes two *views* of a card, never two cards. See the equality note below.
    public var id = UUID()
    public let rank: Rank
    public let suit: Suit

    public init(id: UUID = UUID(), rank: Rank, suit: Suit) {
        self.id = id
        self.rank = rank
        self.suit = suit
    }

    // MARK: - Equality
    //
    // A card is its rank and suit. The synthesised conformance also compared `id`, a
    // fresh UUID per instance, so no independently built card ever equalled another —
    // including the same card built twice, and `Set<Card>` was a set of instances rather
    // than of cards.
    //
    // Every engine here already worked around that by hand-rolling a 0–51 index
    // (`ExactEnumerator.cardIndex`, `MonteCarloEngine.usedIndices`), which is why no
    // equity was ever wrong because of it. What the workaround could not cover is code
    // that reasonably expects value semantics: `Hand.hasDuplicateCards` is
    // `Set(allCards).count != allCards.count`, and `EquityCalculator`'s dead-card check
    // is `deadCards.isDisjoint(with: hand.allCards)`. Neither is expressible while a
    // card is unequal to itself.

    public static func == (lhs: Card, rhs: Card) -> Bool {
        lhs.rank == rhs.rank && lhs.suit == rhs.suit
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rank)
        hasher.combine(suit)
    }

    public var displayString: String {
        "\(rank.symbol)\(suit.symbol)"
    }

    // Bit representation for fast hand evaluation
    public var bitValue: UInt64 {
        let rankBit = UInt64(1) << (rank.rawValue - 2)
        let suitOffset = suit == .spades ? 0 : suit == .hearts ? 13 : suit == .diamonds ? 26 : 39
        return rankBit << suitOffset
    }

    public static func deck() -> [Card] {
        var cards: [Card] = []
        for suit in Suit.allCases {
            for rank in Rank.allCases {
                cards.append(Card(rank: rank, suit: suit))
            }
        }
        return cards
    }
}
