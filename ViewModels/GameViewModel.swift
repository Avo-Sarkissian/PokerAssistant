import Foundation
import Combine

@MainActor
class GameViewModel: ObservableObject {
    @Published var gameState = GameState()
    @Published var isCalculating = false
    @Published var calculationResult: CalculationResult?
    @Published var progressUpdate: ProgressUpdate?
    @Published var stageTimings: [ProgressUpdate.CalculationStage: TimeInterval] = [:]
    
    private let calculator = CalculationViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var calculationTask: Task<Void, Never>?
    private var lastCalculatedState: String = ""
    
    // Add settings reference
    var settings: Settings?
    
    init() {
        calculator.$progressUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.progressUpdate = update
                if let update = update, update.isComplete {
                    self?.stageTimings[update.stage] = update.timeElapsed
                }
            }
            .store(in: &cancellables)
        
        // Listen for game state changes to update canCalculate
        gameState.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    var canCalculate: Bool {
        // Must have both hole cards
        let hasHoleCards = gameState.holeCards.allSatisfy { $0 != nil }
        
        // Must have valid community cards (0, 3, 4, or 5)
        let communityCount = gameState.communityCards.compactMap { $0 }.count
        let hasValidCommunity = [0, 3, 4, 5].contains(communityCount)
        
        // Must have pot size
        let hasPot = gameState.potSize > 0
        
        // Check if state has changed since last calculation
        let currentState = getCurrentStateString()
        let stateChanged = currentState != lastCalculatedState || calculationResult == nil
        
        return hasHoleCards && hasValidCommunity && hasPot && stateChanged && !isCalculating
    }
    
    var calculationError: String {
        if !gameState.holeCards.allSatisfy({ $0 != nil }) {
            return "Select both hole cards"
        }
        
        if gameState.potSize <= 0 {
            return "Enter pot size"
        }
        
        let communityCount = gameState.communityCards.compactMap { $0 }.count
        if ![0, 3, 4, 5].contains(communityCount) {
            return "Invalid board: use 0, 3, 4, or 5 community cards"
        }
        
        if !isCalculating && getCurrentStateString() == lastCalculatedState && calculationResult != nil {
            return "Already calculated for this state"
        }
        
        return ""
    }
    
    private func getCurrentStateString() -> String {
        let holeCards = gameState.holeCards.compactMap { $0?.displayString }.joined()
        let communityCards = gameState.communityCards.compactMap { $0?.displayString }.joined()
        let deadCards = gameState.deadCards.map { $0.displayString }.sorted().joined()
        let opponents = settings?.numberOfOpponents ?? 5
        return "\(holeCards)-\(communityCards)-\(deadCards)-\(gameState.potSize)-\(gameState.toCall)-\(opponents)-\(gameState.position)"
    }
    
    func calculate() async {
        // Use default settings if none are set
        let settingsToUse = settings ?? Settings()

        guard canCalculate else { return }

        // Cancel any existing calculation
        calculationTask?.cancel()

        isCalculating = true
        calculationResult = nil
        progressUpdate = nil
        stageTimings = [:]
        lastCalculatedState = getCurrentStateString()

        // Capture game state for background calculation
        let gameStateCopy = GameStateCopy(from: gameState)

        // Use Task.detached to run calculation OFF the main thread
        // This prevents blocking the UI and allows timeouts to work
        calculationTask = Task.detached(priority: .userInitiated) { [calculator, weak self] in
            do {
                // Wrap in timeout to prevent infinite hangs
                let result = try await withThrowingTaskGroup(of: CalculationResult?.self) { group in
                    // Main calculation task
                    group.addTask {
                        try await calculator.calculateFromCopy(gameState: gameStateCopy, settings: settingsToUse)
                    }

                    // Timeout task (15 seconds max)
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw CalculationError.timeout
                    }

                    // Return first successful result
                    if let result = try await group.next() {
                        group.cancelAll()
                        return result
                    }
                    return nil
                }

                // Update UI on main actor
                await MainActor.run {
                    if !Task.isCancelled {
                        self?.calculationResult = result
                        self?.isCalculating = false
                    }
                }
            } catch CalculationError.timeout {
                await MainActor.run {
                    print("Calculation timed out after 15 seconds")
                    self?.isCalculating = false
                }
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        print("Calculation error: \(error)")
                        self?.isCalculating = false
                    }
                }
            }
        }
    }

    enum CalculationError: Error {
        case timeout
    }
    
    func resetHand() {
        // Cancel any ongoing calculation
        calculationTask?.cancel()
        
        // Reset all state
        gameState.reset()
        calculationResult = nil
        progressUpdate = nil
        stageTimings = [:]
        isCalculating = false
        lastCalculatedState = ""
    }
}
