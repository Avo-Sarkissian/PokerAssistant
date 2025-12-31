import Foundation

class Settings: ObservableObject {
    @Published var buyIn: Double = 20
    @Published var smallBlind: Double = 0.5
    @Published var bigBlind: Double = 1.0
    @Published var numberOfPlayers: Int = 6
    @Published var calculationDepth: CalculationDepth = .accurate
    @Published var trackOpponents: Bool = false
    @Published var showMathDetails: Bool = false
    @Published var simpleExplanations: Bool = true
    @Published var progressiveResults: Bool = true
    
    var numberOfOpponents: Int {
        max(1, numberOfPlayers - 1)
    }
    
    enum CalculationDepth: String, CaseIterable {
        case fast = "Fast"
        case accurate = "Accurate"
        case deep = "Deep"
        case maximum = "Maximum"
        
        var iterations: Int {
            switch self {
            case .fast: return 1_000_000       // 1M - instant
            case .accurate: return 10_000_000  // 10M - ~1.3s
            case .deep: return 50_000_000      // 50M - ~6s
            case .maximum: return 100_000_000  // 100M - ~13s
            }
        }
        
        var description: String {
            switch self {
            case .fast: return "1M sims (~0.2s)"
            case .accurate: return "10M sims (~1.3s)"
            case .deep: return "50M sims (~6s)"
            case .maximum: return "100M sims (~13s)"
            }
        }
        
        // Confidence level for UI - based on standard error of Monte Carlo
        var confidenceLevel: String {
            switch self {
            case .fast: return "±0.05%"
            case .accurate: return "±0.016%"
            case .deep: return "±0.007%"
            case .maximum: return "±0.005%"
            }
        }
    }
}
