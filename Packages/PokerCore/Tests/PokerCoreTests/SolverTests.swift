import Testing
import Foundation
import PokerCore
import PokerTestSupport

// MARK: - Spot construction

/// Builds a `GameStateCopy` for the solver directly, with no view model and no
/// UserDefaults in the way. Building one through the app's `GameState` used to leak
/// blind levels into the shipping app's defaults; the solver never needed either.
func spot(hole: String = "Ad Ac",
          board: String = "",
          pot: Double,
          toCall: Double,
          stack: Double = 100,
          villainStack: Double = 100,
          position: String = "BTN",
          playersInHand: Int = 2,
          bigBlind: Double = 1.0,
          opponentStyle: OpponentStyle = .unknown) -> GameStateCopy {
    let holeCards = cards(hole)
    var community: [Card?] = [nil, nil, nil, nil, nil]
    for (i, c) in cards(board).enumerated() where i < 5 { community[i] = c }

    return GameStateCopy(
        holeCards: [holeCards[0], holeCards[1]],
        communityCards: community,
        deadCards: [],
        stack: stack,
        villainStack: villainStack,
        position: position,
        potSize: pot,
        toCall: toCall,
        bigBlind: bigBlind,
        opponentStyle: opponentStyle,
        playersInHand: playersInHand
    )
}

func makeSettings(bigBlind: Double = 1.0, smallBlind: Double = 0.5) -> SolverSettings {
    SolverSettings(smallBlind: smallBlind, bigBlind: bigBlind, icmPressure: 0)
}

private func evOf(_ action: CalculationResult.RecommendedAction,
                  _ result: ExploitativeSolver.SolverResult) -> Double {
    switch action {
    case .fold:  return result.evFold
    case .call:  return result.evCall
    case .raise: return result.evRaise
    }
}

// MARK: - EV algebra

@Suite("Solver EV algebra")
struct SolverEVTests {

    /// The textbook price of a call: win the pot plus villain's bet with probability
    /// `equity`, otherwise lose the call. No positional adjustment belongs in a figure
    /// the app labels as dollars.
    @Test("Call EV is equity times the final pot, minus the call")
    func callEVMatchesTextbookFormula() {
        let solver = ExploitativeSolver()
        let result = solver.solve(gameState: spot(pot: 100, toCall: 50),
                                  myEquity: 0.60, settings: makeSettings())

        // 0.60 * (100 + 50) - 50 = 40
        #expect(abs(result.evCall - 40.0) < 1e-9, "evCall was \(result.evCall), expected 40")
        #expect(result.evFold == 0, "folding forfeits chips already in the pot; its EV is 0")
    }

    /// Position changes which action is right; it does not change how many dollars a
    /// call is worth. Scaling the reported EV by seat made "Expected: +$X" a fiction.
    @Test("Reported EV does not depend on seat")
    func evIsIndependentOfPosition() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()

        let onButton = solver.solve(gameState: spot(pot: 100, toCall: 50, position: "BTN"),
                                    myEquity: 0.60, settings: settings)
        let inSmallBlind = solver.solve(gameState: spot(pot: 100, toCall: 50, position: "SB"),
                                        myEquity: 0.60, settings: settings)

        #expect(abs(onButton.evCall - inSmallBlind.evCall) < 1e-9,
                "BTN \(onButton.evCall) vs SB \(inSmallBlind.evCall)")
    }

    /// A losing call must be reported as losing by the amount it actually loses.
    @Test("A bad call is priced at its true loss")
    func badCallIsPricedHonestly() {
        let solver = ExploitativeSolver()
        let result = solver.solve(gameState: spot(pot: 20, toCall: 80, position: "SB"),
                                  myEquity: 0.20, settings: makeSettings())

        // 0.20 * (20 + 80) - 80 = -60
        #expect(abs(result.evCall - (-60.0)) < 1e-9, "evCall was \(result.evCall), expected -60")
    }
}

// MARK: - Fold equity

@Suite("Fold equity")
struct FoldEquityTests {

    /// A player who is already all in cannot fold. Crediting fold equity against them
    /// manufactures the EV that drives the recommendation.
    @Test("No fold equity against a villain who is already all in")
    func noFoldEquityVersusAnAllInVillain() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()

        // Villain has shoved: their remaining stack is zero beyond the bet hero faces.
        let allIn = solver.solve(
            gameState: spot(pot: 60, toCall: 40, stack: 200, villainStack: 40, playersInHand: 2),
            myEquity: 0.45, settings: settings)

        // With no fold equity a raise can be worth no more than calling.
        #expect(allIn.evRaise <= allIn.evCall + 1e-9,
                "raise \(allIn.evRaise) beat call \(allIn.evCall) against an all-in villain")
    }

    /// Everyone has to fold, so fold equity compounds downward with each extra player.
    @Test("Fold equity falls as more players must fold")
    func foldEquityFallsWithMoreOpponents() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()

        func raiseEV(players: Int) -> Double {
            solver.solve(gameState: spot(board: "Ks 7h 2d", pot: 60, toCall: 20,
                                         playersInHand: players),
                         myEquity: 0.45, settings: settings).evRaise
        }

        let headsUp = raiseEV(players: 2)
        let threeWay = raiseEV(players: 3)
        let sixWay = raiseEV(players: 6)

        #expect(threeWay < headsUp, "3-way \(threeWay) should be below heads-up \(headsUp)")
        #expect(sixWay < threeWay, "6-way \(sixWay) should be below 3-way \(threeWay)")
    }
}

// MARK: - Legal actions

@Suite("Legal actions")
struct LegalActionTests {

    /// A recommendation the player cannot physically make is worse than no
    /// recommendation: a zero raise, or one larger than the chips on the table.
    @Test("Every recommended raise is a legal size")
    func recommendedRaisesAreLegal() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()
        var checked = 0

        for equity in stride(from: 0.05, through: 0.95, by: 0.10) {
            for pot in [3.0, 20.0, 150.0] {
                for toCall in [0.0, 2.0, 25.0, 140.0] {
                    for stack in [12.0, 60.0, 300.0] {
                        let result = solver.solve(
                            gameState: spot(board: "Ks 7h 2d", pot: pot, toCall: toCall,
                                            stack: stack, villainStack: stack),
                            myEquity: equity, settings: settings)

                        guard case .raise(let amount) = result.action else { continue }
                        checked += 1

                        #expect(amount > 0, "raise of \(amount) at pot \(pot) call \(toCall) stack \(stack)")
                        #expect(toCall + amount <= stack + 1e-9,
                                "raise to \(toCall + amount) exceeds the \(stack) stack")
                        // A raise must at least match what is already owed, unless it
                        // is a shove for everything that is left.
                        let isShove = abs((toCall + amount) - stack) < 1e-6
                        #expect(amount >= toCall - 1e-9 || isShove,
                                "raise of \(amount) is below the \(toCall) already owed and is not a shove")
                    }
                }
            }
        }
        #expect(checked > 20, "the sweep produced only \(checked) raises — widen it")
    }

    /// Hero cannot raise with nothing behind; the only actions are call-all-in or fold.
    @Test("A hero with no chips behind is never told to raise")
    func noRaiseWithoutChipsBehind() {
        let solver = ExploitativeSolver()
        let result = solver.solve(
            gameState: spot(pot: 100, toCall: 40, stack: 40, villainStack: 200),
            myEquity: 0.90, settings: makeSettings())

        if case .raise = result.action {
            Issue.record(Comment(rawValue: "recommended a raise with the entire stack already required to call"))
        }
    }
}

// MARK: - Decision follows the EVs

@Suite("Decision consistency")
struct DecisionConsistencyTests {

    /// The banner and the alternatives panel beneath it are two views of one decision.
    /// When the recommendation is not the argmax of the app's own EV table, the card
    /// contradicts itself in front of the user.
    @Test("The recommended action is the best of the three EVs")
    func recommendationMatchesArgmaxOfItsOwnEVs() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()
        var spots = 0
        var mismatches: [String] = []

        for equity in stride(from: 0.05, through: 0.95, by: 0.05) {
            for pot in [5.0, 30.0, 120.0] {
                for toCall in [0.0, 4.0, 30.0, 90.0] {
                    for position in ["BTN", "SB", "BB"] {
                        for players in [2, 4] {
                            let state = spot(board: "Ks 7h 2d", pot: pot, toCall: toCall,
                                             stack: 200, villainStack: 200,
                                             position: position, playersInHand: players)
                            let result = solver.solve(gameState: state, myEquity: equity,
                                                      settings: settings)
                            spots += 1

                            let chosen = evOf(result.action, result)
                            let best = max(result.evFold, max(result.evCall, result.evRaise))

                            if chosen < best - 1e-6 && mismatches.count < 8 {
                                mismatches.append(
                                    "eq \(String(format: "%.2f", equity)) pot \(pot) call \(toCall) " +
                                    "\(position) \(players)p → \(result.action.displayString) " +
                                    "(ev \(String(format: "%.2f", chosen))) but best was " +
                                    "\(String(format: "%.2f", best))")
                            }
                        }
                    }
                }
            }
        }

        let mismatchReport = "\(mismatches.count)+ of \(spots) spots disagreed with their own EVs:\n"
            + mismatches.joined(separator: "\n")
        #expect(mismatches.isEmpty, Comment(rawValue: mismatchReport))
    }

    /// Never recommend an action the app prices below zero while folding is available.
    @Test("No negative-EV action is recommended when folding is on the table")
    func neverRecommendsANegativeEVActionOverFolding() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()
        var offenders: [String] = []

        for equity in stride(from: 0.02, through: 0.60, by: 0.04) {
            for toCall in [10.0, 50.0, 120.0] {
                let result = solver.solve(
                    gameState: spot(board: "Ks 7h 2d", pot: 30, toCall: toCall,
                                    stack: 200, villainStack: 200),
                    myEquity: equity, settings: settings)

                if case .fold = result.action { continue }
                let chosen = evOf(result.action, result)
                if chosen < -1e-6 && offenders.count < 6 {
                    offenders.append("eq \(String(format: "%.2f", equity)) call \(toCall) -> " +
                                     "\(result.action.displayString) at \(String(format: "%.2f", chosen))")
                }
            }
        }

        let offenderReport = "recommended negative-EV actions:\n" + offenders.joined(separator: "\n")
        #expect(offenders.isEmpty, Comment(rawValue: offenderReport))
    }

    /// Checking is free, so folding can never be the recommendation.
    @Test("Never fold when checking costs nothing")
    func neverFoldsForFree() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()

        for equity in stride(from: 0.02, through: 0.98, by: 0.08) {
            let result = solver.solve(
                gameState: spot(board: "Ks 7h 2d", pot: 40, toCall: 0),
                myEquity: equity, settings: settings)

            if case .fold = result.action {
                let message = "folded at equity \(equity) with nothing to call"
                Issue.record(Comment(rawValue: message))
            }
        }
    }
}
