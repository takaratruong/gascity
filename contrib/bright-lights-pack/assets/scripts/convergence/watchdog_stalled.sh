#!/usr/bin/env bash
# Mark active convergence roots that have had no recent bead updates.

set -u
cd "$HOME/bright-lights" || exit 0

LOG="$HOME/bright-lights/curator.log"
TS=$(date -Iseconds)
THRESHOLD_SECONDS="${STALLED_AFTER_SECONDS:-7200}"

source "$HOME/bright-lights/assets/scripts/curator/events.sh"

LOCK="$HOME/bright-lights/.gc/convergence-watchdog-stalled.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  convergence-watchdog  skipped-overlap" >> "$LOG"
  exit 0
fi

now=$(date +%s)
gc bd list --status open --has-metadata-key convergence.target --json 2>/dev/null | \
  jq -r --argjson now "$now" --argjson threshold "$THRESHOLD_SECONDS" '.[] | select(
    ((.labels // []) | index("status:stalled")) == null
  ) | select(
    ($now - ((.updated_at // .created_at // "1970-01-01T00:00:00Z")
      | sub("\\.[0-9]+Z$"; "Z")
      | fromdateiso8601)) > $threshold
  ) | [
    .id,
    (.title // ""),
    (.metadata["var.rig"] // .metadata["gc.rig"] // ""),
    (.metadata["convergence.active_wisp"] // ""),
    (.metadata["convergence.target"] // ""),
    (.updated_at // .created_at // "")
  ] | @tsv' | while IFS=$'\t' read -r id title rig active_wisp target updated_at; do
    [ -z "$id" ] && continue
    meta=$(jq -n \
      --arg at "$TS" \
      --arg threshold "$THRESHOLD_SECONDS" \
      --arg wisp "$active_wisp" \
      --arg target "$target" \
      '{"gc.watchdog.last_stalled_at":$at,"gc.watchdog.stalled_after_seconds":$threshold,"gc.watchdog.active_wisp":$wisp,"gc.watchdog.target":$target}')
    gc bd update "$id" --add-label status:stalled --metadata "$meta" >/dev/null 2>&1 || true
    echo "$TS  convergence-watchdog  stalled  $id  rig=$rig  target=$target  updated_at=$updated_at  title=$title" >> "$LOG"
    curator_event "convergence-stalled" "$id" "convergence $id appears stalled; target=$target active_wisp=$active_wisp"
  done

exit 0
