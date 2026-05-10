#!/usr/bin/env bash
# Sync run artifacts into a queryable Gas City artifact-index bead.

set -u

ROOT_DIR_ID="${1:?run id required}"
ITERATION="${2:?iteration required}"
RUN_DIR="${3:?run dir required}"
VERDICT="${4:?verdict required}"
THREAD_ID="${5:?thread id required}"
THREAD_TITLE="${6:?thread title required}"
RIG="${7:?rig required}"

cd "$HOME/bright-lights" || exit 1

ARTIFACT_INDEX=$(gc bd list --label kind:artifact-index --metadata-field "gc.run_id=$ROOT_DIR_ID" --status open --json 2>/dev/null | jq -r '.[0].id // empty')
ARTIFACT_INDEX_MD="$RUN_DIR/artifact_index.md"
{
  echo "# Artifact index for $ROOT_DIR_ID"
  echo
  echo "- run: $ROOT_DIR_ID"
  echo "- iteration: $ITERATION"
  echo "- verdict: $VERDICT"
  echo "- run_dir: $RUN_DIR"
  echo
  echo "## Core"
  for p in plan.md implementation.md metrics.json metrics.md review.md followups.md; do
    [ -f "$RUN_DIR/$p" ] && echo "- $RUN_DIR/$p"
  done
  echo
  echo "## Media and plots"
  find "$RUN_DIR" -maxdepth 3 -type f \( -name '*.mp4' -o -name '*.webm' -o -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.svg' -o -name '*.pdf' \) | sort | sed 's/^/- /'
} > "$ARTIFACT_INDEX_MD"

ART_META=$(jq -n \
  --arg run "$ROOT_DIR_ID" \
  --arg thread "$THREAD_ID" \
  --arg title "$THREAD_TITLE" \
  --arg rig "$RIG" \
  --arg dir "$RUN_DIR" \
  --arg verdict "$VERDICT" \
  '{"gc.kind":"artifact_index","gc.run_id":$run,"gc.thread_id":$thread,"gc.thread_title":$title,"gc.rig":$rig,"gc.run_dir":$dir,"gc.verdict":$verdict}')

if [ -z "$ARTIFACT_INDEX" ]; then
  ARTIFACT_INDEX=$(gc bd create "artifacts: $ROOT_DIR_ID iter $ITERATION" --type task \
    --body-file "$ARTIFACT_INDEX_MD" \
    -l "kind:artifact-index,status:active,rig:$RIG" \
    --metadata "$ART_META" --json | jq -r '.id')
else
  gc bd update "$ARTIFACT_INDEX" --body-file "$ARTIFACT_INDEX_MD" --metadata "$ART_META"
fi
gc bd update "$ROOT_DIR_ID" --set-metadata "gc.artifact_index=$ARTIFACT_INDEX"

POLICY_JSON=$(gc bd list --label kind:policy --label "rig:$RIG" --status open --json 2>/dev/null)
REQUIRE_MEDIA=$(printf '%s\n' "$POLICY_JSON" | jq -r '[.[]? | select(.metadata["gc.policy.require_media"] == "true")] | length')
MEDIA_COUNT=$(find "$RUN_DIR" -maxdepth 3 -type f \( -name '*.mp4' -o -name '*.webm' -o -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | wc -l | awk '{print $1}')
if [ "${REQUIRE_MEDIA:-0}" -gt 0 ] && [ "${MEDIA_COUNT:-0}" -eq 0 ]; then
  gc bd update "$ROOT_DIR_ID" --set-metadata gc.artifact_missing=media
  gc bd update "$ARTIFACT_INDEX" --set-metadata gc.artifact_missing=media
  echo "artifact requirement missing: media required by active policy but no media files found in $RUN_DIR"
else
  gc bd update "$ROOT_DIR_ID" --unset-metadata gc.artifact_missing >/dev/null 2>&1 || true
  gc bd update "$ARTIFACT_INDEX" --unset-metadata gc.artifact_missing >/dev/null 2>&1 || true
fi

printf '%s\n' "$ARTIFACT_INDEX"
