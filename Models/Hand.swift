import Foundation

struct Hand {
    let holeCards: [Card]
    let communityCards: [Card]
    
    var allCards: [Card] {
        holeCards + communityCards
    }
    
    var isValid: Bool {
        holeCards.count == 2 && communityCards.count <= 5
    }
    
    var street: Street {
        switch communityCards.count {
        case 0: return .preflop
        case 3: return .flop
        case 4: return .turn
        case 5: return .river
        default: return .preflop
        }
    }
}

enum Street: String, CaseIterable {
    case preflop = "Pre-flop"
    case flop = "Flop"
    case turn = "Turn"
    case river = "River"
}
