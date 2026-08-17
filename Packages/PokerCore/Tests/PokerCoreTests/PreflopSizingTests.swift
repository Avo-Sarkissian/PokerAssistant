import Testing
import Foundation
import PokerCore
import PokerTestSupport

/// Preflop the pot is made only of blinds, so a size expressed as a fraction of it is
/// tiny and clamps onto the minimum-raise floor. Everything here is stated in big blinds,
/// which is how preflop sizing is actually reasoned about at a table.
///
/// The strength sweeps below vary `myEquity`, because that is now the only route hand
/// strength takes into the solver. They used to vary the *hole cards*, which was correct
/// while preflop read the 169-hand chart and ignored the equity it was passed — and
/// became a sweep over an input with no effect the moment #29 removed that chart lookup.
/// A test that varies the wrong knob passes whatever the code does.
@Suite("Preflop raise sizing")
struct PreflopSizingTests {

    private let solver = ExploitativeSolver()

    /// Every grade `HandStrength` can produce, as the equity that produces it. Sizing
    /// must be identical across all five preflop; a sweep that missed a band would not
    /// notice strength leaking back into the size.
    private static let strengthSweep: [Double] = [0.20, 0.42, 0.60, 0.78, 0.92]

    /// Hero's **total street contribution** in big blinds — the posted blind, plus the
    /// call, plus the raise on top. This is the quantity the sizing rules are stated in.
    ///
    /// An earlier version returned only the chips hero *adds*, which is a different
    /// number for any seat holding a blind, and it is how a 4-bet that was 5bb short of
    /// its target passed a `>= 17.0` assertion.
    private func raiseTo(equity: Double = 0.6,
                         pot: Double,
                         toCall: Double,
                         position: String = "BTN",
                         bigBlind: Double = 1.0,
                         stack: Double = 100,
                         heroWagerThisStreet: Double = 0) -> Double {
        let state = spot(pot: pot, toCall: toCall, stack: stack,
                         villainStack: stack, position: position, bigBlind: bigBlind,
                         heroWagerThisStreet: heroWagerThisStreet)
        let settings = SolverSettings(smallBlind: bigBlind / 2, bigBlind: bigBlind)
        let result = solver.solve(gameState: state, myEquity: equity, settings: settings)
        let committed = state.heroCommitted(smallBlind: settings.smallBlind)
        return (committed + toCall + result.raiseAmount) / bigBlind
    }

    /// An unopened pot holds 1.5bb, and a fraction of that is less than the blind hero
    /// already owes, so the size clamps to the legal minimum: everything but aces opened
    /// to exactly 2bb, which gives the big blind 3.5:1 to defend any two cards.
    @Test("An unopened pot opens to a real size at every hand strength",
          arguments: PreflopSizingTests.strengthSweep)
    func unopenedPotOpensToARealSize(equity: Double) {
        let size = raiseTo(equity: equity, pot: 1.5, toCall: 1.0)
        #expect(size >= 2.2 && size <= 3.2, "at \(equity) equity, opened to \(size)bb")
    }

    /// Sizing that varies with hand strength is a tell, and this one is legible from
    /// across the table: aces opened 25% larger than everything else, every time.
    @Test("The open size does not broadcast hand strength")
    func openSizeDoesNotBroadcastStrength() {
        let sizes = Self.strengthSweep.map { ($0, raiseTo(equity: $0, pot: 1.5, toCall: 1.0)) }
        let distinct = Set(sizes.map { ($0.1 * 100).rounded() })

        #expect(distinct.count == 1,
                Comment(rawValue: "opens differ by strength: "
                        + sizes.map { "\($0.0) → \($0.1)bb" }.joined(separator: ", ")))
    }

    /// The same tell one street of betting later.
    @Test("The 3-bet size does not broadcast hand strength")
    func threeBetSizeDoesNotBroadcastStrength() {
        let sizes = Self.strengthSweep.map { ($0, raiseTo(equity: $0, pot: 4.0, toCall: 2.5)) }
        let distinct = Set(sizes.map { ($0.1 * 100).rounded() })

        #expect(distinct.count == 1,
                Comment(rawValue: "3-bets differ by strength: "
                        + sizes.map { "\($0.0) → \($0.1)bb" }.joined(separator: ", ")))
    }

    /// A 3-bet is a multiple of the bet it raises, not a nudge over the minimum. Three
    /// times the open is standard in position; 5bb over a 2.5bb open prices the opener
    /// in with their whole range.
    @Test("A 3-bet is a real multiple of the open it faces")
    func threeBetIsAMultipleOfTheOpen() {
        let size = raiseTo(pot: 4.0, toCall: 2.5)
        #expect(size >= 7.0, "3-bet to only \(size)bb over a 2.5bb open")
    }

    /// Hero opened to 2.5bb and faces a 3-bet to 9bb, so 6.5bb more to call. A 4-bet is
    /// a little over twice the 3-bet; 13bb is not a 4-bet.
    @Test("A 4-bet is a real multiple of the 3-bet it faces")
    func fourBetIsAMultipleOfTheThreeBet() {
        let size = raiseTo(pot: 12.0, toCall: 6.5)
        #expect(size >= 17.0, "4-bet added only \(size)bb over a 9bb 3-bet")
    }

    /// Out of position hero has to charge more: the caller acts last on every street
    /// that follows. The small blind was opening smaller than the button.
    @Test("Out of position opens larger than in position")
    func outOfPositionOpensLarger() {
        // Button owes the full blind; the small blind owes the completion.
        let button = raiseTo(pot: 1.5, toCall: 1.0, position: "BTN")
        let smallBlind = raiseTo(pot: 1.5, toCall: 0.5, position: "SB")

        #expect(smallBlind > button, "SB to \(smallBlind)bb, BTN to \(button)bb")
    }

    /// A size in blinds is scale-free: the same spot at 2.50/5.00 is the same number of
    /// big blinds as at 0.50/1.00.
    @Test("Preflop sizes scale with the blind level")
    func sizesScaleWithTheBlindLevel() {
        let atOne = raiseTo(pot: 1.5, toCall: 1.0, bigBlind: 1.0, stack: 100)
        let atFive = raiseTo(pot: 7.5, toCall: 5.0, bigBlind: 5.0, stack: 500)

        #expect(abs(atOne - atFive) < 1e-9,
                "\(atOne)bb at 0.50/1.00 but \(atFive)bb at 2.50/5.00")
    }

    // MARK: - Regressions the first version of this branch introduced

    /// `facingARaise` was `toCall > bigBlind`, but `toCall` is what hero still *owes*,
    /// not what villain wagered — the two differ by whatever hero has already posted.
    /// The big blind facing a 2bb min-raise owes exactly 1bb, so the predicate read
    /// false, the unopened-pot branch ran, and the most commonly defended seat in the
    /// game was told to re-raise to the bare legal minimum.
    @Test("The big blind facing a min-raise re-raises, not min-raises")
    func bigBlindFacingAMinRaiseReRaises() {
        // Button opens to 2bb: 0.5 + 2.0 already in, hero owes 1.0 more.
        let size = raiseTo(pot: 3.5, toCall: 1.0, position: "BB")
        #expect(size >= 6.0, "BB re-raised to only \(size)bb over a 2bb open")
    }

    /// One cent either side of the boundary must not double the size.
    @Test("The size does not jump at the min-raise boundary")
    func noCliffAtTheMinRaiseBoundary() {
        let atBoundary = raiseTo(pot: 3.5, toCall: 1.0, position: "BB")
        let justOver = raiseTo(pot: 3.52, toCall: 1.01, position: "BB")

        #expect(abs(atBoundary - justOver) < 0.5,
                "\(atBoundary)bb at the boundary vs \(justOver)bb one cent over")
    }

    /// A fixed multiple takes no account of how deep hero is, so it could commit almost
    /// everything and leave a stub behind — chips too few to fold anyone out, which hero
    /// must then ship blind on the flop. The sizing it replaced shoved this spot.
    @Test("A raise that would leave a stub behind is a shove instead")
    func nearShoveBecomesAShove() {
        let stack = 8.0
        let result = solver.solve(
            gameState: spot(hole: "Ad Ac", pot: 4.0, toCall: 2.5, stack: stack,
                            villainStack: stack, position: "BTN"),
            myEquity: 0.85, settings: makeSettings())

        let behind = stack - 2.5 - result.raiseAmount
        #expect(behind == 0 || behind >= 1.0,
                "left \(behind)bb behind — neither committed nor meaningful")
    }

    /// Limpers are dead money that a fixed 2.5bb raise fails to charge for: it lays each
    /// of them better than 4:1 and builds a multiway pot. The standard rule is one extra
    /// blind per limper.
    @Test("An isolation raise charges for the limpers")
    func isolationRaiseChargesForLimpers() {
        // Three limpers: 0.5 + 1.0 blinds + 3 x 1.0 limped = 4.5, hero owes 1.0.
        let threeLimpers = raiseTo(pot: 4.5, toCall: 1.0)
        let unopened = raiseTo(pot: 1.5, toCall: 1.0)

        #expect(threeLimpers > unopened + 2.0,
                "opened to \(threeLimpers)bb over three limpers vs \(unopened)bb unopened")
    }

    /// Villain's wager was reconstructed as hero's *blind* plus what hero owes, but the
    /// identity is hero's whole street contribution plus what hero owes. Once hero has
    /// opened, villain's raise is understated by hero's own — so a 4-bet was sized off
    /// 6.5bb rather than the 9bb villain actually made it, landing at 2.4x instead of 3x.
    @Test("A 4-bet is sized off villain's real raise, not off what hero owes")
    func fourBetSizesOffVillainsRealRaise() {
        // Hero opened to 2.5, villain 3-bet to 9: pot 12, hero owes 6.5.
        let size = raiseTo(pot: 12.0, toCall: 6.5, heroWagerThisStreet: 2.5)
        #expect(size >= 26.0 && size <= 28.0,
                "4-bet to \(size)bb; three times a 9bb 3-bet is 27bb")
    }

    /// The same quantity, one step earlier: hero opened and faces a small 3-bet.
    @Test("A re-raise accounts for what hero already put in")
    func reRaiseAccountsForHerosPriorWager() {
        // Hero opened to 2.5, villain 3-bet to 7.5: pot 10.5, hero owes 5.0.
        let withPrior = raiseTo(pot: 10.5, toCall: 5.0, heroWagerThisStreet: 2.5)
        let withoutPrior = raiseTo(pot: 10.5, toCall: 5.0)

        #expect(withPrior > withoutPrior,
                "\(withPrior)bb knowing hero opened vs \(withoutPrior)bb not knowing")
        #expect(withPrior >= 21.0, "3x a 7.5bb 3-bet is 22.5bb; sized to \(withPrior)bb")
    }

    /// And the read that shares the quantity: a 7.5bb 3-bet is not an opening range.
    @Test("A 3-bet is read as a 3-bet once hero's own raise is counted")
    func threeBetIsReadAsAThreeBet() {
        let state = spot(hole: "Ad Ac", pot: 10.5, toCall: 5.0, position: "BTN",
                         bigBlind: 1.0, heroWagerThisStreet: 2.5)
        let wager = state.villainWagerInBigBlinds(smallBlind: 0.5)

        #expect(abs(wager - 7.5) < 1e-9, "villain's 7.5bb 3-bet measured as \(wager)bb")
        #expect(OpponentRange.preflopRange(villainWagerInBigBlinds: wager) == .tight,
                "read as \(OpponentRange.preflopRange(villainWagerInBigBlinds: wager))")
    }

    /// Postflop is untouched: there the pot is real money and a fraction of it is the
    /// right unit, including the strength and texture terms.
    @Test("Postflop sizing still tracks the pot")
    func postflopSizingStillTracksThePot() {
        func flopBet(pot: Double) -> Double {
            solver.solve(gameState: spot(board: "Ks 7h 2d", pot: pot, toCall: 0),
                         myEquity: 0.85, settings: makeSettings()).raiseAmount
        }

        #expect(flopBet(pot: 100) > flopBet(pot: 10) * 5,
                "pot 10 bet \(flopBet(pot: 10)), pot 100 bet \(flopBet(pot: 100))")
    }

    /// A raise hero cannot afford is still capped by the stack.
    @Test("A short stack cannot be sized past its chips")
    func shortStackIsStillCapped() {
        let result = solver.solve(
            gameState: spot(hole: "Ad Ac", pot: 4.0, toCall: 2.5, stack: 6, villainStack: 6),
            myEquity: 0.8, settings: makeSettings())

        #expect(2.5 + result.raiseAmount <= 6.0 + 1e-9,
                "committed \(2.5 + result.raiseAmount) of a 6bb stack")
    }
}
