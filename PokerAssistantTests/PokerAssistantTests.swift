//
//  PokerAssistantTests.swift
//  PokerAssistantTests
//
//  Hand evaluation, starting-hand rankings, equity and exact enumeration all live in
//  `PokerCoreTests` now — they need no simulator, so keeping them here only made them
//  slower to run. What remains is what genuinely needs the app: the Metal kernel.
//

import Testing
import Foundation
import PokerCore
import PokerTestSupport
@testable import PokerAssistant

// MARK: - GPU / CPU agreement

@Suite("GPU and CPU agreement", .timeLimit(.minutes(3)))
struct GPUConsistencyTests {

    /// The GPU kernel and the exact enumerator must answer the same question the same
    /// way. Exact enumeration is provably correct, so any gap here is the shader's.
    @Test("GPU Monte Carlo matches exact flop enumeration")
    func gpuMatchesExactEnumeration() async throws {
        let flop = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d"))

        guard let metal = MetalCompute() else {
            Issue.record("No Metal device available on this host")
            return
        }

        // The pipeline compiles on a background queue; give it a moment to become ready.
        var gpuEquity: Double? = nil
        for _ in 0..<60 {
            gpuEquity = await metal.simulateGPU(hand: flop, opponents: 1,
                                                deadCards: [], iterations: 2_000_000)
            if gpuEquity != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let gpu = try #require(gpuEquity, "GPU never became ready")
        let exact = try #require(ExactEnumerator().calculateFlop(hand: flop, opponents: 1,
                                                                deadCards: []))

        #expect(abs(gpu - exact) < 0.005,
                "GPU \(gpu) vs exact \(exact) — delta \(abs(gpu - exact))")
    }

    /// On a board nobody can beat, every showdown is an n-way chop, so the answer is
    /// entirely determined by how the engine splits a tied pot. Crediting a flat half
    /// makes hero's share look like 50% however many players are in.
    @Test("GPU splits multiway chops by how many players share the pot")
    func gpuSplitsMultiwayChops() async throws {
        // Broadway straight on board, unpaired, no flush possible: unbeatable.
        let river = Hand(holeCards: cards("2c 3d"), communityCards: cards("As Ks Qh Jd Th"))

        guard let metal = MetalCompute() else {
            Issue.record("No Metal device available on this host")
            return
        }

        var gpuEquity: Double? = nil
        for _ in 0..<60 {
            gpuEquity = await metal.simulateGPU(hand: river, opponents: 2,
                                                deadCards: [], iterations: 1_000_000)
            if gpuEquity != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let gpu = try #require(gpuEquity, "GPU never became ready")
        let exact = try #require(ExactEnumerator().calculateRiver(hand: river, opponents: 2,
                                                                 deadCards: []))

        // Three players, one pot: a third each.
        #expect(abs(exact - 1.0 / 3.0) < 1e-9, "enumerator gave \(exact)")
        #expect(abs(gpu - exact) < 0.005,
                "GPU \(gpu) vs exact \(exact) — a flat half-pot credit gives 0.5")
    }
}
