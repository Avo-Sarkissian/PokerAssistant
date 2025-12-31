import Foundation

class PokerIntelligence {
    static let shared = PokerIntelligence()
    
    // NO INIT required - Instant startup
    // We removed the heavy lookup table generation entirely.
    
    // MARK: - Fast Logical Evaluation
    
    func evaluate7(_ cards: [Card]) -> Int32 {
        guard cards.count >= 5 else { return 0 }
        
        var best: Int32 = 0
        let c = cards
        
        // 5-from-7 combinations manually unrolled for speed
        for i in 0..<6 {
            for j in (i+1)..<7 {
                var temp5: [Card] = []
                temp5.reserveCapacity(5)
                for k in 0..<7 {
                    if k == i || k == j { continue }
                    temp5.append(c[k])
                }
                
                let val = evaluate5(temp5)
                if val > best { best = val }
            }
        }
        return best
    }
    
    func evaluate5(_ cards: [Card]) -> Int32 {
        // Sort for logic checks
        let sorted = cards.sorted { $0.rank.rawValue > $1.rank.rawValue }
        
        let isFlush = (sorted[0].suit == sorted[1].suit) &&
                      (sorted[1].suit == sorted[2].suit) &&
                      (sorted[2].suit == sorted[3].suit) &&
                      (sorted[3].suit == sorted[4].suit)
        
        let r0 = sorted[0].rank.rawValue
        let r1 = sorted[1].rank.rawValue
        let r2 = sorted[2].rank.rawValue
        let r3 = sorted[3].rank.rawValue
        let r4 = sorted[4].rank.rawValue
        
        let isStraight = (r0 - r4 == 4) ||
                         (r0 == 14 && r1 == 5 && r2 == 4 && r3 == 3 && r4 == 2) // Wheel A-5
        
        // Straight Flush
        if isFlush && isStraight {
            return 8_000_000 + Int32(r0 == 14 && r1 == 5 ? 5 : r0)
        }
        
        // Count Ranks
        var counts: [Int: Int] = [:]
        for c in sorted { counts[c.rank.rawValue, default: 0] += 1 }
        
        let pairs = counts.filter { $0.value == 2 }.keys.sorted(by: >)
        let trips = counts.filter { $0.value == 3 }.keys.first
        let quads = counts.filter { $0.value == 4 }.keys.first
        
        // Quads
        if let q = quads {
            let k = counts.filter { $0.value == 1 }.keys.first ?? 0
            return 7_000_000 + Int32(q * 100 + k)
        }
        
        // Full House
        if let t = trips, let p = pairs.first {
            return 6_000_000 + Int32(t * 100 + p)
        }
        
        // Flush
        if isFlush {
            return 5_000_000 + valueFromRanks(r0, r1, r2, r3, r4)
        }
        
        // Straight
        if isStraight {
            return 4_000_000 + Int32(r0 == 14 && r1 == 5 ? 5 : r0)
        }
        
        // Trips
        if let t = trips {
            let kickers = sorted.filter { $0.rank.rawValue != t }.map { $0.rank.rawValue }
            return 3_000_000 + Int32(t * 10000) + Int32(kickers[0] * 100 + kickers[1])
        }
        
        // Two Pair
        if pairs.count >= 2 {
            let p1 = pairs[0]
            let p2 = pairs[1]
            let k = sorted.first { $0.rank.rawValue != p1 && $0.rank.rawValue != p2 }?.rank.rawValue ?? 0
            return 2_000_000 + Int32(p1 * 10000 + p2 * 100 + k)
        }
        
        // Pair
        if let p = pairs.first {
            let kickers = sorted.filter { $0.rank.rawValue != p }.map { $0.rank.rawValue }
            var val = 1_000_000 + Int32(p * 100000)
            val += Int32(kickers[0] * 1000)
            val += Int32(kickers[1] * 10)
            val += Int32(kickers[2])
            return val
        }
        
        // High Card
        return valueFromRanks(r0, r1, r2, r3, r4)
    }
    
    private func valueFromRanks(_ r0: Int, _ r1: Int, _ r2: Int, _ r3: Int, _ r4: Int) -> Int32 {
        return Int32((r0 << 16) | (r1 << 12) | (r2 << 8) | (r3 << 4) | r4)
    }
    
    // Backwards compatibility stubs
    func evaluateHandInstant(_ cards: [Card]) -> Int32 { return evaluate7(cards) }
    func preloadAllData() async {
        // Force completion immediately
        await PerformanceMonitor.shared.reportPreloadProgress(100, isComplete: true)
    }
}
