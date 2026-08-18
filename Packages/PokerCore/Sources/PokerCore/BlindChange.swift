import Foundation

/// A stake: the two posted blinds, as one value.
///
/// It exists so a change of stake is a single observable event. Watching `smallBlind` and
/// `bigBlind` separately looks equivalent and is not — each callback then knows its own
/// previous value and the *current* value of the other, so the pair asks two different
/// half-updated questions and both can answer "no" at once. See `BlindChange`.
public struct Stake: Equatable, Sendable {
    public let smallBlind: Double
    public let bigBlind: Double

    public init(smallBlind: Double, bigBlind: Double) {
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
    }

    /// What the blinds alone put in the middle.
    public var total: Double { smallBlind + bigBlind }
}

/// What changing the stake mid-session should do to the pot on screen.
///
/// This is a value type rather than a method on the view for the reason the branch in
/// `positionExplanation` taught: a `View`'s private function cannot be reached by any test
/// in either target, and that is where a force-unwrap once shipped a launch crash. Any
/// rule with a branch in it belongs somewhere a test can call — *the whole rule*, not the
/// half that is easy to move. An earlier version of this type held only the two totals and
/// left the view to work out which totals to pass; the view got it wrong, in exactly the
/// direction the tests here were written to catch, and no test could see it.
///
/// The rule is the one `initializePotWithBlinds` already applies for the table size:
/// re-seed only when nothing has been entered for this hand yet. A user who has typed a
/// real pot and then opens Settings must not come back to find it discarded. "Nothing
/// entered yet" means the pot is still standing at the *old* stake, which is why the
/// previous stake is part of the question and not just the new one.
public struct BlindChange: Sendable {
    public let previous: Stake
    public let updated: Stake

    public init(from previous: Stake, to updated: Stake) {
        self.previous = previous
        self.updated = updated
    }

    /// The pot to show after the change, or `nil` to leave it alone.
    public func reseededPot(currentPot: Double) -> Double? {
        guard currentPot <= previous.total + 1e-9 else { return nil }
        return updated.total
    }
}
