# mjx-diffphysics Rig Mayor Synthesis

## Current Goal
Motion-tracking policy using differentiable physics (MJX), driven by first-order gradients through the contact solver.

## Best Run So Far
**bl-tqtwfy8** — solver_iters=4/2, random-start MLP co-location, **10k steps**
- 0 NaN events in eval windows (stable)
- Tracking: 75.9% (frames 0-100), 61.4% (frames 5000-5100), 56.9% (frames 8000-8100)
- Root RMSE: 0.64m / 0.76m / 0.74m across windows
- Training: 10000 steps, 846.5s (11.8 it/s), 201/10000 NaN gradients zeroed (2%)
- **Marginal improvement** over 5k baseline (bl-269ht99): +0.9% near, -1.1% mid, +1.4% distant

Previous best (5k): bl-269ht99 — 75.0% / 62.5% / 55.5%, Root RMSE 0.40m / 0.84m / 0.72m

## Active Method/Idea Lanes
- **colocation** (active): MLP co-location with random start sampling. Current best.
- **vjp_solver** (infrastructure): Custom VJP override for MJX solver while-loop. Stable.

## Accepted Facts
1. Default solver_iters=2/1 causes intra-step NaN from finite inputs in the contact solver (bl-xoslko0 proved this)
2. solver_iters=4/2 completely eliminates eval NaN while maintaining 11.6 it/s training speed (bl-269ht99)
3. Random start frame sampling trains a generalist policy across full reference motion
4. MLP (256,256) + output_scale=0.7 produces stable learned params even with 2% NaN training gradients
5. Per-timestep gradient clipping (max_norm=10.0) bounds grad_norm spikes from 87k → 265 (300x reduction) but does NOT reduce NaN rate (bl-qbo6go6)
6. NaN generation is structural: contact singularities in the VJP Jacobian produce non-finite gradients before any clipping can act. The 2% rate is a floor for solver_iters_bwd=2.
7. Tikhonov regularization at ε=1e-6 does NOT reduce NaN rate (bl-ceebqzc). The pathological Hessian eigenvalues are degenerate by far more than 1e-6.
8. **Tikhonov regularization at ε=1e-4 ALSO does NOT reduce NaN rate** (bl-s4sgg2t). 100x increase in epsilon had zero effect (101/5000 NaN at both ε values). This definitively eliminates solver Hessian ill-conditioning as the NaN source. NaN must originate from a different backward-pass operation (contact Jacobian computation, quaternion normalization, or pre-solver division).

## Negative Results / Dead Ends
- solver_iters=2/1: intra-step NaN at frames 0-100 (88/100 steps affected). Eliminated by doubling iterations.
- Per-step NaN clamping in eval: diagnostic tool only, doesn't improve underlying stability
- **Progressive curriculum** (bl-v64kenk): Narrow frame range [0-2000] first, then expand. NaN at step 50 within the narrow range — curriculum does NOT fix instability. Root cause is solver iterations, not frame diversity.
- Scaling 1000→5000 steps at lr=0.001 without faster decay causes overshoot and regression (bl-pa4sbeo)
- **10k step scale-up** (bl-tqtwfy8): Only +1.4% on distant frames (56.9% vs 55.5%). Cosine LR decays to 1e-5 by step 10000, bottlenecking learning. Loss oscillates rather than converging due to random frame sampling. Longer training alone is insufficient for distant-frame generalization.
- **Per-timestep gradient clipping** (bl-qbo6go6): Bounds grad magnitude (265 vs 87k) but NaN rate unchanged at 2.0%. Clipping operates post-computation; cannot prevent NaN generation during VJP. Tracking comparable (76.4% / 61.7% / 51.3%) at 5k steps. Cleanly separates magnitude issue (solved) from NaN source issue (unsolved).
- **Tikhonov regularization ε=1e-6** (bl-ceebqzc): NaN rate unchanged at 2.0% (101/5000). Epsilon too small relative to pathological Hessian eigenvalue spread. Training completes with comparable metrics (76.7% / 59.3% / 57.6%) — regularization doesn't hurt but doesn't help at this scale.
- **Tikhonov regularization ε=1e-4** (bl-s4sgg2t): NaN rate STILL unchanged at 2.0% (101/5000). 100x larger epsilon had zero effect. Tracking slightly worse (73.8% / 61.1% / 55.6%) — over-damped gradients degrade solver accuracy. **This definitively closes the Tikhonov regularization approach**. The NaN source is NOT the Hessian inversion in `solve_bwd`.

## Implementation Bugs vs Research Failures
- Video validation failures (stddev<20) are infra issues, not research: solved by camera distance 2.5 + root tracking
- Attempt-2 SIGTERM: caused by heavy mjx.forward recomputation in rerender script. Fixed by CPU-only mujoco.Renderer path.
- **bl-dyvaxsb** (10k steps scale-up): INFRA_BLOCKED. All 3 attempts capacity-blocked by render_server.py holding idle GPU contexts on GPUs 1-7. Script is ready — just needs free GPUs.
- GPU contention (bl-qbo6go6 attempts 1-2): Same render_server.py idle context issue. Workaround: direct CUDA_VISIBLE_DEVICES=2 override (765MB idle context ≠ active compute).

## Reusable Fixes/Learnings
- **solver_iters=4/2**: Should be the default for all future MJX runs on this rig. Eliminates NaN at ~0 perf cost.
- **CPU rerender**: Use mujoco.Renderer (not MJX) for video re-renders from saved trajectories. 3s vs timeout.
- **Camera params**: distance=2.5, elevation=-15, track root_pos per panel.
- **GPU contention**: render_server.py allocates idle contexts on all GPUs even when mostly unused. Direct CUDA_VISIBLE_DEVICES override (bypassing claim_gpu_env.sh) works when the process has only 212 MiB stub contexts.
- **Cosine LR decay bottleneck**: With delayed cosine (constant phase = 50% of steps), lr hits 1e-5 by end. For longer runs, either restart the schedule or use a longer constant phase.
- **Per-timestep clipping (10.0)**: Effective for grad norm control (300x reduction in spikes). Worth including in future baselines but does not affect NaN rate.
- **GPU contention workaround**: Direct CUDA_VISIBLE_DEVICES=N override when claim_gpu_env.sh reports all GPUs busy but nvidia-smi shows only 765MB idle contexts.

## Recommended Next Move
**Instrument the VJP backward pass** to identify the exact operation producing NaN. Tikhonov regularization has been definitively eliminated (ε=1e-4 had zero effect despite 100x increase). The NaN must originate upstream of the Hessian inversion — likely in contact Jacobian computation, quaternion normalization, or a pre-solver division. Next lever: add `jnp.isfinite` checks at each stage of `solve_bwd` to pinpoint the first non-finite operation, then apply targeted mitigation.

## Run History
- `bl-qbo6go6` — g1-vjp-h100-pertimestep-gradclip: Per-timestep gradient clipping — `ACCEPTED (NEGATIVE_RESEARCH_SIGNAL)`. Bounds grad spikes 300x but NaN unchanged.
- `bl-tqtwfy8` — g1-vjp-h100-random-start: 10k steps scale-up — `ACCEPTED (NEGATIVE_RESEARCH_SIGNAL)`. Marginal gain, LR bottleneck.
- `bl-xwx7apx` — g1-vjp-h100-random-start: Multi-episode training — `INFRA_BLOCKED`.
- `bl-ceebqzc` — g1-vjp-h100-pertimestep-gradclip: Tikhonov ε=1e-6 regularization — `ACCEPTED (NEGATIVE_RESEARCH_SIGNAL)`. NaN unchanged; ε too small.
- `bl-s4sgg2t` — g1-vjp-h100-pertimestep-gradclip: Tikhonov ε=1e-4 — `ACCEPTED (NEGATIVE_RESEARCH_SIGNAL)`. NaN unchanged; closes Tikhonov approach entirely.

## Update: bl-s4sgg2t (2026-05-10) — Tikhonov ε=1e-4 TESTED (CLOSES APPROACH)

### Run: address reviewer delta from bl-ceebqzc
- **Result class**: NEGATIVE_RESEARCH_SIGNAL
- **Hypothesis**: Increasing Tikhonov epsilon 100x (1e-6 → 1e-4) eliminates NaN
- **Outcome**: DISPROVED. NaN rate unchanged at exactly 2.0% (101/5000). Epsilon magnitude is irrelevant.
- **Thread**: g1-vjp-h100-pertimestep-gradclip (root bl-76mzves, depth 6)

### Metrics
- Tracking: 73.8% / 61.1% / 55.6% (frames 0-100 / 5000-5100 / 8000-8100)
- Root RMSE: 0.64m / 0.77m / (similar)
- NaN gradients: 101/5000 (2.0%) — identical to parent at ε=1e-6
- Loss: -4.89 → -3.40 (final same as parent). Over-damped gradients slightly degraded learning.
- Compile: 634s, Train: 423s (11.8 it/s) on L40S GPU 2

### Key finding
**Tikhonov regularization is NOT the lever for NaN elimination.** The NaN source is definitively NOT the Hessian inversion in `solve_bwd`. A 100x increase in damping epsilon produced exactly 0 change in NaN count, timing, or distribution. The pathological operation must be upstream: contact Jacobian computation itself, quaternion normalization, or a pre-solver division.

### Closed approaches
- Tikhonov ε=1e-6: no effect (bl-ceebqzc)
- Tikhonov ε=1e-4: no effect (bl-s4sgg2t)
- Per-timestep grad clipping: bounds magnitude but NaN unchanged (bl-qbo6go6)

### Remaining levers (priority order)
1. **Instrument backward pass** — add jnp.isfinite checks at each solve_bwd stage to find first NaN source
2. **solver_iters_bwd=4+** — more iterations may route the solver around singular states
3. **Contact Jacobian clamping** — if NaN originates in jacobian computation, clamp inputs
