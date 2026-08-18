# PokerAssistant — session handoff

Continuing a correctness overhaul of PokerAssistant, a Texas Hold'em decision-assistant
iOS app (SwiftUI, Metal GPU compute). Work so far is on branch
`fix/evaluator-correctness` — nothing pushed, `main` untouched. For the commit count run
`git rev-list --count main..HEAD`; writing it down here has been wrong three times,
because the commit that records it is the one that changes it.

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
single empty stub to **224 cases across 52 suites, all passing** (173 in PokerCore,
51 in the app target), plus 6 gated external anchors CI runs on every push.

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
| `12009aa` | The four cheap review findings: a vacuous test made real, the tie rule tested, the guards documented honestly, the anchors gate written once |
| `3bbf81c` | Fold equity anchored to α, so bluff profitability stops flipping with bet size |
| `f765256` | Villain stops seeing hero's cards; the preflop cache stops swallowing the depth setting, and stops routing ranged work to a range-blind kernel |
| `f065282` | The result card stops narrating a table that has moved on; "RAISE to" tells the truth; the tracking toggle is honoured; the blinds get an `onChange` |
| `1c99d27` | Villain's own blind is not dead money — the heads-up pot was 4.0 where the truth is 3.0 |
| `fb13aec` | What would unblock tier 3, and why the obvious construction is not enough |
| `d50d2eb` | Adversarial review response: dead cards poisoning the preflop cache, a half-updated blind observer, a street wager carried forward, and a comment that was false |

Equity is now within **0.20 percentage points** of published values where the exact
path runs, down from being wrong by up to 36.

## Do this next, in order

Backlog items 23, 24, 25, 28, 29 are now closed as well as 33, 34, 35; 21, 31 and 32 are
**blocked**, and the reason is in the code. The republished backlog artifact is accurate as
of `1c99d27`:

- Audit report: https://claude.ai/code/artifact/0b6a3220-8588-499e-beb4-655af33f4a71
- Ranked backlog: https://claude.ai/code/artifact/c3758e78-e7b6-46ec-8b1e-6ee4b26937bd

**1. The strategic constants that are left.** The harness exists now, and it has already
turned two hand-authored guesses into something anchored. What it has not touched:

- **`foldFrequencyMultiplier`: 1.3 in position, 0.6 out.** These are the last unmeasured
  numbers in the fold-equity path and they are now doing more work than anyone intended.
  Because fold equity is `α(b) · k(range) · m(position)`, a pure bluff's EV is exactly
  `R·(k·m − 1)` — linear in the bet, so whether bluffing is profitable depends on nothing
  but range and seat. Every out-of-position entry in that twelve-cell table is below one,
  `.random` included at 0.980, so **the solver will never bet a hand with no showdown value
  out of position, against anyone, at any size.** Pinned by
  `bluffabilityIsATwelveEntryTable`, which asserts the table without endorsing it. If one
  thing gets measured next, make it this.
- **The `HandStrength` equity cutoffs** (backlog #32's neighbour) and the 169-hand chart's
  ordering. Both still hand-calibrated.
- **Preflop tier boundaries are absolute in big blinds**, so a 20bb shove reads as a 4-bet.
  The obvious repairs make it worse — as a fraction of stack the same shove is 100% and
  therefore tighter still. What widens a short stack's range is that the bet is an
  *all-in*; modelling that needs a shove-range table by depth, which is five more invented
  constants with no theorem behind them. Written out at `OpponentRange.preflopRange`.

**2. Batch E is blocked, and the specification is written down.** Items 21, 31 and 32 all
sit downstream of the postflop range gate in `EquityCalculator`, and the note there says
what would unblock it: α, `FastHandEvaluator` and the preflop charts compose into a
river-only continuation model with no new constants — but that models a *defending* range,
and the router needs a *betting* range, which is polarised. Filtering to the top 1 − α
deletes villain's bluffs and biases hero's equity by an amount nothing here can measure.
Item 31 is separately downgraded to a performance item: routing now keeps range-conditioned
work off the range-blind GPU kernel, so the kernel is no longer answering questions it
cannot answer.

**3. Calculation Depth is largely decorative**, found while making the preflop fall-through
live. The GPU path caps at 2M iterations, so Accurate, Deep and Maximum are identical
there; the CPU path stops at its first 50,000-hand batch for any threshold at or above
0.0022, which is three of the four settings. The UI advertises 1M to 100M simulations. This
is a UI and performance decision as much as a correctness one, which is why it was left.

**4. Still open from the Batch D review:** the made-hand sizing ladder is a tell (the four
grades descend in lockstep with strength; `.bluff` sizing above `.weak` is *not* a defect
and `PostflopSizingTests` now says so), and `assumedVillainBlind` guesses at three-handed
tables where a partial constraint is actually derivable.

**5. Nothing is pushed.** The branch is a long way ahead of `main` and has been for several
sessions, on one machine.

## Traps that already cost time

- **`xcodebuild -scheme PokerAssistant test` no longer means "the test suite."** It runs
  51 of 224. Use `./scripts/test`. Nothing fails or warns when you get this wrong — the
  Xcode test action just reports the app-target tests as passing. See the note at the top.
- **A skipped test is a green run.** The external anchors are gated behind
  `POKER_EXTERNAL_ANCHORS`, and for three commits CI ran without it, so the strongest
  check in the repository was silently absent from every automated run while the output
  said `Test run with 5 tests in 2 suites passed`. Swift Testing prints skips with a `➜`
  and moves on. If you gate anything, add the CI step in the same commit.
- **Swift Testing has no XFAIL.** `bluffProfitabilityIsMonotoneInBetSize` shipped
  `.disabled` as an executable statement of a defect, and nothing announced when the defect
  was fixed — it had to be gone back to on purpose. It is enabled and passing now.
- **Moving half a rule somewhere testable is worse than not moving it.** `BlindChange` was
  extracted so the re-seed rule could be tested, and the half left in the view — which
  blind totals to compare — was the half that was wrong. Four green tests, and the bug they
  describe was shipping. If a value type owns a rule, give it the whole rule.
- **A permanent cache must key everything that changed the answer.** `PreflopEquityTable`
  is keyed on (hand, opponents, range) and lives in `UserDefaults` forever. Feeding it an
  equity computed with dead cards poisons that hand for every future session. The same
  trap has now fired twice from opposite directions; check the key before adding a writer.
- **A fingerprint is an input list.** `GameViewModel.getCurrentStateString` decides whether
  Calculate does anything. Anything new that reaches the solver has to be added to it in
  the same commit, or the setting works and the button does not.
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
