import Foundation

/// Preflop equity cache, keyed on the suit-normalised hand.
///
/// **It is a cache and nothing else.** It used to compute its own misses, running a short
/// simulation and returning that — which meant the caller's fall-through was dead code and
/// the app's Calculation Depth setting never reached a preflop spot. Populating it is now
/// the caller's job, so the depth the user asked for is the depth that gets cached.
///
/// A stored value is permanent until the schema version changes, so whoever calls `store`
/// owes it enough samples to be worth freezing — `EquityCalculator` holds a floor for
/// exactly that reason. Note the shape of the trap it is guarding: `MonteCarloEngine`
/// stops at its first 50,000-hand batch for any confidence threshold at or above 0.0022,
/// because that is the standard error a 50,000 sample reaches at p ≈ 0.5. This table asked
/// for 200,000 at a threshold of 0.005 and got 50,000, then cached it forever.
///
/// Key format:  "PreflopEq_v4_\(handKey)_\(opponents)_\(range)"
/// Example key: "PreflopEq_v4_AKs_1_s"
public final class PreflopEquityTable {

    public static let shared = PreflopEquityTable()

    private let engine = MonteCarloEngine()
    private let defaults = UserDefaults.standard

    /// Bump this whenever the evaluator, the sampler, or the range model changes.
    /// Cached equities are permanent otherwise, so a corrected engine would never
    /// reach anyone who had already opened the app.
    private static let schemaVersion = 4
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
    public func cachedEquity(hand: Hand, opponents: Int, range: OpponentRange.RangeType) -> Double? {
        guard let key = cacheKey(hand: hand, opponents: opponents, range: range) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let v = memCache[key] { return v }
        let stored = defaults.object(forKey: prefix + key) as? Double
        if let v = stored { memCache[key] = v }
        return stored
    }

    /// Remember an equity computed elsewhere.
    ///
    /// Silently ignores hands it cannot key — anything with community cards, or a hand
    /// that is not exactly two cards — so a caller cannot accidentally file a flop under a
    /// preflop key.
    public func store(hand: Hand, opponents: Int, range: OpponentRange.RangeType, equity: Double) {
        guard equity > 0.001, let key = cacheKey(hand: hand, opponents: opponents, range: range) else { return }
        lock.lock()
        memCache[key] = equity
        lock.unlock()
        defaults.set(equity, forKey: prefix + key)
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
    public var cacheIdentifier: String {
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
