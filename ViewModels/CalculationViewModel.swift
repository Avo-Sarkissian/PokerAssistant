import Foundation
import Combine

class CalculationViewModel: ObservableObject {
    @Published var progressUpdate: ProgressUpdate?

    private let equityCalculator = EquityCalculator()
    private let solver = ExploitativeSolver()

    func calculate(gameState: GameState, settings: Settings) async throws -> CalculationResult {
        let copy = GameStateCopy(from: gameState)
        return try await calculateFromCopy(gameState: copy, settings: settings)
    }

    func calculateFromCopy(gameState: GameStateCopy, settings: Settings) async throws -> CalculationResult {
        let calcStartTime = Date()

        try Task.checkCancellation()

        let hand = Hand(
            holeCards: gameState.holeCards.compactMap { $0 },
            communityCards: gameState.communityCards.compactMap { $0 }
        )

        // Determine opponent range for equity calculation.
        // If the user has tagged the opponent style, that overrides bet-size inference.
        let opponentRange: OpponentRange.RangeType
        if gameState.opponentStyle != .unknown {
            opponentRange = gameState.opponentStyle.rangeType
        } else if gameState.toCall > 0 {
            // Measured against the pot villain bet INTO, not the pot their bet is
            // already inside — the range thresholds are calibrated on "% of pot".
            let entry = PotEntry(potBeforeBet: gameState.potSize - gameState.toCall,
                                 toCall: gameState.toCall)
            let potRelativeBet = entry.betFractionOfPotBeforeBet
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
        // Price against the players still contesting the pot, not every seat at the
        // table — by the river most of them have folded.
        let equity = await equityCalculator.calculateDeep(
            hand: hand,
            opponents: gameState.opponentCount,
            deadCards: gameState.deadCards,
            iterations: settings.calculationDepth.iterations,
            confidenceThreshold: settings.calculationDepth.confidenceThreshold,
            opponentRange: opponentRange
        )

        try Task.checkCancellation()

        // Run solver for action, EVs, reasoning, board texture
        let solverResult = solver.solve(gameState: gameState, myEquity: equity, settings: settings)

        // Build expected value for recommended action
        let expectedValue: Double
        switch solverResult.action {
        case .fold: expectedValue = solverResult.evFold
        case .call: expectedValue = solverResult.evCall
        case .raise: expectedValue = solverResult.evRaise
        }

        // Build alternatives (all actions except the recommended one)
        let alternatives = [
            CalculationResult.AlternativeAction(action: .fold, expectedValue: solverResult.evFold),
            CalculationResult.AlternativeAction(action: .call, expectedValue: solverResult.evCall),
            CalculationResult.AlternativeAction(action: .raise(amount: solverResult.raiseAmount), expectedValue: solverResult.evRaise)
        ].filter { !areActionsEqual($0.action, solverResult.action) }

        // Pot odds display
        let potOddsDisplay: String?
        if gameState.toCall > 0 && gameState.potSize > 0 {
            let ratio = gameState.potSize / gameState.toCall
            potOddsDisplay = "\(String(format: "%.1f", ratio)):1"
        } else {
            potOddsDisplay = nil
        }

        return CalculationResult(
            action: solverResult.action,
            equity: equity,
            expectedValue: expectedValue,
            confidence: .high,
            reasoning: solverResult.reasoning,
            alternativeActions: alternatives,
            calculationTime: Date().timeIntervalSince(calcStartTime),
            toCall: gameState.toCall,
            spr: solverResult.spr,
            potOddsDisplay: potOddsDisplay,
            boardTexture: solverResult.boardTexture,
            street: gameState.currentStreet
        )
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
