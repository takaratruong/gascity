#!/usr/bin/env bash
set -euo pipefail

CITY_DIR="/home/ubuntu/bright-lights"
LOG="$CITY_DIR/curator.log"
TS="$(date -Iseconds)"

cd "$CITY_DIR"

LOCK="$CITY_DIR/.gc/finalize-completed-iterations.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  finalize-completed-iterations  skipped-overlap" >> "$LOG"
  exit 0
fi

roots_json="$(timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${GC_ACTIVE_CONVERGENCE_SCAN_LIMIT:-200}" --json 2>/dev/null || printf '[]')"

printf '%s\n' "$roots_json" | jq -r '
  .[]
  | select(.status == "open")
  | select(.metadata["convergence.state"] == "active")
  | select(.metadata["convergence.active_wisp"] != null)
  | [
      .id,
      (.metadata["convergence.active_wisp"] // ""),
      (.metadata["gc.leg.latest_review"] // "__EMPTY__"),
      (.metadata["gc.worktree_dir"] // "__EMPTY__"),
      (.metadata["var.rig"] // .metadata["gc.rig"] // "__EMPTY__")
    ] | @tsv
' | while IFS=$'\t' read -r root active_wisp review_bead worktree_dir rig; do
  [ "$review_bead" = "__EMPTY__" ] && review_bead=""
  [ "$worktree_dir" = "__EMPTY__" ] && worktree_dir=""
  [ "$rig" = "__EMPTY__" ] && rig=""
  [ -n "$root" ] || continue
  [ -n "$active_wisp" ] || continue
  [ -n "$worktree_dir" ] || continue

  step="$active_wisp.1"
  step_status="$(gc bd show "$step" --json 2>/dev/null | jq -r '(if type == "array" then .[0] else . end).status // empty')"

  if [ -z "$review_bead" ]; then
    if [ "$step_status" = "closed" ]; then
      # Formula/controller failures can leave the active step closed without a
      # review leg and without the wisp root being closed. Close the wisp so the
      # convergence controller can run the gate and iterate normally.
      active_wisp_status="$(gc bd show "$active_wisp" --json 2>/dev/null | jq -r '(if type == "array" then .[0] else . end).status // empty')"
      gc bd update "$step" --set-metadata "molecule_id=$active_wisp" >/dev/null 2>&1 || true
      if [ "$active_wisp_status" != "closed" ]; then
        if gc bd close "$active_wisp" --reason "auto-finalized failed iteration: step closed without review leg" >/dev/null 2>&1; then
          echo "$TS  finalize-completed-iterations  closed-wisp-no-review  $active_wisp  root=$root  step=$step" >> "$LOG"
        else
          echo "$TS  finalize-completed-iterations  close-wisp-no-review-failed  $active_wisp  root=$root  step=$step" >> "$LOG"
        fi
      fi
    fi
    continue
  fi

  # The root keeps gc.leg.latest_review from the previous iteration until the
  # current iteration dispatches its own review. Never finalize the active wisp
  # from a stale review bead, or the controller can burn iterations without work.
  case "$review_bead" in
    "$active_wisp".*) ;;
    *)
      echo "$TS  finalize-completed-iterations  skip-stale-review  $root  active_wisp=$active_wisp  review=$review_bead" >> "$LOG"
      continue
      ;;
  esac

  root_json="$(gc bd show "$root" --json 2>/dev/null || printf '[]')"
  review_json="$(gc bd show "$review_bead" --json 2>/dev/null || printf '[]')"
  review_status="$(printf '%s\n' "$review_json" | jq -r '(if type == "array" then .[0] else . end).status // empty')"
  [ "$review_status" = "closed" ] || continue
  review_parent="$(printf '%s\n' "$review_json" | jq -r '(if type == "array" then .[0] else . end).parent // empty')"
  if [ "$review_parent" != "$active_wisp" ] && [ "$review_parent" != "$active_wisp.1" ]; then
    echo "$TS  finalize-completed-iterations  skip-review-parent-mismatch  $root  active_wisp=$active_wisp  review=$review_bead  parent=$review_parent" >> "$LOG"
    continue
  fi

  case "$step_status" in
    open|in_progress|closed) ;;
    *) continue ;;
  esac

  run_dir="$worktree_dir/results/run-$root"
  review_path="$run_dir/review.md"
  [ -f "$review_path" ] || continue
  verdict="$(grep -E '^VERDICT:' "$review_path" | tail -1 | awk '{print $2}')"
  case "$verdict" in
    ACCEPTED|REJECTED|NEEDS_TAKARA) ;;
    *) continue ;;
  esac

  if [ ! -f "$run_dir/implementation.md" ] || [ ! -f "$run_dir/metrics.json" ] || [ ! -f "$run_dir/metrics.md" ]; then
    echo "$TS  finalize-completed-iterations  missing-artifacts  $root  review=$review_bead" >> "$LOG"
    continue
  fi

  thread_id="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end) as $b | $b.metadata["gc.thread_id"] // $b.metadata["gc.lineage_root"] // $b.id // empty')"
  thread_title="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end) as $b | $b.metadata["gc.thread_title"] // $b.title // $b.id // empty')"
  iteration="${active_wisp##*.}"
  bash "$CITY_DIR/assets/scripts/convergence/sync_artifact_index.sh" \
    "$root" "$iteration" "$run_dir" "$verdict" "$thread_id" "$thread_title" "${rig:-}" >/dev/null 2>&1 || true
  bash "$CITY_DIR/assets/scripts/convergence/synthesize_review_result.sh" \
    "$root" "$run_dir" "${rig:-}" "$thread_id" "$thread_title" >/dev/null 2>&1 || true

  if [ "$step_status" != "closed" ]; then
    gc bd update "$step" --set-metadata "molecule_id=$active_wisp" >/dev/null 2>&1 || true
    if gc bd close "$step" --reason "auto-finalized after review.md verdict=$verdict; attached wisp will autoclose for gate" >/dev/null 2>&1; then
      echo "$TS  finalize-completed-iterations  closed-step  $step  root=$root  verdict=$verdict  review=$review_bead" >> "$LOG"
    else
      echo "$TS  finalize-completed-iterations  close-failed  $step  root=$root  verdict=$verdict" >> "$LOG"
    fi
  fi

  # The controller normally processes the wisp_closed event and terminates
  # accepted convergences. If that event is missed, the root remains open and
  # blocks the rig even though `gc converge test-gate` passes. Repair only the
  # unambiguous success/manual-terminal case; rejected reviews should still
  # iterate through the controller.
  if [ "$verdict" = "ACCEPTED" ] || [ "$verdict" = "NEEDS_TAKARA" ]; then
    gate_output="$(gc converge test-gate "$root" 2>&1 || true)"
    if printf '%s\n' "$gate_output" | grep -q '^Outcome:[[:space:]]*pass'; then
      root_state="$(gc bd show "$root" --json 2>/dev/null | jq -r '.[0].metadata["convergence.state"] // empty')"
      root_status="$(gc bd show "$root" --json 2>/dev/null | jq -r '.[0].status // empty')"
      if [ "$root_status" = "open" ] && [ "$root_state" = "active" ]; then
        gc bd update "$root" \
          --set-metadata convergence.state=terminated \
          --set-metadata convergence.terminal_actor=finalize-completed-iterations \
          --set-metadata convergence.terminal_reason=gate_passed \
          --set-metadata convergence.gate_outcome=pass \
          --remove-label status:stalled \
          --add-label status:accepted \
          --set-metadata "convergence.gate_stdout=$(printf '%s' "$gate_output" | tr '\n' ' ' | cut -c1-1000)" >/dev/null 2>&1 || true
        if gc bd close "$root" --reason "auto-finalized after gate pass ($verdict)" >/dev/null 2>&1; then
          echo "$TS  finalize-completed-iterations  closed-root  $root  verdict=$verdict" >> "$LOG"
        else
          echo "$TS  finalize-completed-iterations  close-root-failed  $root  verdict=$verdict" >> "$LOG"
        fi
      fi
    fi
  fi
done
