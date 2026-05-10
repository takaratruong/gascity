#!/usr/bin/env bash
# Nudge active implementation attempts that have not produced required artifacts.

set -euo pipefail

CITY_DIR="/home/ubuntu/bright-lights"
LOG="$CITY_DIR/curator.log"
TS="$(date -Iseconds)"
GRACE_SECONDS="${EMPTY_ATTEMPT_GRACE_SECONDS:-300}"
COOLDOWN_SECONDS="${EMPTY_ATTEMPT_NUDGE_COOLDOWN_SECONDS:-600}"

cd "$CITY_DIR"

LOCK="$CITY_DIR/.gc/convergence-watchdog-empty-attempts.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  empty-attempt-watchdog  skipped-overlap" >> "$LOG"
  exit 0
fi

parse_epoch() {
  local raw="${1:-1970-01-01T00:00:00Z}"
  raw="$(printf '%s\n' "$raw" | sed -E 's/\.[0-9]+Z$/Z/')"
  date -u -d "$raw" +%s 2>/dev/null || printf '0'
}

now_epoch="$(date -u +%s)"

timeout 15s gc bd list --all --has-metadata-key gc.attempt_run_dir --sort updated --reverse --limit "${EMPTY_ATTEMPT_SCAN_LIMIT:-500}" --json 2>/dev/null | jq -r '
  .[]
  | select(.status == "open" or .status == "in_progress" or .status == "closed")
  | select((.metadata["gc.routed_to"] // "") | test("/workers\\.implementer$"))
  | [
      .id,
      (.status // ""),
      (.title // ""),
      (.metadata["gc.rig"] // ""),
      (.metadata["gc.routed_to"] // ""),
	      (.metadata["gc.attempt_run_dir"] // ""),
	      (.metadata["gc.watchdog.empty_attempt_last_at"] // "__EMPTY__"),
	      (.created_at // ""),
	      (.updated_at // .created_at // "")
	    ] | @tsv
	' | while IFS=$'\t' read -r bead bead_status title rig target attempt_dir last_at created_at updated_at; do
  [ -n "$bead" ] || continue
	  [ -n "$attempt_dir" ] || continue
	  [ -d "$attempt_dir" ] || continue

	  if [ "$bead_status" = "closed" ] && [ -f "$attempt_dir/.gc_attempt_started" ] && [ ! -f "$attempt_dir/.gc_attempt_finished" ] && [ ! -f "$attempt_dir/.gc_attempt_failed" ]; then
	    child_pid="$(cat "$attempt_dir/.gc_attempt_child_pid" 2>/dev/null || true)"
	    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
	      date -Is > "$attempt_dir/.gc_attempt_cancelled"
	      echo "$TS  empty-attempt-watchdog  cancelled-closed-live-attempt  $bead  child_pid=$child_pid  dir=$attempt_dir" >> "$LOG"
	    fi
	    continue
	  fi

  last_epoch=0
  if [ "$last_at" != "__EMPTY__" ] && [ -n "$last_at" ]; then
    last_epoch="$(parse_epoch "$last_at")"
  fi
  if [ "$last_epoch" -gt 0 ] && [ $((now_epoch - last_epoch)) -lt "$COOLDOWN_SECONDS" ]; then
    continue
  fi

  root="${bead%%.*}"
  root_json="$(gc bd show "$root" --json 2>/dev/null || printf '[]')"
  root_thread="$(printf '%s\n' "$root_json" | jq -r '.[0].metadata["gc.thread_id"] // empty' 2>/dev/null || true)"
  root_title="$(printf '%s\n' "$root_json" | jq -r '.[0].metadata["gc.thread_title"] // empty' 2>/dev/null || true)"
  root_rig="$(printf '%s\n' "$root_json" | jq -r '.[0].metadata["gc.rig"] // .[0].metadata["var.rig"] // empty' 2>/dev/null || true)"
  if [ -n "$root_thread" ]; then
    gc bd update "$bead" \
      --set-metadata "gc.thread_id=$root_thread" \
      --set-metadata "gc.thread_title=$root_title" \
      --set-metadata "gc.parent_run=$root" \
      --set-metadata "gc.rig=$root_rig" \
      >/dev/null 2>&1 || true
  fi

  has_required="false"
  if [ -s "$attempt_dir/implementation.md" ] && [ -s "$attempt_dir/metrics.json" ] && [ -s "$attempt_dir/metrics.md" ]; then
    has_required="true"
  fi
  has_progress="false"
  if [ -s "$attempt_dir/progress.jsonl" ]; then
    has_progress="true"
  fi

  if [ -f "$attempt_dir/.gc_attempt_started" ] && [ ! -f "$attempt_dir/.gc_attempt_finished" ] && [ ! -f "$attempt_dir/.gc_attempt_failed" ]; then
    child_pid="$(cat "$attempt_dir/.gc_attempt_child_pid" 2>/dev/null || true)"
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
	      current_status="$(gc bd show "$bead" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null || true)"
	      if [ "$current_status" != "in_progress" ]; then
	        gc bd update "$bead" --status in_progress >/dev/null 2>&1 || true
	        echo "$TS  empty-attempt-watchdog  repaired-live-attempt-status  $bead  status=$current_status  child_pid=$child_pid" >> "$LOG"
	      fi
      continue
    fi
  fi

  if [ -f "$attempt_dir/.gc_attempt_finished" ] || [ -f "$attempt_dir/.gc_attempt_failed" ]; then
    terminal_reason=""
    if [ -f "$attempt_dir/.gc_attempt_failed" ]; then
      terminal_reason="attempt process exited non-zero"
    elif [ ! -s "$attempt_dir/metrics.json" ]; then
      terminal_reason="attempt process finished without metrics.json"
    elif [ "$rig" = "mjx-diffphysics" ] && [ "$has_progress" != "true" ]; then
      terminal_reason="attempt process finished without progress.jsonl"
    fi
    if [ -s "$attempt_dir/metrics.json" ]; then
      finite_bad="$(jq -r '
        if has("finite_gradients") then (.finite_gradients != true)
        elif has("all_gradients_finite") then (.all_gradients_finite != true)
        else false end
      ' "$attempt_dir/metrics.json" 2>/dev/null || echo true)"
      null_bad="$(jq -r '
        . as $m |
        reduce ["tracking_accuracy_pct", "root_rmse_m", "joint_rmse_rad", "final_loss"][] as $k
          (false; . or (($m | has($k)) and (($m[$k] == null) or (($m[$k]|tostring) == "NaN"))))
      ' "$attempt_dir/metrics.json" 2>/dev/null || echo true)"
      if [ -z "$terminal_reason" ] && [ "$finite_bad" = "true" ]; then
        terminal_reason="attempt process finished with non-finite gradients"
      elif [ -z "$terminal_reason" ] && [ "$null_bad" = "true" ]; then
        terminal_reason="attempt process finished with null/NaN tracking metrics"
      fi
    fi

    if [ -z "$terminal_reason" ] && [ "$rig" = "mjx-diffphysics" ]; then
      media_count="$(find "$attempt_dir" -maxdepth 3 -type f \( -name '*.mp4' -o -name '*.webm' -o -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | wc -l | awk '{print $1}')"
      if [ "${media_count:-0}" -eq 0 ]; then
        terminal_reason="attempt process finished without required media/video artifact"
      fi
    fi

    if [ -n "$terminal_reason" ]; then
      printf '%s\n' "$terminal_reason" > "$attempt_dir/validation_failed.txt"
      gc bd update "$bead" \
        --set-metadata "gc.validation=failed" \
        --set-metadata "gc.watchdog.empty_attempt_last_at=$TS" \
        --set-metadata "gc.watchdog.empty_attempt_reason=$terminal_reason" \
        --append-notes "Watchdog: $terminal_reason. Closing this attempt so the coordinator can validate-fail it and create the next Gas City attempt." \
        >/dev/null 2>&1 || true
      gc bd close "$bead" --reason "watchdog closed failed terminal attempt: $terminal_reason" >/dev/null 2>&1 || true
      echo "$TS  empty-attempt-watchdog  closed-terminal-failed-attempt  $bead  rig=$rig  reason=$terminal_reason  dir=$attempt_dir" >> "$LOG"
      continue
    fi

    if [ ! -s "$attempt_dir/metrics.md" ]; then
      {
        echo "# Metrics"
        echo
        jq -r '
          "- tracking_accuracy_pct: \(.tracking_accuracy_pct // "n/a")",
          "- root_rmse_m: \(.root_rmse_m // "n/a")",
          "- joint_rmse_rad: \(.joint_rmse_rad // "n/a")",
          "- final_loss: \(.final_loss // "n/a")",
          "- all_gradients_finite: \(.all_gradients_finite // .finite_gradients // "n/a")",
          "- device: \(.device // "n/a")"
        ' "$attempt_dir/metrics.json" 2>/dev/null || true
      } > "$attempt_dir/metrics.md"
    fi
    if [ ! -s "$attempt_dir/implementation.md" ]; then
      {
        echo "# Implementation"
        echo
        echo "Watchdog materialized this summary because the terminal attempt had valid required metrics/media but no implementation.md."
        echo
        echo "- Attempt bead: $bead"
        echo "- Attempt directory: $attempt_dir"
        echo "- Run log: $attempt_dir/run.log"
      } > "$attempt_dir/implementation.md"
    fi

    rm -f "$attempt_dir/validation_failed.txt"
    gc bd update "$bead" \
      --set-metadata "gc.validation=terminal-complete" \
      --set-metadata "gc.watchdog.empty_attempt_last_at=$TS" \
      --set-metadata "gc.watchdog.empty_attempt_reason=terminal attempt complete" \
      --append-notes "Watchdog: terminal attempt has required metrics/progress/media; closing so coordinator can validate and promote it." \
      >/dev/null 2>&1 || true
    gc bd close "$bead" --reason "watchdog closed terminal complete attempt" >/dev/null 2>&1 || true
    echo "$TS  empty-attempt-watchdog  closed-terminal-complete-attempt  $bead  rig=$rig  dir=$attempt_dir" >> "$LOG"
    continue
  fi

	  if [ -f "$attempt_dir/.gc_attempt_started" ]; then
	    age_epoch="$(parse_epoch "$updated_at")"
	  else
	    age_epoch="$(parse_epoch "$created_at")"
	  fi
	  age=$((now_epoch - age_epoch))
  [ "$age" -ge "$GRACE_SECONDS" ] || continue

  if [ "$has_required" = "true" ] && { [ "$rig" != "mjx-diffphysics" ] || [ "$has_progress" = "true" ]; }; then
    continue
  fi

  reason="active attempt has no required artifacts after ${age}s"
  if [ "$rig" = "mjx-diffphysics" ] && [ "$has_progress" != "true" ]; then
    reason="active MJX attempt has no progress.jsonl heartbeat after ${age}s"
  fi

  gc bd update "$bead" \
    --set-metadata "gc.watchdog.empty_attempt_last_at=$TS" \
    --set-metadata "gc.watchdog.empty_attempt_reason=$reason" \
    --append-notes "Watchdog: $reason. Produce progress/artifacts or close this attempt as blocked; do not launch duplicate work." \
    >/dev/null 2>&1 || true

  gc sling "$target" "$bead" --nudge --no-convoy --force >/dev/null 2>&1 || true
  echo "$TS  empty-attempt-watchdog  nudged  $bead  rig=$rig  target=$target  age=${age}s  reason=$reason  dir=$attempt_dir" >> "$LOG"
done

exit 0
