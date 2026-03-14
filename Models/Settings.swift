import Foundation
import SwiftUI

// MARK: - Game Mode

enum GameMode: String, CaseIterable {
    case cashGame   = "Cash Game"
    case tournament = "Tournament"
}

// MARK: - Tournament Phase

enum TournamentPhase: String, CaseIterable {
    case earlyStage  = "Early"
    case midStage    = "Mid"
    case bubble      = "Bubble"
    case inMoney     = "In the Money"
    case finalTable  = "Final Table"

    /// ICM pressure factor: 0.0 = no pressure (cash game feel), 0.5 = maximum pressure.
    /// Multiplied against fold thresholds in the solver to widen folding ranges.
    var icmPressure: Double {
        switch self {
        case .earlyStage: return 0.0
        case .midStage:   return 0.10
        case .bubble:     return 0.40
        case .inMoney:    return 0.25
        case .finalTable: return 0.30
        }
    }

    var subtitle: String {
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

enum OpponentStyle: String, CaseIterable, Codable {
    case unknown  = "Unknown"
    case tight    = "Tight"
    case standard = "Standard"
    case loose    = "Loose"
    case aggressive = "Aggressive"
    case passive  = "Passive"

    var rangeType: OpponentRange.RangeType {
        switch self {
        case .unknown:    return .standard
        case .tight:      return .tight
        case .standard:   return .standard
        case .loose:      return .wide
        case .aggressive: return .wide
        case .passive:    return .standard
        }
    }

    var symbol: String {
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

class Settings: ObservableObject {
    @AppStorage("buyIn") var buyIn: Double = 20
    @AppStorage("smallBlind") var smallBlind: Double = 0.5
    @AppStorage("bigBlind") var bigBlind: Double = 1.0
    @AppStorage("numberOfPlayers") var numberOfPlayers: Int = 6
    @AppStorage("trackOpponents") var trackOpponents: Bool = false
    @AppStorage("showMathDetails") var showMathDetails: Bool = false
    @AppStorage("simpleExplanations") var simpleExplanations: Bool = true
    @AppStorage("progressiveResults") var progressiveResults: Bool = true

    @AppStorage("gameMode") private var gameModeRaw: String = GameMode.cashGame.rawValue
    var gameMode: GameMode {
        get { GameMode(rawValue: gameModeRaw) ?? .cashGame }
        set { gameModeRaw = newValue.rawValue }
    }

    @AppStorage("tournamentPhase") private var tournamentPhaseRaw: String = TournamentPhase.earlyStage.rawValue
    var tournamentPhase: TournamentPhase {
        get { TournamentPhase(rawValue: tournamentPhaseRaw) ?? .earlyStage }
        set { tournamentPhaseRaw = newValue.rawValue }
    }

    // AppStorage doesn't support custom enums directly, so use RawRepresentable
    @AppStorage("calculationDepth") private var calculationDepthRaw: String = CalculationDepth.accurate.rawValue

    var calculationDepth: CalculationDepth {
        get {
            CalculationDepth(rawValue: calculationDepthRaw) ?? .accurate
        }
        set {
            calculationDepthRaw = newValue.rawValue
        }
    }
    
    var numberOfOpponents: Int {
        max(1, numberOfPlayers - 1)
    }
    
    enum CalculationDepth: String, CaseIterable {
        case fast = "Fast"
        case accurate = "Accurate"
        case deep = "Deep"
        case maximum = "Maximum"

        // Max iterations before early termination kicks in
        var iterations: Int {
            switch self {
            case .fast: return 1_000_000       // 1M max
            case .accurate: return 10_000_000  // 10M max
            case .deep: return 50_000_000      // 50M max
            case .maximum: return 100_000_000  // 100M max
            }
        }

        // Confidence threshold for early termination (standard error %)
        var confidenceThreshold: Double {
            switch self {
            case .fast: return 0.010      // 1.0% SE - least precise, fastest
            case .accurate: return 0.005  // 0.5% SE - balanced
            case .deep: return 0.0025     // 0.25% SE - high precision
            case .maximum: return 0.001   // 0.1% SE - maximum precision
            }
        }

        var description: String {
            switch self {
            case .fast: return "Fast (1-3s, SE < 1%)"
            case .accurate: return "Accurate (3-6s, SE < 0.5%)"
            case .deep: return "Deep (5-8s, SE < 0.25%)"
            case .maximum: return "Maximum (8-10s, SE < 0.1%)"
            }
        }

        // Confidence level for UI
        var confidenceLevel: String {
            switch self {
            case .fast: return "SE < 1.0%"
            case .accurate: return "SE < 0.5%"
            case .deep: return "SE < 0.25%"
            case .maximum: return "SE < 0.1%"
            }
        }
    }
}
