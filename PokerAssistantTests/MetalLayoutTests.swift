import Testing
import Foundation
import PokerCore
import PokerTestSupport
@testable import PokerAssistant

/// The Swift structs here and the ones in `Engine/PokerShaders.metal` are two
/// declarations of the same bytes. Nothing checks that they agree — the GPU simply
/// reads whatever is at each offset — so a field added to one and not the other
/// silently reinterprets every parameter after it.
///
/// The Metal side, for comparison:
///
///     struct SimulationParams {
///         uint iterations;      uint opponents;
///         uint holeCard1;       uint holeCard2;
///         uint communityCount;  uint community[5];
///         uint deadCount;       uint deadCards[52];
///         uint threadCount;
///     };
///     struct ThreadResult { uint equityUnits; uint total; };
@Suite("Metal struct layout")
struct MetalLayoutTests {

    @Test("ThreadResult is two 32-bit words")
    func threadResultLayout() {
        #expect(MemoryLayout<ThreadResult>.size == 8)
        #expect(MemoryLayout<ThreadResult>.stride == 8)
        #expect(MemoryLayout<ThreadResult>.alignment == 4)
    }

    /// 5 scalars + 5 community + 1 + 52 dead + 1 thread count = 64 words.
    @Test("SimulationParams is 64 contiguous 32-bit words")
    func simulationParamsLayout() {
        #expect(MemoryLayout<SimulationParams>.size == 64 * 4)
        #expect(MemoryLayout<SimulationParams>.stride == 64 * 4)
        #expect(MemoryLayout<SimulationParams>.alignment == 4)
    }

    /// The kernel bounds-checks against `threadCount`, so it has to survive the trip.
    /// If it lands at the wrong offset the kernel reads a card index as a thread count
    /// and either drops every thread or checks nothing at all.
    @Test("The thread count reaches the kernel at the end of the struct")
    func threadCountIsLastAndSurvivesEncoding() {
        var params = SimulationParams(
            iterations: 1_000_000, opponents: 1,
            hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
            deadCards: [],
            threadCount: 1000)

        #expect(params.threadCount == 1000)

        // Read it back the way the GPU does: the last word of the struct.
        withUnsafeBytes(of: &params) { raw in
            let words = raw.bindMemory(to: UInt32.self)
            #expect(words.count == 64)
            #expect(words[63] == 1000, "thread count is not the final word")
            #expect(words[0] == 1_000_000, "iterations is not the first word")
        }
    }
}
