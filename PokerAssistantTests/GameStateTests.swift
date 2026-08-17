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

    private func makeViewModel(smallBlind: Double, bigBlind: Double) -> (GameViewModel, Settings) {
        let settings = Settings()
        settings.smallBlind = smallBlind
        settings.bigBlind = bigBlind
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

        viewModel.gameState.opponentStyle = .tight
        #expect(viewModel.getCurrentStateString() != baseline, "opponent style is not in the fingerprint")
        viewModel.gameState.opponentStyle = .unknown

        viewModel.gameState.stack = 999
        #expect(viewModel.getCurrentStateString() != baseline, "stack is not in the fingerprint")
        viewModel.gameState.stack = 20

        viewModel.gameState.playersInHand = 2
        #expect(viewModel.getCurrentStateString() != baseline, "players in hand is not in the fingerprint")
        viewModel.gameState.playersInHand = 6

        // Hero's own street contribution decides how big villain's raise is read to be,
        // which sets both the range and the re-raise size.
        viewModel.gameState.heroWagerThisStreet = 2.5
        #expect(viewModel.getCurrentStateString() != baseline,
                "hero's street wager is not in the fingerprint")
        viewModel.gameState.heroWagerThisStreet = 0

        // The seat sets the bluff premium, the open size and the explanation.
        viewModel.gameState.position = .sb
        #expect(viewModel.getCurrentStateString() != baseline, "the seat is not in the fingerprint")
        viewModel.gameState.position = .btn

        // And the table size sets how far that seat is from the button, so the same seat
        // at a different table size is a different spot.
        viewModel.gameState.tableSize = 9
        #expect(viewModel.getCurrentStateString() != baseline, "table size is not in the fingerprint")
        viewModel.gameState.tableSize = 6

        settings.gameMode = .tournament
        #expect(viewModel.getCurrentStateString() != baseline, "game mode is not in the fingerprint")
        settings.gameMode = .cashGame

        settings.tournamentPhase = .bubble
        #expect(viewModel.getCurrentStateString() != baseline, "tournament phase is not in the fingerprint")
        settings.tournamentPhase = .earlyStage

        // The solver rounds every raise to the small blind and computes SPR from the
        // big blind, so a change to either has to invalidate the fingerprint.
        settings.bigBlind = 5.0
        #expect(viewModel.getCurrentStateString() != baseline, "big blind is not in the fingerprint")
        settings.bigBlind = 1.0

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
    @Test("Shrinking the table moves hero out of a seat it no longer deals")
    func shrinkingTheTableMovesHero() {
        let state = GameState()
        state.tableSize = 9
        state.position = .utg1

        state.tableSize = 3
        state.clampSeatToTable()
        #expect(state.position == .btn, "hero stayed in the \(state.position.rawValue) three-handed")

        state.tableSize = 2
        state.clampSeatToTable()
        #expect(state.position == .sb, "hero stayed in the \(state.position.rawValue) heads-up")

        // A seat that still exists is left alone.
        state.tableSize = 6
        state.position = .co
        state.clampSeatToTable()
        #expect(state.position == .co, "the cutoff exists six-handed and was moved anyway")
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

    /// More players contesting a pot than are seated at the table is not a spot, and the
    /// solver's copy is the last place it can be caught.
    @Test("The solver's copy never seats fewer players than are in the hand")
    func tableSizeNeverBelowPlayersInHand() {
        let state = GameState()
        state.tableSize = 2
        state.position = .sb
        state.playersInHand = 6

        #expect(GameStateCopy(from: state).tableSize >= 6,
                "six players contested a pot at a table seating \(GameStateCopy(from: state).tableSize)")
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
