import Testing
import Foundation
import PokerCore
import PokerTestSupport

// MARK: - Spot construction

/// Builds a `GameStateCopy` for the solver directly, with no view model and no
/// UserDefaults in the way. Building one through the app's `GameState` used to leak
/// blind levels into the shipping app's defaults; the solver never needed either.
/// `tableSize` defaults to six because that is the app's own default and the size every
/// seat assertion in the suite is stated at. It is a *test* default only — `GameStateCopy`
/// requires it, because relative position changes with it and a silent default would let
/// the app forget to pass it.
func spot(hole: String = "Ad Ac",
          board: String = "",
          pot: Double,
          toCall: Double,
          stack: Double = 100,
          villainStack: Double = 100,
          position: Position = .btn,
          playersInHand: Int = 2,
          tableSize: Int = 6,
          heroActsLast: Bool? = nil,
          bigBlind: Double = 1.0,
          heroWagerThisStreet: Double = 0,
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
        playersInHand: playersInHand,
        tableSize: tableSize,
        // Defaults to what the seat implies, which is what the app defaults to. Pass it
        // explicitly to test a hero who says otherwise.
        heroActsLast: heroActsLast ?? position.isInPosition(tableSize: tableSize),
        heroWagerThisStreet: heroWagerThisStreet
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

        let onButton = solver.solve(gameState: spot(pot: 100, toCall: 50, position: .btn),
                                    myEquity: 0.60, settings: settings)
        let inSmallBlind = solver.solve(gameState: spot(pot: 100, toCall: 50, position: .sb),
                                        myEquity: 0.60, settings: settings)

        #expect(abs(onButton.evCall - inSmallBlind.evCall) < 1e-9,
                "BTN \(onButton.evCall) vs SB \(inSmallBlind.evCall)")
    }

    /// Hero can only call for what is in front of them, and the part of villain's bet
    /// hero cannot cover is returned to villain rather than contested. Counting it makes
    /// a desperate call look like the best spot of the session.
    @Test("A call for less than the bet contests only the chips hero can match")
    func shortStackCallContestsOnlyMatchedChips() {
        let solver = ExploitativeSolver()
        // Pot 150 with villain's 140 already in it, so 10 was in the middle before.
        // Hero has 12 behind and 95% equity.
        let result = solver.solve(
            gameState: spot(pot: 150, toCall: 140, stack: 12, villainStack: 200),
            myEquity: 0.95, settings: makeSettings())

        // Contested: the 10 already there, the 12 hero puts in, and the 12 of villain's
        // bet that hero's 12 actually matches. 0.95 * 34 − 12 = 20.30.
        #expect(abs(result.evCall - 20.30) < 1e-9,
                "evCall was \(result.evCall), expected 20.30 — the other 128 of villain's bet is uncalled")
    }

    /// The same defect stated as the property it violates, independent of the arithmetic:
    /// once villain's bet is past what hero can cover, betting more cannot pay hero more.
    @Test("Raising a bet hero already cannot cover does not improve hero's call")
    func uncallableExcessDoesNotImproveTheCall() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()

        // Same 10 in the middle before villain acts, same 12 behind for hero.
        func callEV(villainBet: Double) -> Double {
            solver.solve(gameState: spot(pot: 10 + villainBet, toCall: villainBet,
                                         stack: 12, villainStack: 200),
                         myEquity: 0.95, settings: settings).evCall
        }

        let coverable = callEV(villainBet: 20)
        let overbet = callEV(villainBet: 140)

        #expect(abs(coverable - overbet) < 1e-9,
                "a bigger uncallable bet changed hero's call from \(coverable) to \(overbet)")
    }

    /// A losing call must be reported as losing by the amount it actually loses.
    @Test("A bad call is priced at its true loss")
    func badCallIsPricedHonestly() {
        let solver = ExploitativeSolver()
        let result = solver.solve(gameState: spot(pot: 20, toCall: 80, position: .sb),
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
    ///
    /// The obvious assertion — that a raise is worth no more than a call — is **vacuous
    /// here**, and was for as long as this test existed. When villain cannot continue,
    /// `solve` sets `canRaise` to false and assigns `evRaise = evCall`, so the inequality
    /// holds by construction whatever fold equity does. Deleting `villainCanContinue`
    /// from `canRaise` left it passing.
    ///
    /// What is asserted instead is what the rule actually promises: there is no raise on
    /// offer at all, it is priced at exactly what calling is worth rather than at
    /// something close to it, and it is not what the app recommends.
    @Test("No fold equity against a villain who is already all in")
    func noFoldEquityVersusAnAllInVillain() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()

        // Villain has shoved: their remaining stack is zero beyond the bet hero faces.
        let allIn = solver.solve(
            gameState: spot(pot: 60, toCall: 40, stack: 200, villainStack: 40, playersInHand: 2),
            myEquity: 0.45, settings: settings)

        #expect(allIn.raiseAmount == 0,
                Comment(rawValue: "offered a raise of \(allIn.raiseAmount) into a player "
                        + "with nothing behind"))
        #expect(allIn.evRaise == allIn.evCall,
                Comment(rawValue: "raising into a player who cannot call must be worth "
                        + "exactly what calling is worth — raise \(allIn.evRaise), "
                        + "call \(allIn.evCall)"))
        if case .raise = allIn.action {
            Issue.record("recommended a raise against a villain who is already all in")
        }
    }

    /// Facing a bet larger than the stack behind it. There is no raise to make, so there
    /// must be no raise to price — and pricing one anyway is not invisible: `evRaise`
    /// reaches the alternatives list on the result card.
    ///
    /// This is what the `chipsBehind > 0` half of the raise-legality guard is for. The
    /// action is unchanged without it, because a zero-size raise never becomes a
    /// candidate, which is why an earlier comment here called the two halves of that guard
    /// interchangeable. They are not: dropping this one prices the impossible raise at
    /// 32.0 against a call worth 8.0.
    @Test("A hero who cannot cover the bet is not offered a raise")
    func heroWhoCannotCoverIsNotOfferedARaise() {
        let solver = ExploitativeSolver()
        let facingMoreThanTheStack = solver.solve(
            gameState: spot(pot: 60, toCall: 50, stack: 10, villainStack: 100, playersInHand: 2),
            myEquity: 0.60, settings: makeSettings())

        #expect(facingMoreThanTheStack.raiseAmount == 0)
        #expect(facingMoreThanTheStack.evRaise == facingMoreThanTheStack.evCall,
                Comment(rawValue: "a raise hero cannot make priced at "
                        + "\(facingMoreThanTheStack.evRaise) against a call worth "
                        + "\(facingMoreThanTheStack.evCall)"))
    }

    /// Hero's equity is exactly the pot odds, so calling and folding are worth precisely
    /// the same and the tie rule is the only thing left to decide it.
    ///
    /// The numbers are chosen to be exact in binary rather than nearly exact: hero can
    /// cover, so the contested pot is 150 + 50 = 200, and 0.25 × 200 − 50 is 0.0 with no
    /// rounding anywhere. Without that the test would be measuring the last bit of a
    /// division instead of the rule.
    ///
    /// `makeDecision` documents "ties resolve toward the least aggressive action, which
    /// keeps variance down when two lines are worth the same", and nothing checked it:
    /// relaxing `> best.ev + 1e-9` to `>= best.ev` passed every test in both targets.
    @Test("A tie resolves toward the least aggressive action")
    func tiesResolveTowardTheLeastAggressiveAction() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()
        let breakEven = solver.solve(
            gameState: spot(pot: 150, toCall: 50, stack: 200, villainStack: 200, playersInHand: 2),
            myEquity: 0.25, settings: settings)

        #expect(breakEven.evCall == breakEven.evFold,
                Comment(rawValue: "the spot is not the tie it was built to be: call "
                        + "\(breakEven.evCall) against fold \(breakEven.evFold)"))
        #expect(breakEven.action == .fold,
                Comment(rawValue: "a break-even call was taken rather than declined: "
                        + "\(breakEven.action)"))

        // …and the rule is a tie-breaker, not a thumb on the scale: a hair more equity
        // and the call is on.
        let justAhead = solver.solve(
            gameState: spot(pot: 150, toCall: 50, stack: 200, villainStack: 200, playersInHand: 2),
            myEquity: 0.26, settings: settings)
        #expect(justAhead.action != .fold,
                Comment(rawValue: "folded a call worth \(justAhead.evCall)"))
    }

    /// Villain cannot see hero's cards, so hero's cards cannot change how often villain
    /// folds. The model used to disagree: the position premium was applied only when hero
    /// held a hand graded `.bluff` or `.weak`, which made villain's folding a function of
    /// information villain does not have.
    ///
    /// Reading the fold frequency back out of the solver's own arithmetic is the only way
    /// to see it through the public API, and it needs the bet size held still — grade
    /// normally drives sizing too. Hero is left with less behind than a minimum raise, so
    /// every grade shoves the same 20 chips, and the only difference between the two calls
    /// below is hero's equity:
    ///
    ///     evRaise = f·pot + (1 − f)·(equity·potIfCalled − cost)
    ///     ⟹  f = (evRaise − w) / (pot − w),   w = equity·potIfCalled − cost
    @Test("Hero's hand does not change how often villain folds")
    func villainsFoldingIgnoresHerosCards() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()

        func impliedFoldFrequency(equity: Double) -> Double {
            let state = spot(board: "Ks 7h 2d", pot: 100, toCall: 40,
                             stack: 60, villainStack: 200, position: .btn)
            let result = solver.solve(gameState: state, myEquity: equity, settings: settings)
            // Hero cannot make a legal raise, so the only aggression on offer is the shove.
            #expect(result.raiseAmount == 20,
                    Comment(rawValue: "expected the 20-chip shove, got \(result.raiseAmount)"))
            let cost = 60.0                       // min(toCall + shove, effective stack)
            let potIfCalled = 100.0 + cost + 20.0 // pot + hero's outlay + villain's call
            let whenCalled = equity * potIfCalled - cost
            return (result.evRaise - whenCalled) / (100.0 - whenCalled)
        }

        // 0.20 grades `.bluff`, 0.90 grades `.monster`. Villain can tell these apart only
        // if the model is showing them hero's hand.
        let asBluff = impliedFoldFrequency(equity: 0.20)
        let asMonster = impliedFoldFrequency(equity: 0.90)

        #expect(abs(asBluff - asMonster) < 1e-9,
                Comment(rawValue: "villain folds \(asBluff) against hero's air and "
                        + "\(asMonster) against hero's monster, in the same spot, "
                        + "for the same bet"))
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
                    for position in Position.seats(tableSize: 6) {
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
                                    "\(position.rawValue) \(players)p → \(result.action.displayString) " +
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


// MARK: - What the result card says

/// The recommendation is displayed as a *total* — "RAISE to $X" — and a total has to
/// include the money hero already has in front of them. It did not.
@Suite("Recommendation display")
struct RecommendationDisplayTests {

    /// The spot from the review: a small blind opening to 3bb in a $1 game. Hero posted
    /// $0.50, owes $0.50 to match the big blind, and the solver sizes the raise at $2.00
    /// on top. The total is $3.00 — but the blind was left out, so it read $2.50, which is
    /// exactly what a button open shows, hiding the out-of-position premium the preflop
    /// sizing deliberately adds.
    @Test("A raise from a blind is announced at its true total")
    func aRaiseFromABlindIncludesThePostedBlind() {
        let opened = CalculationResult.RecommendedAction.raise(amount: 2.00)

        #expect(opened.displayStringWithContext(toCall: 0.50, heroWagerThisStreet: 0.50)
                == "RAISE to $3.00 (+$2.00 more)")
        // The button posts nothing, so the same raise is a smaller total — which is the
        // difference the display was hiding.
        #expect(opened.displayStringWithContext(toCall: 0.50, heroWagerThisStreet: 0)
                == "RAISE to $2.50 (+$2.00 more)")
    }

    /// A first bet with nothing already committed is a bet, not a raise to anything.
    @Test("An opening bet is still a bet")
    func anOpeningBetIsNotARaise() {
        let bet = CalculationResult.RecommendedAction.raise(amount: 12.00)
        #expect(bet.displayStringWithContext(toCall: 0, heroWagerThisStreet: 0) == "BET $12.00")
    }

    /// The big blind raising an unopened pot owes nothing but has a blind in front of
    /// them, so it is a raise to more than it adds.
    @Test("The big blind raising a limped pot is raising, not betting")
    func theBigBlindRaisingALimpedPotIsARaise() {
        let raise = CalculationResult.RecommendedAction.raise(amount: 4.00)
        #expect(raise.displayStringWithContext(toCall: 0, heroWagerThisStreet: 1.00)
                == "RAISE to $5.00 (+$4.00 more)")
    }
}
