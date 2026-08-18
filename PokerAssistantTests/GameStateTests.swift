import Testing
import Foundation
import PokerCore
import PokerTestSupport
@testable import PokerAssistant

// Seeded-run reproducibility moved to `PokerCoreTests` with the engine itself.
// What is left here needs the app: `Settings` is @AppStorage-backed and the view
// models are @MainActor types that only exist in the app target.

// MARK: - Hand lifecycle

/// `Settings` is backed by @AppStorage on the shared defaults and the test host is the
/// app itself, so anything a test writes leaks into the real app unless it is restored.
///
/// Snapshot-and-restore is only half of it: Swift Testing runs suites in parallel and
/// they all share one `UserDefaults.standard`, so two tests can snapshot the same clean
/// value, both mutate, and whichever restores second writes the other's dirty value back
/// as the "original". That is not theoretical — a run of this file left the simulator's
/// installed app with `smallBlind = 0.25` persisted, opening on a $1.25 pot instead of
/// $1.50. The other half of the fix is `SettingsBackedStateTests` below, which puts every
/// suite that touches defaults inside one `.serialized` parent.
///
/// A lock here would be the obvious alternative and is the wrong one: these tests await,
/// and holding a blocking lock across a suspension point starves the cooperative pool —
/// tried, and it deadlocked the run until the 180-second time limit killed it.
struct DefaultsSnapshot {
    private static let keys = ["smallBlind", "bigBlind", "numberOfPlayers", "buyIn",
                               "gameMode", "tournamentPhase", "calculationDepth"]
    private let saved: [(String, Any?)]

    init() {
        saved = Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    func restore() {
        for (key, value) in saved {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

/// Every suite that reads or writes `Settings` — and therefore the one shared
/// `UserDefaults` — nests here. `.serialized` applies to the whole tree, so these run one
/// at a time while every other suite in the target still runs in parallel.
@Suite("Settings-backed state", .serialized)
struct SettingsBackedStateTests {


@Suite("Hand lifecycle")
@MainActor
struct HandLifecycleTests {

    /// `numberOfPlayers` is pinned as well as the blinds. It is `@AppStorage` on the one
    /// shared `UserDefaults`, so whatever a sibling suite last wrote is what a fresh
    /// `Settings()` reads — and the fingerprint test below takes its baseline from it. Left
    /// unpinned, that test set the table size to a value it already had and reported the
    /// field as missing.
    private func makeViewModel(smallBlind: Double, bigBlind: Double,
                               players: Int = 6) -> (GameViewModel, Settings) {
        let settings = Settings()
        settings.smallBlind = smallBlind
        settings.bigBlind = bigBlind
        settings.numberOfPlayers = players
        let viewModel = GameViewModel()
        viewModel.settings = settings
        return (viewModel, settings)
    }

    /// Carrying the previous hand's pot into the next one produces a huge pot next to
    /// a one-blind call, which prices almost any two cards as a call.
    @Test("Starting a new hand resets the pot to the blinds")
    func resetRestoresBlindPot() {
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let (viewModel, _) = makeViewModel(smallBlind: 0.5, bigBlind: 1.0)
        viewModel.gameState.potSize = 180
        viewModel.gameState.toCall = 1

        viewModel.resetHand()

        #expect(viewModel.gameState.potSize == 1.5,
                "pot was \(viewModel.gameState.potSize), expected the blinds")
    }

    /// The blind level lives in Settings but SPR and the stack-in-blinds readout are
    /// computed from GameState, so the two have to agree.
    @Test("The blind level reaches the game state")
    func blindLevelPropagates() {
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let (viewModel, _) = makeViewModel(smallBlind: 1.0, bigBlind: 2.0)

        viewModel.resetHand()

        #expect(viewModel.gameState.bigBlind == 2.0,
                "game state still thinks the big blind is \(viewModel.gameState.bigBlind)")
        #expect(viewModel.gameState.potSize == 3.0)
    }

    /// A stale fingerprint makes the app refuse to recompute while still showing an
    /// answer derived from different inputs.
    @Test("The recalculation fingerprint covers every input the solver reads")
    func fingerprintCoversAllInputs() {
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let (viewModel, settings) = makeViewModel(smallBlind: 0.5, bigBlind: 1.0)
        viewModel.gameState.holeCards = [card("Ad"), card("Ac")]
        viewModel.gameState.potSize = 10
        viewModel.gameState.toCall = 3

        let baseline = viewModel.getCurrentStateString()

        // Each field is changed, checked, then restored — and the restoration is checked
        // too. Without that, a fingerprint of `UUID().uuidString` would satisfy every
        // "differs from baseline" assertion below while breaking the app the other way,
        // and a restore that silently failed would make every later case pass spuriously.
        func expectRestored(_ what: String) {
            #expect(viewModel.getCurrentStateString() == baseline,
                    Comment(rawValue: "restoring \(what) did not return the fingerprint to " +
                            "its baseline, so the cases after it prove nothing"))
        }

        viewModel.gameState.opponentStyle = .tight
        #expect(viewModel.getCurrentStateString() != baseline, "opponent style is not in the fingerprint")
        viewModel.gameState.opponentStyle = .unknown
        expectRestored("opponent style")

        viewModel.gameState.stack = 999
        #expect(viewModel.getCurrentStateString() != baseline, "stack is not in the fingerprint")
        viewModel.gameState.stack = 20
        expectRestored("the stack")

        viewModel.gameState.playersInHand = 2
        #expect(viewModel.getCurrentStateString() != baseline, "players in hand is not in the fingerprint")
        viewModel.gameState.playersInHand = 6
        expectRestored("players in hand")

        // Hero's own street contribution decides how big villain's raise is read to be,
        // which sets both the range and the re-raise size.
        viewModel.gameState.heroWagerThisStreet = 2.5
        #expect(viewModel.getCurrentStateString() != baseline,
                "hero's street wager is not in the fingerprint")
        viewModel.gameState.heroWagerThisStreet = 0
        expectRestored("hero's street wager")

        // The seat sets the bluff premium, the open size and the explanation.
        viewModel.gameState.position = .sb
        #expect(viewModel.getCurrentStateString() != baseline, "the seat is not in the fingerprint")
        viewModel.gameState.position = .btn
        expectRestored("the seat")

        // Hero's own answer on position, which changes the postflop size and the
        // fold-equity premium and which no other field implies.
        viewModel.gameState.actsLastOverride = true
        #expect(viewModel.getCurrentStateString() != baseline,
                "hero's position answer is not in the fingerprint")
        viewModel.gameState.actsLastOverride = nil
        expectRestored("hero's position answer")

        // And the table size sets how far that seat is from the button, so the same seat
        // at a different table size is a different spot.
        viewModel.gameState.tableSize = 9
        #expect(viewModel.getCurrentStateString() != baseline, "table size is not in the fingerprint")
        viewModel.gameState.tableSize = 6
        expectRestored("table size")

        // The table size the *user* set, not only the mirror of it on the game state. The
        // mirror is written inside `calculate()`, after `canCalculate` has already read the
        // fingerprint, so on its own it depends on a view-layer `onChange` firing first.
        settings.numberOfPlayers = 9
        #expect(viewModel.getCurrentStateString() != baseline,
                "the configured table size is not in the fingerprint")
        settings.numberOfPlayers = 6
        expectRestored("the configured table size")

        settings.gameMode = .tournament
        #expect(viewModel.getCurrentStateString() != baseline, "game mode is not in the fingerprint")
        settings.gameMode = .cashGame
        expectRestored("game mode")

        settings.tournamentPhase = .bubble
        #expect(viewModel.getCurrentStateString() != baseline, "tournament phase is not in the fingerprint")
        settings.tournamentPhase = .earlyStage
        expectRestored("tournament phase")

        // The solver rounds every raise to the small blind and computes SPR from the
        // big blind, so a change to either has to invalidate the fingerprint.
        settings.bigBlind = 5.0
        #expect(viewModel.getCurrentStateString() != baseline, "big blind is not in the fingerprint")
        settings.bigBlind = 1.0
        expectRestored("the big blind")

        settings.smallBlind = 0.25
        #expect(viewModel.getCurrentStateString() != baseline, "small blind is not in the fingerprint")
    }
}

// MARK: - Seats

/// The app half of backlog #24. `Position` and its table-size arithmetic are covered in
/// PokerCore; what only exists here is the bridge — the seat the badge reads, the seat
/// `reset` chooses, and what happens to a selected seat when the table shrinks under it.
@Suite("Seats and table size")
@MainActor
struct SeatStateTests {

    /// `isInPosition` used to be `position == "BTN" || position == "CO"`. "CO" could not
    /// be selected, so the second half of that test documented a seat the app did not
    /// have — and the first half was wrong heads-up, where the small blind holds the
    /// button and the badge read "Out of Position" while hero acted last.
    @Test("The in-position badge follows the seat and the table size")
    func inPositionFollowsSeatAndTableSize() {
        let state = GameState()

        state.tableSize = 6
        for seat in Position.seats(tableSize: 6) {
            state.position = seat
            #expect(state.isInPosition == (seat == .btn),
                    "6-handed \(seat.rawValue) reported isInPosition = \(state.isInPosition)")
        }

        state.tableSize = 2
        state.position = .sb
        #expect(state.isInPosition, "heads-up the small blind holds the button and acts last")
        state.position = .bb
        #expect(!state.isInPosition, "heads-up the big blind acts first after the flop")
    }

    /// A hand is dealt to every seat, so a fresh hand's table size is its player count.
    /// Resetting to a two-handed table has to leave hero in a seat that exists: the
    /// button is not dealt heads-up.
    @Test("A reset hand seats hero somewhere the table actually deals", arguments: 2...9)
    func resetChoosesALegalSeat(players: Int) {
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let state = GameState()
        state.position = .utg2          // only exists nine-handed
        state.reset(smallBlind: 0.5, bigBlind: 1.0, playersInHand: players)

        #expect(state.tableSize == players)
        #expect(Position.seats(tableSize: players).contains(state.position),
                "\(players)-handed reset left hero in the \(state.position.rawValue)")
        #expect(state.position == (players == 2 ? .sb : .btn))
    }

    /// Choosing UTG at a nine-handed table and then switching Settings to three-handed
    /// leaves hero in a chair that is no longer dealt. The correction is explicit and
    /// testable rather than a `default:` case buried in the solver.
    /// Driven through the assignment, not by calling the corrector. Calling it by hand
    /// tested the corrector while leaving the thing that has to invoke it uncovered: the
    /// app depended on one `calculate()` line, and deleting that line — letting a UTG+2
    /// reach the solver at a three-handed table, the literal #24 failure — would have left
    /// this suite green.
    @Test("Shrinking the table moves hero out of a seat it no longer deals")
    func shrinkingTheTableMovesHero() {
        let state = GameState()
        state.tableSize = 9
        state.position = .utg1

        state.tableSize = 3
        #expect(state.position == .btn, "hero stayed in the \(state.position.rawValue) three-handed")

        state.tableSize = 2
        #expect(state.position == .sb, "hero stayed in the \(state.position.rawValue) heads-up")

        // A seat that still exists is left alone.
        state.tableSize = 6
        state.position = .co
        state.tableSize = 6
        #expect(state.position == .co, "the cutoff exists six-handed and was moved anyway")
    }

    /// The seat supplies a default; hero supplies the answer. A cutoff whose button folded
    /// acts last, and the app tracks how many players are live, never which chairs they
    /// hold — so it asks rather than guessing.
    @Test("Hero's answer on position beats the seat's default")
    func heroOverridesTheSeatDefault() {
        let state = GameState()
        state.tableSize = 6
        state.position = .co

        #expect(!state.isInPosition, "the cutoff's default is out of position")
        state.actsLastOverride = true
        #expect(state.isInPosition, "hero said they act last and was not believed")
        #expect(GameStateCopy(from: state).heroActsLast,
                "hero's answer did not reach the solver's copy")

        state.actsLastOverride = false
        #expect(!state.isInPosition)

        state.actsLastOverride = nil
        #expect(state.isInPosition == state.seatImpliesActsLast,
                "clearing the answer did not fall back to the seat")
    }

    /// The answer is about a seat at a table. Moving either invalidates it, so it clears
    /// rather than following hero to a chair it was never about.
    @Test("Changing the seat or the table clears hero's answer")
    func movingClearsTheOverride() {
        let state = GameState()
        state.tableSize = 6
        state.position = .co
        state.actsLastOverride = true

        state.position = .utg
        #expect(state.actsLastOverride == nil, "the answer survived a seat change")

        state.position = .co
        state.actsLastOverride = true
        state.tableSize = 9
        #expect(state.actsLastOverride == nil, "the answer survived a table-size change")

        // Setting the same value is not a move.
        state.actsLastOverride = true
        state.tableSize = 9
        state.position = .co
        #expect(state.actsLastOverride == true,
                "re-assigning the same seat and table cleared an answer that was still valid")
    }

    /// A fresh hand starts from the seat again.
    @Test("A reset hand forgets hero's answer")
    func resetForgetsTheOverride() {
        let state = GameState()
        state.tableSize = 6
        state.position = .co
        state.actsLastOverride = true

        state.reset(smallBlind: 0.5, bigBlind: 1.0, playersInHand: 6)
        #expect(state.actsLastOverride == nil)
        #expect(state.isInPosition, "a reset hand is on the button, which acts last")
    }

    /// The crash, as a test. `SeatExplanation` exists as a value type precisely so this
    /// pair can be exercised: a stored seat the table does not deal, which is the state the
    /// app is in on launch whenever "Players at Table" was left at 2, because `@State`
    /// cannot be initialised from `Settings` and every corrector runs after the first body.
    @Test("The seat line renders for every seat at every table size, dealt or not")
    func seatExplanationNeverTraps() {
        for tableSize in 2...9 {
            for seat in Position.allCases {
                for isPostFlop in [false, true] {
                    let line = SeatExplanation(seat: seat, tableSize: tableSize,
                                               smallBlind: 0.5, bigBlind: 1.0,
                                               isPostFlop: isPostFlop)
                    #expect(!line.text.isEmpty,
                            "\(tableSize)-handed \(seat.rawValue) postflop=\(isPostFlop) rendered nothing")
                    #expect(line.behindPreflop >= 0,
                            "\(tableSize)-handed \(seat.rawValue): \(line.behindPreflop) seats behind pre-flop")
                    #expect(line.behindPostflop >= 0,
                            "\(tableSize)-handed \(seat.rawValue): \(line.behindPostflop) seats behind post-flop")
                }
            }
        }
    }

    /// And the counts are right where they can be checked by hand.
    @Test("The seat line counts the seats behind hero correctly")
    func seatExplanationCountsAreRight() {
        func line(_ seat: Position, _ tableSize: Int, postflop: Bool) -> SeatExplanation {
            SeatExplanation(seat: seat, tableSize: tableSize, smallBlind: 0.5,
                            bigBlind: 1.0, isPostFlop: postflop)
        }
        // Six-handed: preflop order UTG HJ CO BTN SB BB, so the button has the two blinds
        // behind it; postflop order SB BB UTG HJ CO BTN, so the cutoff has only the button.
        #expect(line(.btn, 6, postflop: false).behindPreflop == 2)
        #expect(line(.utg, 6, postflop: false).behindPreflop == 5)
        #expect(line(.co, 6, postflop: true).behindPostflop == 1)
        #expect(line(.btn, 6, postflop: true).behindPostflop == 0)
        #expect(line(.sb, 6, postflop: true).behindPostflop == 5)

        // Heads-up: the small blind is the button and acts last after the flop.
        #expect(line(.sb, 2, postflop: true).behindPostflop == 0)
        #expect(line(.bb, 2, postflop: true).behindPostflop == 1)
        #expect(line(.sb, 2, postflop: true).text.contains("last after the flop"))
        #expect(line(.bb, 2, postflop: true).text.contains("1 seat "),
                Comment(rawValue: line(.bb, 2, postflop: true).text))

        // Plural agreement, which read "1 player act after you".
        #expect(!line(.co, 6, postflop: true).text.contains("seats"))
    }

    /// The table size has to reach the solver's copy of the spot, or every positional
    /// adjustment is computed against the wrong table.
    @Test("The table size and seat travel into the solver's copy")
    func tableSizeReachesTheSolverCopy() {
        let state = GameState()
        state.tableSize = 9
        state.position = .hj
        state.playersInHand = 4

        let copy = GameStateCopy(from: state)
        #expect(copy.tableSize == 9)
        #expect(copy.position == .hj)
        #expect(!copy.isInPosition, "the hijack is not the last seat to act nine-handed")
    }

    /// More players contesting a pot than are seated at the table is not a spot. The fix
    /// is to seat fewer players, never to invent seats: growing the table moves hero's
    /// chair, and it does so by the largest amount available. This exact input used to
    /// turn a heads-up small blind — the seat that *holds* the button — into a six-handed
    /// small blind, flipping `isInPosition` and swinging the bluff premium 1.3 → 0.6.
    @Test("An impossible player count is seated down, not given extra chairs")
    func impossiblePlayerCountIsSeatedDown() {
        let state = GameState()
        state.tableSize = 2
        state.position = .sb
        state.playersInHand = 6

        let copy = GameStateCopy(from: state)
        #expect(copy.tableSize == 2, "the table grew to \(copy.tableSize) seats")
        #expect(copy.playersInHand == 2, "\(copy.playersInHand) players at a two-handed table")
        #expect(copy.position == .sb, "hero was moved to the \(copy.position.rawValue)")
        #expect(copy.isInPosition, "the heads-up small blind holds the button and acts last")
    }

    /// A fresh heads-up hand is the small blind completing, not a seat that posted
    /// nothing facing a full blind. `reset` chose the seat correctly and then wrote a pot
    /// that contradicted it: $1.00 to call into $0.50, asking 40% equity to complete for
    /// half a blind, where the truth is $0.50 into $1.00 and 25%.
    @Test("A fresh heads-up hand is priced as the small blind completing")
    func headsUpResetPricesTheSmallBlind() {
        let state = GameState()
        state.reset(smallBlind: 0.5, bigBlind: 1.0, playersInHand: 2)

        #expect(state.position == .sb)
        #expect(state.potSize == 1.5, "pot is \(state.potSize)")
        #expect(state.toCall == 0.5, "hero owes \(state.toCall), not the 0.5 completion")
        #expect(state.heroWagerThisStreet == 0.5,
                "hero is recorded as having posted \(state.heroWagerThisStreet)")
    }

    /// Every table size, so the pot and the seat can never disagree again.
    @Test("A reset hand's pot matches the seat it chose", arguments: 2...9)
    func resetPotMatchesTheChosenSeat(players: Int) {
        let state = GameState()
        state.reset(smallBlind: 0.5, bigBlind: 1.0, playersInHand: players)

        let expected = PotEntry.blindsOnly(heroPosition: state.position,
                                           smallBlind: 0.5, bigBlind: 1.0)
        #expect(state.potSize == expected.totalPot,
                "\(players)-handed \(state.position.rawValue): pot \(state.potSize), expected \(expected.totalPot)")
        #expect(state.toCall == expected.toCall,
                "\(players)-handed \(state.position.rawValue): owes \(state.toCall), expected \(expected.toCall)")
    }
}

// MARK: - Card selection

/// `GameState.isUsed` is what the card picker greys out and disables, so it is the only
/// thing standing between the user and entering the same card twice.
///
/// It is deliberately a model method rather than a predicate inline in the view: an
/// earlier version of this suite tested `GameState.availableCards`, which no view has
/// ever called, so it certified a property nothing rendered while the path a user
/// actually touches stayed uncovered.
@Suite("Cards already in play")
@MainActor
struct UsedCardsTests {

    @Test("A card in the hand is already in play")
    func holeAndBoardCardsAreUsed() {
        let state = GameState()
        state.holeCards = [card("Ad"), card("Ac")]
        state.communityCards = [card("Ks"), card("7h"), card("2d"), nil, nil]

        for used in cards("Ad Ac Ks 7h 2d") {
            #expect(state.isUsed(used), "\(used.displayString) is still on offer")
        }
        #expect(!state.isUsed(card("Qh")), "an untouched card was reported as used")
        #expect(!state.isUsed(card("As")), "a different suit is a different card")
    }

    @Test("A dead card is already in play")
    func deadCardsAreUsed() {
        let state = GameState()
        state.holeCards = [card("Ad"), card("Ac")]
        state.deadCards = [card("Kh"), card("Qs")]

        #expect(state.isUsed(card("Kh")))
        #expect(state.isUsed(card("Qs")))
        #expect(!state.isUsed(card("Kd")))
    }

    /// Nothing selected: every card is available.
    @Test("An empty table has no cards in play")
    func emptyTableHasNothingUsed() {
        let state = GameState()
        for card in Card.deck() {
            #expect(!state.isUsed(card), "\(card.displayString) was reported as used")
        }
    }

    /// The whole point: a card entered once cannot be entered again.
    @Test("Every card in play is refused by the picker's gate")
    func everyCardInPlayIsRefused() {
        let state = GameState()
        state.holeCards = [card("Ad"), card("Ac")]
        state.communityCards = [card("Ks"), card("7h"), card("2d"), nil, nil]
        state.deadCards = [card("Kh")]

        let inPlay = cards("Ad Ac Ks 7h 2d Kh")
        let offered = Card.deck().filter { !state.isUsed($0) }

        #expect(offered.count == 52 - inPlay.count,
                "\(52 - offered.count) of \(inPlay.count) cards in play were refused")
        for used in inPlay {
            #expect(!offered.contains(used), "\(used.displayString) is still offered")
        }
    }
}

// MARK: - Settings → solver

/// `Settings.solverSettings` is the app's only route from its persisted preferences into
/// the solver. The solver's own suite lives in PokerCore and constructs `SolverSettings`
/// literally, so it is structurally incapable of noticing a mistake in this mapping:
/// transposing the two blinds, or dropping the tournament check, leaves all 54 tests
/// green while the app rounds every raise to the wrong grid, or prices every ICM spot as
/// a cash game.
@Suite("Settings reach the solver")
@MainActor
struct SolverSettingsMappingTests {

    /// Deliberately asymmetric values: 0.5/1.0 would let a transposition pass.
    private func settings(smallBlind: Double = 0.25, bigBlind: Double = 2.0) -> Settings {
        let s = Settings()
        s.smallBlind = smallBlind
        s.bigBlind = bigBlind
        return s
    }

    @Test("Each blind arrives as itself")
    func blindsAreNotTransposed() {
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let mapped = settings().solverSettings

        #expect(mapped.smallBlind == 0.25, "small blind arrived as \(mapped.smallBlind)")
        #expect(mapped.bigBlind == 2.0, "big blind arrived as \(mapped.bigBlind)")
    }

    /// A cash game has no survival premium, whatever the tournament phase happens to be
    /// left set to.
    @Test("A cash game carries no ICM pressure, even with a phase selected")
    func cashGameHasNoICMPressure() {
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let s = settings()
        s.gameMode = .cashGame
        s.tournamentPhase = .bubble      // the highest-pressure phase there is

        #expect(s.solverSettings.icmPressure == 0,
                "cash game reported ICM pressure \(s.solverSettings.icmPressure)")
    }

    /// Every phase must reach the solver at its own pressure. A mapping that always
    /// returned zero would silently turn tournament mode off.
    @Test("Every tournament phase reaches the solver at its own pressure",
          arguments: TournamentPhase.allCases)
    func tournamentPressureReachesTheSolver(phase: TournamentPhase) {
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let s = settings()
        s.gameMode = .tournament
        s.tournamentPhase = phase

        #expect(s.solverSettings.icmPressure == phase.icmPressure,
                "\(phase.rawValue) mapped to \(s.solverSettings.icmPressure), expected \(phase.icmPressure)")
    }

    /// The bubble is the phase the pressure model exists for; pin that it is non-zero so
    /// the parameterised test above cannot pass by mapping everything to zero.
    @Test("The bubble applies real pressure")
    func bubbleAppliesPressure() {
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let s = settings()
        s.gameMode = .tournament
        s.tournamentPhase = .bubble

        #expect(s.solverSettings.icmPressure > 0.3,
                "the bubble reported \(s.solverSettings.icmPressure)")
    }
}

// MARK: - Players still in the hand

@Suite("Players in the hand", .timeLimit(.minutes(3)))
struct PlayersInHandTests {

    @Test("Opponent count follows the players still contesting the pot")
    func opponentCountDerivesFromPlayersInHand() {
        let state = GameState()

        state.playersInHand = 2
        #expect(state.opponentCount == 1)

        state.playersInHand = 9
        #expect(state.opponentCount == 8)

        // A hand always has at least one opponent to price against.
        state.playersInHand = 1
        #expect(state.opponentCount == 1)
    }

    /// The table can seat nine while only two players see the river. Equity has to be
    /// priced against the players still in the pot, not against every seat.
    @Test("Equity is priced against the players still in the hand, not the table size")
    func equityFollowsPlayersInHand() async {
        let snapshot = DefaultsSnapshot()
        defer { snapshot.restore() }

        let settings = Settings()
        settings.numberOfPlayers = 9        // deliberately unlike the live player count

        func equity(playersInHand: Int) async throws -> Double {
            let state = await GameState()
            await MainActor.run {
                state.holeCards = [card("Ad"), card("Ac")]
                state.potSize = 10
                state.toCall = 0
                // Seats before players: `GameStateCopy` now seats players into the table
                // rather than growing the table to fit them, so a nine-way pot needs a
                // nine-handed table or the count is clamped back to the default six.
                state.tableSize = 9
                state.playersInHand = playersInHand
            }
            let result = try await CalculationViewModel()
                .calculateFromCopy(gameState: GameStateCopy(from: state), settings: settings)
            return result.equity
        }

        let headsUp = try! await equity(playersInHand: 2)
        let nineWay = try! await equity(playersInHand: 9)

        #expect(headsUp > nineWay + 0.30,
                "heads-up \(headsUp) vs nine-way \(nineWay) — the live player count is being ignored")
    }
}
}   // SettingsBackedStateTests
