import Foundation
import Combine

class GameState: ObservableObject {
    @Published var holeCards: [Card?] = [nil, nil]
    @Published var communityCards: [Card?] = [nil, nil, nil, nil, nil]
    @Published var deadCards: Set<Card> = []
    @Published var stack: Double = 20
    @Published var position: String = "BTN"  // Track position for solver

    @Published var potSize: Double = 0 {
        willSet {
            objectWillChange.send()
        }
    }
    
    @Published var toCall: Double = 0 {
        willSet {
            objectWillChange.send()
        }
    }
    
    @Published var bigBlind: Double = 1.0
    
    var effectiveStack: Double {
        stack / bigBlind
    }
    
    var usedCards: Set<Card> {
        var used = deadCards
        holeCards.compactMap { $0 }.forEach { used.insert($0) }
        communityCards.compactMap { $0 }.forEach { used.insert($0) }
        return used
    }
    
    var availableCards: [Card] {
        Card.deck().filter { !usedCards.contains($0) }
    }
    
    // NEW: Computed property for current street
    var currentStreet: Street {
        let communityCount = communityCards.compactMap { $0 }.count
        switch communityCount {
        case 0: return .preflop
        case 3: return .flop
        case 4: return .turn
        case 5: return .river
        default: return .preflop
        }
    }
    
    // Check if we're in position (acting last)
    var isInPosition: Bool {
        position == "BTN" || position == "CO"
    }
    
    func reset() {
        holeCards = [nil, nil]
        communityCards = [nil, nil, nil, nil, nil]
        deadCards = []
        position = "BTN"
        // Don't reset pot size and toCall - keep them for next hand
    }
    
    // Add methods to update pot values
    func updatePotSize(_ newValue: Double) {
        potSize = newValue
    }
    
    func updateToCall(_ newValue: Double) {
        toCall = newValue
    }
}

/// Thread-safe copy of GameState for background calculations
/// This struct can be safely passed to detached tasks
struct GameStateCopy: Sendable {
    let holeCards: [Card?]
    let communityCards: [Card?]
    let deadCards: Set<Card>
    let stack: Double
    let position: String
    let potSize: Double
    let toCall: Double
    let bigBlind: Double

    init(from gameState: GameState) {
        self.holeCards = gameState.holeCards
        self.communityCards = gameState.communityCards
        self.deadCards = gameState.deadCards
        self.stack = gameState.stack
        self.position = gameState.position
        self.potSize = gameState.potSize
        self.toCall = gameState.toCall
        self.bigBlind = gameState.bigBlind
    }

    var currentStreet: Street {
        let communityCount = communityCards.compactMap { $0 }.count
        switch communityCount {
        case 0: return .preflop
        case 3: return .flop
        case 4: return .turn
        case 5: return .river
        default: return .preflop
        }
    }
}
