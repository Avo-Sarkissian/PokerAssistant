import Foundation

class EquityCalculator {
    private let monteCarloEngine = MonteCarloEngine()
    private let metalCompute = MetalCompute()
    
    func calculateQuick(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>
    ) async -> Double {
        return await calculateDeep(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: 50_000
        )
    }
    
    func calculateDeep(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        iterations: Int
    ) async -> Double {
        PerformanceMonitor.shared.reportCalculation()
        
        // Try GPU first (but cap iterations to prevent timeout)
        let gpuMaxIterations = min(iterations, 500_000)
        
        if let metal = metalCompute {
            PerformanceMonitor.shared.reportGPUActive(true)
            
            if let gpuResult = await metal.simulateGPU(
                hand: hand,
                opponents: opponents,
                deadCards: deadCards,
                iterations: gpuMaxIterations
            ), gpuResult > 0.001 {
                PerformanceMonitor.shared.reportGPUActive(false)
                MetalCompute.lastDebugInfo = "GPU OK: \(String(format: "%.1f", gpuResult * 100))%"
                return gpuResult
            }
            
            PerformanceMonitor.shared.reportGPUActive(false)
        }
        
        // CPU fallback - always works
        MetalCompute.lastDebugInfo = "CPU mode (\(iterations / 1000)K iters)"
        return await monteCarloEngine.simulate(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: iterations
        )
    }
}
