# PokerAssistant — session handoff

Continuing a correctness overhaul of PokerAssistant, a Texas Hold'em decision-assistant
iOS app (SwiftUI, Metal GPU compute). Work so far is on branch
`fix/evaluator-correctness` — 7 commits, nothing pushed, `main` untouched.

## Where things stand

An exhaustive audit produced 217 verified findings, consolidated into a ranked
95-item backlog. **29 items are shipped, 1 withdrawn.** The test suite went from a
single empty stub to **80 cases across 17 suites, all passing.**

- Audit report: https://claude.ai/code/artifact/0b6a3220-8588-499e-beb4-655af33f4a71
- Ranked backlog: https://claude.ai/code/artifact/c3758e78-e7b6-46ec-8b1e-6ee4b26937bd
  (three commits out of date — worth republishing early; pass the URL as `url`)

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

Equity is now within **0.20 percentage points** of published values where the exact
path runs, down from being wrong by up to 36.

## Do this next, in order

**1. Extract `Packages/PokerCore` (backlog #83).** Highest leverage available. A scratch
package built and ran a real enumeration test in **13.7s build + 0.24s test** against the
current **116s simulator cycle**. Everything downstream is gated on test runs, so this
roughly 10×s how much can be done per session. Move Card, Hand, HandHistory,
CalculationResult, FastHandEvaluator, ExactEnumerator, OpponentRange, PreflopEquityTable,
MonteCarloEngine. Only two things block it: `Suit.suitIndex` lives in a `import SwiftUI`
file (`Utils/Extensions.swift`), and `ExploitativeSolver.solve` takes `Settings`.

**2. Batch A — guards.** All confirmed absent by grep, all small:
- `calculateCallEV` counts villain's *uncalled* excess as contested, overstating a
  short-stack call up to 7× (pot 150 / call 140 / stack 12 / equity 0.95 reports +141.90
  against a true +20.30). Fix: pot term becomes `potSize - (toCall - cost) + cost`.
- `Card` still `==`/hashes by random UUID (`Models/Card.swift:43`); every engine
  hand-rolls a 0–51 index workaround.
- No duplicate-card validation in `EquityCalculator.calculateDeep` — duplicate hole
  cards return a confident 76.82%.
- `ExactEnumerator` has no `available.count` guards: 45 dead cards traps, 44 silently
  returns 0.0% as a valid answer. `MonteCarloEngine.swift:180` has exactly the guard it
  needs.
- Metal kernel has no `gid` bounds guard, so every dispatch writes past the results
  buffer (survives only because Metal page-rounds allocations).

**3. Batch D — the solver, finished.** Items 21, 23, 24, 25, 28, 29, plus:
- `HandStrength`'s absolute cutoffs (0.85/0.70/0.50/0.35) were calibrated against
  equity-vs-random; 35 of 75 swept spot/range pairs land in a different bucket once
  equity is range-conditioned. This blocks re-enabling #30's routing.
- Preflop range tiers saturate: an unopened button reads `.veryTight`, and
  `RangeInferenceTests.preflopTiersAreOrdered` currently asserts that saturation as
  correct. Threshold preflop on big blinds, not on a fraction of a pot made only of blinds.

**4. Batch E — the range engine.** Items 31, 32, and re-enabling 30's routing behind a
board-conditioned continuation model. See the trap below before starting.

## Traps that already cost time

- **New files under `Models/`, `Engine/`, `Views/` need four `project.pbxproj` entries**
  (PBXFileReference, PBXBuildFile, group children, Sources phase) or they compile to
  nothing, silently. `PokerAssistantTests/` and `PokerAssistant/` are
  `PBXFileSystemSynchronizedRootGroup`s and *do* auto-include — an empty `Sources` phase
  there is normal, not broken.
- **The test host is the app and `Settings` is all `@AppStorage`**, so tests leak blinds
  and player counts into the shipping app's `UserDefaults`. Use the existing
  `DefaultsSnapshot` helper in `GameStateTests.swift`.
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
- The Swift `ThreadResult` struct must match the Metal one byte-for-byte.
- Don't edit files while a review workflow is reading them.

## How to work

- **TDD, strictly.** Write the test, watch it fail for the right reason, then implement.
  Several of these defects existed because someone fixed a bug in one file and nothing
  compared it to the other two.
- **Run an adversarial review of your own commits before declaring a batch done.** Doing
  this found three criticals that had already shipped, including one that silently
  disabled every raise recommendation. Assume the same of new work.
- **You may gate or revert.** The right call on the range work was "don't ship the routing
  yet." Prefer that to forcing something through to call it finished.
- Gate each batch on the full suite plus a real simulator launch; `git commit` per batch
  with a message explaining *why*, not just what. Don't push.

## Biggest open risk

**Nothing this engine produces has ever been checked against anything outside its own
repository.** Every test compares one in-repo implementation to another, and no strategic
constant — fold-equity rates, board-texture factors, SPR bands, the 169-hand chart's
*ordering* — has been backtested against a solver, published charts, or real results. The
app is now internally consistent and externally unproven. Worth slotting an external
validation harness ahead of more feature work.
