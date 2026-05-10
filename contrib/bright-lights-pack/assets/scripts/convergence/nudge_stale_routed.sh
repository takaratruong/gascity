#!/usr/bin/env bash
set -euo pipefail

CITY_DIR="/home/ubuntu/bright-lights"
STALE_SECONDS="${STALE_SECONDS:-90}"
cd "$CITY_DIR"

now_epoch="$(date -u +%s)"

targets=(
  "park-manip/workers.coordinator"
  "park-manip/workers.implementer"
  "park-manip/workers.reviewer"
  "mjx-diffphysics/workers.coordinator"
  "mjx-diffphysics/workers.implementer"
  "mjx-diffphysics/workers.reviewer"
  "robotics-bench/workers.coordinator"
  "robotics-bench/workers.implementer"
  "robotics-bench/workers.reviewer"
)

should_nudge_bead() {
  local bead="$1"
  local root="${bead%%.*}"
  local bead_json root_json root_status conv_state active_session live_refs routed_to attempt_dir attempt_writer

  bead_json="$(gc bd show "$bead" --json 2>/dev/null || printf '[]')"
  routed_to="$(printf '%s\n' "$bead_json" | jq -r '.[0].metadata["gc.routed_to"] // empty')"
  attempt_dir="$(printf '%s\n' "$bead_json" | jq -r '.[0].metadata["gc.attempt_run_dir"] // empty')"
  if [[ "$routed_to" == */workers.implementer ]] && [ -n "$attempt_dir" ]; then
    if [ -f "$attempt_dir/.gc_attempt_finished" ] || [ -f "$attempt_dir/.gc_attempt_failed" ]; then
      echo "nudge terminal implementer bead $bead: attempt marker exists at $attempt_dir"
      return 0
    fi
    if [ -f "$attempt_dir/.gc_attempt_started" ]; then
      attempt_writer="$(ps -eo pid=,args= 2>/dev/null | awk -v dir="$attempt_dir" '
        index($0, dir) && $0 !~ /ps -eo/ && $0 !~ /awk -v dir/ {
          print $1
          exit
        }
      ')"
      if [ -z "$attempt_writer" ]; then
        {
          date -Is
          echo "exit_code=orphaned"
          echo "reason=attempt started but no writer process and no terminal marker"
        } > "$attempt_dir/.gc_attempt_failed"
        {
          printf 'finished_at=%s\n' "$(date -Is)"
          printf 'exit_code=orphaned\n'
          printf 'reason=attempt started but no writer process and no terminal marker\n'
        } >> "$attempt_dir/run.log"
        echo "marked orphaned implementer attempt failed for $bead at $attempt_dir"
        return 0
      fi
      echo "skip implementer bead $bead: attempt writer still running (pid $attempt_writer)"
      return 1
    fi
  fi

  active_session="$(printf '%s\n' "$bead_json" | jq -r '.[0].metadata["gc.active_session"] // empty')"
  if [ -n "$active_session" ]; then
    live_refs="$(gc session list --json 2>/dev/null | jq -r '.[] | select(.State == "active" or .State == "creating") | .ID, .Alias, .AgentName, .SessionName')"
    if printf '%s\n' "$live_refs" | grep -Fxq "$active_session"; then
      echo "skip stale routed bead $bead: live active session recorded ($active_session)"
      return 1
    fi
    echo "recover stale routed bead $bead: clearing dead active session ($active_session)"
    gc bd update "$bead" --unset-metadata gc.active_session --unset-metadata gc.claimed_by >/dev/null || true
  fi

  root_json="$(gc bd show "$root" --json 2>/dev/null || printf '[]')"
  root_status="$(printf '%s\n' "$root_json" | jq -r '.[0].status // empty')"
  conv_state="$(printf '%s\n' "$root_json" | jq -r '.[0].metadata["convergence.state"] // empty')"

  # Non-convergence routed tasks are still eligible. Convergence descendants are
  # eligible only while their root convergence is open + active; otherwise a
  # stopped/terminated root can leak old open child steps back into worker pools.
  if [ -n "$conv_state" ] && { [ "$root_status" != "open" ] || [ "$conv_state" != "active" ]; }; then
    echo "skip stale routed bead $bead: convergence root $root is ${root_status:-unknown}/${conv_state:-unknown}"
    return 1
  fi
  return 0
}

for target in "${targets[@]}"; do
  ready_json="$(gc bd ready \
    --metadata-field "gc.routed_to=$target" \
    --unassigned \
    --include-ephemeral \
    --limit 0 \
    --json 2>/dev/null || printf '[]')"

  while IFS= read -r bead; do
    [ -n "$bead" ] || continue
    should_nudge_bead "$bead" || continue
    echo "nudge stale routed bead $bead -> $target"
    gc sling "$target" "$bead" --nudge --no-convoy --force >/dev/null || true
  done < <(printf '%s\n' "$ready_json" | jq -r --argjson now "$now_epoch" --argjson stale "$STALE_SECONDS" '
    .[]
    | select(.issue_type == "task")
    | . as $b
    | (($b.updated_at // $b.created_at // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) as $ts
    | select($ts == 0 or (($now - $ts) >= $stale))
    | .id
  ')

  in_progress_json="$(gc bd list \
    --status in_progress \
    --metadata-field "gc.routed_to=$target" \
    --limit 0 \
    --json 2>/dev/null || printf '[]')"

  live_sessions="$(gc session list --json 2>/dev/null | jq -r '.[] | select(.State == "active" or .State == "creating") | .ID, .Alias, .AgentName, .SessionName')"

  while IFS=$'\t' read -r bead assignee; do
    [ -n "$bead" ] || continue
    should_nudge_bead "$bead" || continue
    if [ -n "$assignee" ] && printf '%s\n' "$live_sessions" | grep -Fxq "$assignee"; then
      continue
    fi
    echo "recover stale assigned bead $bead (assignee=${assignee:-none}) -> $target"
    gc bd update "$bead" --assignee "" --status open >/dev/null || true
    gc sling "$target" "$bead" --nudge --no-convoy --force >/dev/null || true
  done < <(printf '%s\n' "$in_progress_json" | jq -r --argjson now "$now_epoch" --argjson stale "$STALE_SECONDS" '
    .[]
    | select(.issue_type == "task")
    | . as $b
    | (($b.updated_at // $b.created_at // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) as $ts
    | select($ts == 0 or (($now - $ts) >= $stale))
    | [.id, (.assignee // "")] | @tsv
  ')
done

nudge_coordinators_with_terminal_attempts() {
  local target coord root active_session last_nudged impl attempt_dir msg

  for target in \
    "park-manip/workers.coordinator" \
    "mjx-diffphysics/workers.coordinator" \
    "robotics-bench/workers.coordinator"; do
    gc bd list \
      --status in_progress \
      --metadata-field "gc.routed_to=$target" \
      --limit 0 \
      --json 2>/dev/null | jq -r '.[] | [.id, (.metadata["gc.active_session"] // ""), (.metadata["gc.last_terminal_attempt_nudge"] // "")] | @tsv' | \
      while IFS=$'\t' read -r coord active_session last_nudged; do
        [ -n "$coord" ] || continue
        root="${coord%%.*}"
        impl="$(
          gc bd list --status closed --metadata-field "gc.parent_run=$root" --json 2>/dev/null | \
            jq -r '
              .[]
              | select((.metadata["gc.routed_to"] // "") | endswith("/workers.implementer"))
              | select((.metadata["gc.attempt_run_dir"] // "") != "")
              | [.id, .metadata["gc.attempt_run_dir"]] | @tsv
            ' | while IFS=$'\t' read -r candidate dir; do
              [ -n "$candidate" ] || continue
              if [ -f "$dir/.gc_attempt_finished" ] || [ -f "$dir/.gc_attempt_failed" ]; then
                printf '%s\t%s\n' "$candidate" "$dir"
                break
              fi
            done
        )"
        [ -n "$impl" ] || continue
        attempt_dir="${impl#*$'\t'}"
        impl="${impl%%$'\t'*}"
        [ "$last_nudged" != "$impl" ] || continue

        msg="Closed implementer attempt $impl has terminal marker in $attempt_dir. Validate/promote this attempt, route review, and close only your coordinator step when done. Do not sleep; continue the evaluate-idea loop now."
        gc bd update "$coord" \
          --set-metadata "gc.last_terminal_attempt_nudge=$impl" \
          --append-notes "Maintenance nudge: terminal implementer attempt $impl is ready for coordinator validation." >/dev/null 2>&1 || true
        if [ -n "$active_session" ]; then
          echo "nudge coordinator $coord session $active_session: terminal implementer attempt $impl"
          gc session nudge "$active_session" --delivery queue "$msg" >/dev/null 2>&1 || true
        else
          echo "sling coordinator $coord -> $target: terminal implementer attempt $impl"
          gc sling "$target" "$coord" --nudge --no-convoy --force >/dev/null 2>&1 || true
        fi
      done
  done
}

nudge_coordinators_with_terminal_attempts
