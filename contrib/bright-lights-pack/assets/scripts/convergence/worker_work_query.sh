#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: worker_work_query.sh <routed-target> [items|count]" >&2
  exit 2
fi

TARGET="$1"
MODE="${2:-items}"
CITY_DIR="/home/ubuntu/bright-lights"
CITY_BEADS_DIR="$CITY_DIR/.beads"

cd "$CITY_DIR"

READY_JSON=$(BEADS_DIR="$CITY_BEADS_DIR" bd ready \
  --metadata-field "gc.routed_to=$TARGET" \
  --unassigned \
  --include-ephemeral \
  --limit 0 \
  --json)

IN_PROGRESS_JSON=$(BEADS_DIR="$CITY_BEADS_DIR" bd list \
  --status in_progress \
  --metadata-field "gc.routed_to=$TARGET" \
  --limit 0 \
  --json)

filter_active_convergence_descendants() {
  local items_json="$1"
  local roots_json root_ids items_file roots_file

  root_ids="$(printf '%s\n' "$items_json" | jq -r '
    .[]
    | select(.issue_type == "task")
    | .id
    | split(".")[0]
  ' | sort -u)"

  if [ -z "$root_ids" ]; then
    printf '[]\n'
    return 0
  fi

  # One Beads read for all candidate roots keeps the worker hook fast enough
  # while letting us drop descendants of stopped/terminated convergences.
  roots_json="$(xargs -r gc bd show --json 2>/dev/null <<<"$root_ids" || printf '[]')"

  items_file="$(mktemp)"
  roots_file="$(mktemp)"
  trap 'rm -f "$items_file" "$roots_file"' RETURN
  printf '%s\n' "$items_json" > "$items_file"
  printf '%s\n' "$roots_json" > "$roots_file"

  jq -n \
    --slurpfile items_file "$items_file" \
    --slurpfile roots_file "$roots_file" '
    def obj: if type == "array" then .[] else . end;
    ($items_file[0] // []) as $items
    | ($roots_file[0] // []) as $roots
    | ($roots | [obj] | map({key:.id, value:.}) | from_entries) as $root_by_id
    | [
        $items[]
        | select(.issue_type == "task")
        | (.id | split(".")[0]) as $root_id
        | ($root_by_id[$root_id] // {}) as $root
        | select(
            (($root.metadata["convergence.state"] // "") == "")
            or (
              ($root.status // "") == "open"
              and ($root.metadata["convergence.state"] // "") == "active"
            )
          )
        | . + {
            "_gc_priority_score": (
              if (($root.title // "") | test("smoke|single[- ]joint|vjp"; "i")) then 3
              elif (($root.title // "") | test("motion tracking|G1|g1|humanoid"; "i")) then 2
              elif (($root.title // "") | test("ball|pendulum|cartpole"; "i")) then 0
              else 1 end
            )
          }
      ]
    | sort_by(._gc_priority_score, .updated_at // .created_at // "")
    | reverse
    | map(del(._gc_priority_score))
    | .[:50]
  '
}

READY_JSON="$(filter_active_convergence_descendants "$READY_JSON")"
IN_PROGRESS_JSON="$(filter_active_convergence_descendants "$IN_PROGRESS_JSON")"

case "$MODE" in
  count)
    # Gas City's documented scale_check contract says this should report only
    # new unassigned demand because assigned work is resumed separately. For
    # this city's city-level convergence beads, the supervisor currently logs
    # assignedWorkBeads=0 after a pool worker claims work, then drains the
    # worker as orphaned. Count in-progress routed tasks as demand until that
    # upstream assigned-work path is reliable for our convergence store.
    jq -s '[add[] | select(.issue_type == "task")] | length' \
      <(printf '%s\n' "$READY_JSON") \
      <(printf '%s\n' "$IN_PROGRESS_JSON")
    ;;
  items)
    jq -s '
      [
        add[]
        | select(.issue_type == "task")
        | select(
            .status != "in_progress"
            or (.assignee // "") == env.GC_SESSION_NAME
            or (.assignee // "") == env.GC_AGENT
            or (.assignee // "") == env.GC_ALIAS
          )
      ]
    ' <(printf '%s\n' "$READY_JSON") \
      <(printf '%s\n' "$IN_PROGRESS_JSON")
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 2
    ;;
esac
