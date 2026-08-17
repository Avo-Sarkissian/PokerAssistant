import Foundation

/// Represents opponent's likely hand range based on their action
/// Uses Sklansky-Chubukov rankings adapted for 6-max cash games
public struct OpponentRange {

    public enum RangeType: Double, Sendable {
        case veryTight = 0.10   // Top 10% - 3bet/4bet range
        case tight = 0.20       // Top 20% - open-raise from EP
        case standard = 0.35    // Top 35% - open-raise from MP/CO
        case wide = 0.50        // Top 50% - open-raise from BTN
        case veryWide = 0.70    // Top 70% - limp/call range
        case random = 1.0       // Any two cards

        public var percentile: Double { rawValue }
    }

    /// The 169 starting-hand classes in the order players **open** them: a
    /// Sklansky-Chubukov-style ordering, adapted for 6-max, where suitedness and
    /// connectedness count because they are what makes a hand playable after the flop.
    /// AA=0, KK=1, ..., 72o=168; lower is opened more often.
    ///
    /// This is **not** an ordering by all-in equity against a random hand, and it used to
    /// say that it was. The two disagree sharply — 65s stands 27 places above K6o here
    /// and holds eleven points less all-in equity (43.1% vs 54.2%, measured in
    /// `PreflopHandClassTests`), and AKs stands above JJ while JJ holds eleven points
    /// more. Reading this list as a strength order is exactly the mistake that graded
    /// hero's own hand: see `openingRangeRank`.
    private static let rankedHands: [String] = [
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

    private static let handRankings: [String: Int] = {
        var rankings: [String: Int] = [:]
        for (index, hand) in rankedHands.enumerated() {
            rankings[hand] = index
        }
        return rankings
    }()

    /// Every two-card combination in the deck: 13 pairs x 6, 78 suited x 4, 78 offsuit x 12.
    static let totalCombinations = 1326

    /// Combinations contained in the top *n* hand classes, for every n.
    ///
    /// A range's name is a promise about how much of the deck it holds, and that promise
    /// is about combinations, not classes. The two are very different: a pair is 6
    /// combinations, a suited hand 4, an offsuit hand 12. Taking the top 20% of the 169
    /// *classes* takes mostly pairs and suited hands — the combo-poor ones — so the range
    /// calling itself "top 20%" held 15.5% of the deck. Measured across the tiers, every
    /// name overstated its width by a fifth to a third: 0.20 -> 0.155, 0.35 -> 0.262,
    /// 0.50 -> 0.388, 0.70 -> 0.593.
    private static let cumulativeCombinations: [Int] = {
        var running = 0
        return rankedHands.map { hand in
            // "AA" is a pair, "AKs" suited, "AKo" offsuit.
            running += hand.count == 2 ? 6 : (hand.hasSuffix("s") ? 4 : 12)
            return running
        }
    }()

    /// Convert two cards to canonical hand string
    public static func canonicalHand(_ card1: Card, _ card2: Card) -> String {
        let r1 = card1.rank.tableSymbol
        let r2 = card2.rank.tableSymbol
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

    /// Where a hand sits in the opening-range order (0 = AA, 168 = 72o).
    ///
    /// Named for its one job: deciding which holdings a range of a given width contains.
    /// It was called `handStrength`, and under that name the solver used it to grade
    /// *hero's* hand into monster/strong/medium/weak/bluff — a different question, with a
    /// different right answer. That produced the inversion this rename exists to prevent:
    /// K6o graded above 65s despite ranking 27 places worse, because the tiers only
    /// covered ranks 0–75 and everything past that fell through to an equity test, so the
    /// two hands were graded on two different scales. Hero's grade now comes from equity
    /// on every street, and this ordering has one consumer again — `isHandInRange`.
    public static func openingRangeRank(_ card1: Card, _ card2: Card) -> Int {
        let hand = canonicalHand(card1, card2)
        return handRankings[hand] ?? 168
    }

    /// Whether a hand is inside a range, measured by combinations rather than by hand
    /// classes — see `cumulativeCombinations` for why the two disagree.
    public static func isHandInRange(_ card1: Card, _ card2: Card, range: RangeType) -> Bool {
        guard range != .random else { return true }
        let rank = openingRangeRank(card1, card2)
        guard rank < cumulativeCombinations.count else { return false }
        return Double(cumulativeCombinations[rank])
            <= range.percentile * Double(totalCombinations)
    }

    /// Read villain's preflop range from the size of their wager, in big blinds.
    ///
    /// Preflop is measured in blinds rather than in fractions of the pot, because
    /// preflop the pot *is* the blinds: the big blind alone is twice the 0.5bb sitting
    /// in front of the button, so a pot-relative read saturates before anyone has acted.
    /// Every unopened button inferred `.veryTight` — a 3-bet range read off nobody doing
    /// anything — and every genuine raise collapsed into that same tier, discarding the
    /// distinction between an open, a 3-bet and a 4-bet entirely.
    ///
    /// `wager` is villain's total contribution to the street, which is what hero must
    /// reach to call: whatever hero has already posted, plus what they still owe.
    ///
    /// The boundaries are the standard lines rather than tuned values: a limp is one
    /// blind, opens run 2–4bb, 3-bets 6–12bb, 4-bets 20bb and up.
    public static func preflopRange(villainWagerInBigBlinds wager: Double) -> RangeType {
        if wager <= 1.5  { return .random }     // nobody has raised — a posted blind is not an action
        if wager <= 2.0  { return .veryWide }   // a min-raise
        if wager <= 5.0  { return .standard }   // a standard open
        if wager <= 14.0 { return .tight }      // a 3-bet
        return .veryTight                       // a 4-bet or better
    }

    /// Read villain's postflop range from their bet as a fraction of the pot they bet
    /// into. Postflop the pot is real money, so a fraction of it is the right unit.
    public static func postflopRange(potRelativeBet: Double) -> RangeType {
        if potRelativeBet > 0.8 { return .tight }
        if potRelativeBet > 0.5 { return .standard }
        if potRelativeBet > 0.25 { return .wide }
        return .veryWide
    }

    /// Determine opponent range based on their action.
    ///
    /// Both measurements are required, because the two streets genuinely use different
    /// units — passing only the pot-relative one is what produced the preflop saturation.
    public static func rangeFromAction(
        potRelativeBet: Double,
        villainWagerInBigBlinds: Double,
        street: Street
    ) -> RangeType {
        switch street {
        case .preflop:
            return preflopRange(villainWagerInBigBlinds: villainWagerInBigBlinds)
        case .flop, .turn, .river:
            return postflopRange(potRelativeBet: potRelativeBet)
        }
    }
}
