#!/usr/bin/env bash
# Dispatch pending proposal beads. For each one, (idempotently) dispatch a
# per-proposal curator-decide formula wisp to curator-decider, which does the
# LLM-based dedup decision and promotes novel work to the owning rig coordinator.
# Stale dispatch repair lives in a separate cooldown order.

set -u
cd "$HOME/bright-lights" || exit 0

LOG="$HOME/bright-lights/curator.log"
TS=$(date -Iseconds)
source "$HOME/bright-lights/assets/scripts/curator/control_state.sh"
source "$HOME/bright-lights/assets/scripts/curator/events.sh"
LOCK="$HOME/bright-lights/.gc/curator-poll.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  proposal-dispatch  skipped-overlap" >> "$LOG"
  exit 0
fi

# Hard pause: do nothing.
if curator_hard_pause_active; then
  echo "$TS  proposal-dispatch  hard-paused  $(curator_pause_reason)" >> "$LOG"
  exit 0
fi

# Soft pause: skip slinging new work.
if curator_pause_active; then
  echo "$TS  proposal-dispatch  soft-paused  $(curator_pause_reason)" >> "$LOG"
  exit 0
fi

# No capacity gate on dedup dispatch. curator-decider is cheap (dedup +
# bead writes, no GPU), and gating here was a design error: it conflated
# "implementer pool busy" with "don't dedup more work." Dedup always,
# always — the research pool can queue.

# Pull pending proposals from city + every registered rig. kind:proposal,
# open, no status:held, no assignee. Proposals filed at city level get
# bl-* prefixes; proposals filed in rigs get <rig-prefix>-* IDs. Either
# works for curator-decide; we just need to see them.
collect_pending() {
  local rig_flag="$1"
  # `--unassigned` is not a bd flag; filter assignee in jq instead.
  timeout 15s gc bd list $rig_flag --label kind:proposal --status open --sort updated --reverse --limit "${CURATOR_PROPOSAL_SCAN_LIMIT:-200}" --json 2>/dev/null | \
    jq -r '.[] | select(
      ((.labels // []) | index("status:held")) == null and
      ((.labels // []) | index("status:dispatching")) == null and
      ((.labels // []) | index("status:promoted")) == null and
      ((.labels // []) | index("status:skipped-dedup")) == null and
      ((.labels // []) | index("status:skipped-duplicate")) == null and
      ((.labels // []) | index("status:operator-rejected")) == null and
      ((.labels // []) | index("status:promotion-failed")) == null and
      (.assignee == null or .assignee == "")
    ) | .id'
}

# City-level proposals (no --rig flag).
PENDING=$(collect_pending "")
# Rig-level proposals: enumerate rigs from site.toml.
for rig in $(awk -F'"' '/^\[\[rig\]\]/{f=1} f && /^name = /{print $2; f=0}' "$HOME/bright-lights/.gc/site.toml" 2>/dev/null); do
  PENDING+=$'\n'$(collect_pending "--rig $rig")
done
# Dedup + drop blanks.
PENDING=$(printf '%s\n' "$PENDING" | awk 'NF' | sort -u)

# Prioritize repair work before new science. A failed convergence often files a
# `gc.followup_kind=bugfix` proposal that unblocks the same method lane; if old
# pending science proposals are processed alphabetically first, the rig can keep
# chasing stale ideas while the reliability fix waits. Sort by:
#   1. bugfix for an IMPLEMENTATION_BUG parent first
#   2. other bugfixes
#   3. newest updated_at first
#   4. id for deterministic ties
if [ -n "$PENDING" ]; then
  PENDING=$(for id in $PENDING; do
    proposal_json="$(gc bd show "$id" --json 2>/dev/null | jq 'if type=="array" then .[0] else . end' 2>/dev/null || true)"
    [ -n "$proposal_json" ] || continue
    kind="$(printf '%s\n' "$proposal_json" | jq -r '.metadata["gc.followup_kind"] // ""' 2>/dev/null)"
    parent="$(printf '%s\n' "$proposal_json" | jq -r '.metadata["gc.parent_run"] // ""' 2>/dev/null)"
    updated="$(printf '%s\n' "$proposal_json" | jq -r '.updated_at // ""' 2>/dev/null)"
    score=2
    if [ "$kind" = "bugfix" ]; then
      score=1
      if [ -n "$parent" ]; then
        parent_result="$(gc bd show "$parent" --json 2>/dev/null | jq -r '(if type=="array" then .[0] else . end).metadata["gc.result_class"] // ""' 2>/dev/null)"
        [ "$parent_result" = "IMPLEMENTATION_BUG" ] && score=0
      fi
    fi
    printf '%s\t%s\t%s\n' "$score" "$updated" "$id"
  done | sort -t $'\t' -k1,1n -k2,2r -k3,3 | cut -f3)
fi

if [ -z "$PENDING" ]; then
  exit 0
fi

# For each pending proposal, dispatch a curator-decide formula wisp. The
# curator-decider reads the proposal, reads dead-ends + accepted lists,
# decides, and promotes to the owning rig's workers.coordinator or skips.
dispatched=0
max_dispatch="${CURATOR_MAX_DISPATCH_PER_TICK:-6}"
seen_parent_runs=""
seen_rigs=""
rig_create_lock_busy() {
  local rig="$1" lock="$HOME/bright-lights/.gc/converge-create-${rig}.lock"
  [ -n "$rig" ] || return 1
  mkdir -p "$(dirname "$lock")"
  (
    exec 9>"$lock"
    flock -n 9
  ) >/dev/null 2>&1
  case "$?" in
    0) return 1 ;;
    *) return 0 ;;
  esac
}

for PROPOSAL_ID in $PENDING; do
  if [ "$dispatched" -ge "$max_dispatch" ]; then
    echo "$TS  proposal-dispatch  capped-dispatch  max=$max_dispatch" >> "$LOG"
    break
  fi

  # If the owning rig is paused, do not dispatch a curator-decide wisp.
  # Dispatching while paused only creates repeated "Promotion paused" comments
  # on the same proposal every poll cycle.
  P_RIG=$(gc bd show "$PROPOSAL_ID" --json 2>/dev/null | jq -r '.[0].metadata["gc.rig"] // "park-manip"')
  P_PARENT=$(gc bd show "$PROPOSAL_ID" --json 2>/dev/null | jq -r '.[0].metadata["gc.parent_run"] // empty')
  if rig_create_lock_busy "$P_RIG"; then
    echo "$TS  proposal-dispatch  skipped-rig-create-lock  $PROPOSAL_ID  $P_RIG" >> "$LOG"
    curator_event "skipped-rig-create-lock" "$PROPOSAL_ID" "skipped proposal because rig $P_RIG is currently creating a convergence"
    continue
  fi
  ACTIVE_RIG_RUN=$(timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${CURATOR_ACTIVE_SCAN_LIMIT:-200}" --json 2>/dev/null | jq -r \
    --arg rig "$P_RIG" '
    .[]
    | select(.metadata["convergence.state"] == "active" or .metadata["convergence.state"] == "creating")
    | select((.metadata["gc.rig"] // .metadata["var.rig"] // "") == $rig)
    | .id
  ' | head -1)
  if [ -n "$ACTIVE_RIG_RUN" ]; then
    echo "$TS  proposal-dispatch  skipped-active-rig  $PROPOSAL_ID  $P_RIG  active=$ACTIVE_RIG_RUN" >> "$LOG"
    curator_event "skipped-active-rig" "$PROPOSAL_ID" "skipped proposal because rig $P_RIG already has active convergence $ACTIVE_RIG_RUN"
    continue
  fi
  if [ -n "$P_RIG" ] && printf '%s\n' "$seen_rigs" | grep -Fxq "$P_RIG"; then
    echo "$TS  proposal-dispatch  skipped-same-rig-this-tick  $PROPOSAL_ID  rig=$P_RIG" >> "$LOG"
    curator_event "skipped-same-rig-this-tick" "$PROPOSAL_ID" "skipped proposal this tick because another proposal for rig $P_RIG is already being decided"
    continue
  fi
  if [ -n "$P_PARENT" ] && printf '%s\n' "$seen_parent_runs" | grep -Fxq "$P_PARENT"; then
    echo "$TS  proposal-dispatch  skipped-same-parent-this-tick  $PROPOSAL_ID  parent=$P_PARENT" >> "$LOG"
    curator_event "skipped-same-parent-this-tick" "$PROPOSAL_ID" "skipped proposal this tick because another proposal for parent $P_PARENT is already being decided"
    continue
  fi
  if curator_pause_active "$P_RIG"; then
    echo "$TS  proposal-dispatch  skipped-paused-rig  $PROPOSAL_ID  $P_RIG  $(curator_pause_reason "$P_RIG")" >> "$LOG"
    curator_event "skipped-paused-rig" "$PROPOSAL_ID" "skipped proposal because rig $P_RIG is paused"
    continue
  fi

  # Claim-guard: add status:dispatching before slinging so a concurrent poll
  # skips this proposal. `bd update --add-label` isn't CAS but the filter at
  # the top of this script (which excludes status:dispatching) narrows the
  # race window to the time between this update and the next poll tick.
  # NOTE: `gc sling --formula --on <bead>` returns silent exit 1 in this
  # gascity version — do NOT use it as an atomicity primitive until upstream
  # fix. Upstream PR tracking: look at cmd_sling.go slingOnFormula().
  if ! gc bd update "$PROPOSAL_ID" \
    --remove-label status:pending \
    --add-label status:dispatching \
    --set-metadata "gc.dispatch_started_at=$TS" >/dev/null 2>&1; then
    continue
  fi

  # Route decides to the dedicated curator-decider pool, NOT a rig mayor.
  # Rig mayors run evaluate-idea convergences; routing decides to them
  # starves research runs behind dedup work. curator-decider is
  # short-lived, 6 slots, purpose-built for this.
  if timeout 45s gc sling curator-decider curator-decide --formula --var proposal_id="$PROPOSAL_ID" --nudge >/dev/null 2>&1; then
    echo "$TS  proposal-dispatch  dispatched-decide  $PROPOSAL_ID" >> "$LOG"
    curator_event "dispatched-decide" "$PROPOSAL_ID" "dispatched curator-decide for $PROPOSAL_ID"
    if [ -n "$P_PARENT" ]; then
      if [ -n "$seen_parent_runs" ]; then
        seen_parent_runs="${seen_parent_runs}
$P_PARENT"
      else
        seen_parent_runs="$P_PARENT"
      fi
    fi
    if [ -n "$P_RIG" ]; then
      if [ -n "$seen_rigs" ]; then
        seen_rigs="${seen_rigs}
$P_RIG"
      else
        seen_rigs="$P_RIG"
      fi
    fi
    dispatched=$((dispatched + 1))
  else
    echo "$TS  proposal-dispatch  sling-failed       $PROPOSAL_ID" >> "$LOG"
    curator_event "sling-failed" "$PROPOSAL_ID" "failed to sling curator-decide for $PROPOSAL_ID"
    gc bd update "$PROPOSAL_ID" --remove-label status:dispatching --add-label status:pending >/dev/null 2>&1 || true
    continue
  fi

done

echo "$TS  proposal-dispatch  dispatched=$dispatched" >> "$LOG"
exit 0
