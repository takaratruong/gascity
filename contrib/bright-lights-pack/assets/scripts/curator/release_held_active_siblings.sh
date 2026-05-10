#!/usr/bin/env bash
# Re-open proposals held only because another convergence was active.
#
# curator-decide stamps the active convergence that caused the hold. Once that
# convergence is no longer open+active, the proposal returns to the normal
# pending pool so dispatch_proposals.sh can route it through curator-decide
# again. This keeps the throttle one-at-a-time without turning holds into a dead
# end.

set -euo pipefail

cd "$HOME/bright-lights"

LOG="$HOME/bright-lights/curator.log"
TS="$(date -Iseconds)"

released=0

timeout 15s gc bd list --label kind:proposal --status open --sort updated --reverse --limit "${CURATOR_PROPOSAL_SCAN_LIMIT:-200}" --json 2>/dev/null | jq -r '
  .[]
  | select(
      (((.labels // []) | index("status:held-active-sibling")) != null)
      or (((.labels // []) | index("status:held-active-method-family")) != null)
      or (((.labels // []) | index("status:held-active-rig")) != null)
    )
  | [
      .id,
      (.metadata["gc.active_sibling"] // .metadata["gc.active_method_sibling"] // .metadata["gc.active_rig_run"] // ""),
      (if (((.labels // []) | index("status:held-active-rig")) != null) then "rig" elif (((.labels // []) | index("status:held-active-method-family")) != null) then "method-family" else "sibling" end)
    ] | @tsv
' | while IFS=$'\t' read -r proposal sibling hold_kind; do
  [ -n "$proposal" ] || continue

  if [ -z "$sibling" ]; then
    echo "$TS  release-held-active-${hold_kind:-sibling}  missing-sibling  $proposal" >> "$LOG"
    gc bd update "$proposal" \
      --remove-label status:held \
      --remove-label status:held-active-sibling \
      --remove-label status:held-active-method-family \
      --remove-label status:held-active-rig \
      --add-label status:pending \
      --set-metadata gc.decision=released-missing-active-sibling \
      --set-metadata gc.decision_reason="released because held proposal had no gc.active_sibling" \
      >/dev/null || true
    released=$((released + 1))
    continue
  fi

  sibling_json="$(gc bd show "$sibling" --json 2>/dev/null || printf '[]')"
  sibling_status="$(printf '%s\n' "$sibling_json" | jq -r '.[0].status // empty')"
  sibling_state="$(printf '%s\n' "$sibling_json" | jq -r '.[0].metadata["convergence.state"] // empty')"

  if [ "$sibling_status" = "open" ] && [ "$sibling_state" = "active" ]; then
    continue
  fi

  echo "$TS  release-held-active-${hold_kind:-sibling}  released  $proposal  sibling=$sibling sibling_state=${sibling_status:-unknown}/${sibling_state:-unknown}" >> "$LOG"
  gc bd update "$proposal" \
    --remove-label status:held \
    --remove-label status:held-active-sibling \
    --remove-label status:held-active-method-family \
    --remove-label status:held-active-rig \
    --add-label status:pending \
    --set-metadata gc.decision=released-active-sibling-closed \
    --set-metadata "gc.decision_reason=released because active sibling $sibling is ${sibling_status:-unknown}/${sibling_state:-unknown}" \
    >/dev/null || true
  released=$((released + 1))
done

# If anything was released, immediately run the normal proposal dispatcher.
# This is intentionally the same Gas City path used for newly-created proposals:
# proposal bead -> curator-decide formula -> create_evaluate_idea helper.
timeout 60s "$HOME/bright-lights/assets/scripts/curator/dispatch_proposals.sh" || true

exit 0
