import Testing
import Foundation
import PokerCore
import PokerTestSupport

// MARK: - Published equity anchors
//
// The third external anchor. The census proves the evaluator sorts hands into the right
// categories; it says nothing about whether an *equity* — a share of a pot, ties split —
// comes out right, and nothing about the engine that produces one. These do.
//
// Two shapes, because they test different things:
//
// - **The aces ladder** runs the production `MonteCarloEngine` against the published
//   equity of a pair of aces facing one through eight random opponents. It is the app's
//   real path, sampling and all, measured against a number from outside the repository at
//   every seat count the app offers. Grading a hand by preflop equity is coupled to the
//   opponent count — that is why preflop grading is chart-based — so the whole ladder
//   matters, not just its ends.
//
// - **The classic matchups** are enumerated exhaustively rather than sampled, so there is
//   no sampling error to hide behind: every one of the C(48,5) = 1,712,304 boards, hand
//   class against hand class. They are the standard hand-versus-hand numbers every poker
//   text prints, and between them they pin the three things a category census cannot:
//   that ties are split rather than awarded, that suitedness is worth what it is worth,
//   and that "pair versus two overcards" lands where it is published to land rather than
//   merely somewhere near a coin flip.

@Suite("Published equity anchors", .timeLimit(.minutes(5)))
struct PublishedEquityLadderTests {

    /// Equity of AA against N random opponents, all in preflop, every board run out.
    /// Standard published figures; they are quoted by seats at the table (2 to 9), which
    /// is one more than the opponent count here.
    static let acesLadder: [(opponents: Int, published: Double)] = [
        (1, 0.8520), (2, 0.7336), (3, 0.6387), (4, 0.5586),
        (5, 0.4920), (6, 0.4358), (7, 0.3879), (8, 0.3463),
    ]

    /// Eight tenths of a point either way, per rung — the tolerance the four existing
    /// heads-up anchors already use, and six to seven standard errors at this sample
    /// size. The run stays unseeded so every invocation is a fresh draw rather than a
    /// frozen one; the sample size is a machine-time decision, not a statistical one.
    static let perRungTolerance = 0.008

    /// Two tenths of a point on the *mean signed error* across the eight rungs, which is
    /// the assertion that actually has teeth.
    ///
    /// Per-rung tolerance has to absorb sampling noise, so it is 80× looser than the
    /// published table itself is accurate — an engine biased by half a point sails
    /// through eight times over. The eight rungs' errors are independent draws, so their
    /// mean has a standard error of about 0.0004 and this threshold is five sigma of
    /// *noise* while catching a systematic bias of a quarter of a per-rung tolerance.
    /// Concretely, it is what catches awarding hero the whole pot on a tie instead of a
    /// share: measured, that shifts every rung by +0.0026 to +0.0034 — inside the
    /// per-rung tolerance at every one of the eight, and 7 sigma out on the mean.
    static let meanErrorTolerance = 0.002

    @Test("Aces hold their published equity against one through eight opponents")
    func acesLadderMatchesPublishedEquity() async {
        let engine = MonteCarloEngine()
        var errors: [Double] = []
        var report: [String] = []

        for (opponents, published) in Self.acesLadder {
            let measured = await engine.simulate(
                hand: Hand(holeCards: cards("Ad Ac"), communityCards: []),
                opponents: opponents,
                deadCards: [],
                iterations: 150_000,
                opponentRange: .random,
                // Below the standard error 150,000 samples can reach, so the run is never
                // cut short by the convergence check — see `MonteCarloEngine.simulate`,
                // where a threshold above it stops at the first 50,000-hand batch whatever
                // the caller asked for.
                confidenceThreshold: 0.0,
                // The deadline *is* live here, because it is only disarmed for a seeded
                // run and this one is deliberately unseeded. Set far enough out that a
                // loaded machine cannot quietly answer from a fraction of the samples: if
                // something really does hang, the suite's own time limit should be what
                // fails, loudly, rather than an anchor silently losing its precision.
                maxTimeSeconds: 900
            )

            errors.append(measured - published)
            report.append("AA vs \(opponents): published \(published), measured "
                          + String(format: "%.4f", measured)
                          + " (\(String(format: "%+.4f", measured - published)))")

            #expect(abs(measured - published) < Self.perRungTolerance,
                    Comment(rawValue: report.last!))
        }

        let meanError = errors.reduce(0, +) / Double(errors.count)
        #expect(abs(meanError) < Self.meanErrorTolerance,
                Comment(rawValue: "mean signed error \(String(format: "%+.4f", meanError)) "
                        + "across the ladder — a bias, not noise:\n"
                        + report.joined(separator: "\n")))
    }

    /// An exact answer from a sampling engine, which is worth more than eight approximate
    /// ones: when the board is a royal flush nobody can beat it and nobody can be beaten,
    /// so every hand chops and hero's share is exactly 1/(n+1) on every single deal.
    /// No sampling error, no published table, no tolerance — the arithmetic of splitting
    /// a pot n+1 ways is the whole content.
    ///
    /// It is here because the ladder cannot see this. Paying a two-way share on a
    /// three-way chop moves the ladder by at most 0.0006, well inside even the mean-error
    /// check, and awarding hero the pot outright on a tie moves it by 0.003. Both are
    /// decisive here.
    @Test("A board that plays for everyone splits the pot exactly",
          arguments: [1, 2, 3, 4])
    func aRoyalFlushOnTheBoardChopsExactly(opponents: Int) async {
        let engine = MonteCarloEngine()
        let measured = await engine.simulate(
            hand: Hand(holeCards: cards("2c 3d"), communityCards: cards("As Ks Qs Js Ts")),
            opponents: opponents,
            deadCards: [],
            iterations: 20_000,
            opponentRange: .random,
            confidenceThreshold: 0.0,
            maxTimeSeconds: 900
        )
        let exact = 1.0 / Double(opponents + 1)

        #expect(abs(measured - exact) < 1e-9,
                Comment(rawValue: "\(opponents + 1) players chopping a royal on the board: "
                        + "each is owed \(exact), hero was given \(measured)"))
    }
}

// MARK: - Exhaustive hand-versus-hand

@Suite("Published head-to-head matchups")
struct PublishedMatchupTests {

    // Exhaustive enumeration is ~0.6s per suit configuration in release and sixteen times
    // that in debug, and a hand class runs up to twelve of them, so this shares the
    // census's gate rather than the fast loop. `ExternalAnchors` owns it.

    /// Published equity for the first hand class against the second, all in preflop.
    /// Standard hand-versus-hand figures, quoted to three decimals.
    static let matchups: [(hero: String, heroCards: String, villain: String, published: Double)] = [
        // The most famous cooler in the game, and the one number everyone can check.
        ("AA", "As Ah", "KK",  0.820),
        // Best hand against worst.
        ("AA", "As Ah", "72o", 0.882),
        // Pair against two overcards, the classic race, at both ends of the pair ladder…
        ("TT", "Ts Td", "AKo", 0.570),
        ("22", "2c 2d", "AKo", 0.527),
        // …and the same race twice over, differing only in whether the overcards are
        // suited. The gap is the price of suitedness and nothing else, which makes it the
        // sharpest single check that flushes are being counted.
        ("QQ", "Qh Qd", "AKo", 0.570),
        ("QQ", "Qh Qd", "AKs", 0.540),
    ]

    @Test("Classic matchups enumerate to their published equities",
          .enabled(if: ExternalAnchors.enabled, Comment(rawValue: ExternalAnchors.skipReason)),
          .timeLimit(.minutes(30)),
          arguments: PublishedMatchupTests.matchups)
    func classicMatchupsMatchPublishedEquity(hero: String, heroCards: String,
                                             villain: String, published: Double) {
        let measured = Self.classEquity(hero: cards(heroCards), villainClass: villain)

        #expect(abs(measured - published) < 0.005,
                Comment(rawValue: "\(hero) vs \(villain): published \(published), "
                        + "enumerated \(String(format: "%.4f", measured)) "
                        + "(off by \(String(format: "%.4f", measured - published)))"))
    }

    /// Suitedness is worth something, and the something is not zero. Stated separately
    /// because it survives any re-tolerancing of the numbers above: whatever the two
    /// figures are, they must differ by about three points in the direction that says
    /// the flush matters.
    @Test("Suited overcards beat their offsuit twin by the price of a flush",
          .enabled(if: ExternalAnchors.enabled, Comment(rawValue: ExternalAnchors.skipReason)),
          .timeLimit(.minutes(30)))
    func suitednessIsWorthAboutThreePoints() {
        let queens = cards("Qh Qd")
        let vsOffsuit = Self.classEquity(hero: queens, villainClass: "AKo")
        let vsSuited  = Self.classEquity(hero: queens, villainClass: "AKs")

        let gain = vsOffsuit - vsSuited   // how much better AK does when it is suited
        #expect(gain > 0.02 && gain < 0.04,
                Comment(rawValue: "suited AK gained \(String(format: "%.4f", gain)) "
                        + "(\(String(format: "%.4f", vsSuited)) suited vs "
                        + "\(String(format: "%.4f", vsOffsuit)) offsuit)"))
    }

    // MARK: - Enumeration

    /// Hero's equity against a whole villain hand class, averaged over villain's
    /// combinations.
    ///
    /// Hero's own suits are fixed rather than averaged, and that is exact rather than an
    /// approximation: relabelling the suits is a symmetry of the deck, it carries any one
    /// combination of hero's class onto any other, and it permutes villain's class among
    /// itself while leaving every equity unchanged. So villain's average is the same
    /// whichever of hero's combinations is held fixed — which is the class average.
    ///
    /// Published tables quote the class, not a suit configuration, and the difference is
    /// not small: AA against 7♣2♦ specifically is 87.42%, while AA against the 72o class
    /// is 88.20%, because most of that class shares a suit with an ace.
    static func classEquity(hero: [Card], villainClass: String) -> Double {
        let villains = combinations(of: villainClass, blocking: hero)
        precondition(!villains.isEmpty, "no combinations for \(villainClass)")
        var total = 0.0
        for villain in villains { total += headsUpEquity(hero: hero, villain: villain) }
        return total / Double(villains.count)
    }

    /// Hero's share of the pot over every board, ties split.
    ///
    /// Uses the production `FastHandEvaluator` on purpose. The oracle here is the
    /// published number, not another evaluator — an independent one would only re-check
    /// what the census already proved exhaustively, whereas this checks the showdown
    /// convention the whole app is built on.
    static func headsUpEquity(hero: [Card], villain: [Card]) -> Double {
        let used = Set((hero + villain).map(index))
        let deck = Card.deck().filter { !used.contains(index($0)) }
        let n = deck.count
        let evaluator = FastHandEvaluator()

        var mine = Array(repeating: deck[0], count: 7)
        var theirs = Array(repeating: deck[0], count: 7)
        mine[0] = hero[0];    mine[1] = hero[1]
        theirs[0] = villain[0]; theirs[1] = villain[1]

        var share = 0.0
        var boards = 0
        for a in 0..<(n - 4) {
            mine[2] = deck[a]; theirs[2] = deck[a]
            for b in (a + 1)..<(n - 3) {
                mine[3] = deck[b]; theirs[3] = deck[b]
                for c in (b + 1)..<(n - 2) {
                    mine[4] = deck[c]; theirs[4] = deck[c]
                    for d in (c + 1)..<(n - 1) {
                        mine[5] = deck[d]; theirs[5] = deck[d]
                        for e in (d + 1)..<n {
                            mine[6] = deck[e]; theirs[6] = deck[e]
                            let ours = evaluator.evaluate(mine)
                            let hers = evaluator.evaluate(theirs)
                            if ours > hers { share += 1 } else if ours == hers { share += 0.5 }
                            boards += 1
                        }
                    }
                }
            }
        }
        precondition(boards == 1_712_304, "expected C(48,5) boards, enumerated \(boards)")
        return share / Double(boards)
    }

    /// Every two-card combination of a hand class — "AA", "AKs", "AKo" — that does not
    /// use a card already dealt.
    static func combinations(of label: String, blocking blocked: [Card]) -> [[Card]] {
        let characters = Array(label)
        precondition(characters.count == 2 || characters.count == 3, "unparseable class: \(label)")
        let first = rank(characters[0]), second = rank(characters[1])
        let paired = first == second
        precondition(paired == (characters.count == 2),
                     "a pair takes no suitedness and a non-pair requires one: \(label)")
        let suited = !paired && characters[2] == "s"
        precondition(paired || characters[2] == "s" || characters[2] == "o",
                     "unparseable suitedness: \(label)")

        let dead = Set(blocked.map(index))
        var result: [[Card]] = []
        for firstSuit in Suit.allCases {
            for secondSuit in Suit.allCases {
                let a = Card(rank: first, suit: firstSuit)
                let b = Card(rank: second, suit: secondSuit)
                if paired {
                    if index(a) >= index(b) { continue }        // each pair once, not twice
                } else if suited != (firstSuit == secondSuit) {
                    continue
                }
                if dead.contains(index(a)) || dead.contains(index(b)) { continue }
                result.append([a, b])
            }
        }
        return result
    }

    private static func rank(_ symbol: Character) -> Rank {
        let table: [Character: Rank] = [
            "2": .two, "3": .three, "4": .four, "5": .five, "6": .six, "7": .seven,
            "8": .eight, "9": .nine, "T": .ten, "J": .jack, "Q": .queen, "K": .king, "A": .ace,
        ]
        guard let rank = table[symbol] else { preconditionFailure("unparseable rank: \(symbol)") }
        return rank
    }

    private static func index(_ card: Card) -> Int {
        (card.rank.rawValue - 2) * 4 + card.suit.suitIndex
    }
}
