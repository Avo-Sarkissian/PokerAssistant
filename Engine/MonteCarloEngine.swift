import Foundation
import Accelerate

class MonteCarloEngine {
    private let intelligence = PokerIntelligence.shared

    // Pre-built deck (immutable, thread-safe to share)
    private let deck = Card.deck()

    // Use all performance cores on iPhone 16 Pro
    private let coreCount: Int
    private let performanceCores: Int = 6  // A18 Pro has 6 performance cores

    init() {
        // Use all available cores for iPhone 16 Pro
        self.coreCount = min(performanceCores, ProcessInfo.processInfo.activeProcessorCount)

        // Report to performance monitor
        PerformanceMonitor.shared.reportActiveCores(coreCount)
    }
    
    /// Main simulate function with opponent range weighting and early termination
    /// - Parameters:
    ///   - opponentRange: The estimated range of hands opponents might hold
    ///   - confidenceThreshold: Standard error threshold for early termination (e.g., 0.005 for 0.5%)
    ///   - maxTimeSeconds: Maximum wall-clock time before forced termination
    func simulate(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        iterations: Int,
        opponentRange: OpponentRange.RangeType = .standard,
        confidenceThreshold: Double = 0.005,
        maxTimeSeconds: Double = 10.0
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
                iterations: iterations,
                opponentRange: opponentRange
            )
        }

        // Report active cores for this calculation
        PerformanceMonitor.shared.reportActiveCores(coreCount)

        let startTime = Date()
        let batchSize = 50_000 // Run in batches for early termination checks
        var totalWins = 0
        var totalTies = 0
        var totalRuns = 0
        var iterationsCompleted = 0

        // Run batches until convergence or limits reached
        while iterationsCompleted < iterations {
            let remainingIterations = iterations - iterationsCompleted
            let currentBatchSize = min(batchSize, remainingIterations)

            // Check timeout
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= maxTimeSeconds {
                PerformanceMonitor.shared.reportCalcInfo("CPU: \(iterationsCompleted/1000)K (timeout)")
                break
            }

            // Distribute batch across cores
            let iterationsPerCore = currentBatchSize / coreCount
            let remainder = currentBatchSize % coreCount

            let batchResults = await withTaskGroup(of: SimulationResult.self) { group in
                for coreIndex in 0..<coreCount {
                    let coreIterations = iterationsPerCore + (coreIndex < remainder ? 1 : 0)

                    group.addTask(priority: .userInitiated) {
                        self.simulateOnCore(
                            hand: hand,
                            opponents: opponents,
                            deadCards: deadCards,
                            iterations: coreIterations,
                            coreIndex: coreIndex,
                            opponentRange: opponentRange
                        )
                    }
                }

                var batchWins = 0
                var batchTies = 0
                var batchRuns = 0

                for await result in group {
                    batchWins += result.wins
                    batchTies += result.ties
                    batchRuns += result.total
                }

                return (wins: batchWins, ties: batchTies, total: batchRuns)
            }

            totalWins += batchResults.wins
            totalTies += batchResults.ties
            totalRuns += batchResults.total
            iterationsCompleted += currentBatchSize

            // Check for convergence after each batch (but only after minimum samples)
            if totalRuns >= 50_000 {
                let equity = Double(totalWins) / Double(totalRuns) +
                            (Double(totalTies) / Double(totalRuns) * 0.5)
                let standardError = calculateStandardError(
                    equity: equity,
                    sampleSize: totalRuns
                )

                // Early termination if converged
                if standardError < confidenceThreshold {
                    let elapsedTime = Date().timeIntervalSince(startTime)
                    PerformanceMonitor.shared.reportCalcInfo("CPU: \(totalRuns/1000)K, SE=\(String(format: "%.3f", standardError * 100))%, \(String(format: "%.1f", elapsedTime))s")
                    break
                }
            }
        }

        guard totalRuns > 0 else { return 0.0 }

        let equity = Double(totalWins) / Double(totalRuns) +
                    (Double(totalTies) / Double(totalRuns) * 0.5)
        return min(1.0, max(0.0, equity))
    }

    /// Calculate standard error for equity estimation
    private func calculateStandardError(equity: Double, sampleSize: Int) -> Double {
        // Standard error for proportion: SE = sqrt(p * (1-p) / n)
        let variance = equity * (1.0 - equity)
        let standardError = sqrt(variance / Double(sampleSize))
        return standardError
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
            coreIndex: Int,
            opponentRange: OpponentRange.RangeType
        ) -> SimulationResult {
            // Create resources locally - avoids GCD deadlock with Swift concurrency
            // The slight allocation overhead is worth avoiding deadlock
            var rng = SystemRandomNumberGenerator()

            // Pre-calculate used cards
            let usedCards = Set(hand.allCards + Array(deadCards))

            // Create available cards buffer
            var availableCards = [Card]()
            availableCards.reserveCapacity(52)
            for card in deck where !usedCards.contains(card) {
                availableCards.append(card)
            }

            let availableCount = availableCards.count
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

            let useRangeFilter = opponentRange != .random
            var validIterations = 0

            // Simple, fast simulation loop
            for _ in 0..<iterations {
                // Fisher-Yates partial shuffle - only shuffle what we need
                for i in 0..<neededCards {
                    let j = Int.random(in: i..<availableCount, using: &rng)
                    indices.swapAt(i, j)
                }

                // Deal community cards
                communityCards.removeAll(keepingCapacity: true)
                communityCards.append(contentsOf: hand.communityCards)

                var cardIndex = 0
                while communityCards.count < 5 {
                    communityCards.append(availableCards[indices[cardIndex]])
                    cardIndex += 1
                }

                // Evaluate opponent hands - simple sequential dealing
                var bestOpponentValue = 0
                var validOpponentCount = 0

                for _ in 0..<opponents {
                    let oppCard1 = availableCards[indices[cardIndex]]
                    let oppCard2 = availableCards[indices[cardIndex + 1]]
                    cardIndex += 2

                    // Range filter: skip hands outside opponent's likely range
                    if useRangeFilter {
                        if !OpponentRange.isHandInRange(oppCard1, oppCard2, range: opponentRange) {
                            continue  // Skip this opponent, they wouldn't play this hand
                        }
                    }

                    oppCards.removeAll(keepingCapacity: true)
                    oppCards.append(oppCard1)
                    oppCards.append(oppCard2)
                    oppCards.append(contentsOf: communityCards)

                    let oppValue = Int(intelligence.evaluate7(oppCards))
                    bestOpponentValue = max(bestOpponentValue, oppValue)
                    validOpponentCount += 1
                }

                // Skip iterations where no opponents had hands in range
                // We want equity against hands they WOULD play, not "they all folded"
                if useRangeFilter && validOpponentCount == 0 {
                    continue
                }

                validIterations += 1

                // Evaluate my hand
                myHandCards.removeAll(keepingCapacity: true)
                myHandCards.append(contentsOf: hand.holeCards)
                myHandCards.append(contentsOf: communityCards)

                let myValue = Int(intelligence.evaluate7(myHandCards))

                if myValue > bestOpponentValue {
                    wins += 1
                } else if myValue == bestOpponentValue {
                    ties += 1
                }
            }

            return SimulationResult(wins: wins, ties: ties, total: validIterations)
        }
    
    private func simulateSingleThread(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        iterations: Int,
        opponentRange: OpponentRange.RangeType
    ) async -> Double {
        // Report single core usage
        PerformanceMonitor.shared.reportActiveCores(1)

        let result = simulateOnCore(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: iterations,
            coreIndex: 0,
            opponentRange: opponentRange
        )

        guard result.total > 0 else { return 0.0 }

        let equity = Double(result.wins) / Double(result.total) +
                    (Double(result.ties) / Double(result.total) * 0.5)
        return min(1.0, max(0.0, equity))
    }
}
