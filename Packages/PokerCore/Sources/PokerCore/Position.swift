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

    /// The order seats act **postflop**: the blinds first, the button last — the reverse
    /// of preflop for the three seats at the end.
    ///
    /// Heads-up inverts: the small blind is the button, so it acts *first* preflop and
    /// *last* afterwards.
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
    /// defect this type exists to remove.
    public func postflopActionIndex(tableSize: Int) -> Int {
        let n = max(Self.clamped(tableSize), smallestTableSeatingThis)
        return Self.postflopOrder(tableSize: n).firstIndex(of: self) ?? 0
    }

    /// Hero acts last after the flop — the button, or the small blind heads-up.
    public func isInPosition(tableSize: Int) -> Bool {
        let n = max(Self.clamped(tableSize), smallestTableSeatingThis)
        return postflopActionIndex(tableSize: n) == n - 1
    }

    /// 0 for the first seat to act postflop, 1 for the last. The scale every positional
    /// adjustment is expressed on, so that adding a seat cannot leave a gap in the
    /// middle of a hand-written table.
    public func relativePosition(tableSize: Int) -> Double {
        let n = max(Self.clamped(tableSize), smallestTableSeatingThis)
        guard n > 1 else { return 1 }
        return Double(postflopActionIndex(tableSize: n)) / Double(n - 1)
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

    /// How much more (or less) fold equity a bluff earns from this seat.
    ///
    /// A ramp over the postflop order rather than one constant per seat. The two ends are
    /// the values the three-seat version used — 0.6 for the first to act, 1.3 for the
    /// last — so this re-shapes those constants instead of introducing nine new ones, and
    /// it is monotone in when hero acts by construction. Nine independent numbers are not:
    /// the ones being replaced had the small blind below the big blind, which is right,
    /// and nothing in between to be wrong about.
    ///
    /// The shape is a straight line, and that is a guess — a real curve would be flatter
    /// through the early seats. It is hand-authored like everything else here and is on
    /// the list for the external validation harness.
    public func bluffFrequencyMultiplier(tableSize: Int) -> Double {
        0.6 + 0.7 * relativePosition(tableSize: tableSize)
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
