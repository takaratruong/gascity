#!/usr/bin/env bash
# Convergence gate for evaluate-idea — reads review.md directly.
#
# Called by the controller after each wisp closes. No agent-writes-metadata
# race: this script reads the artifact produced by the reviewer and decides
# iterate vs terminate-with-success.
#
# Exit semantics:
#   0   → gate pass → convergence terminates successfully
#   ≠0  → gate fail → controller spawns next iteration (up to --max-iterations)
#
# Env from ConditionEnv.Environ():
#   GC_BEAD_ID           convergence root (e.g. bl-z7jr)
#   GC_ITERATION         current iteration number
#   GC_MAX_ITERATIONS    configured max
#   HOME                 city path (bright-lights)
#   GC_WISP_ID           wisp ID whose completion triggered this gate
#
# Mapping from reviewer verdict → gate outcome:
#   ACCEPTED      → exit 0 (terminate success)
#   NEEDS_TAKARA  → exit 0 (terminate; operator look required, flagged via stdout)
#   REJECTED      → exit 1 (iterate)
#   missing/other → exit 1 (iterate)
#
# Additional ACCEPTED-path guard:
# - park-manip requires $RUN_DIR/rollout.mp4 for every accepted run.
# - when rollout.mp4 exists, the reviewer-accepted verdict is demoted to
#   iterate if scripts/check_rollout_visual.py (resolved from the run dir's
#   worktree) returns non-zero. Demotion is logged to stdout and to
#   $RUN_DIR/gate_override.md; review.md is left untouched.

set -u
# Do NOT set -e: we always want to emit the debug line.

ROOT="${GC_BEAD_ID:-}"
ITER="${GC_ITERATION:-?}"
MAX="${GC_MAX_ITERATIONS:-?}"

if [ -z "$ROOT" ]; then
  echo "gate: GC_BEAD_ID not set → fail (iterate)"
  exit 1
fi

# Find the run dir. Since convergences now run in per-conv git worktrees,
# results land at /home/ubuntu/worktrees/<rig>/<ROOT>/results/run-<ROOT>,
# NOT at /home/ubuntu/projects/<rig>/results/. Prefer the worktree path;
# fall back to the project dir for legacy runs.
RUN_DIR=""
for d in /home/ubuntu/worktrees/*/"$ROOT"/results/run-"$ROOT" \
         /home/ubuntu/projects/*/results/run-"$ROOT"; do
  if [ -d "$d" ]; then
    RUN_DIR="$d"
    break
  fi
done

if [ -z "$RUN_DIR" ]; then
  echo "gate: no run dir matching run-$ROOT found → fail (iterate)"
  exit 1
fi

REVIEW_MD="$RUN_DIR/review.md"
if [ ! -f "$REVIEW_MD" ]; then
  echo "gate: iter=$ITER/$MAX no review.md at $REVIEW_MD → fail (iterate)"
  exit 1
fi

# --- visual-check helper -----------------------------------------------------
# Run scripts/check_rollout_visual.py against $RUN_DIR/rollout.mp4 IFF the
# rollout exists. Resolve the checker by walking up from $RUN_DIR to its
# worktree root (the first ancestor containing scripts/check_rollout_visual.py).
# Echoes pass/skip/fail lines to stdout. Sets GATE_VISUAL_STATUS to one of
# "pass", "skip", "fail:<reason>". On fail, writes $RUN_DIR/gate_override.md.
run_visual_check() {
  GATE_VISUAL_STATUS="skip"
  local rollout="$RUN_DIR/rollout.mp4"
  local rig="unknown"
  case "$RUN_DIR" in
    /home/ubuntu/worktrees/*/*/results/run-*)
      rig="$(printf '%s\n' "$RUN_DIR" | awk -F/ '{print $5}')"
      ;;
    /home/ubuntu/projects/*/results/run-*)
      rig="$(printf '%s\n' "$RUN_DIR" | awk -F/ '{print $5}')"
      ;;
  esac

  # Policy-driven generic media gate. This catches rigs like mjx-diffphysics
  # that produce baseline.mp4/optimized.mp4 instead of rollout.mp4.
  local policy_json require_media require_video require_visible media_args media_stdout media_rc
  policy_json="$(cd /home/ubuntu/bright-lights && /home/ubuntu/go/bin/gc bd list --label kind:policy --label "rig:$rig" --status open --json 2>/dev/null || printf '[]')"
  require_media="$(printf '%s\n' "$policy_json" | jq -r '[.[]? | select(.metadata["gc.policy.require_media"] == true or .metadata["gc.policy.require_media"] == "true")] | length' 2>/dev/null || echo 0)"
  require_video="$(printf '%s\n' "$policy_json" | jq -r '[.[]? | select(.metadata["gc.policy.require_video"] == true or .metadata["gc.policy.require_video"] == "true")] | length' 2>/dev/null || echo 0)"
  require_visible="$(printf '%s\n' "$policy_json" | jq -r '[.[]? | select(.metadata["gc.policy.require_visible_robot_video"] == true or .metadata["gc.policy.require_visible_robot_video"] == "true")] | length' 2>/dev/null || echo 0)"
  if [ "${require_media:-0}" -gt 0 ] || [ "${require_video:-0}" -gt 0 ] || [ "${require_visible:-0}" -gt 0 ]; then
    media_args=""
    [ "${require_media:-0}" -gt 0 ] && media_args="$media_args --require-media"
    [ "${require_video:-0}" -gt 0 ] && media_args="$media_args --require-video"
    [ "${require_visible:-0}" -gt 0 ] && media_args="$media_args --require-visible-video"
    media_stdout="$(python3 /home/ubuntu/bright-lights/assets/scripts/convergence/check_required_media.py --run-dir "$RUN_DIR" $media_args 2>&1)"
    media_rc=$?
    if [ "$media_rc" -ne 0 ]; then
      local media_failures
      media_failures="$(printf '%s\n' "$media_stdout" | python3 -c 'import json,sys
try:
  data=json.loads(sys.stdin.read())
  fs=data.get("failures") or []
  print("; ".join(fs) if fs else "(no failures list in JSON)")
except Exception as e:
  print(f"(could not parse media checker stdout: {e})")' 2>/dev/null)"
      echo "gate: required-media check FAILED — $media_failures"
      {
        echo "# Gate override"
        echo
        echo "Reviewer verdict ACCEPTED was demoted to REJECTED by the convergence"
        echo "gate because required media policy failed."
        echo
        echo "- iter: $ITER/$MAX"
        echo "- rig: $rig"
        echo "- run_dir: $RUN_DIR"
        echo "- failures: $media_failures"
        echo
        echo '```json'
        printf '%s\n' "$media_stdout"
        echo '```'
      } > "$RUN_DIR/gate_override.md"
      GATE_VISUAL_STATUS="fail:$media_failures"
      return 1
    fi
    python3 /home/ubuntu/bright-lights/assets/scripts/convergence/make_video_contact_sheet.py --run-dir "$RUN_DIR" >/dev/null 2>&1 || true
    echo "gate: required-media check passed for rig=$rig"
    GATE_VISUAL_STATUS="pass"
  fi

  if [ ! -f "$rollout" ]; then
    if [ "$GATE_VISUAL_STATUS" = "pass" ]; then
      echo "gate: no rollout.mp4 in $RUN_DIR, but policy media check already passed for rig=$rig"
      return 0
    fi
    if [ "$rig" = "park-manip" ]; then
      echo "gate: no rollout.mp4 in $RUN_DIR for park-manip — fail (video required)"
      GATE_VISUAL_STATUS="fail:missing rollout.mp4"
      return 1
    fi
    echo "gate: no rollout.mp4 in $RUN_DIR — skipping visual check for rig=$rig"
    return 0
  fi

  local checker=""
  # Prefer the city-level shared copy (one source of truth).
  if [ -f "$HOME/bright-lights/assets/scripts/check_rollout_visual.py" ]; then
    checker="$HOME/bright-lights/assets/scripts/check_rollout_visual.py"
  else
    # Fallback: walk up from RUN_DIR to first ancestor with the file
    # (handles legacy rig-local copies).
    local dir="$RUN_DIR"
    while [ "$dir" != "/" ] && [ -n "$dir" ]; do
      if [ -f "$dir/scripts/check_rollout_visual.py" ]; then
        checker="$dir/scripts/check_rollout_visual.py"
        break
      fi
      dir="$(dirname "$dir")"
    done
  fi

  if [ -z "$checker" ]; then
    echo "gate: visual-check unavailable (scripts/check_rollout_visual.py not found above $RUN_DIR) — skipping"
    return 0
  fi

  local visual_stdout
  visual_stdout="$(python3 "$checker" --video_in "$rollout" 2>&1)"
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "gate: visual-check passed ($(basename "$checker") on rollout.mp4)"
    GATE_VISUAL_STATUS="pass"
    return 0
  fi

  # Extract compact failures list from the checker's JSON, if present.
  local failures
  failures="$(printf '%s\n' "$visual_stdout" \
    | python3 -c 'import json,sys
try:
  data=json.loads(sys.stdin.read())
  fs=data.get("failures") or []
  print("; ".join(fs) if fs else "(no failures list in JSON)")
except Exception as e:
  print(f"(could not parse checker stdout: {e})")' 2>/dev/null)"
  echo "gate: visual-check FAILED — $failures"
  {
    echo "# Gate override"
    echo
    echo "Reviewer verdict ACCEPTED was demoted to REJECTED by the convergence"
    echo "gate because scripts/check_rollout_visual.py failed on rollout.mp4."
    echo
    echo "- iter: $ITER/$MAX"
    echo "- rollout: $rollout"
    echo "- checker: $checker"
    echo "- failures: $failures"
    echo
    echo '```json'
    printf '%s\n' "$visual_stdout"
    echo '```'
  } > "$RUN_DIR/gate_override.md"

  # Append one JSONL record to the city-wide audit log so a systematic
  # demotion pattern is visible in aggregate (per-run gate_override.md is
  # forensic detail; this is the rollup). Append-only, no dedup, no
  # locking — operator-only inspection on POSIX local FS.
  local audit_log="$HOME/bright-lights/gate_overrides.log"
  GATE_OVERRIDE_LOG="$audit_log"
  RUN_DIR="$RUN_DIR" BEAD_ID="${GC_BEAD_ID:-}" ITERATION="${GC_ITERATION:-}" \
  FAILURES="$failures" AUDIT_LOG="$audit_log" \
  python3 -c '
import json, os, re, sys
from datetime import datetime, timezone
run_dir = os.environ.get("RUN_DIR", "")
rig = "unknown"
m = re.match(r"^/home/ubuntu/worktrees/([^/]+)/", run_dir)
if m:
    rig = m.group(1)
else:
    m = re.match(r"^/home/ubuntu/projects/([^/]+)/", run_dir)
    if m:
        rig = m.group(1)
rec = {
    "timestamp":     datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "bead_id":       os.environ.get("BEAD_ID", ""),
    "iteration":     os.environ.get("ITERATION", ""),
    "rig":           rig,
    "run_dir":       run_dir,
    "failure_field": os.environ.get("FAILURES", ""),
    "exit_code":     1,
}
line = json.dumps(rec, ensure_ascii=False)
with open(os.environ["AUDIT_LOG"], "a", encoding="utf-8") as f:
    f.write(line + "\n")
'
  echo "gate: appended override record to $audit_log"
  GATE_VISUAL_STATUS="fail:$failures"
  return 1
}

VERDICT=$(grep -E '^VERDICT:' "$REVIEW_MD" | tail -1 | awk '{print $2}')

case "$VERDICT" in
  ACCEPTED)
    if run_visual_check; then
      echo "gate: iter=$ITER/$MAX reviewer=ACCEPTED → pass (terminate success)"
      exit 0
    else
      echo "gate: iter=$ITER/$MAX reviewer=ACCEPTED but gate-override (visual-check-failed) → fail (iterate)"
      exit 1
    fi
    ;;
  NEEDS_TAKARA)
    echo "gate: iter=$ITER/$MAX reviewer=NEEDS_TAKARA → pass (terminate; operator review recommended)"
    exit 0
    ;;
  REJECTED)
    echo "gate: iter=$ITER/$MAX reviewer=REJECTED → fail (iterate)"
    exit 1
    ;;
  "")
    echo "gate: iter=$ITER/$MAX no VERDICT line in $REVIEW_MD → fail (iterate)"
    exit 1
    ;;
  *)
    echo "gate: iter=$ITER/$MAX reviewer='$VERDICT' unrecognized → fail (iterate)"
    exit 1
    ;;
esac
