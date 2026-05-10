#!/usr/bin/env bash
# Repair proposal beads left in status:dispatching after a failed dispatch path.

set -u
cd "$HOME/bright-lights" || exit 0

LOG="$HOME/bright-lights/curator.log"
TS=$(date -Iseconds)
source "$HOME/bright-lights/assets/scripts/curator/control_state.sh"
source "$HOME/bright-lights/assets/scripts/curator/events.sh"

LOCK="$HOME/bright-lights/.gc/curator-repair-dispatching.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  repair-dispatching  skipped-overlap" >> "$LOG"
  exit 0
fi

curator_hard_pause_active && exit 0

close_completed_decide_roots() {
  timeout 15s gc bd list --status open --has-metadata-key gc.routed_to --limit 300 --json 2>/dev/null | \
    jq -r '
      .[]
      | select((.metadata["gc.routed_to"] // "") == "curator-decider")
      | select((.title // "") == "curator-decide")
      | .id
    ' | while read -r root; do
      [ -n "$root" ] || continue
      step="$root.1"
      step_status="$(gc bd show "$step" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null || true)"
      if [ "$step_status" = "closed" ]; then
        if gc bd close "$root" --reason "auto-closed curator-decide root after step closed" >/dev/null 2>&1; then
          echo "$TS  repair-dispatching  closed-decide-root  $root  step=$step" >> "$LOG"
        fi
      fi
    done
}

repair_stale_dispatching() {
  local rig_flag="$1"
  local now
  now=$(date +%s)
  timeout 15s gc bd list $rig_flag --label kind:proposal --status open --sort updated --reverse --limit "${CURATOR_PROPOSAL_SCAN_LIMIT:-200}" --json 2>/dev/null | \
    jq -r --argjson now "$now" '.[] | select(
      ((.labels // []) | index("status:dispatching")) != null and
      ((.labels // []) | index("status:promoted")) == null and
      ((.labels // []) | index("status:skipped-dedup")) == null and
      ((.labels // []) | index("status:skipped-duplicate")) == null
    ) | select(
	      ($now - ((.metadata["gc.dispatch_started_at"] // .updated_at // .created_at // "1970-01-01T00:00:00Z")
	        | sub("\\.[0-9]+Z$"; "Z")
	        | fromdateiso8601)) > 1200
    ) | .id' | while read -r stale_id; do
	      [ -z "$stale_id" ] && continue
	      open_decide="$(timeout 12s gc bd list --status open --has-metadata-key gc.routed_to --limit 200 --json 2>/dev/null | jq -r --arg proposal "$stale_id" '
	        .[]
	        | select((.metadata["gc.routed_to"] // "") == "curator-decider")
	        | select((.title // "" | contains($proposal)) or (.description // "" | contains($proposal)))
	        | .id
	      ' | head -1)"
	      if [ -n "$open_decide" ]; then
	        echo "$TS  repair-dispatching  skipped-open-decide  $stale_id  decide=$open_decide" >> "$LOG"
	        continue
	      fi
	      stale_rig="$(gc bd show "$stale_id" --json 2>/dev/null | jq -r '.[0].metadata["gc.rig"] // "park-manip"')"
      active_rig_run="$(timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${CURATOR_ACTIVE_SCAN_LIMIT:-200}" --json 2>/dev/null | jq -r \
        --arg rig "$stale_rig" '
        .[]
        | select(.metadata["convergence.state"] == "active" or .metadata["convergence.state"] == "creating")
        | select((.metadata["gc.rig"] // .metadata["var.rig"] // "") == $rig)
        | .id
      ' | head -1)"
      if [ -n "$active_rig_run" ]; then
        echo "$TS  repair-dispatching  skipped-active-rig  $stale_id  $stale_rig  active=$active_rig_run" >> "$LOG"
        curator_event "repair-skipped-active-rig" "$stale_id" "left dispatching alone because rig $stale_rig has active convergence $active_rig_run"
        continue
      fi
      if gc bd update "$stale_id" --remove-label status:dispatching --add-label status:pending >/dev/null 2>&1; then
        echo "$TS  repair-dispatching  repaired  $stale_id" >> "$LOG"
        curator_event "repaired-stale-dispatching" "$stale_id" "repaired stale dispatching claim on $stale_id"
      fi
    done
}

close_completed_decide_roots
repair_stale_dispatching ""
for rig in $(awk -F'"' '/^\[\[rig\]\]/{f=1} f && /^name = /{print $2; f=0}' "$HOME/bright-lights/.gc/site.toml" 2>/dev/null); do
  repair_stale_dispatching "--rig $rig"
done

exit 0
