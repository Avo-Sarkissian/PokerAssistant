import Foundation

class EquityCalculator {
    // Lazy initialization - engines only initialize on first calculation, not app launch
    private lazy var monteCarloEngine = MonteCarloEngine()
    private lazy var metalCompute: MetalCompute? = MetalCompute()

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
            iterations: 50_000,
            opponentRange: opponentRange
        )
    }

    func calculateDeep(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        iterations: Int,
        opponentRange: OpponentRange.RangeType = .standard
    ) async -> Double {
        PerformanceMonitor.shared.reportCalculation()

        // When opponent has bet/raised, use CPU for accurate range filtering
        // GPU doesn't support range weighting, so CPU gives better accuracy
        let useRangeFiltering = opponentRange != .random

        if !useRangeFiltering {
            // No range filtering needed - GPU is faster and equally accurate
            let gpuMaxIterations = min(iterations, 2_000_000)

            if let metal = metalCompute {
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
            }
        }

        // CPU path: supports range filtering for better accuracy when opponent has acted
        // Cap CPU iterations to 50K when range filtering for speed (~3 seconds)
        let cpuIterations = useRangeFiltering ? min(iterations, 50_000) : iterations
        let rangeLabel = useRangeFiltering ? " [vs \(opponentRange)]" : ""
        PerformanceMonitor.shared.reportCalcInfo("CPU: \(cpuIterations / 1000)K\(rangeLabel)")
        return await monteCarloEngine.simulate(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: cpuIterations,
            opponentRange: opponentRange
        )
    }
}
