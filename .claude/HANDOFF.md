# PokerAssistant — session handoff

Continuing a correctness overhaul of PokerAssistant, a Texas Hold'em decision-assistant
iOS app (SwiftUI, Metal GPU compute). Work so far is on branch
`fix/evaluator-correctness` — 17 commits, nothing pushed, `main` untouched.

## Run the tests with `./scripts/test`

**Not** `xcodebuild -scheme PokerAssistant test`, and **not** Cmd-U. The engine now lives
in `Packages/PokerCore` and its tests are a SwiftPM test target, which Xcode will not run
from a project-based scheme — an explicit `TestableReference` for it is silently dropped
rather than rejected, and no `PokerCoreTests` scheme exists to select. So the Xcode test
action covers **28 of the 98 tests**. `./scripts/test` runs both suites; CI runs the same
two steps. `./scripts/test core` is the fast loop: no simulator, and the solver, pot and
range suites finish in 0.04s.

## Where things stand

An exhaustive audit produced 217 verified findings, consolidated into a ranked
95-item backlog. **33 items are shipped, 1 withdrawn.** The test suite went from a
single empty stub to **167 cases across 37 suites, all passing** (130 in PokerCore,
37 in the app target).

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

Equity is now within **0.20 percentage points** of published values where the exact
path runs, down from being wrong by up to 36.

## Do this next, in order

**Batch A and Batch D are done.** Backlog items 24, 28, 29, 33, 34, 35 are closed;
21 belongs with Batch E.

**1. The external validation harness.** Nothing has changed about the reason this is
next — every strategic constant is still hand-authored — but Batch D produced two
concrete anchors worth building it around, and one of them is decisive:

- **A 7-card category census.** Enumerate all C(52,7) = 133,784,560 seven-card hands,
  bucket by `evaluate(...) / 1_000_000`, and compare to the published counts: straight
  flush 41,584 · quads 224,848 · full house 3,473,184 · flush 4,047,644 · straight
  6,180,020 · trips 6,461,620 · two pair 31,433,400 · one pair 58,627,800 · high card
  23,294,460. Those sum to exactly C(52,7), which self-checks the table. This is the
  strongest external validation available to this repo and it needs no network, no
  solver and no reference data beyond nine integers. Budget one CPU pass; keep it out of
  the fast loop.
- **The α / MDF identity for fold equity.** Facing a bet of `b` pots, a balanced defender
  folds exactly `α = b/(1+b)`. Measured against `foldEquityForRange`: at b=0.3 the model
  credits 0.56 against α=0.231 (2.4x), at b=0.5 0.63 vs 0.333 (1.9x), at b=1.0 0.77 vs
  0.50 (1.5x), at b=1.5 0.85 vs 0.60 (1.4x) — so it over-credits *most* at small sizes,
  and the ratio falls as the bet grows, which is backwards. Meanwhile `.veryTight` folds
  0.225 against α=0.333, i.e. **below** a balanced defender, which makes bluffing a tight
  range unprofitable by construction. The solver's own algebra satisfies the identity
  exactly (a zero-equity bet is +EV iff fold equity > α), so a test can assert the
  identity and separately *report* the multiple, rather than baking in a number.
- Extend the published-equity anchors (currently four hands) with classic matchups and
  the AA-vs-N-opponents ladder, and check the 169-hand order against published opening
  range *widths* by position.

**2. Batch E — the range engine.** Items 31, 32, and re-enabling 30's routing behind a
board-conditioned continuation model. See the trap below before starting. Note #32 got
more urgent, not less: the `HandStrength` equity cutoffs are now applied to *postflop*
equity only, and postflop equity is deliberately vs-random, so the cutoffs and their
input finally agree — but they are still the values calibrated by hand.

**3. Found by the Batch D review, deliberately deferred, all with numbers:**

- **A cutoff whose button folded is in position, and the app says otherwise.** It sizes
  1.1x instead of 0.9x — $18.00 against $14.50 into a 40 pot — and the badge reads "Out
  of Position". "Hero opened the CO, the BB called" is the most common flop in 6-max.
  This is a **regression against the pre-#24 app**, where the picker offered only
  BTN/SB/BB so that user selected BTN and got the right answer. Fixing it needs to know
  *which* seats folded, which the app does not collect; the honest fix is probably an
  explicit "I act last after the flop" input rather than a guess.
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
  28 of 98. Use `./scripts/test`. Nothing fails or warns when you get this wrong — the
  Xcode test action just reports the app-target tests as passing. See the note at the top.
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

**Nothing this engine produces has ever been checked against anything outside its own
repository.** Every test compares one in-repo implementation to another, and no strategic
constant — fold-equity rates, board-texture factors, SPR bands, the 169-hand chart's
*ordering* — has been backtested against a solver, published charts, or real results. The
app is now internally consistent and externally unproven. Worth slotting an external
validation harness ahead of more feature work.
