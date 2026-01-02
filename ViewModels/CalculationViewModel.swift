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
        let tableContext = numberOfPlayers <= 3 ? " (short-handed)" : ""

        switch action {
        case .fold:
            return "Equity (\(Int(equity*100))%) doesn't justify the price."
        case .call:
            if gameState.toCall == 0 {
                return equity < 0.35 ? "Check. Low equity doesn't justify building pot." : "Check to control pot size."
            }
            return "Profitable call based on pot odds\(tableContext)."
        case .raise:
            return "Strong equity makes raising optimal\(tableContext)."
        }
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
            confidenceThreshold: settings.calculationDepth.confidenceThreshold,
            opponentRange: opponentRange
        )
    }

    /// Determine opponent's likely range based on their betting action
    private func determineOpponentRange(gameState: GameState) -> OpponentRange.RangeType {
        // No bet to face = no information about opponent's range = use random (enables fast GPU path)
        guard gameState.toCall > 0 else { return .random }

        let potRelativeBet = gameState.toCall / max(gameState.potSize, 1.0)

        return OpponentRange.rangeFromAction(
            potRelativeBet: potRelativeBet,
            street: gameState.currentStreet,
            isRaise: true
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
            calculationTime: Date().timeIntervalSince(startTime ?? Date()),
            toCall: gameState.toCall
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
            if gameState.toCall == 0 {
                if equity < 0.35 {
                    return "Check and see a free card. Low equity doesn't justify building a pot."
                }
                return "Check to control pot size or induce bluffs."
            }
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
