import Foundation
import Combine
import PokerCore

@MainActor
class GameViewModel: ObservableObject {
    @Published var gameState = GameState()
    @Published var isCalculating = false
    @Published var calculationResult: CalculationResult?
    @Published var progressUpdate: ProgressUpdate?
    @Published var stageTimings: [ProgressUpdate.CalculationStage: TimeInterval] = [:]

    // Hand history
    @Published var currentSession: HandSession = HandSession()
    @Published var allSessions: [HandSession] = []

    private let calculator = CalculationViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var calculationTask: Task<Void, Never>?
    private var lastCalculatedState: String = ""

    // Add settings reference
    var settings: Settings?

    private let sessionsKey = "handSessions"
    
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

        loadSessions()
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
    
    /// Every input the calculation reads must appear here. When one is missing the app
    /// decides nothing has changed, refuses to recompute, and keeps showing an answer
    /// derived from different inputs.
    func getCurrentStateString() -> String {
        let holeCards = gameState.holeCards.compactMap { $0?.displayString }.joined()
        let communityCards = gameState.communityCards.compactMap { $0?.displayString }.joined()
        let deadCards = gameState.deadCards.map { $0.displayString }.sorted().joined()

        let fields: [String] = [
            holeCards,
            communityCards,
            deadCards,
            "\(gameState.potSize)",
            "\(gameState.toCall)",
            "\(gameState.stack)",
            "\(gameState.villainStack)",
            "\(gameState.bigBlind)",
            "\(gameState.playersInHand)",
            // Which seats exist, and how far hero sits from the button. Leaving it out
            // let a table-size change go unnoticed while still moving the answer. Both the
            // mirror and its source are listed: the mirror is written inside `calculate()`,
            // *after* `canCalculate` has already decided whether to recompute, so on its
            // own it depends on a view-layer `onChange` in another file having fired first.
            "\(gameState.tableSize)",
            "\(settings?.numberOfPlayers ?? 0)",
            "\(gameState.heroWagerThisStreet)",
            gameState.position.rawValue,
            // Hero's own answer on position, which the seat cannot supply and which
            // changes both the postflop size and the fold-equity premium.
            gameState.actsLastOverride.map(String.init(describing:)) ?? "seat",
            gameState.opponentStyle.rawValue,
            // …and whether that style is being listened to. It became an input to the
            // calculation when `GameStateCopy` started honouring the toggle, and without
            // it here the fingerprint is byte-identical either side of switching Track
            // Opponents off: Calculate stays inert and the result computed against the
            // tagged range stays on screen with no way to refresh it.
            "\(settings?.trackOpponents ?? false)",
            "\(settings?.smallBlind ?? 0)",
            "\(settings?.bigBlind ?? 0)",
            settings?.gameMode.rawValue ?? "",
            settings?.tournamentPhase.rawValue ?? "",
            settings?.calculationDepth.rawValue ?? ""
        ]
        return fields.joined(separator: "-")
    }
    
    func calculate() async {
        // Use default settings if none are set
        let settingsToUse = settings ?? Settings()

        guard canCalculate else { return }

        // Cancel any existing calculation
        calculationTask?.cancel()

        // The solver reads the blind level and the table size off GameState; Settings is
        // the source of truth for both. Assigning `tableSize` corrects the seat through
        // its own `didSet`; players are then seated into the table rather than the table
        // being grown to fit them, which is what would move hero's chair.
        gameState.bigBlind = settingsToUse.bigBlind
        gameState.tableSize = settingsToUse.numberOfPlayers
        gameState.playersInHand = min(gameState.tableSize, gameState.playersInHand)

        isCalculating = true
        calculationResult = nil
        progressUpdate = nil
        stageTimings = [:]
        lastCalculatedState = getCurrentStateString()

        // Capture game state for background calculation
        let gameStateCopy = GameStateCopy(from: gameState, trackingOpponents: settingsToUse.trackOpponents)

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
                        if let result = result {
                            self?.recordHand(result: result)
                        }
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

        // Reset all state, seeding the pot from the configured blinds
        gameState.reset(
            smallBlind: settings?.smallBlind ?? 0.5,
            bigBlind: settings?.bigBlind ?? 1.0,
            playersInHand: settings?.numberOfPlayers ?? 6
        )
        calculationResult = nil
        progressUpdate = nil
        stageTimings = [:]
        isCalculating = false
        lastCalculatedState = ""
    }

    // MARK: - Hand History

    /// Record a completed calculation into the current session.
    func recordHand(result: CalculationResult) {
        let holeCards    = gameState.holeCards.compactMap { $0 }
        let communityCards = gameState.communityCards.compactMap { $0 }
        guard holeCards.count == 2 else { return }

        let record = HandRecord(
            holeCards: holeCards,
            communityCards: communityCards,
            street: gameState.currentStreet,
            position: gameState.position.rawValue,
            potSize: gameState.potSize,
            toCall: gameState.toCall,
            equity: result.equity,
            action: result.action,
            reasoning: result.reasoning
        )

        currentSession.records.append(record)
        saveSessions()
    }

    private func loadSessions() {
        guard let data = UserDefaults.standard.data(forKey: sessionsKey),
              let sessions = try? JSONDecoder().decode([HandSession].self, from: data) else { return }
        allSessions = sessions
    }

    private func saveSessions() {
        // Persist the current session merged with history
        var sessions = allSessions.filter { $0.id != currentSession.id }
        sessions.append(currentSession)
        // Keep only last 20 sessions
        if sessions.count > 20 { sessions = Array(sessions.suffix(20)) }
        allSessions = sessions
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: sessionsKey)
        }
    }

    func clearHistory() {
        allSessions = []
        currentSession = HandSession()
        UserDefaults.standard.removeObject(forKey: sessionsKey)
    }
}
