import Foundation

public struct CalculationResult {
    public let action: RecommendedAction
    public let equity: Double
    public let expectedValue: Double
    public let confidence: Confidence
    public let reasoning: String
    public let alternativeActions: [AlternativeAction]
    public let calculationTime: TimeInterval
    public let toCall: Double  // Stored at calculation time to prevent UI updates
    public let spr: Double
    public let potOddsDisplay: String?  // e.g. "3.2:1"
    public let boardTexture: String?    // e.g. "Flush draw possible · High board"
    public let street: Street

    public init(action: RecommendedAction,
                equity: Double,
                expectedValue: Double,
                confidence: Confidence,
                reasoning: String,
                alternativeActions: [AlternativeAction],
                calculationTime: TimeInterval,
                toCall: Double,
                spr: Double,
                potOddsDisplay: String?,
                boardTexture: String?,
                street: Street) {
        self.action = action
        self.equity = equity
        self.expectedValue = expectedValue
        self.confidence = confidence
        self.reasoning = reasoning
        self.alternativeActions = alternativeActions
        self.calculationTime = calculationTime
        self.toCall = toCall
        self.spr = spr
        self.potOddsDisplay = potOddsDisplay
        self.boardTexture = boardTexture
        self.street = street
    }

    public enum RecommendedAction: Equatable {
        case fold
        case call  // Also used for "check" when toCall is 0
        case raise(amount: Double)

        public var displayString: String {
            switch self {
            case .fold: return "FOLD"
            case .call: return "CALL"
            case .raise(let amount): return "RAISE $\(String(format: "%.2f", amount))"
            }
        }

        public func displayStringWithContext(toCall: Double) -> String {
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
        public func shortDisplayString(toCall: Double) -> String {
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

    public enum Confidence {
        case low, medium, high

        public var displayString: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
    }

    public struct AlternativeAction {
        public let action: RecommendedAction
        public let expectedValue: Double

        public init(action: RecommendedAction, expectedValue: Double) {
            self.action = action
            self.expectedValue = expectedValue
        }
    }
}

public struct ProgressUpdate {
    public let stage: CalculationStage
    public let progress: Double
    public let timeElapsed: TimeInterval
    public let isComplete: Bool
    public let intermediateResult: IntermediateResult?
    public let preliminaryEquity: Double?

    public init(stage: CalculationStage,
                progress: Double,
                timeElapsed: TimeInterval,
                isComplete: Bool,
                intermediateResult: IntermediateResult?,
                preliminaryEquity: Double?) {
        self.stage = stage
        self.progress = progress
        self.timeElapsed = timeElapsed
        self.isComplete = isComplete
        self.intermediateResult = intermediateResult
        self.preliminaryEquity = preliminaryEquity
    }

    public enum CalculationStage: String {
        case basicMath = "Basic Math"
        case winPercentage = "Win Percentage"
        case bestStrategy = "Best Strategy"
        case fineTuning = "Fine Tuning"
    }

    public struct IntermediateResult {
        public let action: CalculationResult.RecommendedAction
        public let confidence: CalculationResult.Confidence

        public init(action: CalculationResult.RecommendedAction,
                    confidence: CalculationResult.Confidence) {
            self.action = action
            self.confidence = confidence
        }
    }
}
