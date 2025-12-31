import Foundation

enum Suit: String, CaseIterable, Codable {
    case spades = "♠"
    case hearts = "♥"
    case diamonds = "♦"
    case clubs = "♣"
    
    var symbol: String { rawValue }
    var color: String {
        switch self {
        case .hearts, .diamonds: return "red"
        case .spades, .clubs: return "black"
        }
    }
}

enum Rank: Int, CaseIterable, Codable {
    case two = 2, three, four, five, six, seven, eight, nine, ten
    case jack = 11, queen = 12, king = 13, ace = 14
    
    var symbol: String {
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
}

struct Card: Identifiable, Hashable, Codable {
    // FIXED: Changed 'let' to 'var' to satisfy Codable requirements
    var id = UUID()
    let rank: Rank
    let suit: Suit
    
    var displayString: String {
        "\(rank.symbol)\(suit.symbol)"
    }
    
    // Bit representation for fast hand evaluation
    var bitValue: UInt64 {
        let rankBit = UInt64(1) << (rank.rawValue - 2)
        let suitOffset = suit == .spades ? 0 : suit == .hearts ? 13 : suit == .diamonds ? 26 : 39
        return rankBit << suitOffset
    }
    
    static func deck() -> [Card] {
        var cards: [Card] = []
        for suit in Suit.allCases {
            for rank in Rank.allCases {
                cards.append(Card(rank: rank, suit: suit))
            }
        }
        return cards
    }
}
