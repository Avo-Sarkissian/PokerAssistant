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
    public let position: String
    public let potSize: Double
    public let toCall: Double
    public let bigBlind: Double
    public let opponentStyle: OpponentStyle
    public let playersInHand: Int

    public init(holeCards: [Card?],
                communityCards: [Card?],
                deadCards: Set<Card>,
                stack: Double,
                villainStack: Double,
                position: String,
                potSize: Double,
                toCall: Double,
                bigBlind: Double,
                opponentStyle: OpponentStyle,
                playersInHand: Int) {
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
        self.playersInHand = playersInHand
    }

    /// Opponents hero is actually up against right now.
    public var opponentCount: Int { max(1, playersInHand - 1) }

    /// Neither player can win or lose more than the smaller stack.
    public var effectiveStackChips: Double { min(stack, villainStack) }

    /// What hero has already put in from a posted blind, before acting.
    public func blindPosted(smallBlind: Double) -> Double {
        switch position {
        case "SB": return smallBlind
        case "BB": return bigBlind
        default:   return 0
        }
    }

    /// Villain's total contribution to this street, in big blinds — the unit both the
    /// preflop range read and preflop raise sizing are expressed in. One definition,
    /// because the solver and the view model both need it and a second copy is how the
    /// two would drift.
    ///
    /// **Known to under-count when hero was the previous aggressor.** The identity is
    /// `villainTotal = heroTotalSoFar + toCall`, and `blindPosted` is only equal to
    /// `heroTotalSoFar` while hero has put in nothing beyond a blind. Once hero has
    /// opened, villain's wager is understated by exactly hero's prior voluntary raise:
    /// hero opens to 2.5bb, villain 3-bets to 9bb, and this returns 6.5bb. A 7.5bb 3-bet
    /// reports 5.0bb and reads `.standard` — an opening range — rather than `.tight`.
    ///
    /// Fixing it needs a field this type does not have: hero's committed-this-street
    /// amount. `PotEntry.preflop` already computes it as `heroPriorWager` and throws it
    /// away when the pot is flattened into `potSize`/`toCall`, so the fix is to carry it
    /// through rather than to derive it here — there is no way to recover it from a pot
    /// total. Until then this is exact for the common case (hero facing an open with
    /// nothing in) and one tier too loose for re-raises, which is still a long way better
    /// than the pot-relative read it replaced, where *every* preflop spot including an
    /// unopened button read as a 3-bet range.
    public func villainWagerInBigBlinds(smallBlind: Double) -> Double {
        guard bigBlind > 0 else { return 0 }
        return (blindPosted(smallBlind: smallBlind) + toCall) / bigBlind
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
