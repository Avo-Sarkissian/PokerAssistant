import Foundation

/// A preflop spot hero can enter with one tap.
public enum PreflopPreset: String, CaseIterable, Identifiable, Sendable {
    case limp     = "Limp"
    case open     = "Open"
    case threeBet = "3-bet"
    case fourBet  = "4-bet"

    public var id: String { rawValue }

    /// Villain's total street contribution for this line, in big blinds.
    /// A raise "to" this amount absorbs any blind villain had already posted.
    public var villainWager: Double {
        switch self {
        case .limp:     return 1.0
        case .open:     return 2.5
        case .threeBet: return 9.0
        case .fourBet:  return 25.0
        }
    }

    /// What hero had already put in before villain's action, beyond a posted blind.
    /// The 3-bet and 4-bet lines assume hero was the previous aggressor.
    public var heroPriorWager: Double {
        switch self {
        case .limp, .open: return 0      // hero has only a blind in, if that
        case .threeBet:    return 2.5    // hero opened
        case .fourBet:     return 9.0    // hero three-bet
        }
    }

    public var label: String { rawValue }
}

/// The two quantities a player actually knows at the table.
///
/// Keeping "the pot before their bet" and "their bet" as separate stored values is
/// what makes the arithmetic unambiguous. Storing a single "pot" leaves it unclear
/// whether the outstanding bet is already inside it, and the app previously used
/// both conventions in different places — the quick-entry buttons assumed one and
/// the equity engine assumed the other.
public struct PotEntry: Equatable, Sendable {

    /// Chips in the middle before villain's current bet, including dead blinds and
    /// hero's own earlier contributions.
    public var potBeforeBet: Double

    /// What hero must put in to call.
    public var toCall: Double

    public init(potBeforeBet: Double = 1.5, toCall: Double = 1.0) {
        self.potBeforeBet = max(0, potBeforeBet)
        self.toCall = max(0, toCall)
    }

    /// Everything in the middle right now, villain's bet included. This is the
    /// quantity the solver calls `potSize`.
    public var totalPot: Double { potBeforeBet + toCall }

    /// Share of the final pot hero must win to break even on the call.
    public var requiredEquity: Double {
        guard toCall > 0 else { return 0 }
        return toCall / (totalPot + toCall)
    }

    /// Villain's bet as a fraction of the pot they bet into — the "he bet 75% pot"
    /// number. Range inference is calibrated against this, NOT against the bet as a
    /// share of the pot it is already inside.
    public var betFractionOfPotBeforeBet: Double {
        guard potBeforeBet > 0 else { return 0 }
        return toCall / potBeforeBet
    }

    /// The spot before anyone has acted: just the posted blinds.
    public static func blindsOnly(heroPosition: Position, smallBlind: Double, bigBlind: Double) -> PotEntry {
        let owed: Double
        switch heroPosition {
        case .bb: owed = 0                     // already posted the full blind
        case .sb: owed = bigBlind - smallBlind // completing
        default:  owed = bigBlind              // every other seat posts nothing
        }
        return PotEntry(potBeforeBet: (smallBlind + bigBlind) - owed, toCall: owed)
    }

    /// Pot odds expressed the way they are spoken at a table, e.g. 3.2 for "3.2 to 1".
    public var potOddsRatio: Double? {
        guard toCall > 0 else { return nil }
        return totalPot / toCall
    }

    // MARK: - Entry

    public mutating func setPotBeforeBet(_ value: Double) {
        potBeforeBet = max(0, value)
    }

    /// No upper bound. An overbet or a shove is a legal bet, and clamping it to the
    /// pot silently answers a different question than the one the player asked.
    public mutating func setCall(_ value: Double) {
        toCall = max(0, value)
    }

    /// Villain bet some fraction of the pot that existed before they acted.
    /// Idempotent: applying 75% twice gives the same spot, because the bet is derived
    /// from `potBeforeBet` rather than from the running total.
    public mutating func applyOpponentBet(fractionOfPot fraction: Double) {
        toCall = max(0, potBeforeBet * fraction)
    }

    // MARK: - Presets

    /// The standard preflop lines, in big blinds.
    ///
    /// `villain` is the raiser's total street contribution; `heroAlreadyIn` is what
    /// hero has already committed (a posted blind and/or an earlier raise), and
    /// `deadMoney` is what folded players left behind. Then
    ///   pot before villain's bet = heroAlreadyIn + deadMoney + (villain − toCall)
    ///   toCall                    = villain − heroAlreadyIn
    public static func preflop(_ preset: PreflopPreset,
                               heroPosition: Position,
                               smallBlind: Double,
                               bigBlind: Double) -> PotEntry {

        let heroBlind: Double
        switch heroPosition {
        case .sb: heroBlind = smallBlind
        case .bb: heroBlind = bigBlind
        default:  heroBlind = 0             // every seat but the blinds posts nothing
        }

        let villain = preset.villainWager * bigBlind
        let heroAlreadyIn = max(preset.heroPriorWager * bigBlind, heroBlind)

        let deadMoney: Double
        switch preset {
        case .limp, .open, .fourBet:
            // Both blinds are live; the ones hero did not post are dead money.
            deadMoney = (smallBlind + bigBlind) - heroBlind
        case .threeBet:
            // Hero opened, so only a blind can re-raise. From the small blind the
            // villain can only be the big blind and nothing else is left in the
            // middle — the one line in the grid with no dead money at all.
            deadMoney = heroPosition == .sb ? 0 : smallBlind
        }

        let toCall = max(0, villain - heroAlreadyIn)
        let total = villain + heroAlreadyIn + deadMoney
        return PotEntry(potBeforeBet: total - toCall, toCall: toCall)
    }
}
