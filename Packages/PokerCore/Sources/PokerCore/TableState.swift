import Foundation

// MARK: - Game Mode

public enum GameMode: String, CaseIterable, Sendable {
    case cashGame   = "Cash Game"
    case tournament = "Tournament"
}

// MARK: - Tournament Phase

public enum TournamentPhase: String, CaseIterable, Sendable {
    case earlyStage  = "Early"
    case midStage    = "Mid"
    case bubble      = "Bubble"
    case inMoney     = "In the Money"
    case finalTable  = "Final Table"

    /// ICM pressure factor: 0.0 = no pressure (cash game feel), 0.5 = maximum pressure.
    /// Multiplied against fold thresholds in the solver to widen folding ranges.
    public var icmPressure: Double {
        switch self {
        case .earlyStage: return 0.0
        case .midStage:   return 0.10
        case .bubble:     return 0.40
        case .inMoney:    return 0.25
        case .finalTable: return 0.30
        }
    }

    public var subtitle: String {
        switch self {
        case .earlyStage:  return "Deep stacks, play for chips"
        case .midStage:    return "Stack pressure building"
        case .bubble:      return "Every fold = money — maximise survival"
        case .inMoney:     return "Relaxed slightly, play for stack depth"
        case .finalTable:  return "Pay-jump pressure, play tight"
        }
    }
}

// MARK: - Opponent Style

public enum OpponentStyle: String, CaseIterable, Codable, Sendable {
    case unknown  = "Unknown"
    case tight    = "Tight"
    case standard = "Standard"
    case loose    = "Loose"
    case aggressive = "Aggressive"
    case passive  = "Passive"

    public var rangeType: OpponentRange.RangeType {
        switch self {
        case .unknown:    return .standard
        case .tight:      return .tight
        case .standard:   return .standard
        case .loose:      return .wide
        case .aggressive: return .wide
        case .passive:    return .standard
        }
    }

    public var symbol: String {
        switch self {
        case .unknown:    return "questionmark"
        case .tight:      return "shield"
        case .standard:   return "person"
        case .loose:      return "flame"
        case .aggressive: return "bolt"
        case .passive:    return "hand.raised"
        }
    }
}

// MARK: - Solver settings

/// Everything the solver needs from the app's `Settings`, as a plain value.
///
/// The solver used to take `Settings` itself — an `ObservableObject` whose every
/// property is `@AppStorage`. That put UserDefaults, SwiftUI and the shipping app's
/// stored preferences inside a pure EV calculation: constructing one in a test wrote
/// blind levels into the real app, and the solver could not be compiled without a UI
/// framework. It never wanted any of that; it wanted three numbers.
public struct SolverSettings: Equatable, Sendable {

    /// Raise sizes are rounded to this, so it must be the live small blind.
    public var smallBlind: Double

    /// The floor on a legal raise, and the denominator for SPR in an empty pot.
    public var bigBlind: Double

    /// Tournament survival premium: chips risked are worth more than chips won.
    /// A risk slider, not a true ICM model — a real one needs the payout ladder and
    /// every stack at the table. Zero in a cash game.
    public var icmPressure: Double

    public init(smallBlind: Double, bigBlind: Double, icmPressure: Double = 0) {
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        self.icmPressure = icmPressure
    }
}

// MARK: - Table state

/// Thread-safe copy of the table for background calculations.
/// This struct can be safely passed to detached tasks.
public struct GameStateCopy: Sendable {
    public let holeCards: [Card?]
    public let communityCards: [Card?]
    public let deadCards: Set<Card>
    public let stack: Double
    public let villainStack: Double
    public let position: Position
    public let potSize: Double
    public let toCall: Double
    public let bigBlind: Double
    public let opponentStyle: OpponentStyle

    /// Players still contesting the pot, hero included. Never more than `tableSize`, and
    /// never fewer than two: a pot with one player in it is not a decision.
    public let playersInHand: Int

    /// Seats dealt in, which decides **which seats exist** and how far hero's seat is
    /// from the button. Distinct from `playersInHand`: six can be dealt in while two see
    /// the river, and hero's chair does not move when someone folds.
    ///
    /// Clamped to the sizes the app offers, and nothing else. More players contesting a
    /// pot than are seated at the table is not a spot, and the fix is to seat fewer
    /// players — see `playersInHand`. Raising the table size instead is what an earlier
    /// version did, and it answered a different question than the caller asked: a
    /// heads-up small blind, the seat that *holds the button*, became a six-handed small
    /// blind, flipping `isInPosition` and swinging the fold-frequency term by 2.17× without a
    /// word.
    public let tableSize: Int

    /// Whether hero acts last after the flop — a **fact hero supplies**, not one the app
    /// derives.
    ///
    /// The seat cannot settle it. A cutoff whose button folded acts last, and the app
    /// tracks how many players are live, never which chairs they hold. Deriving it from
    /// the seat alone meant the most common flop in six-max — hero opens the cutoff, the
    /// big blind calls — was priced out of position and sized $18.00 into a 40 pot where
    /// $14.50 is right. Worse, that was a regression: with only BTN/SB/BB selectable, such
    /// a user picked BTN and got the correct answer, so making their real seat available
    /// made their answer worse.
    ///
    /// `Position.isInPosition(tableSize:)` still supplies the default, so a caller that
    /// does not know any better gets the old behaviour; it is the app's job to let hero
    /// say otherwise.
    public let heroActsLast: Bool

    /// Hero's total contribution to the current street so far: a posted blind, plus any
    /// raise hero has already made this street.
    ///
    /// Cannot be recovered from `potSize`, which is the flattened total — that is why it
    /// is carried. Defaults to 0, and `heroCommitted` floors it at the posted blind, so a
    /// caller that does not track it still gets the blind rather than nothing.
    public let heroWagerThisStreet: Double

    public init(holeCards: [Card?],
                communityCards: [Card?],
                deadCards: Set<Card>,
                stack: Double,
                villainStack: Double,
                position: Position,
                potSize: Double,
                toCall: Double,
                bigBlind: Double,
                opponentStyle: OpponentStyle,
                playersInHand: Int,
                tableSize: Int,
                heroActsLast: Bool,
                heroWagerThisStreet: Double = 0) {
        self.holeCards = holeCards
        self.communityCards = communityCards
        self.deadCards = deadCards
        self.stack = stack
        self.villainStack = villainStack
        self.position = position
        self.potSize = potSize
        self.toCall = toCall
        self.bigBlind = bigBlind
        self.opponentStyle = opponentStyle
        // Seats first, then players into the seats. The other order lets a bad player
        // count invent seats and move hero's chair.
        let seated = min(Position.supportedTableSizes.upperBound,
                         max(Position.supportedTableSizes.lowerBound, tableSize))
        self.tableSize = seated
        self.playersInHand = min(seated, max(2, playersInHand))
        self.heroActsLast = heroActsLast
        self.heroWagerThisStreet = heroWagerThisStreet
    }

    /// Whether hero acts last after the flop. Carried, not derived — see `heroActsLast`.
    public var isInPosition: Bool { heroActsLast }

    /// Opponents hero is actually up against right now.
    public var opponentCount: Int { max(1, playersInHand - 1) }

    /// Whether hero is dealt at all at this table size. False only for a
    /// `(seat, tableSize)` pair the picker cannot produce — a cutoff at a three-handed
    /// table — which every positional read then treats as out of position rather than
    /// quietly relocating hero.
    public var seatIsDealt: Bool { position.exists(tableSize: tableSize) }

    /// Neither player can win or lose more than the smaller stack.
    public var effectiveStackChips: Double { min(stack, villainStack) }

    /// What hero has already put in from a posted blind, before acting.
    public func blindPosted(smallBlind: Double) -> Double {
        switch position {
        case .sb: return smallBlind
        case .bb: return bigBlind
        default:  return 0
        }
    }

    /// Everything hero has put in this street, never less than the blind they posted.
    ///
    /// The floor matters: a caller that has not wired `heroWagerThisStreet` through still
    /// gets the blind, which is the correct answer for every spot where hero has not
    /// raised — and that is most of them.
    public func heroCommitted(smallBlind: Double) -> Double {
        max(heroWagerThisStreet, blindPosted(smallBlind: smallBlind))
    }

    /// Villain's total contribution to this street, in big blinds — the unit both the
    /// preflop range read and preflop raise sizing are expressed in. One definition,
    /// because the solver and the view model both need it and a second copy is how the
    /// two would drift.
    ///
    /// The identity is `villainTotal = heroTotalSoFar + toCall`. Reconstructing
    /// `heroTotalSoFar` as hero's blind alone understated villain's raise by exactly
    /// hero's own prior raise: hero opens to 2.5bb, villain 3-bets to 9bb, and it
    /// returned 6.5bb — so a 7.5bb 3-bet read `.standard`, an *opening* range, and 4-bets
    /// were sized off the wrong number at 2.4x rather than 3x.
    public func villainWagerInBigBlinds(smallBlind: Double) -> Double {
        guard bigBlind > 0 else { return 0 }
        return (heroCommitted(smallBlind: smallBlind) + toCall) / bigBlind
    }

    public var currentStreet: Street {
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
