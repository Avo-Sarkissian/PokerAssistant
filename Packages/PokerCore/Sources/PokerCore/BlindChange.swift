import Foundation

/// What changing the stake mid-session should do to the pot on screen.
///
/// This is a value type rather than a method on the view for the reason the branch in
/// `positionExplanation` taught: a `View`'s private function cannot be reached by any test
/// in either target, and that is where a force-unwrap once shipped a launch crash. Any
/// rule with a branch in it belongs somewhere a test can call.
///
/// The rule itself is the one `initializePotWithBlinds` already applies for the table
/// size: re-seed only when nothing has been entered for this hand yet. A user who has
/// typed a real pot and then opens Settings must not come back to find it discarded.
/// "Nothing entered yet" means the pot is still standing at the *old* blind total, which
/// is why the previous stake is part of the question and not just the new one.
public struct BlindChange: Sendable {
    public let previousBlindTotal: Double
    public let newBlindTotal: Double

    public init(previousBlindTotal: Double, newBlindTotal: Double) {
        self.previousBlindTotal = previousBlindTotal
        self.newBlindTotal = newBlindTotal
    }

    /// The pot to show after the change, or `nil` to leave it alone.
    public func reseededPot(currentPot: Double) -> Double? {
        guard currentPot <= previousBlindTotal + 1e-9 else { return nil }
        return newBlindTotal
    }
}
