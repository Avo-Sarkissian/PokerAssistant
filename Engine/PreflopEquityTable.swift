import Foundation

/// Lazy-build preflop equity cache.
///
/// On first request for a (handType, opponents, range) triple it runs a short
/// Monte Carlo simulation (200K iterations) and stores the result in UserDefaults.
/// Subsequent requests return the cached value instantly.
///
/// Key format:  "PreflopEq_\(handKey)_\(opponents)_\(range)"
/// Example key: "PreflopEq_AsKs_1_standard"
final class PreflopEquityTable {

    static let shared = PreflopEquityTable()

    private let engine = MonteCarloEngine()
    private let defaults = UserDefaults.standard

    /// Bump this whenever the evaluator, the sampler, or the range model changes.
    /// Cached equities are permanent otherwise, so a corrected engine would never
    /// reach anyone who had already opened the app.
    private static let schemaVersion = 3
    private let prefix = "PreflopEq_v\(PreflopEquityTable.schemaVersion)_"

    // In-memory cache so repeated same-session lookups skip UserDefaults entirely
    private var memCache: [String: Double] = [:]
    private let lock = NSLock()

    private init() {
        purgeStaleSchemas()
    }

    /// Drop equities written by an earlier engine so a fix actually takes effect.
    private func purgeStaleSchemas() {
        let stale = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("PreflopEq_") && !$0.hasPrefix(prefix)
        }
        for key in stale { defaults.removeObject(forKey: key) }
    }

    // MARK: – Public API

    /// Returns a cached preflop equity, or nil if not yet computed.
    /// Call `computeAndCache` asynchronously to populate the cache.
    func cachedEquity(hand: Hand, opponents: Int, range: OpponentRange.RangeType) -> Double? {
        guard let key = cacheKey(hand: hand, opponents: opponents, range: range) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let v = memCache[key] { return v }
        let stored = defaults.object(forKey: prefix + key) as? Double
        if let v = stored { memCache[key] = v }
        return stored
    }

    /// Checks the cache; if missing, runs a fast MC simulation and caches the result.
    func equity(hand: Hand, opponents: Int, range: OpponentRange.RangeType) async -> Double? {
        if let cached = cachedEquity(hand: hand, opponents: opponents, range: range) { return cached }
        guard let key = cacheKey(hand: hand, opponents: opponents, range: range) else { return nil }

        // Run a quick simulation (200K iterations converges to ~0.5% SE for preflop)
        let equity = await engine.simulate(
            hand: hand,
            opponents: opponents,
            deadCards: [],
            iterations: 200_000,
            opponentRange: range,
            confidenceThreshold: 0.005,
            maxTimeSeconds: 3.0
        )

        guard equity > 0.001 else { return nil }

        lock.lock()
        memCache[key] = equity
        lock.unlock()
        defaults.set(equity, forKey: prefix + key)

        return equity
    }

    // MARK: – Helpers

    /// Canonical key: suit-normalised hand (suited vs offsuit), e.g. "AKs" or "AKo".
    private func cacheKey(hand: Hand, opponents: Int, range: OpponentRange.RangeType) -> String? {
        guard hand.holeCards.count == 2, hand.communityCards.isEmpty else { return nil }
        let c1 = hand.holeCards[0], c2 = hand.holeCards[1]
        // Sort high-card first
        let (high, low) = c1.rank.rawValue >= c2.rank.rawValue ? (c1, c2) : (c2, c1)
        let suited = high.suit == low.suit ? "s" : "o"
        let handKey = "\(high.rank.tableSymbol)\(low.rank.tableSymbol)\(suited)"
        return "\(handKey)_\(opponents)_\(range.cacheIdentifier)"
    }
}

// MARK: - RangeType string identifier for cache keying

extension OpponentRange.RangeType {
    var cacheIdentifier: String {
        switch self {
        case .veryTight: return "vt"
        case .tight:     return "t"
        case .standard:  return "s"
        case .wide:      return "w"
        case .veryWide:  return "vw"
        case .random:    return "r"
        }
    }
}
