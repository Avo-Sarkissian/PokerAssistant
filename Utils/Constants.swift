import Foundation

struct Constants {
    static let maxPlayers = 9
    static let cardsPerPlayer = 2
    static let communityCardsCount = 5
    static let deckSize = 52
    
    struct Animations {
        static let cardFlip = 0.3
        static let progressUpdate = 0.2
    }
    
    struct Defaults {
        static let buyIn = 20.0      // Changed from 500.0
        static let smallBlind = 0.5  // Changed from 5.0
        static let bigBlind = 1.0    // Changed from 10.0
    }
}
