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

## Negative Results / Dead Ends
- solver_iters=2/1: intra-step NaN at frames 0-100 (88/100 steps affected). Eliminated by doubling iterations.
- Per-step NaN clamping in eval: diagnostic tool only, doesn't improve underlying stability
- **Progressive curriculum** (bl-v64kenk): Narrow frame range [0-2000] first, then expand. NaN at step 50 within the narrow range — curriculum does NOT fix instability. Root cause is solver iterations, not frame diversity.
- Scaling 1000→5000 steps at lr=0.001 without faster decay causes overshoot and regression (bl-pa4sbeo)
- **10k step scale-up** (bl-tqtwfy8): Only +1.4% on distant frames (56.9% vs 55.5%). Cosine LR decays to 1e-5 by step 10000, bottlenecking learning. Loss oscillates rather than converging due to random frame sampling. Longer training alone is insufficient for distant-frame generalization.

## Implementation Bugs vs Research Failures
- Video validation failures (stddev<20) are infra issues, not research: solved by camera distance 2.5 + root tracking
- Attempt-2 SIGTERM: caused by heavy mjx.forward recomputation in rerender script. Fixed by CPU-only mujoco.Renderer path.
- **bl-dyvaxsb** (10k steps scale-up): INFRA_BLOCKED. All 3 attempts capacity-blocked by render_server.py holding idle GPU contexts on GPUs 1-7. Script is ready — just needs free GPUs.

## Reusable Fixes/Learnings
- **solver_iters=4/2**: Should be the default for all future MJX runs on this rig. Eliminates NaN at ~0 perf cost.
- **CPU rerender**: Use mujoco.Renderer (not MJX) for video re-renders from saved trajectories. 3s vs timeout.
- **Camera params**: distance=2.5, elevation=-15, track root_pos per panel.
- **GPU contention**: render_server.py allocates idle contexts on all GPUs even when mostly unused. Direct CUDA_VISIBLE_DEVICES override (bypassing claim_gpu_env.sh) works when the process has only 212 MiB stub contexts.
- **Cosine LR decay bottleneck**: With delayed cosine (constant phase = 50% of steps), lr hits 1e-5 by end. For longer runs, either restart the schedule or use a longer constant phase.

## Recommended Next Move
**bl-qbo6go6**: Per-timestep gradient clipping (max_norm=10.0 before nanmean) to reduce NaN instability. Directly targets the 2% NaN rate and grad_norm spikes (87k+) observed in bl-tqtwfy8. Same 5k steps / solver_iters=4/2 baseline config for controlled comparison against bl-269ht99. If NaN rate drops below 1% and held-out windows improve, this becomes the new default pipeline and unlocks productive scale-up.

- `bl-xwx7apx` — g1-vjp-h100-random-start: Multi-episode training with random reference frame sampling — `INFRA_BLOCKED`. See review.md for details.

- `bl-tqtwfy8` — g1-vjp-h100-random-start: Multi-episode training with random reference frame sampling — `NEGATIVE_RESEARCH_SIGNAL`. See review.md for details.
