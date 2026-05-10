#!/usr/bin/env bash
set -euo pipefail

CITY_DIR="/home/ubuntu/bright-lights"
LOG="$CITY_DIR/curator.log"
TS="$(date -Iseconds)"
GRACE_SECONDS="${MAYOR_ACTION_GRACE_SECONDS:-240}"
COOLDOWN_SECONDS="${MAYOR_ACTION_COOLDOWN_SECONDS:-300}"

cd "$CITY_DIR"

LOCK="$CITY_DIR/.gc/mayor-action-watchdog.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  mayor-action-watchdog  skipped-overlap" >> "$LOG"
  exit 0
fi

mayor_for_rig() {
  case "$1" in
    mjx-diffphysics) printf '%s\n' "mjx-mayor" ;;
    park-manip) printf '%s\n' "park-mayor" ;;
    robotics-bench) printf '%s\n' "robotics-mayor" ;;
    *) printf '%s\n' "$1-mayor" ;;
  esac
}

parse_epoch() {
  local raw="${1:-1970-01-01T00:00:00Z}"
  raw="$(printf '%s\n' "$raw" | sed -E 's/\.[0-9]+Z$/Z/')"
  date -u -d "$raw" +%s 2>/dev/null || printf '0'
}

now_epoch="$(date -u +%s)"
directives_json="$(timeout 15s gc bd list \
  --label kind:directive \
  --label source:operator \
  --label status:active \
  --status open \
  --sort updated \
  --reverse \
  --limit "${MAYOR_ACTION_SCAN_LIMIT:-200}" \
  --json 2>/dev/null || printf '[]')"

active_roots_json="$(timeout 15s gc bd list \
  --has-metadata-key convergence.state \
  --status open \
  --sort updated \
  --reverse \
  --limit "${MAYOR_ACTION_ROOT_SCAN_LIMIT:-300}" \
  --json 2>/dev/null || printf '[]')"

printf '%s\n' "$directives_json" | jq -r '
  .[]
  | [
      .id,
      (.title // ""),
      (.metadata["gc.rig"] // ""),
      (.metadata["gc.directive_to"] // ""),
      (.metadata["gc.directive_action"] // ""),
      (.metadata["gc.linked_work"] // .metadata["gc.linked_convergence"] // ""),
      (.metadata["gc.action_watchdog_last_at"] // ""),
      (.updated_at // .created_at // "")
    ] | @tsv
' | while IFS=$'\t' read -r directive title rig mayor action linked last_at updated_at; do
  [ -n "$directive" ] || continue
  [ -n "$rig" ] || continue
  mayor="${mayor:-$(mayor_for_rig "$rig")}"

  # If the mayor already classified the directive but left active labels behind,
  # clean the lifecycle metadata so the dashboard and hooks do not keep replaying it.
  if [ -n "$action" ]; then
    if [ -n "$linked" ]; then
      gc bd update "$directive" \
        --set-metadata "gc.directive_status=answered" \
        --set-metadata "gc.directive_resolution=classified $action linked $linked" \
        --remove-label status:active \
        --add-label status:answered >/dev/null 2>&1 || true
      echo "$TS  mayor-action-watchdog  normalized-classified  $directive  action=$action  linked=$linked" >> "$LOG"
    fi
    continue
  fi

  updated_epoch="$(parse_epoch "$updated_at")"
  age=$((now_epoch - updated_epoch))
  if [ "$age" -lt "$GRACE_SECONDS" ]; then
    continue
  fi

  linked_root="$(printf '%s\n' "$active_roots_json" | jq -r --arg directive "$directive" '
    [
      .[]
      | select((.metadata["gc.source_directive"] // "") == $directive)
      | .id
    ][0] // empty
  ')"
  if [ -n "$linked_root" ]; then
    gc bd update "$directive" \
      --set-metadata "gc.directive_status=answered" \
      --set-metadata "gc.directive_action=new_convergence" \
      --set-metadata "gc.linked_convergence=$linked_root" \
      --set-metadata "gc.linked_work=$linked_root" \
      --set-metadata "gc.directive_resolution=linked existing convergence $linked_root" \
      --remove-label status:active \
      --add-label status:answered >/dev/null 2>&1 || true
    echo "$TS  mayor-action-watchdog  repaired-link  $directive  root=$linked_root" >> "$LOG"
    continue
  fi

  last_epoch=0
  if [ -n "$last_at" ]; then
    last_epoch="$(parse_epoch "$last_at")"
  fi
  if [ "$last_epoch" -gt 0 ] && [ $((now_epoch - last_epoch)) -lt "$COOLDOWN_SECONDS" ]; then
    continue
  fi

  body="$(cat <<EOF
Mayor action watchdog for operator directive $directive ($rig).

This directive is still active after ${age}s and has no gc.directive_action,
gc.linked_work, or linked convergence. The operator should not need to ask
whether chat produced work.

Directive: $directive
Title: $title

Required response:
1. Classify the directive as chat, clarification, new_convergence,
   continue_convergence, policy, or blocked.
2. If it should launch research, use create_evaluate_idea.sh with
   --source-directive-id "$directive".
3. If it steers existing work, set gc.linked_work to the relevant bead id.
4. Mark the directive answered or blocked with gc.directive_resolution.
EOF
)"

  gc --rig "$rig" mail send "$mayor" \
    --from "mayor-action-watchdog" \
    --subject "action required: classify directive $directive" \
    --message "$body" \
    --notify >/dev/null 2>&1 || true

  gc bd update "$directive" \
    --set-metadata "gc.action_watchdog_last_at=$TS" \
    --append-notes "Mayor action watchdog notified $mayor at $TS: no directive action or linked work after ${age}s." \
    >/dev/null 2>&1 || true

  echo "$TS  mayor-action-watchdog  requested  $directive  rig=$rig  mayor=$mayor  age=${age}s" >> "$LOG"
done

exit 0
