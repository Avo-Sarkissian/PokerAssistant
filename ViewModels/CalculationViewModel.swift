import Foundation
import Combine

class CalculationViewModel: ObservableObject {
    @Published var progressUpdate: ProgressUpdate?

    private let equityCalculator = EquityCalculator()
    private let solver = ExploitativeSolver()
    private var startTime: Date?

    /// Hand rank categories derived from PokerIntelligence scores
    /// Single source of truth - no separate HandEvaluator needed
    enum HandRank: String {
        case highCard = "High Card"
        case pair = "Pair"
        case twoPair = "Two Pair"
        case threeOfAKind = "Three of a Kind"
        case straight = "Straight"
        case flush = "Flush"
        case fullHouse = "Full House"
        case fourOfAKind = "Four of a Kind"
        case straightFlush = "Straight Flush"

        /// Convert PokerIntelligence score to hand rank
        static func from(score: Int32) -> HandRank {
            switch score {
            case 8_000_000...: return .straightFlush
            case 7_000_000..<8_000_000: return .fourOfAKind
            case 6_000_000..<7_000_000: return .fullHouse
            case 5_000_000..<6_000_000: return .flush
            case 4_000_000..<5_000_000: return .straight
            case 3_000_000..<4_000_000: return .threeOfAKind
            case 2_000_000..<3_000_000: return .twoPair
            case 1_000_000..<2_000_000: return .pair
            default: return .highCard
            }
        }
    }
    
    func calculate(gameState: GameState, settings: Settings) async throws -> CalculationResult {
        startTime = Date()
        
        // Stage 1: Basic Math (0.5s)
        await updateProgress(stage: .basicMath, progress: 0.0)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let basicEquity = await calculateBasicEquity(gameState: gameState, settings: settings)
        await updateProgress(stage: .basicMath, progress: 1.0, isComplete: true)
        
        try Task.checkCancellation()
        
        // Stage 2: Deep Equity (2s) - Show intermediate result immediately
        await updateProgress(stage: .winPercentage, progress: 0.0)
        
        let earlyAction = determineEarlyAction(equity: basicEquity, gameState: gameState, settings: settings)
        await updateProgress(
            stage: .winPercentage,
            progress: 0.2,
            intermediateResult: ProgressUpdate.IntermediateResult(
                action: earlyAction,
                confidence: .low
            ),
            preliminaryEquity: basicEquity
        )
        
        let deepEquity = await calculateDeepEquity(gameState: gameState, settings: settings)
        let betterAction = determineEarlyAction(equity: deepEquity, gameState: gameState, settings: settings)
        
        await updateProgress(
            stage: .winPercentage,
            progress: 1.0,
            isComplete: true,
            intermediateResult: ProgressUpdate.IntermediateResult(
                action: betterAction,
                confidence: .medium
            ),
            preliminaryEquity: deepEquity
        )
        
        try Task.checkCancellation()
        
        // Stage 3: Best Strategy (Using new Solver)
        await updateProgress(stage: .bestStrategy, progress: 0.0)
        try await Task.sleep(nanoseconds: 100_000_000) // Reduced sleep for speed
        
        // FIXED: Calling the new solver
        let optimalAction = await solver.solve(gameState: gameState, myEquity: deepEquity, settings: settings)
        
        await updateProgress(stage: .bestStrategy, progress: 1.0, isComplete: true)
        
        try Task.checkCancellation()
        
        // Stage 4: Fine Tuning
        await updateProgress(stage: .fineTuning, progress: 0.0)
        
        // We create the final result using the Solver's output
        let finalResult = await fineTuneStrategy(
            recommendedAction: optimalAction,
            equity: deepEquity,
            gameState: gameState,
            settings: settings
        )
        
        await updateProgress(stage: .fineTuning, progress: 1.0, isComplete: true)
        
        return finalResult
    }
    
    // Helper function to round to nearest small blind
    private func roundToSmallBlind(_ amount: Double, smallBlind: Double) -> Double {
        guard smallBlind > 0 else { return amount }
        return round(amount / smallBlind) * smallBlind
    }
    
    private func calculateBasicEquity(gameState: GameState, settings: Settings) async -> Double {
        let hand = Hand(
            holeCards: gameState.holeCards.compactMap { $0 },
            communityCards: gameState.communityCards.compactMap { $0 }
        )

        // Determine opponent range based on their action
        let opponentRange = determineOpponentRange(gameState: gameState)

        return await equityCalculator.calculateQuick(
            hand: hand,
            opponents: settings.numberOfOpponents,
            deadCards: gameState.deadCards,
            opponentRange: opponentRange
        )
    }

    private func calculateDeepEquity(gameState: GameState, settings: Settings) async -> Double {
        let hand = Hand(
            holeCards: gameState.holeCards.compactMap { $0 },
            communityCards: gameState.communityCards.compactMap { $0 }
        )

        // Determine opponent range based on their action
        let opponentRange = determineOpponentRange(gameState: gameState)

        return await equityCalculator.calculateDeep(
            hand: hand,
            opponents: settings.numberOfOpponents,
            deadCards: gameState.deadCards,
            iterations: settings.calculationDepth.iterations,
            opponentRange: opponentRange
        )
    }

    /// Determine opponent's likely range based on their betting action
    private func determineOpponentRange(gameState: GameState) -> OpponentRange.RangeType {
        let potRelativeBet = gameState.toCall / max(gameState.potSize, 1.0)
        let isRaise = gameState.toCall > 0

        return OpponentRange.rangeFromAction(
            potRelativeBet: potRelativeBet,
            street: gameState.currentStreet,
            isRaise: isRaise
        )
    }
    
    private func getHandStrength(gameState: GameState) -> HandRank? {
        let holeCards = gameState.holeCards.compactMap { $0 }
        let communityCards = gameState.communityCards.compactMap { $0 }

        guard holeCards.count == 2 else { return nil }

        let allCards = holeCards + communityCards
        if allCards.count >= 5 {
            // Use PokerIntelligence (same engine as Monte Carlo) for consistency
            let score = PokerIntelligence.shared.evaluate7(allCards)
            return HandRank.from(score: score)
        }

        return nil
    }
    
    private func determineEarlyAction(equity: Double, gameState: GameState, settings: Settings) -> CalculationResult.RecommendedAction {
        let potOdds = gameState.toCall / (gameState.potSize + gameState.toCall)
        
        if equity < potOdds - 0.05 {
            return .fold
        } else if equity > potOdds + 0.15 {
            let rawRaiseAmount = gameState.toCall + (gameState.potSize * 0.75)
            let raiseAmount = roundToSmallBlind(rawRaiseAmount, smallBlind: settings.smallBlind)
            return .raise(amount: raiseAmount)
        } else {
            return .call
        }
    }
    
    private func fineTuneStrategy(
        recommendedAction: CalculationResult.RecommendedAction,
        equity: Double,
        gameState: GameState,
        settings: Settings
    ) async -> CalculationResult {
        
        // Calculate EV for all options to show alternatives
        let foldEV = 0.0
        let callEV = (equity * (gameState.potSize + gameState.toCall)) - gameState.toCall
        
        let rawRaiseAmount = gameState.toCall + (gameState.potSize * 0.75)
        let raiseAmount = roundToSmallBlind(rawRaiseAmount, smallBlind: settings.smallBlind)
        
        // Simplified Raise EV for display purposes
        let raiseEV = (0.4 * gameState.potSize) + (0.6 * ((equity * (gameState.potSize + raiseAmount)) - raiseAmount))
        
        let expectedValue: Double
        switch recommendedAction {
        case .fold: expectedValue = foldEV
        case .call: expectedValue = callEV
        case .raise: expectedValue = raiseEV
        }
        
        let reasoning = generateReasoning(
            action: recommendedAction,
            equity: equity,
            gameState: gameState,
            handRank: getHandStrength(gameState: gameState),
            numberOfPlayers: settings.numberOfPlayers
        )
        
        // Create alternatives
        let alternatives = [
            CalculationResult.AlternativeAction(action: .fold, expectedValue: foldEV),
            CalculationResult.AlternativeAction(action: .call, expectedValue: callEV),
            CalculationResult.AlternativeAction(
                action: .raise(amount: raiseAmount),
                expectedValue: raiseEV
            )
        ].filter { alt in
            !areActionsEqual(alt.action, recommendedAction)
        }
        
        return CalculationResult(
            action: recommendedAction,
            equity: equity,
            expectedValue: expectedValue,
            confidence: .high,
            reasoning: reasoning,
            alternativeActions: alternatives,
            calculationTime: Date().timeIntervalSince(startTime ?? Date())
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
    
    private func generateReasoning(
        action: CalculationResult.RecommendedAction,
        equity: Double,
        gameState: GameState,
        handRank: HandRank?,
        numberOfPlayers: Int
    ) -> String {
        let tableContext = numberOfPlayers <= 3 ? " (short-handed)" : ""

        if let rank = handRank {
            switch rank {
            case .straightFlush, .fourOfAKind, .fullHouse:
                return "Monster hand. Build the pot immediately\(tableContext)."
            case .flush, .straight:
                return "Strong hand. Extraction is priority\(tableContext)."
            case .threeOfAKind:
                return "Very strong. Watch for flush/straight draws."
            default:
                break
            }
        }

        switch action {
        case .fold:
            return "Equity (\(Int(equity*100))%) doesn't justify the price."
        case .call:
            return "Profitable call based on pot odds and implied value."
        case .raise:
            return "High equity + fold equity makes raising optimal."
        }
    }
    
    @MainActor
    private func updateProgress(
        stage: ProgressUpdate.CalculationStage,
        progress: Double,
        isComplete: Bool = false,
        intermediateResult: ProgressUpdate.IntermediateResult? = nil,
        preliminaryEquity: Double? = nil
    ) async {
        let timeElapsed = Date().timeIntervalSince(startTime ?? Date())
        
        self.progressUpdate = ProgressUpdate(
            stage: stage,
            progress: progress,
            timeElapsed: timeElapsed,
            isComplete: isComplete,
            intermediateResult: intermediateResult,
            preliminaryEquity: preliminaryEquity
        )
    }
}
