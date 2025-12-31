import Foundation
import Accelerate

class MonteCarloEngine {
    private let intelligence = PokerIntelligence.shared
    
    // Thread-local storage for maximum performance
    // This prevents memory allocation overhead inside the hot loop
    private static let threadLocalRandom = ThreadLocal<RandomNumberGenerator> { SystemRandomNumberGenerator() }
    private static let threadLocalDeck = ThreadLocal<[Card]> { Card.deck() }
    private static let threadLocalBuffer = ThreadLocal<[Card]> {
        var buffer = [Card]()
        buffer.reserveCapacity(52)
        return buffer
    }
    
    // Use all performance cores on iPhone 16 Pro
    private let coreCount: Int
    private let performanceCores: Int = 6  // A18 Pro has 6 performance cores
    
    init() {
        // Use all available cores for iPhone 16 Pro
        self.coreCount = min(performanceCores, ProcessInfo.processInfo.activeProcessorCount)
        print("🚀 MonteCarloEngine using \(coreCount) cores")
        
        // Report to performance monitor
        PerformanceMonitor.shared.reportActiveCores(coreCount)
    }
    
    func simulate(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        iterations: Int
    ) async -> Double {
        guard hand.holeCards.count == 2 else { return 0.0 }
        
        // Report GPU not active (CPU mode)
        PerformanceMonitor.shared.reportGPUActive(false)
        
        // For small iterations, don't parallelize (overhead > gain)
        if iterations < 10000 {
            return await simulateSingleThread(
                hand: hand,
                opponents: opponents,
                deadCards: deadCards,
                iterations: iterations
            )
        }
        
        // Report active cores for this calculation
        PerformanceMonitor.shared.reportActiveCores(coreCount)
        
        // Distribute work across all cores
        let iterationsPerCore = iterations / coreCount
        let remainder = iterations % coreCount
        
        return await withTaskGroup(of: SimulationResult.self) { group in
            for coreIndex in 0..<coreCount {
                let coreIterations = iterationsPerCore + (coreIndex < remainder ? 1 : 0)
                
                group.addTask(priority: .userInitiated) {
                    self.simulateOnCore(
                        hand: hand,
                        opponents: opponents,
                        deadCards: deadCards,
                        iterations: coreIterations,
                        coreIndex: coreIndex
                    )
                }
            }
            
            var totalWins = 0
            var totalTies = 0
            var totalRuns = 0
            
            for await result in group {
                totalWins += result.wins
                totalTies += result.ties
                totalRuns += result.total
            }
            
            guard totalRuns > 0 else { return 0.0 }
            
            let equity = Double(totalWins) / Double(totalRuns) +
                        (Double(totalTies) / Double(totalRuns) * 0.5)
            return min(1.0, max(0.0, equity))
        }
    }
    
    private struct SimulationResult {
        let wins: Int
        let ties: Int
        let total: Int
    }
    
    private func simulateOnCore(
            hand: Hand,
            opponents: Int,
            deadCards: Set<Card>,
            iterations: Int,
            coreIndex: Int
        ) -> SimulationResult {
            // Get thread-local resources
            var rng = Self.threadLocalRandom.value!
            let deck = Self.threadLocalDeck.value!
            var buffer = Self.threadLocalBuffer.value!
            
            // Pre-calculate used cards
            let usedCards = Set(hand.allCards + Array(deadCards))
            
            // Create available cards buffer once
            buffer.removeAll(keepingCapacity: true)
            for card in deck where !usedCards.contains(card) {
                buffer.append(card)
            }
            
            let availableCount = buffer.count
            let neededCards = (5 - hand.communityCards.count) + (opponents * 2)
            
            guard availableCount >= neededCards else {
                return SimulationResult(wins: 0, ties: 0, total: 0)
            }
            
            var wins = 0
            var ties = 0
            
            // Pre-allocate arrays for reuse
            var indices = Array(0..<availableCount)
            var communityCards = Array(hand.communityCards)
            communityCards.reserveCapacity(5)
            
            var myHandCards = Array(hand.holeCards)
            myHandCards.reserveCapacity(7)
            
            var oppCards = [Card]()
            oppCards.reserveCapacity(7)
            
            // Main simulation loop - optimized for speed
            for i in 0..<iterations {
                // Fisher-Yates shuffle on indices (faster than shuffling card objects)
                for j in (1..<availableCount).reversed() {
                    let k = Int.random(in: 0...j, using: &rng)
                    indices.swapAt(j, k)
                }
                
                // Deal remaining community cards
                communityCards.removeAll(keepingCapacity: true)
                communityCards.append(contentsOf: hand.communityCards)
                
                var cardIndex = 0
                while communityCards.count < 5 && cardIndex < availableCount {
                    communityCards.append(buffer[indices[cardIndex]])
                    cardIndex += 1
                }
                
                // Evaluate my hand
                myHandCards.removeAll(keepingCapacity: true)
                myHandCards.append(contentsOf: hand.holeCards)
                myHandCards.append(contentsOf: communityCards)
                
                // UPDATED: Using the new evaluate7 method
                let myValue = Int(intelligence.evaluate7(myHandCards))
                
                // Evaluate opponent hands
                var bestOpponentValue = 0
                
                for _ in 0..<opponents {
                    guard cardIndex + 1 < availableCount else { break }
                    
                    oppCards.removeAll(keepingCapacity: true)
                    oppCards.append(buffer[indices[cardIndex]])
                    oppCards.append(buffer[indices[cardIndex + 1]])
                    oppCards.append(contentsOf: communityCards)
                    cardIndex += 2
                    
                    // UPDATED: Using the new evaluate7 method
                    let oppValue = Int(intelligence.evaluate7(oppCards))
                    bestOpponentValue = max(bestOpponentValue, oppValue)
                }
                
                if myValue > bestOpponentValue {
                    wins += 1
                } else if myValue == bestOpponentValue {
                    ties += 1
                }
                
                // Report progress periodically (every 5000 iters to reduce overhead)
                if i % 5000 == 0 {
                    PerformanceMonitor.shared.reportCalculation()
                }
            }
            
            // Store thread-local resources back
            Self.threadLocalBuffer.value = buffer
            
            return SimulationResult(wins: wins, ties: ties, total: iterations)
        }
    
    private func simulateSingleThread(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        iterations: Int
    ) async -> Double {
        // Report single core usage
        PerformanceMonitor.shared.reportActiveCores(1)
        
        let result = simulateOnCore(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: iterations,
            coreIndex: 0
        )
        
        guard result.total > 0 else { return 0.0 }
        
        let equity = Double(result.wins) / Double(result.total) +
                    (Double(result.ties) / Double(result.total) * 0.5)
        return min(1.0, max(0.0, equity))
    }
}

// MARK: - Thread Local Storage
// Kept this helper class as it is excellent for this architecture

private class ThreadLocal<T> {
    private var storage = [Thread: T]()
    private let queue = DispatchQueue(label: "threadlocal", attributes: .concurrent)
    private let initializer: () -> T
    
    init(initialValue: @escaping () -> T) {
        self.initializer = initialValue
    }
    
    var value: T? {
        get {
            let thread = Thread.current
            return queue.sync {
                if let value = storage[thread] {
                    return value
                } else {
                    let value = initializer()
                    queue.async(flags: .barrier) {
                        self.storage[thread] = value
                    }
                    return value
                }
            }
        }
        set {
            let thread = Thread.current
            queue.async(flags: .barrier) {
                if let newValue = newValue {
                    self.storage[thread] = newValue
                } else {
                    self.storage.removeValue(forKey: thread)
                }
            }
        }
    }
}
