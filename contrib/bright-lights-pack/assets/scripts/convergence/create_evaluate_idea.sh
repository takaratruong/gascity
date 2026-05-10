#!/usr/bin/env bash
# Create and route an evaluate-idea convergence.
#
# This centralizes the local workaround for current Gas City convergence
# behavior: `gc converge create` materializes the first wisp, but this city
# must still sling the first wisp and stamp routing metadata on the step bead.

set -euo pipefail

cd "$HOME/bright-lights"

TITLE=""
IDEA=""
IDEA_DESC=""
RIG=""
MAX_ITERATIONS="3"
PROPOSAL_ID=""
LINEAGE_ROOT=""
PARENT_RUN=""
LINEAGE_DEPTH="0"
THREAD_ID=""
THREAD_TITLE=""
FOLLOWUP_KIND="new-thread"
THREAD_REASON=""
METHOD_FAMILY=""
ALLOW_PARALLEL="false"
SOURCE_DIRECTIVE_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title) TITLE="${2:-}"; shift 2 ;;
    --idea) IDEA="${2:-}"; shift 2 ;;
    --idea-description) IDEA_DESC="${2:-}"; shift 2 ;;
    --rig) RIG="${2:-}"; shift 2 ;;
    --max-iterations) MAX_ITERATIONS="${2:-}"; shift 2 ;;
    --proposal-id) PROPOSAL_ID="${2:-}"; shift 2 ;;
    --lineage-root) LINEAGE_ROOT="${2:-}"; shift 2 ;;
    --parent-run) PARENT_RUN="${2:-}"; shift 2 ;;
    --lineage-depth) LINEAGE_DEPTH="${2:-}"; shift 2 ;;
    --thread-id) THREAD_ID="${2:-}"; shift 2 ;;
    --thread-title) THREAD_TITLE="${2:-}"; shift 2 ;;
    --followup-kind) FOLLOWUP_KIND="${2:-}"; shift 2 ;;
    --thread-reason) THREAD_REASON="${2:-}"; shift 2 ;;
    --method-family) METHOD_FAMILY="${2:-}"; shift 2 ;;
    --allow-parallel) ALLOW_PARALLEL="true"; shift ;;
    --source-directive-id) SOURCE_DIRECTIVE_ID="${2:-}"; shift 2 ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$TITLE" ] || [ -z "$IDEA_DESC" ] || [ -z "$RIG" ]; then
  echo "missing required --title, --idea-description, or --rig" >&2
  exit 2
fi
if [ -z "$IDEA" ]; then
  IDEA="$TITLE"
fi

if [ "$RIG" = "mjx-diffphysics" ]; then
  REQUEST_TEXT="$(printf '%s\n%s\n%s\n' "$TITLE" "$IDEA" "$IDEA_DESC")"
  if printf '%s\n' "$REQUEST_TEXT" | grep -Eiq 'ball|cartpole|pendulum'; then
    if ! printf '%s\n' "$REQUEST_TEXT" | grep -Eiq 'G1|humanoid|motion[ -]?tracking|simplified_g1'; then
      echo "refusing to launch off-priority mjx-diffphysics proxy run: current priority is G1/MJX motion tracking with first-order gradients" >&2
      exit 76
    fi
  fi
fi

if [ -n "$PROPOSAL_ID" ]; then
  PROPOSAL_JSON="$(gc bd show "$PROPOSAL_ID" --json 2>/dev/null || printf '[]')"
  [ -n "$LINEAGE_ROOT" ] || LINEAGE_ROOT="$(printf '%s\n' "$PROPOSAL_JSON" | jq -r '.[0].metadata["gc.lineage_root"] // empty')"
  [ -n "$PARENT_RUN" ] || PARENT_RUN="$(printf '%s\n' "$PROPOSAL_JSON" | jq -r '.[0].metadata["gc.parent_run"] // empty')"
  [ -n "$THREAD_ID" ] || THREAD_ID="$(printf '%s\n' "$PROPOSAL_JSON" | jq -r '.[0].metadata["gc.thread_id"] // empty')"
  [ -n "$THREAD_TITLE" ] || THREAD_TITLE="$(printf '%s\n' "$PROPOSAL_JSON" | jq -r '.[0].metadata["gc.thread_title"] // empty')"
  [ "$FOLLOWUP_KIND" != "new-thread" ] || FOLLOWUP_KIND="$(printf '%s\n' "$PROPOSAL_JSON" | jq -r '.[0].metadata["gc.followup_kind"] // "new-thread"')"
  [ -n "$METHOD_FAMILY" ] || METHOD_FAMILY="$(printf '%s\n' "$PROPOSAL_JSON" | jq -r '.[0].metadata["gc.method_family"] // .[0].metadata["gc.research_lane"] // empty')"
fi

if [ -n "$PARENT_RUN" ] && [ -z "$THREAD_ID" ]; then
  echo "refusing to launch followup without gc.thread_id; repair proposal metadata first" >&2
  exit 64
fi

if ! gc rig list --json 2>/dev/null | jq -e --arg rig "$RIG" '(.rigs[]?, .items[]?, .[]? | objects) | select(.name == $rig)' >/dev/null; then
  echo "unknown rig: $RIG" >&2
  exit 1
fi

RIG_COORDINATOR="$RIG/workers.coordinator"
case "$RIG" in
  mjx-diffphysics) RIG_MAYOR="mjx-mayor" ;;
  park-manip) RIG_MAYOR="park-mayor" ;;
  robotics-bench) RIG_MAYOR="robotics-mayor" ;;
  *) RIG_MAYOR="$RIG-mayor" ;;
esac

# Serialize creation per rig. Without this, multiple curator-decider wisps can
# all observe "no active run" and then create parallel convergences before any
# one root receives its gc.rig metadata.
PROMOTION_LOCK="$HOME/bright-lights/.gc/converge-create-${RIG}.lock"
exec 7>"$PROMOTION_LOCK"
if command -v flock >/dev/null && ! flock -w 120 7; then
  echo "refusing to launch: timed out waiting for $RIG convergence create lock" >&2
  exit 74
fi

if [ -n "$PROPOSAL_ID" ]; then
  PROPOSAL_DECIDED=$(gc bd show "$PROPOSAL_ID" --json 2>/dev/null | jq -r '
    (if type=="array" then .[0] else . end) as $b
    | if (($b.labels // []) | index("status:promoted")) != null or (($b.metadata["gc.promoted_to"] // "") != "") then "yes" else "" end
  ')
  if [ "$PROPOSAL_DECIDED" = "yes" ]; then
    echo "refusing to launch: proposal $PROPOSAL_ID is already promoted" >&2
    exit 79
  fi
fi

# Exact duplicate guard: parallel research is useful, duplicate roots with the
# same rig + title are not. Enforce this even when --allow-parallel is used.
ACTIVE_DUPLICATE=$(timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${GC_ACTIVE_CONVERGENCE_SCAN_LIMIT:-200}" --json 2>/dev/null | jq -r \
  --arg rig "$RIG" \
  --arg title "$TITLE" \
  --arg idea "$IDEA" \
  --arg proposal "$PROPOSAL_ID" '
  .[]
  | select(.metadata["convergence.state"] == "active")
  | select((.metadata["gc.rig"] // .metadata["var.rig"] // "") == $rig)
  | select((.title // "") == $title or (.metadata["var.idea"] // "") == $idea)
  | select($proposal == "" or (.metadata["gc.promoted_from_proposal"] // "") != $proposal)
  | .id
' | head -1)
if [ -n "$ACTIVE_DUPLICATE" ]; then
  echo "refusing to launch duplicate active $RIG convergence for title '$TITLE': $ACTIVE_DUPLICATE" >&2
  exit 77
fi

if [ -n "$METHOD_FAMILY" ]; then
  ACTIVE_METHOD_DUPLICATE=$(timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${GC_ACTIVE_CONVERGENCE_SCAN_LIMIT:-200}" --json 2>/dev/null | jq -r \
    --arg rig "$RIG" \
    --arg method "$METHOD_FAMILY" \
    --arg proposal "$PROPOSAL_ID" '
    .[]
    | select(.metadata["convergence.state"] == "active")
    | select((.metadata["gc.rig"] // .metadata["var.rig"] // "") == $rig)
    | select((.metadata["gc.method_family"] // .metadata["gc.research_lane"] // "") == $method)
    | select($proposal == "" or (.metadata["gc.promoted_from_proposal"] // "") != $proposal)
    | .id
  ' | head -1)
  if [ -n "$ACTIVE_METHOD_DUPLICATE" ]; then
    echo "refusing to launch duplicate active $RIG method family '$METHOD_FAMILY': $ACTIVE_METHOD_DUPLICATE" >&2
    exit 78
  fi
fi

# Gas City-native throttle: Beads are the execution state, so the launch path
# must inspect active convergence beads before creating more work. Prompts may
# ask mayors/curators to keep one experiment active, but the helper is the only
# shared path used by mayor chat and curator promotion.
if [ "$ALLOW_PARALLEL" != "true" ]; then
  ACTIVE_RUNS=$(timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${GC_ACTIVE_CONVERGENCE_SCAN_LIMIT:-200}" --json 2>/dev/null | jq -r \
    --arg rig "$RIG" \
    --arg proposal "$PROPOSAL_ID" '
    .[]
    | select(.metadata["convergence.state"] == "active" or .metadata["convergence.state"] == "creating")
    | select((.metadata["gc.rig"] // .metadata["var.rig"] // "") == $rig)
    | select($proposal == "" or (.metadata["gc.promoted_from_proposal"] // "") != $proposal)
    | [.id, .title] | @tsv
  ')
  if [ -n "$ACTIVE_RUNS" ]; then
    echo "refusing to launch: active $RIG convergence already exists; pass --allow-parallel to override" >&2
    printf '%s\n' "$ACTIVE_RUNS" >&2
    exit 75
  fi
fi

set +e
CREATE_OUTPUT="$(gc converge create \
  --formula evaluate-idea \
  --target "$RIG_COORDINATOR" \
  --gate condition \
  --gate-condition prompts/convergence/gate.sh \
  --max-iterations "$MAX_ITERATIONS" \
  --title "$TITLE" \
  --var idea="$IDEA" \
  --var idea_description="$IDEA_DESC" \
  --var rig="$RIG" 2>&1)"
CREATE_STATUS=$?
set -e

NEW_ROOT="$(printf '%s\n' "$CREATE_OUTPUT" | grep -Eo 'bl-[a-z0-9]+' | tail -1 || true)"

if ! printf '%s' "$NEW_ROOT" | grep -Eq '^[a-z]+-[a-z0-9]+'; then
  # A supervisor timeout can occur after the convergence root is persisted.
  # Recover by finding the newest matching root and continue with routing.
  NEW_ROOT="$(timeout 12s gc bd list --sort updated --reverse --limit 200 --has-metadata-key convergence.state --json 2>/dev/null \
    | jq -r --arg title "$TITLE" --arg idea "$IDEA" --arg rig "$RIG" '
      [
        .[]
        | select(.issue_type == "convergence")
        | select((.title // "") == $title or (.metadata["var.idea"] // "") == $idea)
        | select(((.metadata["var.rig"] // .metadata["gc.rig"] // "") == $rig))
        | .id
      ][0] // empty
    ')"
fi

if ! printf '%s' "$NEW_ROOT" | grep -Eq '^[a-z]+-[a-z0-9]+'; then
  echo "gc converge create exited with status $CREATE_STATUS" >&2
  echo "failed to parse or recover convergence root from gc converge create output:" >&2
  printf '%s\n' "$CREATE_OUTPUT" >&2
  exit 1
fi

NEW_WISP="$NEW_ROOT.1"

THREAD_ROLE="experiment"
PARENT_THREAD_ID=""
if [ -z "$LINEAGE_ROOT" ]; then
  LINEAGE_ROOT="$NEW_ROOT"
fi
if [ "$FOLLOWUP_KIND" = "new-thread" ] || [ -z "$THREAD_ID" ]; then
  PARENT_THREAD_ID="$THREAD_ID"
  THREAD_ID="$NEW_ROOT"
  THREAD_ROLE="root"
fi
if [ -z "$THREAD_TITLE" ] || [ "$THREAD_ROLE" = "root" ]; then
  THREAD_TITLE="$TITLE"
fi

META=$(jq -n \
  --arg lineage_root "$LINEAGE_ROOT" \
  --arg parent_run "$PARENT_RUN" \
  --arg depth "$LINEAGE_DEPTH" \
  --arg proposal "$PROPOSAL_ID" \
  --arg rig "$RIG" \
  --arg mayor "$RIG_MAYOR" \
  --arg coordinator "$RIG_COORDINATOR" \
  --arg thread "$THREAD_ID" \
  --arg thread_title "$THREAD_TITLE" \
  --arg thread_role "$THREAD_ROLE" \
  --arg parent_thread "$PARENT_THREAD_ID" \
  --arg kind "$FOLLOWUP_KIND" \
  --arg reason "$THREAD_REASON" \
  --arg method "$METHOD_FAMILY" \
  --arg source_directive "$SOURCE_DIRECTIVE_ID" \
  '{
    "gc.lineage_root": $lineage_root,
    "gc.parent_run": $parent_run,
    "gc.lineage_depth": $depth,
    "gc.promoted_from_proposal": $proposal,
    "gc.rig": $rig,
    "gc.rig_mayor": $mayor,
    "gc.rig_coordinator": $coordinator,
    "gc.thread_id": $thread,
    "gc.thread_title": $thread_title,
    "gc.thread_role": $thread_role,
    "gc.parent_thread_id": $parent_thread,
    "gc.followup_kind": $kind,
    "gc.thread_reason": $reason,
    "gc.method_family": $method,
    "gc.research_lane": $method,
    "gc.source_directive": $source_directive
  }')
gc bd update "$NEW_ROOT" --metadata "$META" >/dev/null

ROOT_META_CHECK="$(gc bd show "$NEW_ROOT" --json 2>/dev/null | jq -r \
  --arg lineage_root "$LINEAGE_ROOT" \
  --arg parent_run "$PARENT_RUN" \
  --arg thread "$THREAD_ID" \
  --arg proposal "$PROPOSAL_ID" '
    .[0].metadata as $m |
    if (($m["gc.lineage_root"] // "") == $lineage_root
        and ($m["gc.parent_run"] // "") == $parent_run
        and ($m["gc.thread_id"] // "") == $thread
        and ($proposal == "" or (($m["gc.promoted_from_proposal"] // "") == $proposal)))
    then "ok" else "bad" end
  ')"
if [ "$ROOT_META_CHECK" != "ok" ]; then
  echo "failed to stamp lineage metadata on new convergence $NEW_ROOT" >&2
  exit 80
fi

if [ -n "$PROPOSAL_ID" ]; then
  PROMOTE_META=$(jq -n --arg root "$NEW_ROOT" '{"gc.promoted_to":$root,"gc.decision":"promoted"}')
  gc bd update "$PROPOSAL_ID" --metadata "$PROMOTE_META" --remove-label status:dispatching --remove-label status:pending --add-label status:promoted >/dev/null 2>&1 || true
fi

if [ -n "$SOURCE_DIRECTIVE_ID" ]; then
  gc bd update "$SOURCE_DIRECTIVE_ID" \
    --set-metadata "gc.directive_status=answered" \
    --set-metadata "gc.directive_action=new_convergence" \
    --set-metadata "gc.linked_convergence=$NEW_ROOT" \
    --set-metadata "gc.linked_work=$NEW_ROOT" \
    --set-metadata "gc.directive_resolution=launched $NEW_ROOT" \
    --remove-label status:active \
    --add-label status:answered >/dev/null 2>&1 || true
fi

ROUTE_META=$(jq -n --arg target "$RIG_COORDINATOR" '{"gc.routed_to":$target}')
gc bd update "$NEW_WISP.1" --metadata "$ROUTE_META" >/dev/null
gc sling "$RIG_COORDINATOR" "$NEW_WISP.1" --nudge --no-convoy --force >/dev/null 2>&1 || true

jq -n \
  --arg root "$NEW_ROOT" \
  --arg wisp "$NEW_WISP" \
  --arg step "$NEW_WISP.1" \
  --arg target "$RIG_COORDINATOR" \
  --arg mayor "$RIG_MAYOR" \
  --arg thread "$THREAD_ID" \
  '{root:$root,wisp:$wisp,step:$step,target:$target,mayor:$mayor,thread_id:$thread}'
