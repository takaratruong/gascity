#!/usr/bin/env bash
set -euo pipefail

CITY_DIR="/home/ubuntu/bright-lights"
LOG="$CITY_DIR/curator.log"
TS="$(date -Iseconds)"
STALE_SECONDS="${MAYOR_PROGRESS_STALE_SECONDS:-600}"
COOLDOWN_SECONDS="${MAYOR_PROGRESS_COOLDOWN_SECONDS:-600}"

cd "$CITY_DIR"

LOCK="$CITY_DIR/.gc/mayor-progress-watchdog.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  mayor-progress-watchdog  skipped-overlap" >> "$LOG"
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
all_json="$(timeout 15s gc bd list --status open --limit "${MAYOR_PROGRESS_SCAN_LIMIT:-500}" --sort updated --reverse --json 2>/dev/null || printf '[]')"

# Clean obsolete watchdog directives before creating new ones. These are
# controller bookkeeping, not research work; leaving them open buries fresh
# operator mail and makes the mayor spend context on already-closed roots.
printf '%s\n' "$all_json" | jq -r '
  .[]
  | select(.status == "open")
  | select(((.labels // []) | index("kind:directive")) != null)
  | select(((.labels // []) | index("source:watchdog")) != null)
  | select(((.labels // []) | index("status:active")) != null)
  | [
      .id,
      (.metadata["gc.watchdog.root"] // "")
    ] | @tsv
' | while IFS=$'\t' read -r directive root; do
  [ -n "$directive" ] || continue
  [ -n "$root" ] || continue
  root_json="$(gc bd show "$root" --json 2>/dev/null || printf '[]')"
  root_status="$(printf '%s\n' "$root_json" | jq -r '.[0].status // empty' 2>/dev/null || true)"
  root_state="$(printf '%s\n' "$root_json" | jq -r '.[0].metadata["convergence.state"] // empty' 2>/dev/null || true)"
  if [ "$root_status" != "open" ] || [ "$root_state" = "terminated" ]; then
    gc bd update "$directive" \
      --remove-label status:active \
      --add-label status:answered \
      --set-metadata "gc.directive_status=answered" \
      --set-metadata "gc.watchdog.auto_answered_at=$TS" \
      --append-notes "Auto-answered: watched root $root is ${root_status:-unknown}/${root_state:-unknown}." \
      >/dev/null 2>&1 || true
    gc bd close "$directive" --reason "auto-answered obsolete watchdog directive" >/dev/null 2>&1 || true
    echo "$TS  mayor-progress-watchdog  auto-answered-obsolete  $directive  root=$root  root_state=${root_status:-unknown}/${root_state:-unknown}" >> "$LOG"
  fi
done

printf '%s\n' "$all_json" | jq -r '
  .[]
  | select(.status == "open")
  | select(.metadata["convergence.state"] == "active" or .metadata["convergence.target"] != null)
  | select(.metadata["convergence.state"] != "terminated")
  | select(((.labels // []) | index("status:accepted")) == null)
  | select(((.labels // []) | index("status:dead-end")) == null)
  | select(((.labels // []) | index("status:operator-stopped")) == null)
  | select(((.labels // []) | index("status:operator-rejected")) == null)
  | [
      .id,
      (.title // ""),
      (.metadata["gc.rig"] // .metadata["var.rig"] // ""),
      (.metadata["gc.rig_mayor"] // ""),
      (.metadata["gc.watchdog.mayor_last_at"] // ""),
      (.metadata["convergence.active_wisp"] // ""),
      (.metadata["convergence.target"] // ""),
      (.updated_at // .created_at // "")
    ] | @tsv
' | while IFS=$'\t' read -r root title rig mayor last_at active_wisp target root_updated; do
  [ -n "$root" ] || continue
  [ -n "$rig" ] || continue
  mayor="${mayor:-$(mayor_for_rig "$rig")}"

  root_ts="$(parse_epoch "$root_updated")"
  last_child_row="$(printf '%s\n' "$all_json" | jq -r --arg root "$root" '
    [
      .[]
      | select((.id // "") | startswith($root + "."))
      | {
          id,
          status,
          title: (.title // ""),
          updated: (.updated_at // .created_at // "1970-01-01T00:00:00Z"),
          routed_to: (.metadata["gc.routed_to"] // ""),
          parent_run: (.metadata["gc.parent_run"] // "")
        }
    ]
    | sort_by(.updated)
    | last // {}
    | [.id // "", .status // "", .title // "", .updated // "", .routed_to // ""] | @tsv
  ')"
  IFS=$'\t' read -r child_id child_status child_title child_updated child_routed_to <<< "$last_child_row"
  child_ts="$(parse_epoch "$child_updated")"
  latest_ts="$root_ts"
  if [ "${child_ts:-0}" -gt "$latest_ts" ]; then latest_ts="$child_ts"; fi
  age=$((now_epoch - latest_ts))
  if [ "$age" -lt "$STALE_SECONDS" ]; then
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
Mayor progress watchdog for active run $root ($rig).

The run has no bead update newer than ${age}s. Operator should not need to inspect worker panes.

Root: $root
Title: $title
Active wisp: ${active_wisp:-unknown}
Target: ${target:-unknown}
Latest child: ${child_id:-none} ${child_status:+($child_status)} ${child_title}
Latest child route: ${child_routed_to:-unknown}

Action required:
1. Classify this run as actively progressing, stalled, failed, or complete.
2. If complete, report metrics/artifacts and ensure beads close.
3. If still running, report the next expected artifact and when to check again.
4. If stalled, nudge or re-route the existing bead once using Gas City primitives. Do not launch new experiments.
5. Reply to human concisely, then mark this directive answered.
EOF
)"

  meta="$(jq -n \
    --arg rig "$rig" \
    --arg mayor "$mayor" \
    --arg root "$root" \
    --arg child "$child_id" \
    --arg source "mayor_progress_watchdog" \
    '{"gc.kind":"operator_directive","gc.directive_to":$mayor,"gc.directive_status":"active","gc.source":$source,"gc.rig":$rig,"gc.watchdog.root":$root,"gc.watchdog.latest_child":$child}')"
  directive="$(gc bd create "watchdog: $rig progress check $root" \
    --type decision \
    --priority 2 \
    --description "$body" \
    --labels "kind:directive,source:watchdog,status:active,rig:$rig" \
    --metadata "$meta" \
    --json 2>/dev/null | jq -r '.id // empty' || true)"

  gc --rig "$rig" mail send "$mayor" \
    --from "mayor-progress-watchdog" \
    --subject "watchdog: progress check $root" \
    --message "$body" \
    --notify >/dev/null 2>&1 || true

  gc bd update "$root" \
    --set-metadata "gc.watchdog.mayor_last_at=$TS" \
    --set-metadata "gc.watchdog.mayor_last_directive=$directive" >/dev/null 2>&1 || true

  echo "$TS  mayor-progress-watchdog  requested  $root  rig=$rig  mayor=$mayor  age=${age}s  child=${child_id:-none}  directive=${directive:-none}" >> "$LOG"
done

exit 0
