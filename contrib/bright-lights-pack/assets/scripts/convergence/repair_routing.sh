#!/usr/bin/env bash
# Repair active evaluate-idea convergences created before rig-scoped workers.

set -u
cd "$HOME/bright-lights" || exit 0

LOG="$HOME/bright-lights/curator.log"
TS=$(date -Iseconds)
LOCK="$HOME/bright-lights/.gc/convergence-repair-routing.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  convergence-repair-routing  skipped-overlap" >> "$LOG"
  exit 0
fi

target_for_rig() {
  case "$1" in
    park-manip) printf '%s\n' "park-manip/workers.coordinator" ;;
    mjx-diffphysics) printf '%s\n' "mjx-diffphysics/workers.coordinator" ;;
    robotics-bench) printf '%s\n' "robotics-bench/workers.coordinator" ;;
    *) return 1 ;;
  esac
}

is_legacy_target() {
  case "$1" in
    mayor|park-mayor|mjx-mayor|park-coordinator|mjx-coordinator) return 0 ;;
    *) return 1 ;;
  esac
}

repair_root() {
  local id="$1" rig="$2" active_wisp="$3" current_target="$4"
  local target route_meta step step_json step_status step_target active_session
  target="$(target_for_rig "$rig")" || return 0

  if is_legacy_target "$current_target"; then
    gc bd update "$id" --set-metadata "convergence.target=$target" >/dev/null 2>&1 || true
    echo "$TS  convergence-repair-routing  root-target  $id  $current_target -> $target" >> "$LOG"
  fi

  [ -z "$active_wisp" ] && return 0
  step="$active_wisp.1"
  step_json="$(gc bd show "$step" --json 2>/dev/null | jq 'if type=="array" then .[0] else . end' 2>/dev/null || true)"
  step_status="$(printf '%s\n' "$step_json" | jq -r '.status // empty' 2>/dev/null || true)"
  if [ "$step_status" = "closed" ]; then
    echo "$TS  convergence-repair-routing  skip-closed-step  $id  $step" >> "$LOG"
    return 0
  fi
  step_target="$(printf '%s\n' "$step_json" | jq -r '.metadata["gc.routed_to"] // empty' 2>/dev/null || true)"
  active_session="$(printf '%s\n' "$step_json" | jq -r '.metadata["gc.active_session"] // empty' 2>/dev/null || true)"

  if [ "$current_target" = "$target" ] && [ "$step_target" = "$target" ]; then
    return 0
  fi

  route_meta="$(jq -n --arg target "$target" '{"gc.routed_to":$target}')"

  gc bd update "$active_wisp" --metadata "$route_meta" >/dev/null 2>&1 || true
  if [ -n "$active_session" ] || [ "$step_status" = "in_progress" ]; then
    gc bd update "$step" \
      --metadata "$route_meta" \
      --parent "$active_wisp" >/dev/null 2>&1 || true
    echo "$TS  convergence-repair-routing  retarget-live-step  $id  $step -> $target" >> "$LOG"
    return 0
  fi

  gc bd update "$step" \
    --metadata "$route_meta" \
    --parent "$active_wisp" \
    --assignee "" \
    --status open \
    --unset-metadata gc.claimed_by >/dev/null 2>&1 || true
  gc sling "$target" "$step" --nudge --no-convoy --force >/dev/null 2>&1 || true
  echo "$TS  convergence-repair-routing  routed-active-wisp  $id  $active_wisp -> $target" >> "$LOG"
}

gc bd list --status open --has-metadata-key convergence.target --sort updated --reverse --limit "${CONVERGENCE_REPAIR_ROUTING_SCAN_LIMIT:-1000}" --json 2>/dev/null | \
  jq -r '.[] | [
    .id,
    (.metadata["var.rig"] // .metadata["gc.rig"] // ""),
    (.metadata["convergence.active_wisp"] // ""),
    (.metadata["convergence.target"] // "")
  ] | @tsv' | while IFS=$'\t' read -r id rig active_wisp target; do
    [ -z "$id" ] && continue
    [ -z "$rig" ] && continue
    repair_root "$id" "$rig" "$active_wisp" "$target"
  done

exit 0
