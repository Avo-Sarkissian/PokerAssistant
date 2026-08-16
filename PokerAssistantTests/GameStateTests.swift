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
