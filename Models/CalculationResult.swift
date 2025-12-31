import Foundation

struct CalculationResult {
    let action: RecommendedAction
    let equity: Double
    let expectedValue: Double
    let confidence: Confidence
    let reasoning: String
    let alternativeActions: [AlternativeAction]
    let calculationTime: TimeInterval
    
    enum RecommendedAction: Equatable {
        case fold
        case call  // Also used for "check" when toCall is 0
        case raise(amount: Double)
        
        var displayString: String {
            switch self {
            case .fold: return "FOLD"
            case .call: return "CALL"
            case .raise(let amount): return "RAISE $\(String(format: "%.2f", amount))"
            }
        }
        
        func displayStringWithContext(toCall: Double) -> String {
            switch self {
            case .fold:
                return "FOLD"
                
            case .call:
                if toCall == 0 {
                    return "CHECK ✓"
                } else {
                    return "CALL $\(String(format: "%.2f", toCall))"
                }
                
            case .raise(let amount):
                if toCall == 0 {
                    // No bet to call - this is an opening bet, not a raise
                    return "BET $\(String(format: "%.2f", amount))"
                } else {
                    // There's a bet - show raise details
                    let totalCommitted = toCall + amount
                    return "RAISE to $\(String(format: "%.2f", totalCommitted)) (+$\(String(format: "%.2f", amount)) more)"
                }
            }
        }
        
        // NEW: Short version for alternatives list
        func shortDisplayString(toCall: Double) -> String {
            switch self {
            case .fold:
                return "Fold"
                
            case .call:
                if toCall == 0 {
                    return "Check"
                } else {
                    return "Call $\(String(format: "%.2f", toCall))"
                }
                
            case .raise(let amount):
                if toCall == 0 {
                    return "Bet $\(String(format: "%.2f", amount))"
                } else {
                    let total = toCall + amount
                    return "Raise to $\(String(format: "%.2f", total))"
                }
            }
        }
    }
    
    enum Confidence {
        case low, medium, high
        
        var displayString: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
    }
    
    struct AlternativeAction {
        let action: RecommendedAction
        let expectedValue: Double
    }
}

struct ProgressUpdate {
    let stage: CalculationStage
    let progress: Double
    let timeElapsed: TimeInterval
    let isComplete: Bool
    let intermediateResult: IntermediateResult?
    let preliminaryEquity: Double?
    
    enum CalculationStage: String {
        case basicMath = "Basic Math"
        case winPercentage = "Win Percentage"
        case bestStrategy = "Best Strategy"
        case fineTuning = "Fine Tuning"
    }
    
    struct IntermediateResult {
        let action: CalculationResult.RecommendedAction
        let confidence: CalculationResult.Confidence
    }
}
