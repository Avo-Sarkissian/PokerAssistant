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

    // Everything below is captured at calculation time for the same reason `toCall` is:
    // this struct is a snapshot of a decision, and the card that displays it must not
    // narrate a table that has moved on since. `ResultView` used to read hero's seat and
    // the pot odds live from `GameState`, so tapping a seat flipped the "In Position"
    // badge above a reasoning string that still said the opposite.

    /// Whether hero acts last after the flop — the fact hero supplied, as it stood when
    /// this decision was made.
    public let heroActsLast: Bool

    /// The share of the final pot hero needed for calling to break even, as a fraction.
    /// Zero when there was nothing to call.
    public let requiredEquity: Double

    /// What hero had already put in on this street — a posted blind, plus anything bet
    /// before villain raised. Needed to say what a raise is *to*, rather than what it adds.
    public let heroWagerThisStreet: Double

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
                street: Street,
                heroActsLast: Bool,
                requiredEquity: Double,
                heroWagerThisStreet: Double) {
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
        self.heroActsLast = heroActsLast
        self.requiredEquity = requiredEquity
        self.heroWagerThisStreet = heroWagerThisStreet
    }

    /// The headline the result card shows, built from the snapshot rather than from
    /// whatever the table looks like now.
    public var actionDisplay: String {
        action.displayStringWithContext(toCall: toCall, heroWagerThisStreet: heroWagerThisStreet)
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

        /// `heroWagerThisStreet` is what hero has already put in — a posted blind, or a bet
        /// villain then raised. Without it "RAISE to" names the wrong number: a small blind
        /// opening to 3bb showed "RAISE to $2.50", the same figure a button open shows,
        /// which hid the out-of-position premium the sizing deliberately adds. The blind is
        /// hero's money and it is already in the pot; the total is what hero will have in
        /// after acting.
        public func displayStringWithContext(toCall: Double, heroWagerThisStreet: Double = 0) -> String {
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
                let totalThisStreet = heroWagerThisStreet + toCall + amount
                if toCall == 0 && heroWagerThisStreet == 0 {
                    // Nothing to call and nothing already in: an opening bet, not a raise.
                    return "BET $\(String(format: "%.2f", amount))"
                }
                return "RAISE to $\(String(format: "%.2f", totalThisStreet)) "
                     + "(+$\(String(format: "%.2f", amount)) more)"
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
