import Foundation

class EquityCalculator {
    // MonteCarloEngine is lazy since it's only needed for heads-up preflop with range filtering
    private lazy var monteCarloEngine = MonteCarloEngine()

    // MetalCompute is initialized in background to not block app launch
    private var metalCompute: MetalCompute?
    private var metalInitStarted = false
    private let metalLock = NSLock()

    init() {
        // Start Metal initialization in background immediately
        // Don't wait for it - this allows app to launch quickly
        startMetalInitInBackground()
    }

    private func startMetalInitInBackground() {
        metalLock.lock()
        guard !metalInitStarted else {
            metalLock.unlock()
            return
        }
        metalInitStarted = true
        metalLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metal = MetalCompute()
            self?.metalLock.lock()
            self?.metalCompute = metal
            self?.metalLock.unlock()
        }
    }

    /// Non-blocking check for Metal availability
    /// Returns nil immediately if Metal is still initializing (lock held)
    /// This prevents calculation thread from blocking on Metal init
    private func getMetalCompute() -> MetalCompute? {
        // Try to acquire lock without blocking
        guard metalLock.try() else {
            // Lock is held by init thread - Metal not ready yet
            return nil
        }
        defer { metalLock.unlock() }
        return metalCompute
    }

    func calculateQuick(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        opponentRange: OpponentRange.RangeType = .standard
    ) async -> Double {
        return await calculateDeep(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: 1_000_000, // Max iterations for Quick
            confidenceThreshold: 0.01, // 1.0% SE - fastest
            opponentRange: opponentRange
        )
    }

    func calculateDeep(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        iterations: Int,
        confidenceThreshold: Double = 0.005, // Default: 0.5% SE
        opponentRange: OpponentRange.RangeType = .standard
    ) async -> Double {
        PerformanceMonitor.shared.reportCalculation()

        // Range filtering ONLY for preflop heads-up situations:
        // 1. Multi-way pots: rejection sampling too slow (most deals rejected)
        // 2. Post-flop: opponents can have ANY hand that connected with the board
        //    (preflop hand rankings don't apply to post-flop betting)
        // GPU path is fast and accurate for all other situations
        let isPreflop = hand.communityCards.isEmpty
        let useRangeFiltering = isPreflop && opponentRange != .random && opponents == 1

        if !useRangeFiltering {
            // No range filtering needed - try GPU first (faster)
            let gpuMaxIterations = min(iterations, 2_000_000)

            if let metal = getMetalCompute() {
                PerformanceMonitor.shared.reportGPUActive(true)

                if let gpuResult = await metal.simulateGPU(
                    hand: hand,
                    opponents: opponents,
                    deadCards: deadCards,
                    iterations: gpuMaxIterations
                ), gpuResult > 0.001 {
                    PerformanceMonitor.shared.reportGPUActive(false)
                    PerformanceMonitor.shared.reportCalcInfo("GPU: \(gpuMaxIterations/1000)K → \(String(format: "%.1f", gpuResult * 100))%")
                    return gpuResult
                }

                PerformanceMonitor.shared.reportGPUActive(false)
                // GPU failed or timed out - fall through to CPU
            }

            // Metal not ready or GPU returned nil - use CPU fallback
            // IMPORTANT: Use .random to match GPU behavior (no range filtering)
            PerformanceMonitor.shared.reportCalcInfo("CPU (random)...")
            return await monteCarloEngine.simulate(
                hand: hand,
                opponents: opponents,
                deadCards: deadCards,
                iterations: iterations,
                opponentRange: .random,  // Match GPU: no range filtering for multi-way
                confidenceThreshold: confidenceThreshold,
                maxTimeSeconds: 10.0
            )
        }

        // CPU path with range filtering: only for heads-up preflop
        PerformanceMonitor.shared.reportCalcInfo("CPU (range filter)...")
        return await monteCarloEngine.simulate(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: iterations,
            opponentRange: opponentRange,
            confidenceThreshold: confidenceThreshold,
            maxTimeSeconds: 10.0
        )
    }
}
