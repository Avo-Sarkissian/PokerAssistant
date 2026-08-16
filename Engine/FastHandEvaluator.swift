import Foundation

/// Fast 7-card poker hand evaluator.
/// Evaluates all 7 cards directly using bit manipulation — no C(7,5) combo iteration.
/// Returns Int32 where higher value = stronger hand (safe for direct comparison).
///
/// Stateless and therefore safe to share across threads: the counters live in SIMD
/// locals on the stack, so concurrent calls cannot see each other's work. (An earlier
/// version kept them as instance properties; sharing one instance across 8 tasks
/// corrupted 98% of results.)
final class FastHandEvaluator: @unchecked Sendable {

    /// Evaluate a 7-card hand. The array must contain exactly 7 cards.
    func evaluate(_ cards: [Card]) -> Int32 {
        var rc  = SIMD16<UInt8>()   // rank counts, indices 2–14
        var sc  = SIMD4<UInt8>()    // suit counts, indices 0–3
        var srb = SIMD4<UInt16>()   // rank bitmask per suit
        var rb: UInt16 = 0

        for c in cards {
            let r = c.rank.rawValue   // 2–14
            let s = c.suit.suitIndex  // 0–3
            rc[r] &+= 1
            sc[s] &+= 1
            let bit = UInt16(1) << r
            srb[s] |= bit
            rb     |= bit
        }

        // ── Flush / Straight-Flush ─────────────────────────────────────────
        for s in 0..<4 where sc[s] >= 5 {
            let fb    = srb[s]
            let sfTop = straightTop(fb)
            if sfTop > 0 { return 8_000_000 + sfTop }      // Straight Flush
            return 5_000_000 + top5Value(fb)                // Flush
        }

        // ── Count categories (high → low for automatic rank priority) ──────
        var quads = 0, trips1 = 0, trips2 = 0, pair1 = 0, pair2 = 0
        for r in stride(from: 14, through: 2, by: -1) {
            switch rc[r] {
            case 4: if quads  == 0 { quads  = r }
            case 3: if trips1 == 0 { trips1 = r } else if trips2 == 0 { trips2 = r }
            case 2: if pair1  == 0 { pair1  = r } else if pair2  == 0 { pair2  = r }
            default: break
            }
        }

        // ── Quads ──────────────────────────────────────────────────────────
        if quads > 0 {
            var k = 0
            for r in stride(from: 14, through: 2, by: -1) where r != quads {
                if rc[r] > 0 { k = r; break }
            }
            return 7_000_000 + Int32(quads * 100 + k)
        }

        // ── Full House ─────────────────────────────────────────────────────
        if trips1 > 0 {
            let p = max(pair1, trips2)   // trips2 acts as a pair for the full house
            if p > 0 { return 6_000_000 + Int32(trips1 * 100 + p) }
        }

        // ── Straight ───────────────────────────────────────────────────────
        let st = straightTop(rb)
        if st > 0 { return 4_000_000 + st }

        // ── Trips ──────────────────────────────────────────────────────────
        if trips1 > 0 {
            var k1 = 0, k2 = 0
            for r in stride(from: 14, through: 2, by: -1) where r != trips1 {
                if rc[r] > 0 { if k1 == 0 { k1 = r } else { k2 = r; break } }
            }
            return 3_000_000 + Int32(trips1 * 10_000 + k1 * 100 + k2)
        }

        // ── Two Pair ───────────────────────────────────────────────────────
        if pair1 > 0 && pair2 > 0 {
            var k = 0
            for r in stride(from: 14, through: 2, by: -1) where r != pair1 && r != pair2 {
                if rc[r] > 0 { k = r; break }
            }
            return 2_000_000 + Int32(pair1 * 10_000 + pair2 * 100 + k)
        }

        // ── One Pair ───────────────────────────────────────────────────────
        // Multiplier 50_000 keeps max one-pair value (≈1.71M) below two-pair base (2.0M)
        if pair1 > 0 {
            var k1 = 0, k2 = 0, k3 = 0
            for r in stride(from: 14, through: 2, by: -1) where r != pair1 {
                if rc[r] > 0 {
                    if k1 == 0 { k1 = r }
                    else if k2 == 0 { k2 = r }
                    else { k3 = r; break }
                }
            }
            return 1_000_000 + Int32(pair1 * 50_000 + k1 * 1_000 + k2 * 10 + k3)
        }

        // ── High Card ──────────────────────────────────────────────────────
        return top5Value(rb)
    }

    // MARK: – Bit helpers

    /// Returns the high card of the best straight in `bits`, or 0 if none.
    private func straightTop(_ bits: UInt16) -> Int32 {
        for top in stride(from: 14, through: 6, by: -1) {
            let mask = UInt16(0x1F) << UInt16(top - 4)
            if (bits & mask) == mask { return Int32(top) }
        }
        // Wheel: A-2-3-4-5
        let wheel: UInt16 = (1 << 14) | (1 << 5) | (1 << 4) | (1 << 3) | (1 << 2)
        if (bits & wheel) == wheel { return 5 }
        return 0
    }

    /// Encodes the top 5 ranks present in `bits` as a base-15 integer.
    private func top5Value(_ bits: UInt16) -> Int32 {
        var result: Int32 = 0
        var n = 0
        for r in stride(from: 14, through: 2, by: -1) {
            if bits & (UInt16(1) << r) != 0 {
                result = result * 15 + Int32(r)
                n += 1
                if n == 5 { break }
            }
        }
        return result
    }
}
