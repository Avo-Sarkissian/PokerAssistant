import Foundation

/// Represents opponent's likely hand range based on their action
/// Uses Sklansky-Chubukov rankings adapted for 6-max cash games
struct OpponentRange {

    enum RangeType: Double {
        case veryTight = 0.10   // Top 10% - 3bet/4bet range
        case tight = 0.20       // Top 20% - open-raise from EP
        case standard = 0.35    // Top 35% - open-raise from MP/CO
        case wide = 0.50        // Top 50% - open-raise from BTN
        case veryWide = 0.70    // Top 70% - limp/call range
        case random = 1.0       // Any two cards

        var percentile: Double { rawValue }
    }

    /// Hand strength rankings (0-168, lower = stronger)
    /// Based on preflop all-in equity vs random hands
    /// Format: (rank1, rank2, suited) -> strength index
    private static let handRankings: [String: Int] = {
        // Top 169 hands ranked by preflop equity
        // AA=0, KK=1, ..., 72o=168
        let rankedHands = [
            // Tier 1: Premium (0-4)
            "AA", "KK", "QQ", "AKs", "JJ",
            // Tier 2: Strong (5-12)
            "AQs", "TT", "AKo", "AJs", "KQs", "99", "ATs", "AQo",
            // Tier 3: Good (13-25)
            "KJs", "88", "QJs", "KTs", "AJo", "A9s", "KQo", "A8s", "QTs", "77", "ATo", "JTs", "A7s",
            // Tier 4: Playable (26-45)
            "KJo", "A5s", "A6s", "66", "A4s", "K9s", "QJo", "A3s", "Q9s", "J9s", "KTo", "A2s", "55",
            "T9s", "K8s", "QTo", "K7s", "JTo", "44", "Q8s",
            // Tier 5: Marginal (46-75)
            "K6s", "J8s", "98s", "33", "T8s", "K5s", "A9o", "K4s", "Q7s", "K3s", "97s", "J7s", "Q6s",
            "22", "K2s", "87s", "A8o", "Q5s", "T7s", "Q4s", "J9o", "76s", "A7o", "Q3s", "96s", "J6s",
            "A5o", "Q2s", "T9o", "65s", "A6o",
            // Tier 6: Weak (76-110)
            "86s", "J5s", "A4o", "K9o", "75s", "J4s", "T6s", "54s", "Q9o", "A3o", "J3s", "95s", "K8o",
            "64s", "J2s", "T5s", "98o", "A2o", "K7o", "85s", "T4s", "53s", "Q8o", "74s", "T3s", "K6o",
            "T2s", "87o", "43s", "Q7o", "97o", "J8o", "K5o", "94s",
            // Tier 7: Trash (111-168)
            "63s", "84s", "K4o", "T8o", "92s", "76o", "K3o", "52s", "Q6o", "65o", "93s", "42s", "K2o",
            "73s", "J7o", "Q5o", "86o", "82s", "96o", "Q4o", "54o", "32s", "J6o", "75o", "83s", "Q3o",
            "T7o", "J5o", "Q2o", "64o", "72s", "62s", "J4o", "85o", "T6o", "53o", "J3o", "95o", "43o",
            "J2o", "74o", "T5o", "92o", "63o", "84o", "T4o", "42o", "T3o", "52o", "73o", "T2o", "62o",
            "94o", "82o", "93o", "32o", "83o", "72o"
        ]

        var rankings: [String: Int] = [:]
        for (index, hand) in rankedHands.enumerated() {
            rankings[hand] = index
        }
        return rankings
    }()

    /// Convert two cards to canonical hand string
    static func canonicalHand(_ card1: Card, _ card2: Card) -> String {
        let r1 = card1.rank.symbol
        let r2 = card2.rank.symbol
        let suited = card1.suit == card2.suit

        // Higher rank first
        let highRank = card1.rank.rawValue >= card2.rank.rawValue ? r1 : r2
        let lowRank = card1.rank.rawValue >= card2.rank.rawValue ? r2 : r1

        if card1.rank == card2.rank {
            return "\(highRank)\(lowRank)"  // Pairs like "AA"
        } else if suited {
            return "\(highRank)\(lowRank)s"
        } else {
            return "\(highRank)\(lowRank)o"
        }
    }

    /// Get hand strength index (0 = AA, 168 = 72o)
    static func handStrength(_ card1: Card, _ card2: Card) -> Int {
        let hand = canonicalHand(card1, card2)
        return handRankings[hand] ?? 168
    }

    /// Check if hand is within range
    static func isHandInRange(_ card1: Card, _ card2: Card, range: RangeType) -> Bool {
        let strength = handStrength(card1, card2)
        let threshold = Int(Double(169) * range.percentile)
        return strength < threshold
    }

    /// Determine opponent range based on their action
    static func rangeFromAction(
        potRelativeBet: Double,
        street: Street,
        isRaise: Bool
    ) -> RangeType {
        switch street {
        case .preflop:
            if isRaise {
                if potRelativeBet > 0.5 { return .veryTight }  // 3bet+
                if potRelativeBet > 0.25 { return .tight }     // Open raise
                return .standard
            } else {
                if potRelativeBet > 0.1 { return .wide }       // Call raise
                return .veryWide                                // Limp
            }

        case .flop, .turn, .river:
            // Post-flop: betting indicates strength commitment
            if potRelativeBet > 0.8 { return .tight }
            if potRelativeBet > 0.5 { return .standard }
            if potRelativeBet > 0.25 { return .wide }
            return .veryWide
        }
    }
}
