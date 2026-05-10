#!/usr/bin/env bash
# Label convergence runs that have terminated since last tick.
# Deterministic: accepted vs dead-end based on terminal_reason.
# Safe to run every 30s — idempotent (only labels unlabeled runs).

set -u
cd "$HOME/bright-lights" || exit 0
source "$HOME/bright-lights/assets/scripts/curator/control_state.sh"
source "$HOME/bright-lights/assets/scripts/curator/events.sh"

# Hard pause: do nothing.
curator_hard_pause_active && exit 0

LOG="$HOME/bright-lights/curator.log"
TS=$(date -Iseconds)


# List every convergence root that has a terminal_reason metadata AND is not
# yet labeled status:accepted or status:dead-end. Terminated convergences
# are CLOSED, so we must use --all (bd list defaults to open-only).
labeled=0
timeout 15s gc bd list --all --has-metadata-key convergence.terminal_reason --sort updated --reverse --limit "${CURATOR_LABEL_RUNS_SCAN_LIMIT:-300}" --json 2>/dev/null | \
  jq -r '.[] | select(
    ((.labels // []) | index("status:accepted")) == null and
    ((.labels // []) | index("status:dead-end")) == null and
    ((.labels // []) | index("status:operator-stopped")) == null
  ) | "\(.id)\t\(.metadata["convergence.terminal_reason"] // "")"' | \
  while IFS=$'\t' read -r ID TERM; do
    [ -z "$ID" ] && continue
    case "$TERM" in
      approved|gate_passed)
        gc bd update "$ID" --add-label status:accepted >/dev/null 2>&1 && labeled=$((labeled+1))
        echo "$TS  label  $ID  status:accepted" >> "$LOG"
        curator_event "labeled-accepted" "$ID" "labeled $ID as accepted"
        ;;
      no_convergence)
        gc bd update "$ID" --add-label status:dead-end >/dev/null 2>&1 && labeled=$((labeled+1))
        echo "$TS  label  $ID  status:dead-end" >> "$LOG"
        curator_event "labeled-dead-end" "$ID" "labeled $ID as dead-end"
        ;;
      stopped)
        # Operator-stopped; don't dedup against these. Label so we skip next tick.
        gc bd update "$ID" --add-label status:operator-stopped >/dev/null 2>&1 && labeled=$((labeled+1))
        echo "$TS  label  $ID  status:operator-stopped" >> "$LOG"
        curator_event "labeled-operator-stopped" "$ID" "labeled $ID as operator-stopped"
        ;;
    esac
  done

exit 0
