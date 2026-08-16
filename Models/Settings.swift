import Foundation
import SwiftUI
import PokerCore

// `GameMode`, `TournamentPhase` and `OpponentStyle` live in PokerCore: the solver
// reads all three, and it can only be tested away from the app if they come with it.

class Settings: ObservableObject {
    @AppStorage("buyIn") var buyIn: Double = 20
    @AppStorage("smallBlind") var smallBlind: Double = 0.5
    @AppStorage("bigBlind") var bigBlind: Double = 1.0
    @AppStorage("numberOfPlayers") var numberOfPlayers: Int = 6
    @AppStorage("trackOpponents") var trackOpponents: Bool = false
    /// The app used to force dark mode app-wide, overriding the system setting with no
    /// way to opt out. Default stays dark; the user can now follow the system instead.
    @AppStorage("forceDarkMode") var forceDarkMode: Bool = true
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

    /// The three numbers the solver actually reads, as a plain value.
    ///
    /// Handing the solver `Settings` itself put @AppStorage inside an EV calculation:
    /// every solver test wrote blind levels into the shipping app's defaults, and the
    /// solver could not be compiled without SwiftUI.
    var solverSettings: SolverSettings {
        SolverSettings(
            smallBlind: smallBlind,
            bigBlind: bigBlind,
            icmPressure: gameMode == .tournament ? tournamentPhase.icmPressure : 0
        )
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
