# Decision log — robotics-bench

## 2026-05-05 — multi-start PF (bl-kosdpc2)

- **Decision**: ACCEPT the multi-start-pf iteration (1/1) as infra-correct
  but mark it `NEGATIVE_RESEARCH_SIGNAL`. The improvement in
  `min_clearance` is within basin wiggle, not a real escape from the
  single-start local optimum.
- **Rationale**: All infra gates pass. The run technically clears the
  plan's "success == true" bar by `+0.004 min_clearance` but 7/8
  perturbed starts converge to the same basin; IID Gaussian perturbation
  keeps every start homotopic to the straight-line baseline and cannot
  route around obstacles on the opposite side.
- **Next**: Two followups filed — (1) sigma sweep at fixed K to test
  whether the IID lane is salvageable at higher noise; (2) topologically-
  diverse initialization as a separate lane if the IID lane fails.

## 2026-05-05 — multi-start PF sigma sweep (bl-1ygqtpl)

- **Decision**: ACCEPT the sigma sweep (1/1) as infra-correct, mark it
  `NEGATIVE_RESEARCH_SIGNAL`, and rule out IID Gaussian interior-waypoint
  perturbation as a standalone multi-start lever on this scene.
- **Rationale**: Across σ ∈ {0.15, 0.25, 0.4} at K=8, best
  `clearance_improvement_vs_baseline = +0.00995` (at σ=0.4), far below
  plan.md's 0.045 escape threshold. Collision count is 0/8 at every σ
  including σ=0.4 — the PF attractor pulls perturbations back into the
  baseline basin even at 5× the bl-kosdpc2 noise scale. Lane cannot be
  salvaged by cranking σ further.
- **Next**: Two followups to file — (1) CEM over waypoints (new
  method family that reshapes sampling covariance), (2) tighter-
  corridor scene variant where the single-start PF actually fails. Both
  are orthogonal to the in-flight bl-e1dbf4k homotopy-init lane.

## 2026-05-05 — tight-corridor seed sweep (bl-92kv0mo)

- **Decision**: ACCEPT the tight-corridor seed sweep (1/1) as
  infra-correct and stamp it `ACCEPTED_RESEARCH_SIGNAL`. The
  homotopy-diverse lane generalizes at σ=0.015 jitter across 8 seeds.
- **Rationale**: All infra gates pass. `python3 -m pytest -q` clean;
  loose-scene smoke bit-identical to parent `conv/bl-2gfreo7`;
  `make_tight_scene(0, jitter=0.015)` bit-identical to parent
  (`np.array_equal → True`); `seed_0/metrics.json` bit-identical to
  parent's `results/tight_corridor/metrics.json` (plumbing preserves
  parent per-seed result too); aggregate.json has all plan-schema
  fields, all numerics finite. Research metrics: success_rate 8/8,
  mean_clearance_improvement +0.263, range [+0.242, +0.317]. Seed 3's
  straight-init PF collides (`min_clearance = −0.018`) then
  homotopy-init recovers to 0.299 — canonical evidence for the lane.
- **Caveat**: σ=0.015 is a stability probe, not a geometry probe — the
  selected class (`R-0-L-1-L-2-L-3-L-4`) is identical on every seed.
  Reviewer flagged this as a follow-up direction, not a defect.
- **Next**: Two followups — (1) wider-jitter retry at σ=0.05 (and maybe
  σ=0.10) to test whether the winning homotopy class can shift under
  genuine geometric variation; (2) CEM baseline on tight scene
  (carried over from bl-2gfreo7's priority 2, still orthogonal).

## 2026-05-05 — scene-catalog for homotopy-init (bl-02ryj2g)

- **Decision**: ACCEPT the scene-catalog run (1/1) as infra-correct and
  mark it `ACCEPTED_RESEARCH_SIGNAL`. The homotopy-diverse lane genuinely
  re-orients its selected non-trivial class under layout change.
- **Rationale**: Across `{central_pinch, u_shape, offset_wall} × {0,1,2,3}`
  at σ=0.05, the lane selected 3 distinct non-trivial labels
  (`R-0-L-1-L-2-L-3-L-4`, `L-0-R-1-L-2-R-3-L-4-R-5-R-6`,
  `L-0-L-1-L-2-L-3-L-4-L-5-R-6`), clearing the research bar
  (`distinct_non_trivial_label_count ≥ 2`). Implementation is fully
  additive (`scene_catalog.py`, `scene_catalog_sweep.py`,
  `test_scene_catalog.py`) with empty `git diff` against the four
  forbidden modules; `central_pinch` byte-identical to `make_tight_scene`
  (test-enforced over seeds 0–3 × jitters {0.015, 0.05}); 9.43s wall time
  on a 3×4 sweep; pytest 7/7.
- **Insight**: Combining this with bl-57syh2q (NEGATIVE on jitter) draws
  a sharper boundary: the homotopy-diverse lane is **layout-sensitive
  but jitter-insensitive within a layout**. Useful asymmetry — the lane
  actually responds to topology, not to noise. Also learned that the PF
  repulsion has a per-scene equilibrium clearance (~0.20 with current
  defaults); any narrow-gap scene whose gap width exceeds this is
  indistinguishable to the scoring function, which is why `offset_wall`
  currently rides `straight` on all 4 seeds (gap geometry above the PF
  equilibrium).
- **Next**: Two followups — (1) `offset_wall_tight` scene variant with
  radii > 0.35 and narrow gap < 0.20 to put the gap below PF
  equilibrium; (2) CEM baseline on `make_tight_scene` (carried from
  bl-92kv0mo — sharper question now that the lane is confirmed
  topology-driven, not just "strong prior works"). Skipping the
  drop-straight ablation — P1 dominates it on information-per-run.

## 2026-05-05 — tight-corridor scene for homotopy-init (bl-2gfreo7)

- **Decision**: ACCEPT the tight-corridor run (1/1) as infra-correct and
  mark it `ACCEPTED_RESEARCH_SIGNAL`. This is the first positive research
  result on this thread.
- **Rationale**: On `make_tight_scene(0)` (5-obstacle pinch), straight-
  init PF achieves `min_clearance = 0.0439` while homotopy-diverse init
  best achieves `0.2956` (`R-0-L-1-L-2-L-3-L-4`), a +0.252 gain (6.7×) at
  length-ratio 1.157. 7/7 distinct homotopy classes, all 7 non-colliding.
  Plan's research `success` bar cleared; all 8 infra gates pass;
  reviewer independently reproduced `metrics.json` bit-for-bit. Loose-
  scene smoke digest unchanged, confirming the `homotopy_init.run()`
  `scene_fn` refactor is strictly additive.
- **Insight**: Scene geometry, not method noise magnitude, was the
  missing variable. bl-e1dbf4k (default scene) found 7 classes but all
  converged to baseline because the default scene's ~0.18 clearance
  everywhere gave no class a geometric advantage. On a scene whose left/
  right corridors differ materially in width, homotopy-diverse init
  discriminates cleanly.
- **Next**: Two followups — (1) sweep tight-scene geometry over seeds
  (does it generalize beyond seed 0?), (2) CEM-baseline comparison on
  the tight scene (is homotopy structure the ingredient, or does any
  strong multi-start beat straight-init PF here?).
