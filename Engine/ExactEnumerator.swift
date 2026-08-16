import Foundation

/// Exact (deterministic) equity calculator for turn and river.
///
/// Instead of Monte Carlo sampling, it enumerates every possible opponent
/// hand combination and computes the true equity with no approximation error.
///
/// Routing:
///   River, 1 opponent  — C(n,2) ≈ 990 combos    → sub-millisecond, exact
///   River, 2 opponents — C(n,4)×3 ≈ 447K combos → ~200–500 ms, exact
///   Turn,  1 opponent  — 46 rivers × C(45,2)      → ~48K combos, exact
///
/// All other situations (3+ opponents, or turn 2+ opponents) are left to the
/// GPU Monte Carlo path which is faster than full enumeration for those cases.
final class ExactEnumerator {

    private let deck     = Card.deck()            // 52 cards, stable UUIDs
    private let evaluator = FastHandEvaluator()   // reusable instance, pre-allocated buffers

    // MARK: – Public API

    /// Exact river equity (1 or 2 opponents). Returns nil if unsupported case.
    func calculateRiver(hand: Hand, opponents: Int, deadCards: Set<Card>,
                        opponentRange: OpponentRange.RangeType = .random) -> Double? {
        guard hand.communityCards.count == 5 else { return nil }
        let available = buildAvailable(hand: hand, deadCards: deadCards)
        switch opponents {
        case 1: return riverOneOpponent(hand: hand, available: available, range: opponentRange)
        case 2: return riverTwoOpponents(hand: hand, available: available, range: opponentRange)
        default: return nil
        }
    }

    /// Exact turn equity (1 opponent only). Returns nil if unsupported.
    func calculateTurn(hand: Hand, opponents: Int, deadCards: Set<Card>,
                       opponentRange: OpponentRange.RangeType = .random) -> Double? {
        guard hand.communityCards.count == 4, opponents == 1 else { return nil }
        let available = buildAvailable(hand: hand, deadCards: deadCards)
        return turnOneOpponent(hand: hand, available: available, range: opponentRange)
    }

    /// Exact flop equity (1 opponent only).
    /// Enumerates every (turn, river) pair × every opponent hand.
    /// ~46×45/2 × 44×43/2 ≈ 1.07M evaluations — typically ~300 ms.
    func calculateFlop(hand: Hand, opponents: Int, deadCards: Set<Card>,
                       opponentRange: OpponentRange.RangeType = .random) -> Double? {
        guard hand.communityCards.count == 3, opponents == 1 else { return nil }
        let available = buildAvailable(hand: hand, deadCards: deadCards)
        return flopOneOpponent(hand: hand, available: available, range: opponentRange)
    }

    /// Precomputes which (i, j) pairs of the available deck are hands villain would
    /// hold, so the inner loops do one array lookup instead of re-deriving the hand
    /// class. Returns nil when no filtering is needed.
    private func inRangeMask(_ available: [Card], _ range: OpponentRange.RangeType) -> [Bool]? {
        guard range != .random else { return nil }
        let n = available.count
        var mask = [Bool](repeating: false, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                if OpponentRange.isHandInRange(available[i], available[j], range: range) {
                    mask[i * n + j] = true
                }
            }
        }
        return mask
    }

    // MARK: – River: 1 opponent

    private func riverOneOpponent(hand: Hand, available: [Card],
                                  range: OpponentRange.RangeType) -> Double? {
        let board = hand.communityCards  // 5 cards
        let n     = available.count      // typically ~45

        // My hand score is constant for the whole enumeration (board is fixed)
        var myHand = hand.holeCards + board
        let myScore = evaluator.evaluate(myHand)

        // Pre-allocate opponent hand buffer once — reused every iteration
        var oppHand = Array(repeating: available[0], count: 7)
        for i in 0..<5 { oppHand[i + 2] = board[i] }

        let mask = inRangeMask(available, range)
        var equitySum = 0.0
        var total     = 0

        for i in 0..<(n - 1) {
            oppHand[0] = available[i]
            for j in (i + 1)..<n {
                if let mask, !mask[i * n + j] { continue }
                oppHand[1] = available[j]
                let oppScore = evaluator.evaluate(oppHand)
                if      myScore > oppScore { equitySum += 1.0 }
                else if myScore == oppScore { equitySum += 0.5 }
                total += 1
            }
        }

        _ = myHand
        // No hand in the assumed range survives the board: fall back rather than
        // reporting a number derived from nothing.
        guard total > 0 else { return nil }
        return equitySum / Double(total)
    }

    // MARK: – River: 2 opponents

    // Enumerates C(n,4) groups of 4 cards and splits each 3 ways.
    // Total combos: C(45,4) × 3 ≈ 447K. Exact equity, no approximation.
    private func riverTwoOpponents(hand: Hand, available: [Card],
                                   range: OpponentRange.RangeType) -> Double? {
        let board = hand.communityCards
        let n     = available.count

        var myHand = hand.holeCards + board
        let myScore = evaluator.evaluate(myHand)

        // Two opponent hand buffers, board slots pre-filled
        var opp1 = Array(repeating: available[0], count: 7)
        var opp2 = Array(repeating: available[0], count: 7)
        for i in 0..<5 { opp1[i + 2] = board[i]; opp2[i + 2] = board[i] }

        let mask = inRangeMask(available, range)
        // Both opponents must hold a hand from the assumed range.
        func pairAllowed(_ x: Int, _ y: Int) -> Bool {
            guard let mask else { return true }
            return mask[min(x, y) * n + max(x, y)]
        }

        var equitySum = 0.0
        var total     = 0

        for a in 0..<(n - 3) {
            for b in (a + 1)..<(n - 2) {
                for c in (b + 1)..<(n - 1) {
                    for d in (c + 1)..<n {
                        // 3 ways to split {a,b,c,d} into 2 pairs:
                        // Split 1: (a,b) vs (c,d)
                        if pairAllowed(a, b) && pairAllowed(c, d) {
                            opp1[0] = available[a]; opp1[1] = available[b]
                            opp2[0] = available[c]; opp2[1] = available[d]
                            accumulateEquity(myScore: myScore, opp1: &opp1, opp2: &opp2,
                                             equitySum: &equitySum, total: &total)
                        }

                        // Split 2: (a,c) vs (b,d)
                        if pairAllowed(a, c) && pairAllowed(b, d) {
                            opp1[0] = available[a]; opp1[1] = available[c]
                            opp2[0] = available[b]; opp2[1] = available[d]
                            accumulateEquity(myScore: myScore, opp1: &opp1, opp2: &opp2,
                                             equitySum: &equitySum, total: &total)
                        }

                        // Split 3: (a,d) vs (b,c)
                        if pairAllowed(a, d) && pairAllowed(b, c) {
                            opp1[0] = available[a]; opp1[1] = available[d]
                            opp2[0] = available[b]; opp2[1] = available[c]
                            accumulateEquity(myScore: myScore, opp1: &opp1, opp2: &opp2,
                                             equitySum: &equitySum, total: &total)
                        }
                    }
                }
            }
        }

        _ = myHand
        guard total > 0 else { return nil }
        return equitySum / Double(total)
    }

    @inline(__always)
    private func accumulateEquity(
        myScore: Int32,
        opp1: inout [Card],
        opp2: inout [Card],
        equitySum: inout Double,
        total: inout Int
    ) {
        let s1 = evaluator.evaluate(opp1)
        let s2 = evaluator.evaluate(opp2)
        let best = max(s1, s2)
        if myScore > best {
            equitySum += 1.0
        } else if myScore == best {
            // 3-way tie (both opponents match) or 2-way tie (one opponent matches)
            equitySum += (s1 == s2) ? (1.0 / 3.0) : 0.5
        }
        total += 1
    }

    // MARK: – Turn: 1 opponent

    // Enumerates every possible river card × every possible opponent hand.
    // For each river card, my score is recomputed (1 eval) then all opponent
    // combos are enumerated (C(remaining, 2) evals).
    // Total: ~46 × 1,035 ≈ 47K evaluations. Sub-100ms.
    private func turnOneOpponent(hand: Hand, available: [Card],
                                 range: OpponentRange.RangeType) -> Double? {
        let board = hand.communityCards  // 4 cards
        let n     = available.count      // typically ~46

        // My hand template: hole cards + 4 board cards + 1 river (position 6)
        var myHand = hand.holeCards + board + [available[0]]

        // Opponent hand template: 2 hole slots + 4 board cards + 1 river (position 6)
        var oppHand = Array(repeating: available[0], count: 7)
        for i in 0..<4 { oppHand[i + 2] = board[i] }

        let mask = inRangeMask(available, range)
        var equitySum = 0.0
        var total     = 0

        for ri in 0..<n {
            let river = available[ri]

            // Update river slot in both hands
            myHand[6]  = river
            oppHand[6] = river

            let myScore = evaluator.evaluate(myHand)

            for i in 0..<n {
                if i == ri { continue }
                oppHand[0] = available[i]
                for j in (i + 1)..<n {
                    if j == ri { continue }
                    if let mask, !mask[i * n + j] { continue }
                    oppHand[1] = available[j]
                    let oppScore = evaluator.evaluate(oppHand)
                    if      myScore > oppScore  { equitySum += 1.0 }
                    else if myScore == oppScore { equitySum += 0.5 }
                    total += 1
                }
            }
        }

        guard total > 0 else { return nil }
        return equitySum / Double(total)
    }

    // MARK: – Flop: 1 opponent

    // Outer loops: every (turn, river) pair from available cards.
    // Inner loop: every opponent hand from remaining cards (excludes turn & river).
    // Total: C(n,2) × C(n-2,2) ≈ C(45,2)×C(43,2) ≈ 990 × 903 ≈ 894K evaluations.
    // Sub-500ms on device.
    private func flopOneOpponent(hand: Hand, available: [Card],
                                 range: OpponentRange.RangeType) -> Double? {
        let board3 = hand.communityCards  // 3 flop cards
        let n      = available.count      // typically ~45

        var myHand  = hand.holeCards + board3 + [available[0], available[0]] // slots 5 & 6 filled below
        var oppHand = Array(repeating: available[0], count: 7)
        for i in 0..<3 { oppHand[i + 2] = board3[i] }
        // oppHand[5] = turn, oppHand[6] = river — filled in loop

        let mask = inRangeMask(available, range)
        var equitySum = 0.0
        var total     = 0

        for ti in 0..<(n - 1) {
            let turn = available[ti]
            myHand[5]  = turn
            oppHand[5] = turn

            for ri in (ti + 1)..<n {
                let river = available[ri]
                myHand[6]  = river
                oppHand[6] = river

                let myScore = evaluator.evaluate(myHand)

                // Enumerate opponent hands from cards not used as turn or river
                for i in 0..<n {
                    if i == ti || i == ri { continue }
                    oppHand[0] = available[i]
                    for j in (i + 1)..<n {
                        if j == ti || j == ri { continue }
                        if let mask, !mask[i * n + j] { continue }
                        oppHand[1] = available[j]
                        let oppScore = evaluator.evaluate(oppHand)
                        if      myScore > oppScore  { equitySum += 1.0 }
                        else if myScore == oppScore { equitySum += 0.5 }
                        total += 1
                    }
                }
            }
        }

        guard total > 0 else { return nil }
        return equitySum / Double(total)
    }

    // MARK: – Helpers

    /// Build the list of cards not in the hand or dead-card set.
    /// Uses rank+suit comparison (not UUID) to correctly identify used cards.
    private func buildAvailable(hand: Hand, deadCards: Set<Card>) -> [Card] {
        var used = Set<Int>()
        for c in hand.holeCards    { used.insert(cardIndex(c)) }
        for c in hand.communityCards { used.insert(cardIndex(c)) }
        for c in deadCards         { used.insert(cardIndex(c)) }
        return deck.filter { !used.contains(cardIndex($0)) }
    }

    /// Canonical 0–51 card index based on rank and suit (not UUID).
    @inline(__always)
    private func cardIndex(_ c: Card) -> Int {
        (c.rank.rawValue - 2) * 4 + c.suit.suitIndex
    }
}
