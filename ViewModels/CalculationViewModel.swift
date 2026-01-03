import Foundation
import Combine

class CalculationViewModel: ObservableObject {
    @Published var progressUpdate: ProgressUpdate?

    // Lazy-loaded to defer Metal initialization until first calculation
    // This improves app startup time
    private lazy var equityCalculator = EquityCalculator()
    
    func calculate(gameState: GameState, settings: Settings) async throws -> CalculationResult {
        // Convert to thread-safe copy and use the background-safe method
        let copy = GameStateCopy(from: gameState)
        return try await calculateFromCopy(gameState: copy, settings: settings)
    }

    /// Background-safe calculation using thread-safe GameStateCopy
    /// This method can run on any thread without blocking the main actor
    func calculateFromCopy(gameState: GameStateCopy, settings: Settings) async throws -> CalculationResult {
        let calcStartTime = Date()

        try Task.checkCancellation()

        // Calculate equity directly - no UI updates from background thread
        let hand = Hand(
            holeCards: gameState.holeCards.compactMap { $0 },
            communityCards: gameState.communityCards.compactMap { $0 }
        )

        // Determine opponent range
        let opponentRange: OpponentRange.RangeType
        if gameState.toCall > 0 {
            let potRelativeBet = gameState.toCall / max(gameState.potSize, 1.0)
            opponentRange = OpponentRange.rangeFromAction(
                potRelativeBet: potRelativeBet,
                street: gameState.currentStreet,
                isRaise: true
            )
        } else {
            opponentRange = .random
        }

        try Task.checkCancellation()

        // Run equity calculation
        let equity = await equityCalculator.calculateDeep(
            hand: hand,
            opponents: settings.numberOfOpponents,
            deadCards: gameState.deadCards,
            iterations: settings.calculationDepth.iterations,
            confidenceThreshold: settings.calculationDepth.confidenceThreshold,
            opponentRange: opponentRange
        )

        try Task.checkCancellation()

        // Determine action using solver logic (simplified inline version)
        let action = determineAction(equity: equity, gameState: gameState, settings: settings)

        // Build result
        let foldEV = 0.0
        let callEV = (equity * (gameState.potSize + gameState.toCall)) - gameState.toCall
        let rawRaiseAmount = gameState.toCall + (gameState.potSize * 0.75)
        let raiseAmount = roundToSmallBlind(rawRaiseAmount, smallBlind: settings.smallBlind)
        let raiseEV = (0.4 * gameState.potSize) + (0.6 * ((equity * (gameState.potSize + raiseAmount)) - raiseAmount))

        let expectedValue: Double
        switch action {
        case .fold: expectedValue = foldEV
        case .call: expectedValue = callEV
        case .raise: expectedValue = raiseEV
        }

        let reasoning = generateReasoningFromCopy(action: action, equity: equity, gameState: gameState, numberOfPlayers: settings.numberOfPlayers)

        let alternatives = [
            CalculationResult.AlternativeAction(action: .fold, expectedValue: foldEV),
            CalculationResult.AlternativeAction(action: .call, expectedValue: callEV),
            CalculationResult.AlternativeAction(action: .raise(amount: raiseAmount), expectedValue: raiseEV)
        ].filter { !areActionsEqual($0.action, action) }

        return CalculationResult(
            action: action,
            equity: equity,
            expectedValue: expectedValue,
            confidence: .high,
            reasoning: reasoning,
            alternativeActions: alternatives,
            calculationTime: Date().timeIntervalSince(calcStartTime),
            toCall: gameState.toCall
        )
    }

    private func determineAction(equity: Double, gameState: GameStateCopy, settings: Settings) -> CalculationResult.RecommendedAction {
        let potOdds = gameState.toCall > 0 ? gameState.toCall / (gameState.potSize + gameState.toCall) : 0

        // Check for free check
        if gameState.toCall == 0 {
            if equity > 0.6 {
                let raiseAmount = roundToSmallBlind(gameState.potSize * 0.75, smallBlind: settings.smallBlind)
                return .raise(amount: raiseAmount)
            }
            return .call // Check
        }

        // With bet to face - need proper equity vs pot odds
        // Fold if equity doesn't justify the price (need decent edge for variance/implied odds)
        // With 25% pot odds, need ~30% equity to call profitably
        if equity < potOdds + 0.05 {
            return .fold
        } else if equity > potOdds + 0.15 {
            // Strong equity advantage - raise for value
            let raiseAmount = roundToSmallBlind(gameState.toCall + gameState.potSize * 0.75, smallBlind: settings.smallBlind)
            return .raise(amount: raiseAmount)
        }
        // Marginal call with small edge
        return .call
    }

    private func generateReasoningFromCopy(
        action: CalculationResult.RecommendedAction,
        equity: Double,
        gameState: GameStateCopy,
        numberOfPlayers: Int
    ) -> String {
        let equityPct = Int(equity * 100)
        let tableContext = numberOfPlayers <= 3 ? " (short-handed)" : ""

        // Calculate pot odds when there's a bet to call
        let potOdds = gameState.toCall > 0 ? gameState.toCall / (gameState.potSize + gameState.toCall) : 0
        let potOddsPct = Int(potOdds * 100)
        let potRatio = gameState.toCall > 0 ? gameState.potSize / gameState.toCall : 0

        switch action {
        case .fold:
            return "Fold: \(equityPct)% equity < \(potOddsPct)% pot odds needed. Paying $\(String(format: "%.2f", gameState.toCall)) into $\(String(format: "%.2f", gameState.potSize)) pot is -EV."
        case .call:
            if gameState.toCall == 0 {
                if equity < 0.35 {
                    return "Check: \(equityPct)% equity is marginal. Control pot size and see next card for free."
                } else if equity < 0.55 {
                    return "Check: \(equityPct)% equity. No need to build pot without strong hand."
                } else {
                    return "Check: \(equityPct)% equity is decent, but pot control is reasonable here."
                }
            }
            let edge = equityPct - potOddsPct
            return "Call: \(equityPct)% equity vs \(potOddsPct)% needed (\(String(format: "%.1f", potRatio)):1 odds). +\(edge)% edge makes calling profitable\(tableContext)."
        case .raise(let amount):
            let raiseSize = String(format: "%.2f", amount)
            if gameState.toCall == 0 {
                return "Raise to $\(raiseSize): \(equityPct)% equity is strong. Build value with a bet."
            }
            return "Raise to $\(raiseSize): \(equityPct)% equity vs \(potOddsPct)% pot odds. Strong edge (+\(equityPct - potOddsPct - 15)%) supports raising for value\(tableContext)."
        }
    }
    
    // Helper function to round to nearest small blind
    private func roundToSmallBlind(_ amount: Double, smallBlind: Double) -> Double {
        guard smallBlind > 0 else { return amount }
        return round(amount / smallBlind) * smallBlind
    }

    private func areActionsEqual(_ action1: CalculationResult.RecommendedAction, _ action2: CalculationResult.RecommendedAction) -> Bool {
        switch (action1, action2) {
        case (.fold, .fold), (.call, .call):
            return true
        case let (.raise(amount1), .raise(amount2)):
            return abs(amount1 - amount2) < 0.01
        default:
            return false
        }
    }
}
