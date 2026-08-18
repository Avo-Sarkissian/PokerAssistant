# PokerAssistant — session handoff

Continuing a correctness overhaul of PokerAssistant, a Texas Hold'em decision-assistant
iOS app (SwiftUI, Metal GPU compute). Work so far is on branch
`fix/evaluator-correctness` — 25 commits, nothing pushed, `main` untouched.

## Run the tests with `./scripts/test`

**Not** `xcodebuild -scheme PokerAssistant test`, and **not** Cmd-U. The engine now lives
in `Packages/PokerCore` and its tests are a SwiftPM test target, which Xcode will not run
from a project-based scheme — an explicit `TestableReference` for it is silently dropped
rather than rejected, and no `PokerCoreTests` scheme exists to select. So the Xcode test
action covers a fifth of the suite. `./scripts/test` runs both suites; CI runs the same
steps.

`./scripts/test core` is the fast loop: no simulator, ~70s. It used to be a few seconds —
the published-equity anchors added by the harness work are Monte Carlo runs and cost about
20s of it, which is the price of checking against numbers from outside the repository on
every edit.

`./scripts/test anchors` is new and separate: the exhaustive C(52,7) category census and
the classic matchups enumerated over all 1,712,304 boards, ~37s in release. It is gated
behind `POKER_EXTERNAL_ANCHORS` so it stays out of the fast loop, and **CI runs it** —
without that step it would be skipped in every automated run, and a skipped test is a
green run.

## Where things stand

An exhaustive audit produced 217 verified findings, consolidated into a ranked
95-item backlog. **33 items are shipped, 1 withdrawn.** The test suite went from a
single empty stub to **190 cases across 43 suites, all passing** (150 in PokerCore,
40 in the app target), plus 6 gated external anchors.

Batch D is done: #24, #28 and #29 are closed. Item 28 was closed as **stale** — the
fold-below-pot-odds guard it describes went away with `bd2bedf`, verified by splicing the
guard back in and watching the new test fail.

- Audit report: https://claude.ai/code/artifact/0b6a3220-8588-499e-beb4-655af33f4a71
- Ranked backlog: https://claude.ai/code/artifact/c3758e78-e7b6-46ec-8b1e-6ee4b26937bd
  (out of date — worth republishing early; pass the URL as `url`)

  **Do not trust its "shipped" markings without checking the code.** Item 33, the Metal
  `gid` bounds guard, is recorded as shipped in `cddd9dc`. It never was: no revision of
  `PokerShaders.metal` has ever contained that guard, and `cddd9dc` touched the file only
  for chop splitting. Verified with
  `for c in $(git log --format=%h -- Engine/PokerShaders.metal); do git show $c:Engine/PokerShaders.metal | grep -c 'gid >='; done`
  → 0 everywhere. Items 2, 3, 6, 7, 8, 10, 15, 17, 19, 36 and 37 were spot-checked and do
  hold, so it looks like one bad marking rather than a systemic problem.

Shipped, by commit:

| SHA | What |
|---|---|
| `b4c0970` | Deleted a broken duplicate evaluator; fixed the Metal one-pair overflow and its LCG; rejection sampling; chop splitting; the `"10"`/`"T"` range-table key; preflop routing; cache versioning |
| `8c59689` | `PotEntry` input model; players-in-hand; seedable RNG; hand lifecycle; recalculation fingerprint |
| `cddd9dc` | Repaired a pot-convention regression from the previous commit; GPU chop splitting |
| `bd2bedf` | Solver decides by argmax of its own EVs; removed positional fudge from EV; fold equity vs all-in and multiway; legal raise sizing |
| `78b685d` | Range-conditioned exact enumeration (capability); deleted a heap-corrupting debug static |
| `2abc163` | Restored raising (a regression); gated postflop range conditioning |
| `f39443d` | CI; App Store blockers — icon, `NavigationStack`, privacy manifest, encryption flag, deployment target 17.0, dark-mode preference |
| `a596903` | `Packages/PokerCore` extracted (#83); seeded runs made reproducible under load; `scripts/test` |
| `c3a41ac` | Batch A guards (#33, #34, #35): short-stack call EV, `Card` value equality, deal validation pushed into the engines, enumerator bounds, Metal `gid` and starved-deck guards |
| `6aa9d45` | Preflop sizing and range reads in big blinds (#25); combo-weighted range widths (#23) |
| `f1c3bfc` | Hero's committed-this-street amount carried into the input model, so villain's raise is measured correctly |
| `bbe0a5f` | `scripts/test` resolves a simulator that exists on this machine |
| `d339bde` | #28 verified stale; the semi-bluff line pinned |
| `f3fbfad` | #29 first attempt — **superseded**, see `c6d8824` |
| `b6d72f8` | #24 — nine-seat `Position`, table size in the spot, heads-up position fixed |
| `c6d8824` | Adversarial review response: a launch crash, the heads-up reset pot, #29 reverted the other way, the bluff premium re-keyed, five vacuous tests |
| `0043d8a` | Position is a fact hero supplies, not one the seat implies — closes the cutoff regression |
| `81465ed` | External anchor 1: the C(52,7) category census against the nine published counts |
| `8fd1657` | External anchor 2: the solver's bluff arithmetic against α = b/(1+b) |
| `46bd073` | External anchor 3: the aces ladder and six classic matchups; the shared-board showdown suite |
| `af66471` | Adversarial review response and an 11-mutation pass; CI runs the anchors |

Equity is now within **0.20 percentage points** of published values where the exact
path runs, down from being wrong by up to 36.

## Do this next, in order

**Batch A and Batch D are done.** Backlog items 24, 28, 29, 33, 34, 35 are closed;
21 belongs with Batch E.

**1. The external validation harness — done.** All three anchors are in, and CI runs
them. What each one found:

- **The C(52,7) category census** (`./scripts/test anchors`, ~21s in release). All nine
  published counts match **exactly**. Four of the nine are now derived in the test from
  the combinatorics rather than transcribed, so a mistyped reference cannot masquerade as
  an evaluator bug. The fast loop keeps a seeded 300,000-hand sampled version — useful,
  but weak where the category is rare: five sigma is 1% of the one-pair count and 52% of
  the straight-flush count, so anything touching under ~0.05% of hands passes it. The
  exhaustive pass is the proof, which is why it is a CI step.
- **The α = b/(1+b) identity.** Asserted end to end through `solve()`: a zero-equity
  bluff's EV must equal fⁿ·P − (1−fⁿ)·C·r and must be positive exactly when fⁿ clears α,
  and the recommendation must follow its own arithmetic. It holds over 900 spots. ICM
  pressure falls out of it cleanly — a risk premium of r raises the required fold
  frequency exactly as if the bet were r times larger.
- **Published equity anchors.** The aces ladder reproduces all eight published rungs
  (85.20 · 73.36 · 63.87 · 55.86 · 49.20 · 43.58 · 38.79 · 34.63) and, more usefully,
  the *mean signed error* across the eight is pinned at 0.002 — a per-rung tolerance has
  to absorb sampling noise and is 80× looser than the published table is accurate. Six
  classic matchups enumerated over all C(48,5) boards, hand class against hand class, all
  inside half a point.

**What the harness found, all deferred deliberately:**

- **Bluff profitability is not monotone in bet size.** `foldEquityForRange` multiplies its
  base rate by a *step* function of bet size while α rises smoothly, so the sign flips
  back and forth: `.standard` changes four times over a 0.10–3.00 pot sweep — profitable
  to 0.82 pot, unprofitable from 0.82, profitable again from 0.85, unprofitable from 0.99,
  profitable at 1.10, unprofitable from 1.11. In a $100 pot an $82 bluff is priced as
  losing and an $85 bluff as winning, against the same opponent with the same cards, and
  the solver's own sizing reaches that band routinely (a medium hand out of position on a
  wet board at SPR under 4 sizes to 0.87 pot). **There is a test for this, and it is
  `.disabled`** — `bluffProfitabilityIsMonotoneInBetSize` in `FoldEquityIdentityTests`.
  The fix is written out in its note and introduces no constant that is not already
  there: `f(range, b) = min(α(b)·k(range), 0.85)` with
  `k(range) = foldEquityForRange(range, 0.75) / α(0.75)`. That reproduces today's numbers
  exactly at the model's default size, makes the multiple constant in bet size, and makes
  the test pass. It also moves every raise EV in the app, which is why it was not smuggled
  into a test commit. **Swift Testing has no XFAIL, so nobody will be told when this
  starts passing — check it deliberately when you take it on.**
- **The α-multiple is backwards.** The model credits 2.80× α at a quarter-pot bet and
  0.50× at 1.75 pot; the multiple *falls* as the bet grows. Real opponents over-fold to
  big bets and call small ones too wide, so an exploitative model should do the opposite.
  Bounded, not pinned: `creditedFoldEquityStaysNearTheBalancedBaseline` allows a factor of
  three either side, and today's worst case is 2.80, so there is very little slack left.
- **`.veryTight` clears α only below a quarter-pot bet**, which the solver reaches only
  when hero is nearly all in. At every size it normally chooses, bluffing a range read as
  tight is unprofitable by construction rather than by measurement.
- **The 169-hand order against published opening-range widths could not be done**, because
  there is nothing left to compare: `openingRangePercentile` and the rest of the
  positional opening ranges went with the old three-case `Position` (see `bd2bedf`), and
  the six `RangeType` widths are already checked against their own claimed percentiles in
  `RangeWidthTests`. Re-basing the 169-hand order on all-in equity is still open and is
  really backlog #32's neighbour.

**The mutation pass, for calibration of how much the suite is worth.** Eleven single-line
mutations of production code; five were caught by the new tests, six survived and needed a
new test each. Worth reading before trusting a green run:

- The category census is *definitionally* blind to ordering — it bins on
  `evaluate(...)/1_000_000` and throws away every bit below. Two tie-break multipliers
  were one decimal place too small to collide and nothing noticed; the collisions are real
  pots (board 9♠9♥2♦4♣2♣ chops nines-and-threes against nines-and-twos).
- Published *equity* anchors are blind to anything that leaves the mean unbiased. Freezing
  the batch seed, or inverting the convergence check, makes a 150,000-sample run return
  the 50,000-sample answer exactly — the caller loses two thirds of the precision they
  asked for and every anchor still passes. `A longer run is a different run` is what
  catches that.
- Drawing each opponent's first card from the whole deck instead of the undealt part
  reaches back into a seat that has already passed the range filter and swaps one of its
  cards. No duplicate, no missing player, and it survived all 150 tests. Only a comparison
  against exact enumeration with *two* opponents *and* a range filter sees it — 0.0083
  above the enumerator against 0.0006 clean.

**2. Batch E — the range engine.** Items 31, 32, and re-enabling 30's routing behind a
board-conditioned continuation model. See the trap below before starting. Note #32 got
more urgent, not less: the `HandStrength` equity cutoffs are now applied to *postflop*
equity only, and postflop equity is deliberately vs-random, so the cutoffs and their
input finally agree — but they are still the values calibrated by hand.

**3. Found by the harness review, deferred, and cheap:**

- **`noFoldEquityVersusAnAllInVillain` is vacuous.** In the spot it builds, `canRaise` is
  false, so `evRaise = evCall` by assignment in `solve()` and the assertion holds however
  fold equity is computed. It was written to guard the "a player with nothing behind
  cannot fold" rule and does not reach it.
- **Five guards in `calculateRaiseEV` are unreachable**, so no test can cover them and
  nothing will notice if they rot: `min(toCall + raiseAmount, effectiveStack)` and
  `min(raiseAmount, max(0, villainStack - toCall))` can never bind, because
  `calculateOptimalRaiseSize` already clamps to `chipsBehind`; `villainHasChipsBehind` is
  always true, because `canRaise` requires it before the call is made; `max(f, 0)` cannot
  bind, because the smallest product is 0.25 × 0.80 × 0.6; and `max(1, opponents)` is
  inert, because `GameStateCopy.opponentCount` is already `max(1, playersInHand - 1)`.
  Either delete them or leave a comment saying they are belt-and-braces — as written they
  read as live cases.
- **`makeDecision`'s documented tie rule is untested.** "Ties resolve toward the least
  aggressive action, which keeps variance down" — replacing `> best.ev + 1e-9` with
  `>= best.ev` passes every test in both targets. The identity sweep deliberately skips
  the knife edge, which is the only place the rule bites.
- **The `POKER_EXTERNAL_ANCHORS` gate string is written out twice**, in
  `CategoryCensusTests` and `PublishedEquityTests`. A typo in one silently retires that
  suite, and a skipped suite is a green run.

**4. Found by the Batch D review, deliberately deferred, all with numbers:**

- ~~A cutoff whose button folded is in position, and the app says otherwise.~~ **Fixed in
  `0043d8a`** by asking rather than guessing: `GameStateCopy.heroActsLast` is a supplied
  fact, seeded from the seat, overridable from a row under the seat picker. The solver now
  takes position as two facts — posted a blind, acts last — and re-derives neither.
- **`PotEntry.preflop` double-counts villain's posted blind whenever villain is a blind.**
  Heads-up "Open / SB" — the button facing a big-blind raise, *the* heads-up spot —
  computes a 4.0 pot where the truth is 3.0, understating required equity by 6.7 points
  (33.3% shown against 40.0% true). Also fires 6-handed when villain is the small blind.
  Pre-existing; needs villain's seat.
- **`bluffFrequencyMultiplier` is dimensionally suspect.** Villain cannot see hero's
  cards, so hero's *hand* should not move villain's fold rate at all; villain can see
  hero's *seat*, which argues a late-position bettor is called looser and the sign is
  backwards. It is the only route position takes into raise EV, so removing it would
  collapse the nine seats to two groups. Wants the harness first.
- **`.bluff` sizes larger than `.weak` postflop** (0.40 vs 0.33), so the grade ladder is
  not monotone in sizing. Pre-existing.
- **`EquityCalculator`'s preflop cache-miss fall-through is dead.** The comment claims a
  miss continues to a higher-accuracy GPU/CPU run, but `PreflopEquityTable.equity`
  returns the value it just computed, so the deeper `CalculationDepth` settings never
  apply preflop.
- **The blind level has no `onChange`.** #24 added one for `numberOfPlayers` because
  Settings is a sheet and `onAppear` never fires again; `smallBlind`/`bigBlind` are
  mirrored the same way and did not get one. Change the blinds mid-session and the pot
  stays seeded at the old level until Reset.
- **Disabling "Track Opponents" leaves `opponentStyle` live.** The selector is hidden but
  the stored style still short-circuits bet-size range inference, so villain stays a
  `.wide` range forever with no control on screen.
- **`ResultView` mixes live state into a snapshot card.** The "In Position" badge and the
  "Need X% to call" check read current game state while everything else comes from the
  `CalculationResult` captured at solve time, so tapping a seat flips the badge above a
  reasoning string that still says the opposite.
- **`ResultView`'s "RAISE to" figure omits hero's posted blind**, so a small-blind open
  sized to 3.0bb displays as "RAISE to $2.50" — the same number shown for a button open,
  hiding the out-of-position premium the sizing deliberately adds.
- **Preflop tier boundaries are absolute in big blinds**, so a 20bb shove reads as a
  4-bet range. Right for 100bb, wrong for 25bb; the boundaries probably want to scale
  with the effective stack.

## Traps that already cost time

- **`xcodebuild -scheme PokerAssistant test` no longer means "the test suite."** It runs
  40 of 190. Use `./scripts/test`. Nothing fails or warns when you get this wrong — the
  Xcode test action just reports the app-target tests as passing. See the note at the top.
- **A skipped test is a green run.** The external anchors are gated behind
  `POKER_EXTERNAL_ANCHORS`, and for three commits CI ran without it, so the strongest
  check in the repository was silently absent from every automated run while the output
  said `Test run with 5 tests in 2 suites passed`. Swift Testing prints skips with a `➜`
  and moves on. If you gate anything, add the CI step in the same commit.
- **Swift Testing has no XFAIL.** `bluffProfitabilityIsMonotoneInBetSize` is `.disabled`
  because it documents a real defect. Nothing will tell you when the defect is fixed and
  the test could be re-enabled — you have to go and look.
- **Anything new in `Packages/PokerCore` is picked up automatically** (SwiftPM globs the
  Sources directory) — but it must be `public` to be visible from the app, and the
  compiler will not remind you until a call site fails.
- **New files under `Models/`, `Engine/`, `Views/` need four `project.pbxproj` entries**
  (PBXFileReference, PBXBuildFile, group children, Sources phase) or they compile to
  nothing, silently. `PokerAssistantTests/` and `PokerAssistant/` are
  `PBXFileSystemSynchronizedRootGroup`s and *do* auto-include — an empty `Sources` phase
  there is normal, not broken. Prefer putting new engine code in the package instead.
- **The app test host is the app and `Settings` is all `@AppStorage`**, so app-target
  tests leak blinds and player counts into the shipping app's `UserDefaults`. Use the
  existing `DefaultsSnapshot` helper in `GameStateTests.swift`. Package tests are free of
  this — that is one reason the solver's suite moved.
- **The package cannot see `Settings`, and that cuts both ways.** `Settings.solverSettings`
  is the only bridge from the app's persisted blinds and ICM phase into the solver, and no
  package test can observe it. It is covered by `SolverSettingsMappingTests` in the app
  target; keep it that way, because transposing the two blinds there leaves every other
  test green.
- **Pick test cases that stress the model, not confirm it.** This went wrong twice:
  a range-monotonicity test used aces (the one hand where a tighter range *helps*), and
  a postflop range test used KJo (which behaves correctly) while 33 on 8-7-6-2-4 goes
  35.4% → 68.4% as the range narrows — an inversion that shipped.
- **Postflop range conditioning is deliberately gated** in `EquityCalculator`. Applying
  a preflop starting-hand chart to a postflop showdown keeps broadway hands that would
  have folded and deletes the connected hands that bet, so a *bigger* villain bet raised
  hero's equity. Don't un-gate it without a continuation model.
- `#expect(cond, message)` takes a `Comment`; a computed String needs
  `Comment(rawValue:)`.
- The Swift `ThreadResult` and `SimulationParams` structs must match the Metal ones
  byte-for-byte. `MetalLayoutTests` now pins the Swift side's size, alignment and field
  order; the Metal side is quoted in that file's doc comment and is still only checked by
  the GPU-vs-exact agreement tests, which fail loudly but not precisely.
- Don't edit files while a review workflow is reading them.
- **A `View`'s `private var` cannot be tested, and that is where the crash was.** #24
  shipped a force-unwrap in `positionExplanation` that trapped on launch at a two-handed
  table. No test in either target could reach it. Anything with a branch in it belongs in
  a value type — `SeatExplanation` is the pattern.
- **`@State` cannot be initialised from `Settings`, and every corrector runs after the
  first body pass.** `onAppear` and `onChange` are both too late to protect the body that
  reads the stale value. Resolve it in the body instead.
- **`simctl spawn defaults write` does not reach the app's `@AppStorage`.** Writing the
  container's plist directly does not either — `cfprefsd` has it cached. Two attempts
  failed; a preference-dependent UI state could not be forced for a screenshot. Cover it
  with a test instead.
- **`MonteCarloEngine.simulate` stops at the first 50K batch** whenever
  `confidenceThreshold >= 0.0022`, whatever `iterations` says, because that is the
  standard error at n=50,000 and p≈0.5. `PreflopEquityTable` asked for 200K at 0.005 and
  got 50K, then cached it in `UserDefaults` permanently. Pass a threshold below the SE
  the requested count actually reaches, and bump `schemaVersion` when you do.
- **Grading anything by preflop equity couples it to the opponent count.** Equity falls
  mechanically as players are added — AA against eight opponents is 34.3% — so any fixed
  cutoff makes aces trash nine-handed. Preflop grading is chart-based for this reason.

## How to work

- **TDD, strictly.** Write the test, watch it fail for the right reason, then implement.
  Several of these defects existed because someone fixed a bug in one file and nothing
  compared it to the other two.
  Where the code already exists and is correct — a mapping, an adapter — the honest
  substitute is to write the test, *mutate the production code to break it*, watch it
  fail, then revert. `SolverSettingsMappingTests` was built that way.
- **Run an adversarial review of your own commits before declaring a batch done.** Doing
  this found three criticals that had already shipped, including one that silently
  disabled every raise recommendation. On the PokerCore extraction it found that the
  Xcode test action had quietly stopped covering most of the suite, and that the new
  `Settings → SolverSettings` mapping had no test at all. Assume the same of new work.
- **You may gate or revert.** The right call on the range work was "don't ship the routing
  yet." Prefer that to forcing something through to call it finished.
- Gate each batch on `./scripts/test` plus a real simulator launch; `git commit` per batch
  with a message explaining *why*, not just what. Don't push.

## Smaller things found and not yet done

- **`ResultView`'s "RAISE to" figure omits hero's posted blind**, so a small-blind open
  that the solver sized to 3.0bb is displayed as "RAISE to $2.50" — the same number shown
  for a button open, hiding the out-of-position premium the sizing deliberately adds.
- **Preflop tier boundaries are absolute in big blinds**, so a short-stack shove of 20bb
  reads as a 4-bet range. Correct for a 100bb game, wrong for a 25bb one; the boundaries
  probably want to scale with the effective stack.

## Known dead code (not worth its own commit, but don't be misled)

- `Utils/Constants.swift` — nothing references `Constants.*` anywhere. Predates this
  work; deleting it needs the usual four `project.pbxproj` removals.

## Biggest open risk

**The evaluator and the equity engine are now externally checked; the strategy is not.**

What is anchored: hand classification (exhaustively, against the published C(52,7)
census), showdown ordering (against an independent oracle over shared boards), equity
(against the published aces ladder and six classic matchups), and the solver's bluff
arithmetic (against α = b/(1+b), which is a theorem rather than a table).

What is still hand-authored and unbacktested: **every strategic constant.** Fold-equity
base rates and their bet-size multipliers, the bluff position premium, board-texture
factors, SPR bands, the postflop `HandStrength` equity cutoffs (#32), preflop tier
boundaries, and the 169-hand chart's *ordering*. The harness has already shown two of
these are wrong in a checkable direction — the α-multiple falls with bet size when it
should rise, and bluff profitability is not even monotone in bet size — and neither has
been fixed, because both change every raise EV in the app.

The next honest step is not another anchor. It is picking one of those constants and
re-basing it on something the harness can measure, starting with the fold-equity table,
where the target is already written out.
