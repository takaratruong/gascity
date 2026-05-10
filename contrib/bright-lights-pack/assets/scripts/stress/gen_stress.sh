#!/usr/bin/env bash
# Synthesize a multi-root, multi-depth lineage for dashboard stress testing.
# Every created bead gets the label 'kind:test-stress' so we can nuke them
# all via `scripts/stress/clean_stress.sh`.
#
# This does NOT fire real convergences — it just writes beads that LOOK like
# a real lineage to the UI. Faster than waiting for the autoloop to produce
# a deep tree.

set -euo pipefail
cd "$HOME/bright-lights"

STRESS_LABEL="kind:test-stress"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkbead() {
  # mkbead "title" type status label_list meta_json description
  local title=$1 t=$2 status=$3 labels=$4 meta=$5 desc=${6:-}
  local id
  id=$(gc bd create "$title" \
    -t "$t" \
    ${desc:+-d "$desc"} \
    -l "$STRESS_LABEL,$labels" \
    --metadata "$meta" \
    --json 2>/dev/null | jq -r '.id')
  if [ "$status" = "closed" ]; then
    gc bd close "$id" --reason "stress seed" >/dev/null 2>&1 || true
  fi
  echo "$id"
}

# Long markdown for verdict testing
LONG_DESC=$(cat <<'MD'
# Overview

This is a stress test seed with real markdown so we can check rendering.

## Goals

- Verify **bold** and _italic_ render.
- Check `inline code` and fenced blocks:

```python
def hello():
    print("hello from stress test")
    return 42
```

## Lists

1. Ordered item one
2. Ordered item two
3. Nested:
   - sub
   - sub with `code`

> A blockquote to confirm styling.

| col A | col B |
|-------|-------|
| one   | two   |
| three | four  |
MD
)

REVIEW_EXAMPLE=$(cat <<'MD'
# Review: stress test

## Acceptance criterion check

All sub-conditions pass:

| Check | Result |
|-------|--------|
| (a) stdout matches | PASS |
| (b) exit code 0    | PASS |
| (c) metrics shape  | PASS |

## Scope audit

No out-of-scope edits.

VERDICT: ACCEPTED
MD
)

echo "== creating 5 roots =="
declare -a ROOTS
for i in 1 2 3 4 5; do
  # Mix of states: 3 accepted, 1 dead-end, 1 running
  case $i in
    1|2|3)
      STATUS=closed
      LABELS="status:accepted"
      META=$(jq -n --arg v "approved" --arg g "gate: iter=1/3 reviewer=ACCEPTED → pass" \
        '{"gc.lineage_depth":"0","convergence.terminal_reason":$v,"convergence.gate_stdout":$g,"convergence.iteration":"1","convergence.max_iterations":"3"}')
      ;;
    4)
      STATUS=closed
      LABELS="status:dead-end"
      META=$(jq -n --arg v "no_convergence" \
        '{"gc.lineage_depth":"0","convergence.terminal_reason":$v,"convergence.iteration":"3","convergence.max_iterations":"3"}')
      ;;
    5)
      STATUS=open
      LABELS=""
      META=$(jq -n \
        '{"gc.lineage_depth":"0","convergence.iteration":"2","convergence.max_iterations":"3","convergence.active_wisp":"fakewisp"}')
      ;;
  esac
  ROOT_ID=$(mkbead "stress root #$i: exploring direction $i" convergence "$STATUS" "$LABELS" "$META" "$LONG_DESC")
  # Patch lineage_root to self
  SELF_META=$(jq -n --arg r "$ROOT_ID" '{"gc.lineage_root": $r}')
  bd update "$ROOT_ID" --metadata "$SELF_META" >/dev/null
  ROOTS[$i]=$ROOT_ID
  echo "  root $i = $ROOT_ID  status=$STATUS  labels=$LABELS"
done

echo ""
echo "== creating depth-1 branches for each accepted root =="
for ROOT in "${ROOTS[1]}" "${ROOTS[2]}" "${ROOTS[3]}"; do
  for j in 1 2 3; do
    # Proposal bead first (kind:proposal)
    PROP_META=$(jq -n --arg lr "$ROOT" --arg pr "$ROOT" --arg d "1" --arg idea "Branch $j of $ROOT: vary on axis $j" \
      '{"gc.lineage_root":$lr,"gc.parent_run":$pr,"gc.lineage_depth":$d,"gc.proposal_idea_desc":$idea}')
    PROP_STATUS_LABEL=""
    # Vary outcomes: 1=promoted, 2=skipped-dedup, 3=pending
    case $j in
      1) PROP_STATUS_LABEL="status:promoted" ;;
      2) PROP_STATUS_LABEL="status:skipped-dedup" ;;
      3) PROP_STATUS_LABEL="status:pending" ;;
    esac
    PROP_ID=$(mkbead "proposal ${ROOT}/$j: follow up axis $j" task open "kind:proposal,$PROP_STATUS_LABEL" "$PROP_META" "Idea: vary axis $j and see if it unlocks better performance.")
    # For promoted, also create the follow-on convergence
    if [ "$j" = "1" ]; then
      CONV_META=$(jq -n --arg lr "$ROOT" --arg pr "$ROOT" --arg pf "$PROP_ID" --arg d "1" --arg v "approved" \
        '{"gc.lineage_root":$lr,"gc.parent_run":$pr,"gc.promoted_from_proposal":$pf,"gc.lineage_depth":$d,"convergence.terminal_reason":$v,"convergence.iteration":"1","convergence.max_iterations":"3"}')
      CHILD=$(mkbead "depth-1: ${ROOT}/$j outcome" convergence closed "status:accepted" "$CONV_META")
      # Close the proposal bead since it got promoted
      bd close "$PROP_ID" --reason "promoted to $CHILD" >/dev/null
      echo "    ${ROOT}  → prop $PROP_ID → conv $CHILD"

      # Depth-2: 2 further followups for this one (only for ROOTS[1] to show deep tree)
      if [ "$ROOT" = "${ROOTS[1]}" ]; then
        for k in 1 2; do
          PROP2_META=$(jq -n --arg lr "$ROOT" --arg pr "$CHILD" --arg d "2" --arg idea "Deeper exploration" \
            '{"gc.lineage_root":$lr,"gc.parent_run":$pr,"gc.lineage_depth":$d,"gc.proposal_idea_desc":$idea}')
          PROP2_ID=$(mkbead "proposal ${CHILD}/$k: deeper axis $k" task open "kind:proposal,status:promoted" "$PROP2_META" "Idea: deeper exploration branch.")
          CONV2_META=$(jq -n --arg lr "$ROOT" --arg pr "$CHILD" --arg pf "$PROP2_ID" --arg d "2" --arg v "approved" \
            '{"gc.lineage_root":$lr,"gc.parent_run":$pr,"gc.promoted_from_proposal":$pf,"gc.lineage_depth":$d,"convergence.terminal_reason":$v,"convergence.iteration":"1","convergence.max_iterations":"3"}')
          GRANDCHILD=$(mkbead "depth-2: ${CHILD}/$k" convergence closed "status:accepted" "$CONV2_META")
          bd close "$PROP2_ID" --reason "promoted" >/dev/null
          echo "      depth-2: $GRANDCHILD"
        done
      fi

    elif [ "$j" = "2" ]; then
      bd close "$PROP_ID" --reason "dedup match bl-xyz" >/dev/null
      echo "    ${ROOT}  → prop $PROP_ID [skipped-dedup]"
    else
      echo "    ${ROOT}  → prop $PROP_ID [pending]"
    fi
  done
done

echo ""
echo "== seeding a few mail messages referencing roots =="
# Use gc mail send so threading works. These also get kind:test-stress via
# description so the cleanup script catches them.
gc mail send human --from mayor -s "stress: question about ${ROOTS[1]}" \
  -m "I'm wondering if the axis-1 branch in ${ROOTS[1]} is really worth pursuing — the margin looks small. Can you re-evaluate?" \
  >/dev/null 2>&1 || true
gc mail send park-mayor --from curator -s "stress: heads up on ${ROOTS[5]}" \
  -m "Running iteration 2 on ${ROOTS[5]}. Expect it to ACCEPT by next tick." \
  --notify >/dev/null 2>&1 || true

echo ""
echo "== summary =="
echo "  total stress beads:"
bd list --label "$STRESS_LABEL" --all 2>&1 | tail -3
echo ""
echo "  roots:"
for i in 1 2 3 4 5; do
  echo "    root $i = ${ROOTS[$i]}"
done
echo ""
echo "  clean up with: scripts/stress/clean_stress.sh"
