import Foundation
import Combine

class GameState: ObservableObject {
    @Published var holeCards: [Card?] = [nil, nil]
    @Published var communityCards: [Card?] = [nil, nil, nil, nil, nil]
    @Published var deadCards: Set<Card> = []
    @Published var stack: Double = 20 {
        didSet {
            // There is no separate control for villain's stack yet, so keep it in step
            // with hero's. Without this the default 20 pinned the effective stack and
            // silently disabled every raise once the user edited their own stack.
            if villainStack == oldValue { villainStack = stack }
        }
    }

    /// The largest stack hero can actually be called by. Commitment decisions turn on
    /// the effective stack, not hero's own — and fold equity does not exist against a
    /// player who is already all in.
    @Published var villainStack: Double = 20

    @Published var position: String = "BTN"  // Track position for solver
    @Published var opponentStyle: OpponentStyle = .unknown

    /// How many players are still contesting this pot, hero included.
    /// Distinct from the table size in Settings: by the river most seats have folded,
    /// and pricing a heads-up decision against eight live opponents is badly wrong.
    @Published var playersInHand: Int = 6

    /// Opponents hero is actually up against right now.
    var opponentCount: Int { max(1, playersInHand - 1) }

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
    
    /// Hero's stack measured in big blinds (a display figure).
    var effectiveStack: Double {
        stack / bigBlind
    }

    /// The stack that actually governs commitment: neither player can win or lose more
    /// than the smaller of the two.
    var effectiveStackChips: Double { min(stack, villainStack) }
    
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
    
    /// Start a fresh hand. The pot goes back to the posted blinds: carrying the last
    /// hand's pot forward leaves a huge pot beside a one-blind call, which prices
    /// almost any two cards as a profitable call.
    func reset(smallBlind: Double = 0.5, bigBlind: Double = 1.0, playersInHand: Int = 6) {
        holeCards = [nil, nil]
        communityCards = [nil, nil, nil, nil, nil]
        deadCards = []
        position = "BTN"
        opponentStyle = .unknown
        self.bigBlind = bigBlind
        self.villainStack = stack
        self.playersInHand = max(2, playersInHand)
        potSize = smallBlind + bigBlind
        toCall = bigBlind          // the button owes the big blind to enter
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
    let villainStack: Double
    let position: String
    let potSize: Double
    let toCall: Double
    let bigBlind: Double
    let opponentStyle: OpponentStyle
    let playersInHand: Int

    /// Opponents hero is actually up against right now.
    var opponentCount: Int { max(1, playersInHand - 1) }

    /// Neither player can win or lose more than the smaller stack.
    var effectiveStackChips: Double { min(stack, villainStack) }

    init(from gameState: GameState) {
        self.holeCards = gameState.holeCards
        self.communityCards = gameState.communityCards
        self.deadCards = gameState.deadCards
        self.stack = gameState.stack
        self.villainStack = gameState.villainStack
        self.position = gameState.position
        self.potSize = gameState.potSize
        self.toCall = gameState.toCall
        self.bigBlind = gameState.bigBlind
        self.opponentStyle = gameState.opponentStyle
        self.playersInHand = gameState.playersInHand
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
