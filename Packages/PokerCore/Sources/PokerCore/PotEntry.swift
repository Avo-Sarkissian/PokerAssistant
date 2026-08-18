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
    /// `villain` is the raiser's total street contribution — a raise is *to* an amount, so
    /// it already absorbs any blind villain had posted. That is where this used to go
    /// wrong: dead money was "the blinds hero did not post", which counts villain's own
    /// blind a second time whenever villain is a blind. Two-handed that is every spot,
    /// because two-handed both players are blinds and nothing is dead. The button facing a
    /// big-blind raise — *the* heads-up spot — built a 4.0 pot where the truth is 3.0, and
    /// priced the call at 33.3% where hero actually needs 40.0%.
    ///
    ///   dead money = both blinds − hero's blind − villain's blind
    ///   pot before villain's bet = heroAlreadyIn + deadMoney + (villain − toCall)
    ///   toCall = villain − heroAlreadyIn
    ///
    /// `tableSize` is how villain's blind gets settled: two-handed it is known exactly,
    /// because villain holds whichever blind hero does not. Larger tables cannot know it
    /// without villain's seat, which the app does not track, so `assumedVillainBlind`
    /// carries the assumption in the open rather than hiding it in an arithmetic branch.
    public static func preflop(_ preset: PreflopPreset,
                               heroPosition: Position,
                               tableSize: Int,
                               smallBlind: Double,
                               bigBlind: Double) -> PotEntry {
        preflop(preset, heroPosition: heroPosition, smallBlind: smallBlind, bigBlind: bigBlind,
                villainBlind: assumedVillainBlind(preset, heroPosition: heroPosition,
                                                  tableSize: tableSize,
                                                  smallBlind: smallBlind, bigBlind: bigBlind))
    }

    /// The same lines with villain's posted blind supplied rather than assumed.
    public static func preflop(_ preset: PreflopPreset,
                               heroPosition: Position,
                               smallBlind: Double,
                               bigBlind: Double,
                               villainBlind: Double) -> PotEntry {

        let heroBlind: Double
        switch heroPosition {
        case .sb: heroBlind = smallBlind
        case .bb: heroBlind = bigBlind
        default:  heroBlind = 0             // every seat but the blinds posts nothing
        }

        let villain = preset.villainWager * bigBlind
        let heroAlreadyIn = max(preset.heroPriorWager * bigBlind, heroBlind)

        // What is left in the middle that belongs to neither of them. Clamped because a
        // caller may hand over a blind hero also claims — the answer is then "nothing
        // dead", not "negative money".
        let deadMoney = max(0, (smallBlind + bigBlind) - heroBlind - villainBlind)

        let toCall = max(0, villain - heroAlreadyIn)
        let total = villain + heroAlreadyIn + deadMoney
        return PotEntry(potBeforeBet: total - toCall, toCall: toCall)
    }

    /// What villain most likely had posted as a blind before acting.
    ///
    /// Two-handed this is not a guess: both players are blinds and villain holds the one
    /// hero does not. Any larger table needs villain's seat, which the app does not ask
    /// for, so the rest is the assumption the presets have always made, written down:
    ///
    /// - A limp, an open or a four-bet comes from someone who posted nothing. Openers are
    ///   usually not blinds, and a four-bet is the original raiser coming back over the top.
    /// - A three-bet is a re-raise over hero's open, so it comes from a player still to act
    ///   — which after an open means a blind, and the big blind more often than the small.
    ///
    /// Hero holding the big blind is where that last assumption is weakest, and the code
    /// deliberately does not branch on it. Two things are true there. Villain cannot hold
    /// the big blind, because hero does — but substituting the small one changes nothing,
    /// since hero's own big blind already exceeds what the pair of blinds leaves behind
    /// and the dead-money clamp lands on zero either way. A branch was written for it
    /// first and deleted: mutation testing showed no input could tell the two apart.
    ///
    /// The *assumption* is more arguable than the arithmetic. Hero opening from the big
    /// blind means hero raised over limpers, since the big blind acts last preflop — and a
    /// re-raise then often comes from a limper or a later seat rather than from the small
    /// blind, in which case the small blind really is dead and this returns a pot half a
    /// blind short. It is one blind either way, the pot fields stay editable, and the
    /// alternative would be a second unknowable guess rather than a better one.
    public static func assumedVillainBlind(_ preset: PreflopPreset,
                                           heroPosition: Position,
                                           tableSize: Int,
                                           smallBlind: Double,
                                           bigBlind: Double) -> Double {
        if tableSize <= 2 {
            return heroPosition == .sb ? bigBlind : smallBlind
        }
        switch preset {
        case .limp, .open, .fourBet:
            return 0
        case .threeBet:
            return bigBlind
        }
    }
}
