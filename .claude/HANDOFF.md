# PokerAssistant — session handoff

Continuing a correctness overhaul of PokerAssistant, a Texas Hold'em decision-assistant
iOS app (SwiftUI, Metal GPU compute). Work so far is on branch
`fix/evaluator-correctness` — 9 commits, nothing pushed, `main` untouched.

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
95-item backlog. **30 items are shipped, 1 withdrawn.** The test suite went from a
single empty stub to **98 cases across 26 suites, all passing** (70 in PokerCore,
28 in the app target).

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
| _(this one)_ | Hero's committed-this-street amount carried into the input model, so villain's raise is measured correctly |

Equity is now within **0.20 percentage points** of published values where the exact
path runs, down from being wrong by up to 36.

## Do this next, in order

Batch A (guards) is **done** — see the commit table above. Backlog items 33, 34 and 35 are
closed by it, and item 34 was closed as a side effect: the kernel's new "deck cannot seat
this deal" early-return means the board fill can no longer read uninitialised memory.

**1. Batch D — the rest.** Items 24, 29, 21, 28:
- **24** (High/Small, touches the UI) only BTN/SB/BB exist at a nine-handed table, so
  every other seat silently maps to button-level aggression and a banner names a "CO"
  that cannot be selected. Make `Position` an enum driven by table size.
- **29** (Med/Med, package-local) one ranking list serves both hero's hand class and
  opponent-range construction, which want opposite orderings — K6o grades above 65s
  despite ranking 27 places worse.
- **28** re-verify before doing anything: the backlog says the fold-below-pot-odds guard
  makes the bluff branch unreachable, but `makeDecision` was rewritten to EV-argmax in
  `bd2bedf`, so the finding is probably stale.
- **21** is Large and depends on range-conditioned equity; it belongs with Batch E.

**2. Then: an external validation harness — recommended ahead of Batch E.**
Every defect that mattered in the last three sessions was found by comparing against
something *outside* the code: the reference evaluator, published equities, an adversarial
reader, or measuring what the sizing actually emitted. No strategic constant has that.
Fold-equity rates, board-texture factors, SPR bands, the 169-hand chart's ordering, and
now the preflop tier boundaries and open sizes written in `6aa9d45` — all hand-authored,
none backtested. Items 21, 31 and 32 build a continuation model *on top of* these, so
validating them first is what makes that work worth doing.

The `HandStrength` cutoffs (0.85/0.70/0.50/0.35) were calibrated against equity-vs-random;
35 of 75 swept spot/range pairs land in a different bucket once equity is range-conditioned.
That is backlog #32, and it is what blocks re-enabling #30's routing.

**3. Batch E — the range engine.** Items 31, 32, and re-enabling 30's routing behind a
board-conditioned continuation model. See the trap below before starting.

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
