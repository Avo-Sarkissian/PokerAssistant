import Foundation
import Accelerate

class MonteCarloEngine {
    /// The single hand-ranking implementation for every CPU path. It is stateless, so
    /// one instance is safe to share across the worker tasks below.
    private let evaluator = FastHandEvaluator()

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
        var totalEquity = 0.0
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

                var batchEquity = 0.0
                var batchRuns = 0

                for await result in group {
                    batchEquity += result.equitySum
                    batchRuns += result.total
                }

                return (equitySum: batchEquity, total: batchRuns)
            }

            totalEquity += batchResults.equitySum
            totalRuns += batchResults.total
            iterationsCompleted += currentBatchSize

            // Check for convergence after each batch (but only after minimum samples)
            if totalRuns >= 50_000 {
                let equity = totalEquity / Double(totalRuns)
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

        return min(1.0, max(0.0, totalEquity / Double(totalRuns)))
    }

    /// Calculate standard error for equity estimation
    private func calculateStandardError(equity: Double, sampleSize: Int) -> Double {
        // Standard error for proportion: SE = sqrt(p * (1-p) / n)
        let variance = equity * (1.0 - equity)
        let standardError = sqrt(variance / Double(sampleSize))
        return standardError
    }
    
    /// `equitySum` accumulates fractional pot shares, so a three-way chop contributes
    /// 1/3 rather than the 1/2 a win/tie counter would imply.
    private struct SimulationResult {
        let equitySum: Double
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

            // Build used-card index set using rank+suit (not UUID) for correct filtering.
            // Card.id is a random UUID, so UUID-based Set<Card> membership would always
            // miss deck cards (different instances) — use a compact 0–51 integer index instead.
            var usedIndices = Set<Int>(minimumCapacity: 16)
            for c in hand.allCards  { usedIndices.insert((c.rank.rawValue - 2) * 4 + c.suit.suitIndex) }
            for c in deadCards      { usedIndices.insert((c.rank.rawValue - 2) * 4 + c.suit.suitIndex) }

            // Create available cards buffer
            var availableCards = [Card]()
            availableCards.reserveCapacity(52)
            for card in deck where !usedIndices.contains((card.rank.rawValue - 2) * 4 + card.suit.suitIndex) {
                availableCards.append(card)
            }

            let availableCount = availableCards.count
            let boardNeeded = 5 - hand.communityCards.count
            let neededCards = boardNeeded + (opponents * 2)

            guard availableCount >= neededCards else {
                return SimulationResult(equitySum: 0, total: 0)
            }

            var equitySum = 0.0

            // Pre-allocate arrays for reuse
            var indices = Array(0..<availableCount)
            var communityCards = Array(hand.communityCards)
            communityCards.reserveCapacity(5)

            var myHandCards = Array(hand.holeCards)
            myHandCards.reserveCapacity(7)

            var oppCards = [Card]()
            oppCards.reserveCapacity(7)

            let useRangeFilter = opponentRange != .random
            // Guards against a range so narrow that the remaining deck cannot fill it.
            let maxRedraws = 256

            for _ in 0..<iterations {
                // 1. Deal hole cards before the board, exactly as a real deal does.
                //    Rejecting a hand after the board is already fixed would
                //    over-weight boards that consume the range's own cards.
                //
                //    A seat whose cards fall outside the range is re-dealt, never
                //    removed: dropping the player silently changes how many opponents
                //    hero is up against and inflates equity.
                var cardIndex = 0
                for _ in 0..<opponents {
                    var draws = 0
                    while true {
                        let a = Int.random(in: cardIndex..<availableCount, using: &rng)
                        indices.swapAt(cardIndex, a)
                        let b = Int.random(in: (cardIndex + 1)..<availableCount, using: &rng)
                        indices.swapAt(cardIndex + 1, b)
                        draws += 1

                        if !useRangeFilter { break }
                        let inRange = OpponentRange.isHandInRange(
                            availableCards[indices[cardIndex]],
                            availableCards[indices[cardIndex + 1]],
                            range: opponentRange
                        )
                        if inRange || draws >= maxRedraws { break }
                    }
                    cardIndex += 2
                }

                // 2. Run the board out of whatever is left.
                communityCards.removeAll(keepingCapacity: true)
                communityCards.append(contentsOf: hand.communityCards)
                for i in 0..<boardNeeded {
                    let slot = cardIndex + i
                    let j = Int.random(in: slot..<availableCount, using: &rng)
                    indices.swapAt(slot, j)
                    communityCards.append(availableCards[indices[slot]])
                }

                // 3. Score every opponent against the finished board.
                var bestOpponentValue = Int32.min
                var tiedOpponents = 0

                for seat in 0..<opponents {
                    oppCards.removeAll(keepingCapacity: true)
                    oppCards.append(availableCards[indices[seat * 2]])
                    oppCards.append(availableCards[indices[seat * 2 + 1]])
                    oppCards.append(contentsOf: communityCards)

                    let oppValue = evaluator.evaluate(oppCards)
                    if oppValue > bestOpponentValue {
                        bestOpponentValue = oppValue
                        tiedOpponents = 1
                    } else if oppValue == bestOpponentValue {
                        tiedOpponents += 1
                    }
                }

                // Evaluate my hand
                myHandCards.removeAll(keepingCapacity: true)
                myHandCards.append(contentsOf: hand.holeCards)
                myHandCards.append(contentsOf: communityCards)

                let myValue = evaluator.evaluate(myHandCards)

                if myValue > bestOpponentValue {
                    equitySum += 1.0
                } else if myValue == bestOpponentValue {
                    // Split the pot with every opponent holding the same hand.
                    equitySum += 1.0 / Double(tiedOpponents + 1)
                }
            }

            return SimulationResult(equitySum: equitySum, total: iterations)
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

        return min(1.0, max(0.0, result.equitySum / Double(result.total)))
    }
}
