import Foundation
import Metal
import MetalPerformanceShaders

class MetalCompute {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var computePipeline: MTLComputePipelineState?
    private var pipelineSetupComplete = false
    private let pipelineLock = NSLock()

    // For debug output
    static var lastDebugInfo: String = "No GPU run yet"

    // Constants
    private let threadsPerThreadgroup = 256
    private let iterationsPerThread = 1000

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            MetalCompute.lastDebugInfo = "Metal not supported"
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        MetalCompute.lastDebugInfo = "GPU: \(device.name)"

        // Start shader compilation in background immediately
        // This way it's ready by the time user presses Calculate
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.ensurePipelineReady()
        }
    }

    /// Ensure pipeline is ready (compile on first use) - thread-safe
    /// Called from background thread during init to compile shader
    @discardableResult
    private func ensurePipelineReady() -> Bool {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }

        if pipelineSetupComplete {
            return computePipeline != nil
        }
        pipelineSetupComplete = true
        setupPipelines()
        return computePipeline != nil
    }

    /// Non-blocking check if pipeline is ready
    /// Returns false immediately if lock is held (shader still compiling)
    /// This prevents calculation thread from blocking on shader compilation
    private func isPipelineReady() -> Bool {
        // Try to acquire lock without blocking
        guard pipelineLock.try() else {
            // Lock is held by shader compilation thread - not ready
            MetalCompute.lastDebugInfo = "GPU: Shader compiling..."
            return false
        }
        defer { pipelineLock.unlock() }

        // Check if pipeline was successfully created
        return pipelineSetupComplete && computePipeline != nil
    }
    
    private func setupPipelines() {
        // Use PRE-COMPILED shader from PokerShaders.metal
        // This is compiled at BUILD time by Xcode, not at runtime
        // Eliminates the 5-10 second runtime compilation delay
        do {
            // Get the default library which contains pre-compiled .metal shaders
            guard let library = device.makeDefaultLibrary() else {
                MetalCompute.lastDebugInfo += " | No default library"
                return
            }

            if let function = library.makeFunction(name: "monteCarloPoker") {
                computePipeline = try device.makeComputePipelineState(function: function)
                MetalCompute.lastDebugInfo += " | Pipeline OK (precompiled)"
            } else {
                MetalCompute.lastDebugInfo += " | Function not found"
            }
        } catch {
            MetalCompute.lastDebugInfo += " | Error: \(error.localizedDescription)"
        }
    }
    
    func simulateGPU(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        iterations: Int
    ) async -> Double? {
        // NON-BLOCKING check: If shader is still compiling, return nil immediately
        // Caller will fall back to CPU - don't block the calculation thread
        guard isPipelineReady(), let pipeline = computePipeline else {
            // Pipeline not ready - caller should use CPU fallback
            return nil
        }

        let totalThreads = max(1, iterations / iterationsPerThread)

        // Create results buffer - one slot per thread
        guard let resultsBuffer = device.makeBuffer(
            length: MemoryLayout<ThreadResult>.stride * totalThreads,
            options: .storageModeShared
        ) else {
            MetalCompute.lastDebugInfo = "Results buffer failed"
            return nil
        }

        // Create and fill random seeds buffer
        guard let randomBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.size * totalThreads,
            options: .storageModeShared
        ) else {
            MetalCompute.lastDebugInfo = "Random buffer failed"
            return nil
        }

        let randomPtr = randomBuffer.contents().bindMemory(to: UInt32.self, capacity: totalThreads)
        for i in 0..<totalThreads {
            randomPtr[i] = UInt32.random(in: 1..<UInt32.max)
        }

        // Create params
        var params = SimulationParams(
            iterations: UInt32(iterations),
            opponents: UInt32(opponents),
            hand: hand,
            deadCards: deadCards
        )

        guard let paramsBuffer = device.makeBuffer(
            bytes: &params,
            length: MemoryLayout<SimulationParams>.size,
            options: .storageModeShared
        ) else {
            MetalCompute.lastDebugInfo = "Params buffer failed"
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            MetalCompute.lastDebugInfo = "Command buffer failed"
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(resultsBuffer, offset: 0, index: 0)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 1)
        encoder.setBuffer(randomBuffer, offset: 0, index: 2)

        let threadgroupsPerGrid = (totalThreads + threadsPerThreadgroup - 1) / threadsPerThreadgroup

        encoder.dispatchThreadgroups(
            MTLSize(width: threadgroupsPerGrid, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1)
        )
        encoder.endEncoding()

        MetalCompute.lastDebugInfo = "Threads: \(totalThreads), Groups: \(threadgroupsPerGrid)"

        // Use timeout to prevent GPU hangs from freezing the app
        return await withGPUTimeout(commandBuffer: commandBuffer, resultsBuffer: resultsBuffer, totalThreads: totalThreads)
    }

    /// Execute GPU command with timeout - prevents infinite hangs
    /// FIXED: Returns immediately when timeout fires, doesn't wait for GPU
    private func withGPUTimeout(
        commandBuffer: MTLCommandBuffer,
        resultsBuffer: MTLBuffer,
        totalThreads: Int,
        timeoutSeconds: Double = 5.0
    ) async -> Double? {
        // Use a simple race between GPU completion and timeout
        // CRITICAL: Return immediately when first result arrives
        return await withTaskGroup(of: Double?.self) { group in
            // GPU completion task
            group.addTask {
                await withCheckedContinuation { continuation in
                    commandBuffer.addCompletedHandler { [resultsBuffer, totalThreads] buffer in
                        if let error = buffer.error {
                            MetalCompute.lastDebugInfo = "GPU Error: \(error.localizedDescription)"
                            continuation.resume(returning: nil)
                            return
                        }

                        // Sum up all thread results
                        let resultsPtr = resultsBuffer.contents().bindMemory(to: ThreadResult.self, capacity: totalThreads)

                        var totalWins: UInt64 = 0
                        var totalTies: UInt64 = 0
                        var totalSims: UInt64 = 0

                        for i in 0..<totalThreads {
                            totalWins += UInt64(resultsPtr[i].wins)
                            totalTies += UInt64(resultsPtr[i].ties)
                            totalSims += UInt64(resultsPtr[i].total)
                        }

                        MetalCompute.lastDebugInfo = "W:\(totalWins) T:\(totalTies) N:\(totalSims)"

                        if totalSims > 0 {
                            let equity = Double(totalWins) / Double(totalSims) +
                                        (Double(totalTies) / Double(totalSims) * 0.5)
                            continuation.resume(returning: min(1.0, max(0.0, equity)))
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                    commandBuffer.commit()
                }
            }

            // Timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil
            }

            // Take FIRST result only - immediately return, don't wait for second
            let first = await group.next()
            group.cancelAll()

            if let result = first, result != nil {
                return result
            }

            MetalCompute.lastDebugInfo = "GPU timeout after \(timeoutSeconds)s"
            return nil
        }
    }
}

// Must match Metal struct exactly
private struct ThreadResult {
    var wins: UInt32 = 0
    var ties: UInt32 = 0
    var total: UInt32 = 0
}

private struct SimulationParams {
    var iterations: UInt32
    var opponents: UInt32
    var holeCard1: UInt32
    var holeCard2: UInt32
    var communityCount: UInt32
    var community: (UInt32, UInt32, UInt32, UInt32, UInt32)
    var deadCount: UInt32
    var deadCards: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                    UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                    UInt32, UInt32, UInt32, UInt32)
    
    init(iterations: UInt32, opponents: UInt32, hand: Hand, deadCards: Set<Card>) {
        self.iterations = iterations
        self.opponents = opponents
        
        self.holeCard1 = UInt32(hand.holeCards[0].rank.rawValue - 2) * 4 + UInt32(hand.holeCards[0].suit.suitIndex)
        self.holeCard2 = UInt32(hand.holeCards[1].rank.rawValue - 2) * 4 + UInt32(hand.holeCards[1].suit.suitIndex)
        
        self.communityCount = UInt32(hand.communityCards.count)
        var comm = [UInt32](repeating: 0, count: 5)
        for (i, card) in hand.communityCards.enumerated() {
            comm[i] = UInt32(card.rank.rawValue - 2) * 4 + UInt32(card.suit.suitIndex)
        }
        self.community = (comm[0], comm[1], comm[2], comm[3], comm[4])
        
        self.deadCount = UInt32(deadCards.count)
        var dead = [UInt32](repeating: 0, count: 52)
        for (i, card) in deadCards.enumerated() {
            dead[i] = UInt32(card.rank.rawValue - 2) * 4 + UInt32(card.suit.suitIndex)
        }
        
        self.deadCards = (
            dead[0], dead[1], dead[2], dead[3], dead[4], dead[5], dead[6], dead[7],
            dead[8], dead[9], dead[10], dead[11], dead[12], dead[13], dead[14], dead[15],
            dead[16], dead[17], dead[18], dead[19], dead[20], dead[21], dead[22], dead[23],
            dead[24], dead[25], dead[26], dead[27], dead[28], dead[29], dead[30], dead[31],
            dead[32], dead[33], dead[34], dead[35], dead[36], dead[37], dead[38], dead[39],
            dead[40], dead[41], dead[42], dead[43], dead[44], dead[45], dead[46], dead[47],
            dead[48], dead[49], dead[50], dead[51]
        )
    }
}
