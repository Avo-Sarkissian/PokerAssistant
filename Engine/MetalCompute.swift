import Foundation
import Metal
import MetalPerformanceShaders

class MetalCompute {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var computePipeline: MTLComputePipelineState?
    
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
        
        setupPipelines()
        
        MetalCompute.lastDebugInfo = "GPU: \(device.name)"
    }
    
    private func setupPipelines() {
        // Simplified shader - each thread writes to its own result slot
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct SimulationParams {
            uint iterations;
            uint opponents;
            uint holeCard1;
            uint holeCard2;
            uint communityCount;
            uint community[5];
            uint deadCount;
            uint deadCards[52];
        };
        
        // Each thread writes to its own slot
        struct ThreadResult {
            uint wins;
            uint ties;
            uint total;
        };
        
        uint evaluate5Cards(uint c0, uint c1, uint c2, uint c3, uint c4) {
            uint r[5], s[5];
            r[0] = (c0 >> 2) + 2;
            r[1] = (c1 >> 2) + 2;
            r[2] = (c2 >> 2) + 2;
            r[3] = (c3 >> 2) + 2;
            r[4] = (c4 >> 2) + 2;
            s[0] = c0 & 3;
            s[1] = c1 & 3;
            s[2] = c2 & 3;
            s[3] = c3 & 3;
            s[4] = c4 & 3;
            
            for (int i = 0; i < 4; i++) {
                for (int j = i + 1; j < 5; j++) {
                    if (r[j] > r[i]) {
                        uint temp = r[i]; r[i] = r[j]; r[j] = temp;
                        temp = s[i]; s[i] = s[j]; s[j] = temp;
                    }
                }
            }
            
            bool isFlush = (s[0] == s[1]) && (s[1] == s[2]) && (s[2] == s[3]) && (s[3] == s[4]);
            bool isStraight = (r[0] - r[4] == 4) && (r[0] != r[1]) && (r[1] != r[2]) && (r[2] != r[3]) && (r[3] != r[4]);
            bool isWheel = (r[0] == 14 && r[1] == 5 && r[2] == 4 && r[3] == 3 && r[4] == 2);
            if (isWheel) isStraight = true;
            
            if (isFlush && isStraight) return 8000000 + (isWheel ? 5 : r[0]);
            
            uint counts[15] = {0};
            for (int i = 0; i < 5; i++) counts[r[i]]++;
            
            uint quadRank = 0, tripRank = 0, pairRanks[2] = {0, 0}, numPairs = 0;
            
            for (int rank = 14; rank >= 2; rank--) {
                if (counts[rank] == 4) quadRank = rank;
                else if (counts[rank] == 3) tripRank = rank;
                else if (counts[rank] == 2 && numPairs < 2) pairRanks[numPairs++] = rank;
            }
            
            if (quadRank > 0) {
                uint kicker = 0;
                for (int i = 0; i < 5; i++) if (r[i] != quadRank) { kicker = r[i]; break; }
                return 7000000 + quadRank * 100 + kicker;
            }
            if (tripRank > 0 && numPairs > 0) return 6000000 + tripRank * 100 + pairRanks[0];
            if (isFlush) return 5000000 + (r[0] << 16) + (r[1] << 12) + (r[2] << 8) + (r[3] << 4) + r[4];
            if (isStraight) return 4000000 + (isWheel ? 5 : r[0]);
            if (tripRank > 0) {
                uint k[2]; int ki = 0;
                for (int i = 0; i < 5 && ki < 2; i++) if (r[i] != tripRank) k[ki++] = r[i];
                return 3000000 + tripRank * 10000 + k[0] * 100 + k[1];
            }
            if (numPairs >= 2) {
                uint kicker = 0;
                for (int i = 0; i < 5; i++) if (r[i] != pairRanks[0] && r[i] != pairRanks[1]) { kicker = r[i]; break; }
                return 2000000 + pairRanks[0] * 10000 + pairRanks[1] * 100 + kicker;
            }
            if (numPairs == 1) {
                uint k[3]; int ki = 0;
                for (int i = 0; i < 5 && ki < 3; i++) if (r[i] != pairRanks[0]) k[ki++] = r[i];
                return 1000000 + pairRanks[0] * 100000 + k[0] * 1000 + k[1] * 10 + k[2];
            }
            return (r[0] << 16) + (r[1] << 12) + (r[2] << 8) + (r[3] << 4) + r[4];
        }
        
        uint evaluateHand7(uint cards[7]) {
            uint best = 0;
            for (int skip1 = 0; skip1 < 6; skip1++) {
                for (int skip2 = skip1 + 1; skip2 < 7; skip2++) {
                    uint hand[5]; int hi = 0;
                    for (int k = 0; k < 7; k++) {
                        if (k != skip1 && k != skip2) hand[hi++] = cards[k];
                    }
                    uint val = evaluate5Cards(hand[0], hand[1], hand[2], hand[3], hand[4]);
                    if (val > best) best = val;
                }
            }
            return best;
        }
        
        kernel void monteCarloPoker(
            device ThreadResult* results [[buffer(0)]],
            constant SimulationParams* params [[buffer(1)]],
            device uint* randomSeeds [[buffer(2)]],
            uint gid [[thread_position_in_grid]]
        ) {
            uint seed = randomSeeds[gid] ^ (gid * 1099087573u) ^ 0xDEADBEEF;
            
            // Build available cards array
            uint availableCards[52];
            uint availableCount = 0;
            
            bool isUsed[52] = {false};
            isUsed[params->holeCard1] = true;
            isUsed[params->holeCard2] = true;
            
            for (uint i = 0; i < params->communityCount; i++) {
                isUsed[params->community[i]] = true;
            }
            for (uint i = 0; i < params->deadCount; i++) {
                isUsed[params->deadCards[i]] = true;
            }
            
            for (uint i = 0; i < 52; i++) {
                if (!isUsed[i]) availableCards[availableCount++] = i;
            }
            
            uint wins = 0, ties = 0;
            
            for (uint iter = 0; iter < 1000; iter++) {
                // Fisher-Yates shuffle
                uint shuffled[52];
                for (uint i = 0; i < availableCount; i++) shuffled[i] = availableCards[i];
                
                for (uint i = availableCount - 1; i > 0; i--) {
                    seed = seed * 1664525u + 1013904223u;
                    uint j = seed % (i + 1);
                    uint temp = shuffled[i];
                    shuffled[i] = shuffled[j];
                    shuffled[j] = temp;
                }
                
                // Build my hand
                uint myHand[7];
                myHand[0] = params->holeCard1;
                myHand[1] = params->holeCard2;
                
                uint cardIndex = 0;
                for (uint i = 0; i < params->communityCount; i++) {
                    myHand[2 + i] = params->community[i];
                }
                for (uint i = params->communityCount; i < 5; i++) {
                    myHand[2 + i] = shuffled[cardIndex++];
                }
                
                uint myValue = evaluateHand7(myHand);
                
                // Evaluate opponents
                uint bestOppValue = 0;
                for (uint opp = 0; opp < params->opponents; opp++) {
                    if (cardIndex + 1 >= availableCount) break;
                    
                    uint oppHand[7];
                    oppHand[0] = shuffled[cardIndex++];
                    oppHand[1] = shuffled[cardIndex++];
                    for (uint i = 0; i < 5; i++) oppHand[2 + i] = myHand[2 + i];
                    
                    uint oppValue = evaluateHand7(oppHand);
                    if (oppValue > bestOppValue) bestOppValue = oppValue;
                }
                
                if (myValue > bestOppValue) wins++;
                else if (myValue == bestOppValue) ties++;
            }
            
            // Write to this thread's slot
            results[gid].wins = wins;
            results[gid].ties = ties;
            results[gid].total = 1000;
        }
        """
        
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            if let function = library.makeFunction(name: "monteCarloPoker") {
                computePipeline = try device.makeComputePipelineState(function: function)
                MetalCompute.lastDebugInfo += " | Pipeline OK"
            } else {
                MetalCompute.lastDebugInfo += " | Function failed"
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
        guard let pipeline = computePipeline else {
            MetalCompute.lastDebugInfo = "No pipeline"
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
        
        return await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { [resultsBuffer, totalThreads] buffer in
                if let error = buffer.error {
                    MetalCompute.lastDebugInfo = "GPU Error: \(error.localizedDescription)"
                    continuation.resume(returning: 0.0)
                    return
                }
                
                // Sum up all thread results on CPU
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
                    continuation.resume(returning: 0.0)
                }
            }
            commandBuffer.commit()
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
