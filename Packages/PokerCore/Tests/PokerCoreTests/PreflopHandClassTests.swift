import Testing
import Foundation
@testable import PokerCore
import PokerTestSupport

// MARK: - Two consumers, two questions

/// `OpponentRange`'s 169-hand list answers two different questions in this codebase:
///
/// 1. **How wide is villain's range?** — `isHandInRange` walks the list to decide which
///    holdings a "top 20%" opponent is representing. That is what the list measures.
/// 2. **How strong is hero's hand?** — the solver grades hero preflop from the same list.
///    That is a different question, and the list is a knowingly imperfect answer to it:
///    `openingRangeOrderIsNotAShowdownStrengthOrder` measures how imperfect.
///
/// Backlog #29 was not that the two share a list. It was that hero's grade came from the
/// list for ranks 0–75 and from *equity* above that, so charted and uncharted hands were
/// graded on two different scales and K6o graded above 65s despite ranking 27 places
/// worse. `preflopGradeIsMonotoneInTheOpeningRangeOrder` is the guard on the fix.
@Suite("Preflop hand class", .timeLimit(.minutes(3)))
struct PreflopHandClassTests {

    /// The invariant that kills the inversion: walking the whole 169-class order, hero's
    /// grade may never improve as the rank gets worse. Any scheme that reads two scales at
    /// once breaks this somewhere, which is why it is asserted over every class rather
    /// than at the pair that happened to be reported.
    @Test("Hero's preflop grade never improves as the hand ranks worse")
    func preflopGradeIsMonotoneInTheOpeningRangeOrder() {
        // Strongest first, so the grade must be non-increasing across the list.
        let order: [ExploitativeSolver.HandStrength] = [.monster, .strong, .medium, .weak, .bluff]
        func rung(_ grade: ExploitativeSolver.HandStrength) -> Int { order.firstIndex(of: grade)! }

        var previous = 0
        var worst: [String] = []
        for rank in 0...168 {
            let here = rung(ExploitativeSolver.HandStrength(openingRangeRank: rank))
            if here < previous && worst.count < 6 {
                worst.append("rank \(rank) grades \(order[here]), better than rank \(rank - 1)")
            }
            previous = max(previous, here)
        }
        #expect(worst.isEmpty, Comment(rawValue: worst.joined(separator: "\n")))

        // And the specific pair the backlog named, through the public API.
        let sixFiveSuited = cards("6s 5s")
        let kingSixOffsuit = cards("Kh 6c")
        let scGrade = ExploitativeSolver.HandStrength(
            openingRangeRank: OpponentRange.openingRangeRank(sixFiveSuited[0], sixFiveSuited[1]))
        let bcGrade = ExploitativeSolver.HandStrength(
            openingRangeRank: OpponentRange.openingRangeRank(kingSixOffsuit[0], kingSixOffsuit[1]))
        #expect(rung(scGrade) <= rung(bcGrade),
                "65s grades \(scGrade) and the 27-places-worse K6o grades \(bcGrade)")
    }

    /// Every rank must land somewhere: a ladder with a hole in it would fall through to
    /// whatever the last `default` said, which is how the equity fallback got in.
    @Test("Every one of the 169 ranks grades, and all five grades are used")
    func theLadderIsTotal() {
        let grades = (0...168).map { ExploitativeSolver.HandStrength(openingRangeRank: $0) }
        #expect(Set(grades).count == 5,
                "the ladder produces \(Set(grades).count) grades, not 5")
        // Pinned boundaries. These are the tier boundaries in `rankedHands`, and moving
        // one changes the app's advice, so they are written out rather than derived.
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 0) == .monster)
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 4) == .monster)
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 5) == .strong)
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 12) == .strong)
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 13) == .medium)
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 45) == .medium)
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 46) == .weak)
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 110) == .weak)
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 111) == .bluff)
        #expect(ExploitativeSolver.HandStrength(openingRangeRank: 168) == .bluff)
    }

    /// Preflop the grade must not move with the equity it is handed, because equity
    /// preflop moves with the *opponent count* and the *range read* rather than with
    /// hero's hand. Grading by equity made aces a `.bluff` against eight opponents and
    /// cost the short-stack shove; this is the guard against that returning.
    @Test("Preflop grading ignores equity, so opponent count cannot demote a hand")
    func preflopGradeIsIndependentOfEquity() {
        let solver = ExploitativeSolver()
        let settings = makeSettings()

        // Aces on an 8bb stack over three limpers: SPR 1.78, so the short-stack commit
        // rule decides this hand. Equity against four opponents is ~0.56, which as a
        // *grade* would be `.medium` and would skip the shove.
        func advice(equity: Double) -> ExploitativeSolver.SolverResult {
            solver.solve(gameState: spot(hole: "Ad Ac", pot: 4.5, toCall: 1.0,
                                         stack: 8, villainStack: 8,
                                         position: .btn, playersInHand: 5, tableSize: 6),
                         myEquity: equity, settings: settings)
        }

        let asMeasured = advice(equity: 0.557)   // AA vs 4 opponents
        let asHeadsUp = advice(equity: 0.852)    // AA vs 1 opponent

        #expect(asMeasured.raiseAmount == asHeadsUp.raiseAmount,
                Comment(rawValue: "the same aces sized to \(asMeasured.raiseAmount) at 4-way " +
                        "equity and \(asHeadsUp.raiseAmount) at heads-up equity"))
        #expect(asMeasured.action == asHeadsUp.action)
    }

    /// The evidence that the list is a poor stand-in for strength, measured rather than
    /// asserted: 65s stands 27 places *above* K6o in the opening-range order, and holds
    /// eleven points *less* all-in equity against a random hand.
    ///
    /// This is also the receipt for the list's own doc comment, which used to claim the
    /// order was by preflop all-in equity against a random hand. It is not.
    @Test("The opening-range order is not a showdown-strength order")
    func openingRangeOrderIsNotAShowdownStrengthOrder() async {
        let engine = MonteCarloEngine()
        func allInEquity(_ hole: String) async -> Double {
            await engine.simulate(
                hand: Hand(holeCards: cards(hole), communityCards: []),
                opponents: 1, deadCards: [], iterations: 600_000,
                opponentRange: .random, confidenceThreshold: 0.0,
                maxTimeSeconds: 120, seed: 0xC0FFEE)
        }

        let suitedConnector = cards("6s 5s")   // 65s
        let bigCardOffsuit = cards("Kh 6c")    // K6o

        let scRank = OpponentRange.openingRangeRank(suitedConnector[0], suitedConnector[1])
        let bcRank = OpponentRange.openingRangeRank(bigCardOffsuit[0], bigCardOffsuit[1])
        #expect(scRank == 75, "65s moved in the ordering: now \(scRank)")
        #expect(bcRank == 102, "K6o moved in the ordering: now \(bcRank)")
        #expect(bcRank - scRank == 27,
                "the gap this test is about is now \(bcRank - scRank) places, not 27")

        let scEquity = await allInEquity("6s 5s")
        let bcEquity = await allInEquity("Kh 6c")

        #expect(bcEquity > scEquity + 0.05,
                Comment(rawValue: "the worse-ranked hand no longer holds more equity: " +
                        "65s \(scEquity) vs K6o \(bcEquity) — re-derive this test's premise"))
    }

    /// What the list is primarily for. A hand that ranks better must be inside every range
    /// the worse-ranked hand is inside; a range that admitted a hand while excluding a
    /// better one would not be a "top X%" of anything.
    @Test("Range membership is monotone in the opening-range order")
    func rangeMembershipIsMonotoneInTheOrdering() {
        let deck = Card.deck()
        var byRank: [Int: (Card, Card)] = [:]
        for i in 0..<deck.count {
            for j in (i + 1)..<deck.count {
                byRank[OpponentRange.openingRangeRank(deck[i], deck[j])] = (deck[i], deck[j])
            }
        }
        #expect(byRank.count == 169, "the ordering covers \(byRank.count) classes, not 169")

        let ranks = byRank.keys.sorted()
        for range in [OpponentRange.RangeType.veryTight, .tight, .standard, .wide, .veryWide] {
            var sawOutsider = false
            for rank in ranks {
                let (a, b) = byRank[rank]!
                let inside = OpponentRange.isHandInRange(a, b, range: range)
                if !inside { sawOutsider = true }
                if inside && sawOutsider {
                    Issue.record(Comment(rawValue:
                        "\(range) admits rank \(rank) (\(OpponentRange.canonicalHand(a, b))) " +
                        "while excluding something ranked better"))
                    break
                }
            }
        }
    }
}

// MARK: - Committing a short stack

/// The `spr < 2 && (monster || strong)` branch in `calculateOptimalRaiseSize` had **no
/// coverage at all**: disabling it left all 119 tests green. In every low-SPR spot the
/// suite built, the stub-shove guard and the legality clamp independently returned the
/// same number, so nothing could tell the branch from its neighbours.
///
/// These tests distinguish it: the stack is deep enough that the stub guard cannot fire
/// (`chipsBehind - legal` stays above a big blind), so a shove can only come from the
/// commit rule. This is also the branch that grading preflop by equity silently disabled
/// for aces in limped pots.
@Suite("Committing a short stack")
struct ShortStackCommitTests {

    private let solver = ExploitativeSolver()

    /// Aces, 8bb behind, three limpers: SPR 1.78. A sized raise here would be 5.5bb of an
    /// 8bb stack, leaving a 2.5bb stub — too little to fold anyone out, which hero then
    /// has to ship blind on the flop.
    @Test("A premium hand at SPR below 2 commits rather than leaving a stub")
    func premiumHandShovesBelowSPRTwo() {
        let stack = 8.0
        let result = solver.solve(
            gameState: spot(hole: "Ad Ac", pot: 4.5, toCall: 1.0, stack: stack,
                            villainStack: stack, position: .btn,
                            playersInHand: 5, tableSize: 6),
            myEquity: 0.557, settings: makeSettings())

        #expect(result.spr < 2, "SPR is \(result.spr); this spot no longer tests the branch")
        #expect(abs(result.raiseAmount - (stack - 1.0)) < 1e-9,
                "committed \(result.raiseAmount) of the \(stack - 1.0) behind")
        #expect(result.reasoning.contains("All-in"),
                Comment(rawValue: "an all-in was announced as: \(result.reasoning)"))
    }

    /// The other side of the same boundary, so the test cannot pass by shoving always.
    /// Same hand, same limpers, a stack deep enough that SPR clears 2.
    @Test("The same hand above SPR 2 sizes a raise instead of committing")
    func premiumHandSizesAboveSPRTwo() {
        let stack = 20.0
        let result = solver.solve(
            gameState: spot(hole: "Ad Ac", pot: 4.5, toCall: 1.0, stack: stack,
                            villainStack: stack, position: .btn,
                            playersInHand: 5, tableSize: 6),
            myEquity: 0.557, settings: makeSettings())

        #expect(result.spr >= 2, "SPR is \(result.spr); this spot no longer tests the branch")
        #expect(result.raiseAmount < stack - 1.0 - 1e-9,
                "shoved \(result.raiseAmount) of \(stack - 1.0) behind at SPR \(result.spr)")
        #expect(!result.reasoning.contains("All-in"),
                Comment(rawValue: "a sized raise was announced as an all-in: \(result.reasoning)"))
    }

    /// The commit rule is for hands worth committing. A trash hand in the same short-stack
    /// spot must not be jammed, or the branch is just "always shove when shallow".
    @Test("A trash hand at the same SPR is not committed")
    func trashHandDoesNotShoveBelowSPRTwo() {
        let stack = 8.0
        let result = solver.solve(
            gameState: spot(hole: "7d 2c", pot: 4.5, toCall: 1.0, stack: stack,
                            villainStack: stack, position: .btn,
                            playersInHand: 5, tableSize: 6),
            myEquity: 0.557, settings: makeSettings())

        #expect(result.spr < 2)
        // 72o grades `.bluff`, so the commit rule must not fire. Whatever the sizing does
        // afterwards, it must not be a jam of everything behind.
        if case .raise(let amount) = result.action {
            #expect(amount < stack - 1.0 - 1e-9,
                    "72o jammed \(amount) of the \(stack - 1.0) behind")
        }
    }

    /// The reasoning string must describe the action taken, not the grade that usually
    /// produces it. The stub rule and the legality clamp both return `chipsBehind` at any
    /// grade, so an all-in used to be announced as "raising for value".
    @Test("Any raise that puts the last chip in is announced as an all-in")
    func everyShoveIsAnnouncedAsOne() {
        let settings = makeSettings()
        var checked = 0

        for hole in ["Ad Ac", "9d 9c", "Jd Tc", "7d 2c"] {
            for stack in [3.0, 4.75, 6.0, 8.0, 12.0] {
                for (pot, toCall) in [(1.5, 1.0), (2.5, 1.0), (4.0, 2.5), (4.5, 1.0)] {
                    let result = solver.solve(
                        gameState: spot(hole: hole, pot: pot, toCall: toCall, stack: stack,
                                        villainStack: stack, position: .btn,
                                        playersInHand: 2, tableSize: 6),
                        myEquity: 0.60, settings: settings)

                    guard case .raise(let amount) = result.action else { continue }
                    let isShove = amount >= stack - toCall - 1e-9
                    guard isShove else {
                        #expect(!result.reasoning.contains("All-in"),
                                Comment(rawValue: "\(hole) \(stack)bb pot \(pot): sized raise " +
                                        "of \(amount) announced as an all-in"))
                        continue
                    }
                    checked += 1
                    #expect(result.reasoning.contains("All-in"),
                            Comment(rawValue: "\(hole) \(stack)bb pot \(pot) call \(toCall): " +
                                    "all-in for \(amount) announced as: \(result.reasoning)"))
                }
            }
        }
        #expect(checked > 10, "the sweep produced only \(checked) shoves — widen it")
    }
}
