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

    /// The kernel returns early for any thread without a slot in the results buffer.
    /// The dispatch rounds up to whole threadgroups of 256, so this uses an iteration
    /// count whose thread count sits just past a boundary — 257 threads dispatched as
    /// 512 — where 255 threads must do nothing and the other 257 must all still run.
    ///
    /// The assertion is on the simulation *count*, not the equity. Equity cannot detect
    /// this: at 257,000 samples the standard error is ~0.0006, so a thread more or fewer
    /// moves the estimate far below any tolerance a Monte Carlo test can use. Writing the
    /// guard as `gid > threadCount` (one thread still writing past the buffer — the exact
    /// undefined behaviour it exists to remove) or as `gid >= threadCount - 1` (one thread
    /// silently skipped) both leave the equity indistinguishable, and both fail here.
    @Test("Every dispatched thread with a slot runs exactly once when the grid is rounded up")
    func partialThreadgroupRunsEveryThreadExactlyOnce() async throws {
        let flop = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d"))

        guard let metal = MetalCompute() else {
            Issue.record("No Metal device available on this host")
            return
        }

        // 257 threads at 1000 iterations each; 257 % 256 == 1.
        var result: MetalCompute.GPUResult? = nil
        for _ in 0..<60 {
            result = await metal.simulateGPUCounting(hand: flop, opponents: 1,
                                                     deadCards: [], iterations: 257_000)
            if result != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let gpu = try #require(result, "the kernel produced no results at all")

        #expect(gpu.simulations == 257_000,
                "257 threads × 1000 iterations should be 257,000 showdowns, got \(gpu.simulations)")

        let exact = try #require(ExactEnumerator().calculateFlop(hand: flop, opponents: 1,
                                                                deadCards: []))
        #expect(abs(gpu.equity - exact) < 0.01,
                "GPU \(gpu.equity) vs exact \(exact)")
    }

    /// A deck too short to deal cannot be answered, and the kernel used to answer it with
    /// 100%: its opponent loop breaks on the first seat, `bestOppValue` stays 0, and
    /// hero's real hand beats 0 every iteration. Every thread must now decline, which
    /// leaves no simulations and makes the host return nil so the caller falls back.
    @Test("A starved deck produces no GPU result rather than a confident one")
    func starvedDeckProducesNoGPUResult() async throws {
        let river = Hand(holeCards: cards("Ad Ac"), communityCards: cards("Ks 7h 2d 9c 4s"))
        let inPlay = river.allCards
        let dead = Set(Card.deck().filter { !inPlay.contains($0) })   // all 45 others

        guard let metal = MetalCompute() else {
            Issue.record("No Metal device available on this host")
            return
        }

        // Wait for the pipeline on a spot the GPU *can* answer, so a nil below means
        // "declined", not "not ready yet".
        var ready: Double? = nil
        for _ in 0..<60 {
            ready = await metal.simulateGPU(hand: river, opponents: 1,
                                            deadCards: [], iterations: 100_000)
            if ready != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = try #require(ready, "GPU never became ready")

        let starved = await metal.simulateGPUCounting(hand: river, opponents: 1,
                                                      deadCards: dead, iterations: 100_000)

        #expect(starved == nil,
                Comment(rawValue: "a deck with nothing left to deal returned "
                        + "\(starved?.equity ?? -1) from \(starved?.simulations ?? 0) simulations"))
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
