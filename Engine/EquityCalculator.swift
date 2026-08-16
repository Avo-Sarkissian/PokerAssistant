import Foundation

class EquityCalculator {

    // ── Engines ────────────────────────────────────────────────────────────

    /// Exact enumerator: used for river (1–2 opponents) and turn (1 opponent).
    /// Returns provably correct equity with zero approximation error.
    private let exact = ExactEnumerator()

    /// GPU Monte Carlo: used for flop and for situations where exact
    /// enumeration would exceed the 3-second budget.
    private var metalCompute: MetalCompute?
    private var metalInitStarted = false
    private let metalLock = NSLock()

    /// CPU Monte Carlo: fallback when GPU is unavailable.
    private lazy var monteCarloEngine = MonteCarloEngine()

    init() {
        startMetalInitInBackground()
    }

    private func startMetalInitInBackground() {
        metalLock.lock()
        guard !metalInitStarted else { metalLock.unlock(); return }
        metalInitStarted = true
        metalLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metal = MetalCompute()
            self?.metalLock.lock()
            self?.metalCompute = metal
            self?.metalLock.unlock()
        }
    }

    private func getMetalCompute() -> MetalCompute? {
        guard metalLock.try() else { return nil }
        defer { metalLock.unlock() }
        return metalCompute
    }

    // MARK: – Public API

    func calculateQuick(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        opponentRange: OpponentRange.RangeType = .standard
    ) async -> Double {
        await calculateDeep(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: 1_000_000,
            confidenceThreshold: 0.01,
            opponentRange: opponentRange
        )
    }

    func calculateDeep(
        hand: Hand,
        opponents: Int,
        deadCards: Set<Card>,
        iterations: Int,
        confidenceThreshold: Double = 0.005,
        opponentRange: OpponentRange.RangeType = .standard
    ) async -> Double {
        guard hand.holeCards.count == 2    else { return 0.0 }
        guard hand.communityCards.count <= 5 else { return 0.0 }
        guard opponents >= 1               else { return 0.0 }

        PerformanceMonitor.shared.reportCalculation()

        // ── Routing ───────────────────────────────────────────────────────
        //
        // Exact enumeration (no randomness, provably correct):
        //   River, 1 opp  → ~990 evals   — sub-millisecond
        //   River, 2 opp  → ~447K evals  — ~200–500 ms
        //   Turn,  1 opp  → ~47K evals   — ~50 ms
        //
        // GPU Monte Carlo (fast approximation for everything else):
        //   Flop (any), Turn 2+ opp, River 3+ opp, Preflop (with range filtering)

        switch hand.street {

        case .river:
            if let equity = exact.calculateRiver(hand: hand, opponents: opponents, deadCards: deadCards) {
                let method = opponents == 1 ? "Exact river" : "Exact river 2-opp"
                PerformanceMonitor.shared.reportCalcInfo("\(method) → \(String(format: "%.1f", equity * 100))%")
                return equity
            }
            // 3+ opponents: fall through to GPU MC

        case .turn:
            if let equity = exact.calculateTurn(hand: hand, opponents: opponents, deadCards: deadCards) {
                PerformanceMonitor.shared.reportCalcInfo("Exact turn → \(String(format: "%.1f", equity * 100))%")
                return equity
            }
            // 2+ opponents: fall through to GPU MC

        case .flop:
            // Exact flop enumeration for 1-opp heads-up (~300–500 ms, provably correct)
            if let equity = exact.calculateFlop(hand: hand, opponents: opponents, deadCards: deadCards) {
                PerformanceMonitor.shared.reportCalcInfo("Exact flop → \(String(format: "%.1f", equity * 100))%")
                return equity
            }
            // 2+ opponents: fall through to GPU MC

        case .preflop:
            // Check preflop lookup table first (instant if cached)
            // Pass the caller's range through untouched. Substituting `.standard` for
            // `.random` answered a different question than the one asked: with no bet
            // in front of them, the user is asking about a random hand, not a raiser.
            if let cached = await PreflopEquityTable.shared.equity(
                hand: hand,
                opponents: opponents,
                range: opponentRange
            ) {
                PerformanceMonitor.shared.reportCalcInfo("Preflop table → \(String(format: "%.1f", cached * 100))%")
                return cached
            }
            // Cache miss (or first run): the table ran a quick sim to warm the cache.
            // Continue to GPU/CPU MC below for a higher-accuracy result this session.
        }

        // ── GPU Monte Carlo ───────────────────────────────────────────────
        // Range filtering only for preflop heads-up (see reasoning in comments below)
        let isPreflop = hand.communityCards.isEmpty
        let useRangeFiltering = isPreflop && opponentRange != .random && opponents == 1

        if !useRangeFiltering {
            let gpuIterations = min(iterations, 2_000_000)
            if let metal = getMetalCompute(),
               let result = await metal.simulateGPU(hand: hand, opponents: opponents,
                                                     deadCards: deadCards, iterations: gpuIterations),
               result > 0.001 {
                PerformanceMonitor.shared.reportCalcInfo("GPU MC \(gpuIterations / 1000)K → \(String(format: "%.1f", result * 100))%")
                return result
            }
        }

        // ── CPU Monte Carlo fallback ──────────────────────────────────────
        let range: OpponentRange.RangeType = useRangeFiltering ? opponentRange : .random
        PerformanceMonitor.shared.reportCalcInfo("CPU MC (range: \(range))...")
        return await monteCarloEngine.simulate(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: iterations,
            opponentRange: range,
            confidenceThreshold: confidenceThreshold,
            maxTimeSeconds: 10.0
        )
    }
}
