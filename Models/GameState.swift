import Foundation
import Combine
import PokerCore

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

    /// Hero's seat. A `Position` rather than a string: as a string, the solver's parser
    /// mapped anything it did not recognise to the button, so the six seats a nine-handed
    /// table has beyond BTN/SB/BB were all priced as buttons.
    @Published var position: Position = .btn {
        didSet { if position != oldValue { actsLastOverride = nil } }
    }

    @Published var opponentStyle: OpponentStyle = .unknown

    /// How many players are still contesting this pot, hero included.
    /// Distinct from the table size in Settings: by the river most seats have folded,
    /// and pricing a heads-up decision against eight live opponents is badly wrong.
    @Published var playersInHand: Int = 6

    /// Seats dealt in, mirrored from `Settings.numberOfPlayers` the same way `bigBlind` is.
    ///
    /// It decides which seats exist and how far hero's seat is from the button, so it has
    /// to travel with the spot: `playersInHand` cannot stand in for it, because folding
    /// down to heads-up does not move hero's chair.
    ///
    /// The seat is corrected here rather than at the call sites. Correcting it by hand left
    /// one call site as the only thing standing between a UTG+2 selection and a
    /// three-handed table, and a test that invoked the corrector itself could not have
    /// noticed that call going missing.
    @Published var tableSize: Int = 6 {
        didSet {
            guard tableSize != oldValue else { return }
            clampSeatToTable()
            actsLastOverride = nil
        }
    }

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

    /// What hero has already put into this street — a posted blind, plus any raise hero
    /// has already made. `potSize` is the flattened total and cannot be decomposed, so
    /// this is tracked alongside it: without it villain's raise is understated by hero's
    /// own, which reads a 3-bet as an opening range and under-sizes every 4-bet.
    @Published var heroWagerThisStreet: Double = 0
    
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
    
    /// Whether a card is already in hero's hand, on the board, or marked dead.
    ///
    /// This is the card picker's only defence against the same card being entered twice,
    /// so it lives here where it can be tested rather than inline in a view. `usedCards`
    /// is a `Set<Card>`, which is only a correct answer because `Card` compares by rank
    /// and suit — under the old per-instance-UUID equality this lookup would always miss.
    func isUsed(_ card: Card) -> Bool {
        usedCards.contains(card)
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
    
    /// Hero's answer to "do you act last after the flop", when hero has given one.
    ///
    /// `nil` means "use what the seat implies", which is the default and the old
    /// behaviour. It exists because the seat cannot settle the question: a cutoff whose
    /// button folded acts last, and the app knows how many players are live but never
    /// which chairs they hold. Deriving it and stopping priced the most common flop in
    /// six-max — hero opens the cutoff, the big blind calls — out of position.
    ///
    /// Cleared whenever the seat or the table changes, because the default it was
    /// overriding has changed with them.
    @Published var actsLastOverride: Bool?

    /// Whether hero acts last after the flop: hero's answer if given, the seat's
    /// otherwise.
    ///
    /// This used to read `position == "BTN" || position == "CO"`, naming a seat the
    /// picker could not select — so the "In Position" badge was documentation for a
    /// feature that did not exist — and it was wrong heads-up, where the small blind
    /// holds the button and acts last.
    var isInPosition: Bool {
        actsLastOverride ?? position.isInPosition(tableSize: tableSize)
    }

    /// What the seat alone implies, which is what the control is seeded with.
    var seatImpliesActsLast: Bool { position.isInPosition(tableSize: tableSize) }

    /// Start a fresh hand. The pot goes back to the posted blinds: carrying the last
    /// hand's pot forward leaves a huge pot beside a one-blind call, which prices
    /// almost any two cards as a profitable call.
    func reset(smallBlind: Double = 0.5, bigBlind: Double = 1.0, playersInHand: Int = 6) {
        holeCards = [nil, nil]
        communityCards = [nil, nil, nil, nil, nil]
        deadCards = []
        opponentStyle = .unknown
        actsLastOverride = nil
        self.bigBlind = bigBlind
        self.villainStack = stack
        // A fresh hand is dealt to every seat, so the two are the same number here and
        // diverge only as players fold.
        self.playersInHand = min(9, max(2, playersInHand))
        self.tableSize = self.playersInHand
        // The button is the default seat, but it is not dealt at a two-handed table.
        position = Position.btn.exists(tableSize: tableSize) ? .btn : .sb

        // The pot has to follow the seat that was just chosen, not assume one. Writing
        // `toCall = bigBlind` unconditionally contradicted the line above it heads-up,
        // where the seat is the small blind: a fresh hand then showed a $1.00 bet into
        // $0.50 and asked for 40% equity to complete for half a blind, against the true
        // $0.50 into $1.00 and 25%.
        let entry = PotEntry.blindsOnly(heroPosition: position,
                                        smallBlind: smallBlind,
                                        bigBlind: bigBlind)
        potSize = entry.totalPot
        toCall = entry.toCall
        heroWagerThisStreet = position == .sb ? smallBlind
            : (position == .bb ? bigBlind : 0)
    }

    /// Bring the seat back inside the table after the table size changes.
    ///
    /// Selecting UTG at a nine-handed table and then switching to three-handed leaves
    /// hero in a chair that no longer exists. Falling back to the button is the one
    /// substitution that is always available above heads-up, and it is explicit here
    /// rather than being a `default:` case hidden inside the solver.
    func clampSeatToTable() {
        guard !position.exists(tableSize: tableSize) else { return }
        position = Position.btn.exists(tableSize: tableSize) ? .btn : .sb
    }
    
    // Add methods to update pot values
    func updatePotSize(_ newValue: Double) {
        potSize = newValue
    }
    
    func updateToCall(_ newValue: Double) {
        toCall = newValue
    }
}

/// `GameStateCopy` itself lives in PokerCore — it is the solver's only input, so the
/// solver could not be tested without it. Only the bridge from the observable app
/// object stays here.
extension GameStateCopy {
    init(from gameState: GameState) {
        self.init(
            holeCards: gameState.holeCards,
            communityCards: gameState.communityCards,
            deadCards: gameState.deadCards,
            stack: gameState.stack,
            villainStack: gameState.villainStack,
            position: gameState.position,
            potSize: gameState.potSize,
            toCall: gameState.toCall,
            bigBlind: gameState.bigBlind,
            opponentStyle: gameState.opponentStyle,
            playersInHand: gameState.playersInHand,
            tableSize: gameState.tableSize,
            heroActsLast: gameState.isInPosition,
            heroWagerThisStreet: gameState.heroWagerThisStreet
        )
    }
}
