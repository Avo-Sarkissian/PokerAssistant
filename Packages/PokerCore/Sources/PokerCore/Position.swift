import Foundation

/// A seat at the table.
///
/// This used to be a `String` on the game state, parsed by a switch with
/// `default: self = .btn`. Three seats existed — BTN, SB and BB — while the app offered
/// tables of up to nine players, so every seat from under the gun to the cutoff was
/// unreachable in the picker and, if it reached the solver anyway, was priced as a
/// button. Measured on one flop spot: UTG, UTG+1, MP, LJ, HJ, CO, BTN and the literal
/// string "banana" all produced a $13.00 bet with a raise EV of 29.2432 and an
/// explanation reading "in position". Only the two blinds differed.
///
/// The names are the modern 6-max/9-max convention: UTG, UTG+1, UTG+2, LJ (lojack),
/// HJ (hijack), CO (cutoff), BTN, SB, BB.
public enum Position: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case utg  = "UTG"
    case utg1 = "UTG+1"
    case utg2 = "UTG+2"
    case lj   = "LJ"
    case hj   = "HJ"
    case co   = "CO"
    case btn  = "BTN"
    case sb   = "SB"
    case bb   = "BB"

    public var id: String { rawValue }

    /// Table sizes the app supports, matching the picker in Settings.
    public static let supportedTableSizes = 2...9

    // MARK: - Which seats exist

    /// The seats at a table of `tableSize` players, in the order they act **preflop**:
    /// under the gun first, the big blind last.
    ///
    /// Written out per table size rather than derived from one ladder, because the
    /// earliest seat is named for acting first and the late seats are named for their
    /// distance from the button, so no single ordering produces conventional names at
    /// every size. Six-handed is UTG/HJ/CO/BTN/SB/BB; a derived ladder would have called
    /// that first seat LJ, and eight-handed would have had a UTG+2 with no UTG.
    ///
    /// Heads-up has no button seat: the small blind holds the button, which is why it is
    /// the seat that acts last after the flop.
    public static func seats(tableSize: Int) -> [Position] {
        switch clamped(tableSize) {
        case 2:  return [.sb, .bb]
        case 3:  return [.btn, .sb, .bb]
        case 4:  return [.co, .btn, .sb, .bb]
        case 5:  return [.utg, .co, .btn, .sb, .bb]
        case 6:  return [.utg, .hj, .co, .btn, .sb, .bb]
        case 7:  return [.utg, .lj, .hj, .co, .btn, .sb, .bb]
        case 8:  return [.utg, .utg1, .lj, .hj, .co, .btn, .sb, .bb]
        default: return [.utg, .utg1, .utg2, .lj, .hj, .co, .btn, .sb, .bb]
        }
    }

    /// Whether this seat is dealt at a table of this size.
    public func exists(tableSize: Int) -> Bool {
        Self.seats(tableSize: tableSize).contains(self)
    }

    /// The order seats act **postflop**: the blinds first, then the seats in preflop
    /// order, so the button is last. A rotation of the two blinds to the front, not a
    /// reversal — `seats(6)` ends `[BTN, SB, BB]` and `postflopOrder(6)` begins
    /// `[SB, BB]` and ends on the button.
    ///
    /// Heads-up inverts instead: the small blind is the button, so it acts *first*
    /// preflop and *last* afterwards.
    public static func postflopOrder(tableSize: Int) -> [Position] {
        let n = clamped(tableSize)
        guard n > 2 else { return [.bb, .sb] }
        let seated = seats(tableSize: n)
        return [.sb, .bb] + seated.filter { $0 != .sb && $0 != .bb }
    }

    // MARK: - Relative position

    /// Where this seat falls in the postflop betting order: 0 acts first, `tableSize − 1`
    /// acts last.
    ///
    /// A seat the table is too small to hold is read at the smallest table that does hold
    /// it, never remapped to a different seat. The picker cannot produce that pair, but a
    /// stored hand or a test can, and quietly turning a cutoff into a button is the whole
    /// defect this type exists to remove. Every seat is present in the order at its own
    /// smallest table, so the lookup below cannot miss.
    public func postflopActionIndex(tableSize: Int) -> Int {
        let n = max(Self.clamped(tableSize), smallestTableSeatingThis)
        return Self.postflopOrder(tableSize: n).firstIndex(of: self) ?? 0
    }

    /// Hero acts last after the flop: the button, or the small blind heads-up.
    ///
    /// **Definitely** last, which is not the same as "last against the players still in
    /// the hand": a cutoff whose button has folded also acts last, and no seat can say so.
    /// This is therefore the *default* the app seeds its position control with, not the
    /// answer the solver uses — that comes from `GameStateCopy.heroActsLast`, which hero
    /// supplies. Deriving it here and stopping was what priced the most common flop in
    /// six-max out of position.
    ///
    /// A seat the table does not deal is not in position at that table. Widening the
    /// table until the seat exists — which `postflopActionIndex` does — would otherwise
    /// report a button as last to act at a two-handed table that has no button.
    public func isInPosition(tableSize: Int) -> Bool {
        let n = Self.clamped(tableSize)
        guard exists(tableSize: n) else { return false }
        return postflopActionIndex(tableSize: n) == n - 1
    }

    /// Hero posted a blind, so hero is out of position against the whole field and
    /// already has money in the pot.
    ///
    /// This — not `isInPosition` — is what preflop raise *sizing* keys on. The two were
    /// the same predicate while only BTN, SB and BB existed, and they part company as
    /// soon as a cutoff does: a cutoff opens the same 2.5bb as a button by convention,
    /// while a small blind opens larger. Keying the size on "acts last postflop" would
    /// have made every seat but the button open like a small blind.
    public var postsABlind: Bool { self == .sb || self == .bb }

    // MARK: - Positional adjustments

    /// How much more (or less) fold equity a bluff earns: the two values the three-seat
    /// version used, keyed on whether hero acts last.
    ///
    /// Static, and taking the fact rather than a seat, because the seat cannot settle it —
    /// a cutoff whose button folded acts last too. `GameStateCopy.heroActsLast` carries the
    /// answer; `isInPosition(tableSize:)` supplies its default.
    ///
    /// This was briefly a ramp over the postflop order, interpolating 0.6 to 1.3 across
    /// all nine seats. That was wrong, and measurably so. Postflop only *live* players
    /// act, and the ramp divided by the table size, so one identical spot — hero in the
    /// big blind, one villain, 30% equity on a dry flop — priced across a 40% range on
    /// nothing but how many seats had already folded: raise EV 17.67 two-handed, 24.72
    /// three-handed, 20.49 six-handed. There is one villain in all three, hero acts first
    /// against that villain in all three, and the ramp's own definition demands the same
    /// answer each time. Relative position among the live players is not derivable from a
    /// seat and a headcount, so the model does not pretend to it.
    ///
    /// The term itself is still suspect and is on the list for the validation harness:
    /// villain cannot see hero's cards, so hero's *hand* should not move villain's fold
    /// rate at all, and villain can see hero's *seat* — which argues the sign is backwards,
    /// since a late-position bettor is credited with a wider range and called looser.
    public static func bluffFrequencyMultiplier(actingLast: Bool) -> Double {
        actingLast ? 1.3 : 0.6
    }

    /// Hero's total street contribution when opening an unopened pot, in big blinds.
    /// Larger from a blind, which will be out of position on every later street.
    public var preflopOpenBlinds: Double { postsABlind ? 3.0 : 2.5 }

    /// A re-raise as a multiple of the bet it is raising.
    public var preflopRaiseMultiple: Double { postsABlind ? 3.5 : 3.0 }

    // MARK: - Helpers

    private static func clamped(_ tableSize: Int) -> Int {
        min(supportedTableSizes.upperBound, max(supportedTableSizes.lowerBound, tableSize))
    }

    /// The fewest players a table needs before this seat is dealt.
    private var smallestTableSeatingThis: Int {
        switch self {
        case .sb, .bb: return 2
        case .btn:     return 3
        case .co:      return 4
        case .utg:     return 5
        case .hj:      return 6
        case .lj:      return 7
        case .utg1:    return 8
        case .utg2:    return 9
        }
    }
}
