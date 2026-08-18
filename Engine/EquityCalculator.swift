import Foundation
import PokerCore

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

        // A card cannot be in two places. Nothing downstream will object: every engine
        // builds the remaining deck from a set of 0–51 indices, so the duplicate
        // collapses there while still being scored twice in hero's own hand. Measured,
        // that answered impossible deals with 85.6%, 99.95% and 89.3% — numbers the UI
        // presents exactly like a real one.
        guard !hand.hasDuplicateCards else { return 0.0 }
        guard deadCards.isDisjoint(with: hand.allCards) else { return 0.0 }

        // Enough deck must be left to run the board out and deal every opponent a hand.
        // The engines below each guard themselves now, but they disagree about what to
        // do when they cannot answer: the enumerators return nil, which this method
        // reads as "try the next engine". That fall-through is why this check has to
        // exist here as well — otherwise a starved deck reaches whichever engine happens
        // to be ready, and the answer depends on the hardware rather than the cards.
        let cardsInPlay = Set(hand.allCards).union(deadCards)
        let cardsNeeded = (5 - hand.communityCards.count) + opponents * 2
        guard 52 - cardsInPlay.count >= cardsNeeded else { return 0.0 }

        // Load-bearing beyond the counter it looks like: `reportCalculation` is the only
        // thing that starts the monitor's sampling timer, so deleting it blanks the whole
        // performance panel. If this file ever follows the engine into PokerCore, this
        // call needs an `EngineTelemetrySink` requirement to survive the move.
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

        // Postflop the inferred range is NOT applied. `OpponentRange` is a preflop
        // starting-hand chart with no continuation model, so filtering a postflop
        // showdown by it keeps the broadway hands that would have folded the flop and
        // deletes the connected hands that actually bet. Measured on 3c3d / 8s7h6d2c4h,
        // that inverts the relationship: hero reads 35.4% against a random hand and
        // 68.4% against a "tight" one, so a bigger villain bet raises hero's equity.
        // The enumerators support ranges (see ExactEnumerator); only the routing is
        // gated, until there is a board-conditioned continuation model.
        let postflopRange: OpponentRange.RangeType = .random

        switch hand.street {

        case .river:
            if let equity = exact.calculateRiver(hand: hand, opponents: opponents, deadCards: deadCards, opponentRange: postflopRange) {
                let method = opponents == 1 ? "Exact river" : "Exact river 2-opp"
                PerformanceMonitor.shared.reportCalcInfo("\(method) → \(String(format: "%.1f", equity * 100))%")
                return equity
            }
            // 3+ opponents: fall through to GPU MC

        case .turn:
            if let equity = exact.calculateTurn(hand: hand, opponents: opponents, deadCards: deadCards, opponentRange: postflopRange) {
                PerformanceMonitor.shared.reportCalcInfo("Exact turn → \(String(format: "%.1f", equity * 100))%")
                return equity
            }
            // 2+ opponents: fall through to GPU MC

        case .flop:
            // Exact flop enumeration for 1-opp heads-up (~300–500 ms, provably correct)
            if let equity = exact.calculateFlop(hand: hand, opponents: opponents, deadCards: deadCards, opponentRange: postflopRange) {
                PerformanceMonitor.shared.reportCalcInfo("Exact flop → \(String(format: "%.1f", equity * 100))%")
                return equity
            }
            // 2+ opponents: fall through to GPU MC

        case .preflop:
            // A lookup and nothing more. The table used to compute its own misses and
            // return the result, which made everything below this point unreachable
            // preflop — so the comment that used to sit here, promising a
            // higher-accuracy run on a miss, described code that never ran, and the
            // Calculation Depth setting never applied to a preflop spot at all.
            //
            // Pass the caller's range through untouched. Substituting `.standard` for
            // `.random` answered a different question than the one asked: with no bet
            // in front of them, the user is asking about a random hand, not a raiser.
            if let cached = PreflopEquityTable.shared.cachedEquity(
                hand: hand,
                opponents: opponents,
                range: opponentRange
            ) {
                PerformanceMonitor.shared.reportCalcInfo("Preflop table → \(String(format: "%.1f", cached * 100))%")
                return cached
            }
            // Miss: fall through, compute at the caller's depth, and cache that.
        }

        let isPreflop = hand.communityCards.isEmpty

        // ── Range filtering decides the engine, not the other way round ────
        //
        // The GPU kernel has no range filter (backlog #31), so it may only be used when
        // the answer does not depend on one. This used to also require `opponents == 1`,
        // which was harmless only because the preflop table absorbed every multiway
        // request before it got here — with the fall-through live, that condition would
        // have sent range-conditioned multiway preflop spots to a kernel that silently
        // ignores the range. Correct and slower beats fast and wrong.
        let useRangeFiltering = isPreflop && opponentRange != .random

        // A cached preflop equity is permanent until the schema version changes, so it is
        // never computed at less than the floor the table itself used to apply. A deeper
        // setting still wins; a shallower one cannot poison the cache. Note the threshold:
        // anything at or above 0.0022 stops `MonteCarloEngine` after its first 50,000-hand
        // batch, and the app's own default is 0.005.
        let sampleCount = isPreflop ? max(iterations, 200_000) : iterations
        let precision = isPreflop ? min(confidenceThreshold, 0.001) : confidenceThreshold

        func remember(_ equity: Double) -> Double {
            if isPreflop {
                PreflopEquityTable.shared.store(hand: hand, opponents: opponents,
                                                range: opponentRange, equity: equity)
            }
            return equity
        }

        // ── GPU Monte Carlo ───────────────────────────────────────────────
        if !useRangeFiltering {
            let gpuIterations = min(sampleCount, 2_000_000)
            if let metal = getMetalCompute(),
               let result = await metal.simulateGPU(hand: hand, opponents: opponents,
                                                     deadCards: deadCards, iterations: gpuIterations),
               result > 0.001 {
                PerformanceMonitor.shared.reportCalcInfo("GPU MC \(gpuIterations / 1000)K → \(String(format: "%.1f", result * 100))%")
                return remember(result)
            }
        }

        // ── CPU Monte Carlo fallback ──────────────────────────────────────
        let range: OpponentRange.RangeType = useRangeFiltering ? opponentRange : .random
        PerformanceMonitor.shared.reportCalcInfo("CPU MC (range: \(range))...")
        return remember(await monteCarloEngine.simulate(
            hand: hand,
            opponents: opponents,
            deadCards: deadCards,
            iterations: sampleCount,
            opponentRange: range,
            confidenceThreshold: precision,
            maxTimeSeconds: 10.0
        ))
    }
}
