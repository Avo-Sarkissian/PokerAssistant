import Foundation

public struct Hand: Sendable {
    public let holeCards: [Card]
    public let communityCards: [Card]

    public init(holeCards: [Card], communityCards: [Card]) {
        self.holeCards = holeCards
        self.communityCards = communityCards
    }

    public var allCards: [Card] {
        holeCards + communityCards
    }

    public var isValid: Bool {
        holeCards.count == 2 && communityCards.count <= 5
    }

    public var street: Street {
        switch communityCards.count {
        case 0: return .preflop
        case 3: return .flop
        case 4: return .turn
        case 5: return .river
        default: return .preflop
        }
    }
}

public enum Street: String, CaseIterable, Sendable {
    case preflop = "Pre-flop"
    case flop = "Flop"
    case turn = "Turn"
    case river = "River"
}
