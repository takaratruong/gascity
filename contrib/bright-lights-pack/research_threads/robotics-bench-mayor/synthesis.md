# robotics-bench mayor synthesis

## Current goal

Improve 2D planar navigation through clutter beyond the single-start
potential-field baseline in `robotics_bench.planar_nav`.

## Active lanes

- **multi-start potential-field** (lane: `pf-sampling`) — sample K
  perturbed straight-line inits, run the existing optimizer per start,
  select by combined (clearance, length, smoothness) score. **Status
  after bl-1ygqtpl: ruled out as a standalone lever.** IID Gaussian
  perturbation up to σ=0.4 does not change homotopy class on the default
  scene.
- **homotopy-diverse initialization** (lane: `pf-topo-init`) — route K
  inits around each obstacle on opposite sides. `bl-e1dbf4k` (default
  scene): 7 classes found but all converge to the same basin because the
  default scene's corridors are too loose. **Status after bl-2gfreo7
  (tight scene): lane validated** — on a tight scene the lane beats the
  straight-init PF baseline by 6.7× clearance. **Status after bl-02ryj2g
  (scene-catalog): validated as layout-sensitive.** Across 3 named
  layouts × 4 seeds, the lane picked 3 distinct non-trivial labels
  (`research_lane_reorients=True`). The lane re-selects its homotopy
  class under layout change, confirming it responds to genuinely
  distinct scene topologies — not just jitter basins. **Status after
  bl-sowaomd (CEM honest baseline on tight scene): the "topology is
  the ingredient" interpretation is REJECTED on `make_tight_scene`.**
  A generic Gaussian CEM over interior waypoints (pop=24, iter=20,
  σ=0.12, 480 PFs/seed) matches homotopy-diverse init on 8 tight-scene
  seeds: mean clearance 0.2986 vs 0.2959, `Δ_homotopy_vs_cem = −0.0027`
  (well below the 0.03 "matches" threshold). Both methods beat
  straight-init PF by the same +0.26 margin. **The tight-scene win from
  bl-2gfreo7/bl-92kv0mo is explained by basin geometry being reachable
  with enough PF-refined probes**, not by routing priors that encode
  L/R assignment. Lane still valid as a cheap deterministic method (7
  starts vs 480 PFs; ~120× compute advantage at equal result), but the
  *research claim* that topology is load-bearing does not hold at this
  compute scale on this scene.
- **honest-baseline / CEM lane** (lane: `honest-baseline`) — new:
  opened and answered by bl-sowaomd. Gaussian CEM over interior
  waypoints matches homotopy-diverse init on `make_tight_scene` at
  moderate CEM compute. Open sub-question: does the match persist at
  **compute-matched** settings (CEM with pop=7, iter=1 ≡ 7 refined
  starts, matching homotopy's deterministic 7 inits)? If yes, CEM's
  Gaussian structure is genuinely sufficient. If no, the bl-sowaomd
  match is "CEM wins with more compute" and the topology claim
  partially survives. Followup filed.
- **scene-geometry lane** (lane: `scene-design`) — catalog of named
  tight-corridor layouts exists (`central_pinch`, `u_shape`,
  `offset_wall`, via `make_scene_named(name, seed, jitter)`). Control
  (`central_pinch`) is byte-identical to `make_tight_scene`.
  `offset_wall` needs a tighter-gap variant to exercise its L/R dilemma
  (PF equilibrium clearance ~0.20 currently masks it; follow-up scene
  tuning open). **Priority raised after bl-sowaomd:** the scene lane
  is now the primary way to discriminate methods — finding a scene
  where CEM *cannot* match homotopy (e.g. narrow gap where the L/R
  choice is binary and σ=0.12 Gaussian noise can't reliably select the
  correct side) would restore the topology claim.
- **tight-scene jitter-robustness sub-lane** (under `pf-topo-init`) —
  confirmed by bl-92kv0mo (σ=0.015) and bl-57syh2q (σ∈{0.05, 0.10}).
  **Closed as a standalone lever** — further jitter tuning on a fixed
  scene is expected to produce diminishing information.
- **scene-catalog / layout-sensitivity sub-lane** — opened and
  validated by bl-02ryj2g. Together with bl-57syh2q, it locates the
  binding constraint: the homotopy-diverse lane is **layout-sensitive
  but jitter-insensitive within a layout**.

## Run ledger

| Run | Idea | Verdict | Headline | Signal |
|-----|------|---------|----------|--------|
| bl-kosdpc2 | multi-start-pf (K=8, sigma=0.08) | ACCEPTED | `min_clearance` +0.45% (0.1808 → 0.1853) | NEGATIVE_RESEARCH_SIGNAL |
| bl-1ygqtpl | multi-start-pf sigma sweep (K=8, σ∈{0.15, 0.25, 0.4}) | ACCEPTED | best `+0.00995` at σ=0.4; collisions 0/8 at every sigma | NEGATIVE_RESEARCH_SIGNAL |
| bl-e1dbf4k | homotopy-diverse K=7 init (default scene) | ACCEPTED | 7/7 distinct classes, `best.min_clearance = 0.1808` (= baseline; no differentiation) | NEGATIVE_RESEARCH_SIGNAL |
| bl-2gfreo7 | tight-corridor scene for homotopy-init | ACCEPTED | straight-init PF 0.0439 → homotopy-best 0.2956 (**+0.252, 6.7×**), 7/7 classes, `success=true` | ACCEPTED_RESEARCH_SIGNAL |
| bl-92kv0mo | tight-corridor seed sweep (8 seeds, σ=0.015 jitter) | ACCEPTED | 8/8 success, mean improvement **+0.263**, range [+0.242, +0.317], seed 3 baseline collides (clearance −0.018) then homotopy recovers to 0.299 | ACCEPTED_RESEARCH_SIGNAL |
| bl-57syh2q | wider-jitter tight-corridor sweep (σ=0.05, 0.10) | ACCEPTED | σ=0.05: 8/8 success, mean **+0.208**; σ=0.10: 8/8 success, mean **+0.078** (seed 2 −0.013); selected non-trivial class is `R-0-L-1-L-2-L-3-L-4` on every seed both σ | NEGATIVE_RESEARCH_SIGNAL |
| bl-02ryj2g | scene-catalog for homotopy-init (3 scenes × 4 seeds, σ=0.05) | ACCEPTED | `research_lane_reorients=True`, 3 distinct non-trivial labels across the catalog; `central_pinch` keeps `R-0-L-1-L-2-L-3-L-4`, `u_shape` picks 2 new labels on 2/4 seeds, `offset_wall` rides `straight` on all 4 (PF-equilibrium masks the narrow gap) | ACCEPTED_RESEARCH_SIGNAL |
| bl-sowaomd | CEM honest-baseline vs homotopy on tight scene (seeds 0..7, σ=0.015) | ACCEPTED | CEM mean clearance 0.2986 vs homotopy 0.2959; `Δ_homotopy_vs_cem = −0.0027`; `CEM_matches_homotopy=True`; both +0.26 over straight-init PF; CEM sweep 94.8 s vs homotopy ≈7 s (~13× slower, same result) | NEGATIVE_RESEARCH_SIGNAL |

## Accepted facts

- Multi-start PF implementation is correct, deterministic, CPU-only, and
  back-compatible with the single-start baseline (smoke metrics
  bit-identical).
- IID Gaussian waypoint perturbation cannot change homotopy class on the
  default scene; the PF attractor absorbs perturbations up to σ=0.4.
- Homotopy-diverse initialization (7 L/R combos around 3 obstacles) is
  correctly implemented (bl-e1dbf4k) and generates genuinely distinct
  classes.
- **Scene geometry is the binding constraint.** `make_scene(seed=0)` has
  ~0.18 clearance everywhere, so no init strategy can differentiate on
  clearance and no perturbation magnitude induces collisions. The method
  lane and the scene lane interact: method comparisons are meaningless on
  under-constrained scenes.
- **On a tight scene (`make_tight_scene(0)`, 5 obstacles staggered into a
  central pinch with ~0.044 straight-init clearance), homotopy-diverse
  init beats straight-init PF by +0.252 min-clearance (0.0439 → 0.2956)
  at length_ratio 1.157.** The best route (`R-0-L-1-L-2-L-3-L-4`) is in a
  different homotopy class from the straight-init PF's basin. This is
  the first run on this thread where the planner is actually
  discriminated.
- **The tight-scene homotopy-init result is robust to small perturbation
  (σ=0.015 obstacle jitter) across 8 seeds.** bl-92kv0mo: success_rate
  1.0, mean clearance improvement +0.263, worst +0.242, best +0.317.
  Seed 3 is the strongest case: the straight-init PF actually collides
  (`min_clearance = −0.018`) while homotopy-diverse init still returns
  `0.299`, matching the other seeds. Selected homotopy label is
  `R-0-L-1-L-2-L-3-L-4` on every seed — at this jitter the 5-obstacle
  pinch's discriminating class doesn't shift.
- **Wider jitter on `make_tight_scene` softens but does not break the
  lane.** bl-57syh2q: at σ=0.05, 8/8 success, mean improvement +0.208
  (≈σ=0.015 magnitude). At σ=0.10, 8/8 success but mean improvement
  collapses ~4× to +0.078, and one seed (2) regresses slightly by
  −0.013. Selected-label diversity is still trivial: the non-trivial
  winner is always `R-0-L-1-L-2-L-3-L-4`; the only "shift" is `straight`
  winning on seeds where the straight-init PF already out-clears every
  homotopy candidate (1 seed at σ=0.05, 3 seeds at σ=0.10).
- **The 5-obstacle tight geometry is too rigid to produce topology-level
  diversity under jitter.** Both bl-92kv0mo and bl-57syh2q confirm this:
  jitter up to σ=0.10 does not rotate the winning homotopy class. The
  binding constraint is scene *layout*, not scene perturbation.
- **The homotopy-diverse lane genuinely re-orients under layout change**
  (bl-02ryj2g). Across the catalog at σ=0.05 the lane selected 3
  distinct non-trivial labels: `R-0-L-1-L-2-L-3-L-4` on `central_pinch`,
  `L-0-R-1-L-2-R-3-L-4-R-5-R-6` and `L-0-L-1-L-2-L-3-L-4-L-5-R-6` on
  `u_shape`. The lane is **layout-sensitive but jitter-insensitive
  within a layout**.
- **`offset_wall` does not discriminate homotopy classes at the current
  PF equilibrium clearance (~0.20)** (bl-02ryj2g). Straight wins on all
  4 seeds because the PF repulsion sits at ~0.20 clearance anywhere,
  which is already higher than any LR combo's score on this layout's
  geometry. Not a lane failure — it's a scene-tuning gap (obstacle radii
  need to be > 0.35 so PF equilibrium falls below 0.20).
- **A generic Gaussian CEM over interior waypoints matches
  homotopy-diverse init on `make_tight_scene` when given enough
  compute** (bl-sowaomd). At pop=24, iter=20, σ=0.12, elite_frac=0.25
  (480 PF-refined probes per seed): mean cem_best_clearance 0.2986,
  mean homotopy_best_clearance 0.2959 — the gap is −0.00266
  (|Δ|<0.03 ⇒ "matches" verdict). Both methods produce success_rate
  1.0 and mean improvement over straight-init PF of +0.265 / +0.263
  respectively. **Interpretation: on `make_tight_scene` the good
  basin is reachable with any sufficiently-broad multi-start; the
  homotopy structure in `pf-topo-init` encodes `which basin` with 7
  deterministic probes, which is a large compute-efficiency
  advantage (~13×), but not a uniqueness advantage.** The `bl-2gfreo7`
  tight-scene win is real, but the causal explanation is "reach a
  better basin than straight-init PF" — not "topological L/R
  assignment is the load-bearing ingredient."
- **CEM's wall-clock cost is ≈13× higher at parity of research
  outcome on `make_tight_scene`** (bl-sowaomd: CEM 94.8 s vs homotopy
  ≈7 s sweep; 0.024 s per PF ×480 × 8 seeds = CEM budget). If compute
  matters, homotopy wins outright; if research claim about L/R routing
  matters, CEM ties.

## Negative results / dead ends

- IID Gaussian interior-waypoint perturbation is decisively ruled out as
  a standalone multi-start lever on the default scene.
- Homotopy-diverse init **on the default scene** is ruled out as a
  discriminator: the classes exist but all converge to the same basin
  because the corridors are too wide (bl-e1dbf4k).
- Any further method comparisons on `make_scene(seed=0)` are suspect —
  that scene geometry is under-constrained for discriminating clearance-
  seeking methods.
- **Wider-jitter probing on `make_tight_scene` has saturated as a
  diagnostic.** The winning non-trivial class is invariant across
  σ∈{0.015, 0.05, 0.10}.
- **Scene-family probing at σ=0.05 is answered** (bl-02ryj2g). The lane
  does reorient under layout change. Further scene *variety* is not the
  binding constraint; the next question is which scene *properties*
  drive reorientation (gap width vs PF equilibrium clearance, multi-gap
  trade-offs, asymmetric costs).
- **The "topology is the load-bearing ingredient" interpretation of
  bl-2gfreo7 on `make_tight_scene` is ruled out at CEM(480)-scale
  compute** (bl-sowaomd). To revive the claim we need either
  (a) a scene family where Gaussian CEM cannot match, or
  (b) a compute-matched comparison (CEM with 7 refined probes) where
  homotopy still wins.

## Implementation bugs vs. research failures

- bl-kosdpc2, bl-1ygqtpl, bl-e1dbf4k: no implementation bugs.
- bl-2gfreo7: no implementation bugs. Reviewer flagged two minor
  non-blocking observations: (a) a non-top-of-file import in
  `tight_corridor.py:33`, (b) the research-metric `success` OR-left-arm
  uses straight-line-interpolation collision rather than
  `straight_init_baseline.collision`, but the OR's right arm is already
  True, so the outcome is invariant. Neither affects correctness.
- bl-92kv0mo: no implementation bugs. Reviewer noted that
  `run_tight_corridor_sweep` re-runs PF once per seed to rebuild the
  selected candidate for the composite plot — ~2× PF cost but invisible
  at ~7 s total. Flag-only, not worth fixing at current seed count.
- bl-57syh2q: no implementation bugs. Pure additive utility
  (`robotics_bench/compare_sweeps.py`, ~111 LOC) plus a unit test; no
  edits to any production module. Reviewer noted only cosmetic issues
  (`0.1` vs `0.10` rendering) and that the new utility's CLI `main()`
  is not unit-tested.
- bl-02ryj2g: no implementation bugs. Fully additive
  (`robotics_bench/scene_catalog.py`, `scene_catalog_sweep.py`,
  `tests/test_scene_catalog.py`) — empty `git diff` against
  `tight_scene.py`, `tight_corridor.py`, `homotopy_init.py`,
  `planar_nav.py`. `central_pinch` is byte-identical to
  `make_tight_scene` (test enforced over seeds 0–3 × jitters {0.015,
  0.05}). 9.43s wall time on the 3×4 sweep. Reviewer's cosmetic
  observation: `metrics.md` could surface a per-scene count of
  non-trivial selections, not just unique-label count; doesn't affect
  correctness.
- bl-sowaomd: no implementation bugs. Fully additive
  (`robotics_bench/cem_tight.py`, `robotics_bench/tight_head_to_head.py`,
  `tests/test_cem_tight.py`, `tests/test_tight_head_to_head.py`). Byte-
  identical loose-scene smoke vs parent branch (diff -r exit 0).
  Metrics-honesty spot-check: reported `cem_best.min_clearance` for
  seed 0 (0.3009223648563331) bit-identical to `path_metrics(
  selected_path.npy, obstacles)` recompute. All 10 infra gates in
  plan.md pass. Total CEM sweep 94.76 s; budget 480 s. Minor reviewer
  observations (non-blocking): `tight_head_to_head._homotopy_time_
  estimate` returns an analytic estimate because `tight_corridor.py`
  (frozen) doesn't emit per-seed wall-clock — documented honestly.
  No "runner-up elites" overlay on trajectory plots (plan did not
  require it; implementer deliberately kept plots legible).

## Reusable learnings

- When a "method works on scene A" vs "method works on scene B" disagree,
  scene geometry is usually the discriminator, not the method. **Before
  scaling up a method lane, validate it on a scene where the baseline
  demonstrably fails.**
- `homotopy_init.run()` accepts `scene_fn=...`; other drivers that
  previously hardcoded `make_scene(seed)` should adopt the same pattern
  so they can be reused on new scenes without a fork.
- PF `offset=0.12` works on both the default and tight scenes at K=7
  without retuning — the L/R routing geometry scales with obstacle
  radius.
- Scene-tuning loop: target `straight_init_baseline.min_clearance ∈
  [0.02, 0.08]` on the new scene so the baseline is genuinely stressed
  without universally infeasible.
- **Jitter on a fixed layout only perturbs basin membership, not basin
  identity.** To probe whether a method genuinely re-selects homotopy
  classes, vary the obstacle *layout* (scene family), not just the
  obstacle positions within a single layout.
- `compare_sweeps.py` is a generic seed×jitter cross-table utility — any
  future sweep pair (e.g. scene-A vs scene-B) can reuse the same
  aggregate-merging logic with a different axis label.
- **PF repulsion has a per-scene equilibrium clearance** set by the
  active-distance threshold (≈0.20 with current defaults). Any scene
  designed to test a "narrow-gap" vs "wide-detour" tradeoff must place
  the narrow gap *below* this equilibrium (obstacle radii > 0.35 on
  current settings). Otherwise the PF sits at equilibrium and makes
  the scene indistinguishable to the scoring function.
- **`scene_catalog.make_scene_named(name, seed, jitter)` is the new
  shared entry point** for building named layouts. New sweeps should go
  through it; drivers should accept `scene_fn` hooks rather than
  hardcode one scene.
- **Per-cell "straight wins" under a scoring function doesn't mean the
  PF is following the straight line** — the PF still deforms. Before
  calling a cell "uninformative," check the per-cell trajectory plot,
  not just the selected-label string.
- **Selected-label diversity is a lower bound on topological diversity,
  not an equivalent.** The label format uses projected-order indices,
  so two topologically distinct scenes can reuse a label if obstacle
  projection order aligns. For stronger evidence of topology shift,
  inspect trajectories, not labels.
- **When two methods hit the same basin on the same scene, that is
  evidence about the scene, not about the methods.** bl-sowaomd:
  homotopy-diverse init and Gaussian CEM tie because
  `make_tight_scene`'s good basin is reachable by any
  sufficiently-broad multi-start. To genuinely compare priors, pick
  scenes where the priors differ on *which basin is best* (e.g. a
  narrow gap where only one L/R assignment is feasible).
- **CEM over interior-waypoint offsets + PF refinement is a reusable
  honest-baseline pattern.** `robotics_bench/cem_tight.py` is generic
  enough to point at any `scene_fn` via a shim; future honest-baseline
  comparisons on new scenes should reuse this driver rather than fork
  a new CEM. The `tight_head_to_head` aggregator is also reusable —
  feed any two sweep aggregates with the same seeds.
- **Compute-parity matters when reading "X matches Y" claims.**
  bl-sowaomd's CEM used 480 PF-refined probes per seed to match
  homotopy's 7; interpreting this as "CEM equals homotopy" without
  the budget footnote would be misleading. Always report
  refinements-per-seed and wall-clock alongside headline clearance.

## Recommended next moves

bl-sowaomd answered Priority 2 from the prior synthesis with a clean
negative research signal on the homotopy topology claim. Two of the
three prior priorities remain informative; one new compute-parity lever
becomes the natural follow-up.

**Priority 1 — PF-equilibrium-sensitive scene variant
(`offset_wall_tight`).** Carried forward from the prior synthesis and
sharpened by bl-sowaomd. The `offset_wall` cell in bl-02ryj2g selected
`straight` on all 4 seeds because the PF equilibrium clearance (~0.20)
is higher than the scene-defining gap geometry. Build a variant with
obstacle radii > 0.35 and a narrow gap width < 0.20 so the PF cannot
sit in equilibrium; rerun bl-02ryj2g-style and also run the bl-sowaomd
CEM head-to-head on the new variant. Predicts: (a) the L/R dilemma
activates and the catalog emits a new non-trivial label;
(b) if the gap is narrow enough, Gaussian CEM at σ=0.12 cannot reliably
select the correct side and homotopy-diverse init finally beats CEM.
Directly addresses the "need a scene where priors differ on *which
basin*" gap surfaced by bl-sowaomd.

**Priority 2 — compute-matched CEM ablation.** New lever opened by
bl-sowaomd's reviewer observation: CEM used 480 PF-refined probes per
seed, homotopy used 7. Re-run the bl-sowaomd sweep with CEM pop=7,
iter=1 (or pop=1, iter=7), σ=0.12 so both methods get the same 7-probe
budget. If compute-matched CEM drops significantly below homotopy
(e.g. mean clearance < 0.20 vs 0.29) the topology claim partially
revives: structured L/R priors extract more per-probe information than
Gaussian noise. If compute-matched CEM still matches, the claim is
dead even at parity — the basin is genuinely that easy.

**Priority 3 — drop-straight ablation sweep on bl-02ryj2g catalog.**
Cheap (~10 s), informational only; still dominated by P1 on
information-per-run but kept as a free correctness spotcheck for the
catalog sweep's label analysis.

Filing Priority 1 (`offset_wall_tight` + CEM rematch on the tight
variant) and Priority 2 (compute-matched CEM ablation on
`make_tight_scene`) as concrete proposals on this thread. Skipping
Priority 3 — it's been dominated twice now and isn't in line for any
promotion this round.
