import Testing
import Foundation
@testable import PokerAssistant

// MARK: - Reproducibility

@Suite("Reproducibility", .timeLimit(.minutes(3)))
struct ReproducibilityTests {

    /// Without a seed the engine is free to differ run to run, but a caller that
    /// supplies one must get the same number back every time — otherwise no
    /// regression test can ever pin an equity.
    @Test("The same seed produces the same equity")
    func seededRunsAreReproducible() async {
        let engine = MonteCarloEngine()
        func run() async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
                opponents: 3,
                deadCards: [],
                iterations: 120_000,
                opponentRange: .random,
                confidenceThreshold: 0.0,   // never terminate early
                maxTimeSeconds: 60,
                seed: 0xA11CE
            )
        }
        let first = await run()
        let second = await run()

        #expect(first == second, "seeded runs diverged: \(first) vs \(second)")
    }

    @Test("Different seeds explore different samples")
    func differentSeedsDiffer() async {
        let engine = MonteCarloEngine()
        func run(seed: UInt64) async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
                opponents: 3,
                deadCards: [],
                iterations: 120_000,
                opponentRange: .random,
                confidenceThreshold: 0.0,
                maxTimeSeconds: 60,
                seed: seed
            )
        }
        let a = await run(seed: 1)
        let b = await run(seed: 2)

        #expect(a != b, "two different seeds produced identical output — is the seed used at all?")
        #expect(abs(a - b) < 0.02, "seeds disagree far more than sampling error allows")
    }
}

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
