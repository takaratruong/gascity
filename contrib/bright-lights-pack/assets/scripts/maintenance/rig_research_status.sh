#!/usr/bin/env bash
set -euo pipefail

CITY_DIR="${CITY_DIR:-/home/ubuntu/bright-lights}"
RIG="${1:-}"
[ -n "$RIG" ] || { echo "usage: rig_research_status.sh RIG" >&2; exit 2; }

cd "$CITY_DIR"

mayor_for_rig() {
  case "$1" in
    mjx-diffphysics) printf '%s\n' "mjx-mayor" ;;
    park-manip) printf '%s\n' "park-mayor" ;;
    robotics-bench) printf '%s\n' "robotics-mayor" ;;
    *) printf '%s\n' "$1-mayor" ;;
  esac
}

coordinator_for_rig() {
  printf '%s\n' "$1/workers.coordinator"
}

json_list() {
  timeout "${GC_RIG_STATUS_TIMEOUT:-8s}" gc bd list "$@" --json 2>/dev/null || printf '[]'
}

flatten_unique() {
  jq -s '[.[] | if type == "array" then .[] else empty end] | unique_by(.id)'
}

MAYOR="$(mayor_for_rig "$RIG")"
COORDINATOR="$(coordinator_for_rig "$RIG")"

ACTIVE_ROOTS="$(
  {
    json_list --status open --has-metadata-key convergence.state --metadata-field "gc.rig=$RIG" --sort updated --reverse --limit 20
    json_list --status open --has-metadata-key convergence.state --metadata-field "var.rig=$RIG" --sort updated --reverse --limit 20
  } | flatten_unique
)"

WORK_BEADS="[]"
while IFS= read -r root; do
  [ -n "$root" ] || continue
  root_json="$(printf '%s\n' "$ACTIVE_ROOTS" | jq -r --arg root "$root" '.[] | select(.id == $root)')"
  active_wisp="$(printf '%s\n' "$root_json" | jq -r '.metadata["convergence.active_wisp"] // empty')"
  {
    json_list --status open,in_progress --metadata-field "gc.parent_run=$root" --sort updated --reverse --limit 80
    if [ -n "$active_wisp" ]; then
      json_list --status open,in_progress --parent "$active_wisp" --sort updated --reverse --limit 40
      json_list --status open,in_progress --parent "$active_wisp.1" --sort updated --reverse --limit 40
    fi
  } | flatten_unique > /tmp/gc-rig-status-work-$$.json
  WORK_BEADS="$(jq -s '.[0] + .[1] | unique_by(.id)' <(printf '%s\n' "$WORK_BEADS") /tmp/gc-rig-status-work-$$.json)"
  rm -f /tmp/gc-rig-status-work-$$.json
done < <(printf '%s\n' "$ACTIVE_ROOTS" | jq -r '.[].id')

PROPOSALS="$(json_list --label kind:proposal --label "rig:$RIG" --status open --sort updated --reverse --limit 20 | flatten_unique)"
DIRECTIVES="$(json_list --label kind:directive --label source:operator --label status:active --label "rig:$RIG" --status open --sort updated --reverse --limit 20 | flatten_unique)"
RESULTS="$(
  {
    json_list --all --metadata-field "gc.rig=$RIG" --has-metadata-key gc.result_class --sort updated --reverse --limit 20
    json_list --all --metadata-field "var.rig=$RIG" --has-metadata-key gc.result_class --sort updated --reverse --limit 20
    json_list --all --label status:accepted --label "rig:$RIG" --sort updated --reverse --limit 20
  } | flatten_unique | jq 'sort_by(.updated_at // .closed_at // .created_at // "") | reverse | .[:10]'
)"

CURRENT_RUN="$(printf '%s\n' "$ACTIVE_ROOTS" | jq 'sort_by(.updated_at // .created_at // "") | reverse | .[0] // null')"
CURRENT_STEP="$(printf '%s\n' "$WORK_BEADS" | jq 'sort_by(.updated_at // .created_at // "") | reverse | .[0] // null')"

jq -n \
  --arg rig "$RIG" \
  --arg mayor "$MAYOR" \
  --arg coordinator "$COORDINATOR" \
  --argjson activeRuns "$ACTIVE_ROOTS" \
  --argjson workBeads "$WORK_BEADS" \
  --argjson proposals "$PROPOSALS" \
  --argjson directives "$DIRECTIVES" \
  --argjson results "$RESULTS" \
  --argjson currentRun "$CURRENT_RUN" \
  --argjson currentStep "$CURRENT_STEP" '
  def route: (.metadata["gc.routed_to"] // "");
  def worker_state:
    if .status == "in_progress" then "claimed"
    elif (route | length) > 0 then "queued"
    else (.status // "unknown") end;
  {
    rig: $rig,
    mayor: $mayor,
    coordinator: $coordinator,
    activeRuns: $activeRuns,
    staleRuns: [],
    workBeads: ($workBeads | map(. + {ui_worker_state: worker_state, ui_worker_session: (.assignee // null)})),
    proposals: $proposals,
    acceptedRuns: ($results | map(select(((.labels // []) | index("status:accepted")) != null)) | .[:5]),
    latestResultRuns: ($results | .[:5]),
    heldProposals: ($proposals | map(select(any(.labels[]?; startswith("status:held"))))),
    activeDirectives: $directives,
    sessions: [],
    summary: {
      currentRun: $currentRun,
      currentStep: $currentStep,
      nextAction: (
        if $currentRun != null then
          "Running " + (($currentStep.metadata["gc.routed_to"] // $currentRun.metadata["convergence.target"] // "worker") | tostring) + " on " + ($currentRun.id | tostring)
        elif ($proposals | length) > 0 then
          (($proposals | length | tostring) + " proposal(s) waiting for curator/mayor decision")
        elif ($results | length) > 0 then
          "Idle after result " + ($results[0].id | tostring)
        else
          "Idle; no active convergence"
        end
      )
    },
    errors: {}
  }'
