#!/usr/bin/env bash
# Deterministic safety net for post-review research metadata.
#
# Coordinators are instructed to synthesize results and file followups before
# closing a convergence step. If they skip that work, this script repairs the
# structured Beads state from review.md so the mayor dashboard and curator do
# not lose the research signal.

set -euo pipefail

ROOT_ID="${1:?root convergence id required}"
RUN_DIR="${2:?run dir required}"
RIG="${3:?rig required}"
THREAD_ID="${4:-}"
THREAD_TITLE="${5:-}"

cd "$HOME/bright-lights"

review="$RUN_DIR/review.md"
[ -f "$review" ] || exit 0

root_json="$(gc bd show "$ROOT_ID" --json 2>/dev/null || printf '[]')"
if [ -z "$THREAD_ID" ]; then
  THREAD_ID="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end) as $b | $b.metadata["gc.thread_id"] // $b.metadata["gc.lineage_root"] // $b.id // empty')"
fi
if [ -z "$THREAD_TITLE" ]; then
  THREAD_TITLE="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end) as $b | $b.metadata["gc.thread_title"] // $b.title // empty')"
fi
THREAD_ID="${THREAD_ID:-$ROOT_ID}"
THREAD_TITLE="${THREAD_TITLE:-$ROOT_ID}"

current_result="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.result_class"] // empty')"
if [ -z "$current_result" ]; then
  verdict="$(grep -E '^VERDICT:' "$review" | tail -1 | awk '{print $2}')"
  negative_signal="$(
    grep -E 'NEGATIVE_RESEARCH_SIGNAL' "$review" 2>/dev/null \
      | grep -Evi 'no[[:space:][:punct:]]+`?NEGATIVE_RESEARCH_SIGNAL|not[[:space:][:punct:]]+`?NEGATIVE_RESEARCH_SIGNAL|no.*negative research signal' \
      | head -1 || true
  )"
  if [ -n "$negative_signal" ]; then
    result_class="NEGATIVE_RESEARCH_SIGNAL"
  elif grep -q 'IMPLEMENTATION_BUG' "$review"; then
    result_class="IMPLEMENTATION_BUG"
  elif grep -q 'INFRA_BLOCKED' "$review"; then
    result_class="INFRA_BLOCKED"
  elif grep -q 'REVIEWER_BLOCKED' "$review"; then
    result_class="REVIEWER_BLOCKED"
  elif grep -q 'SPEC_AMBIGUOUS' "$review"; then
    result_class="SPEC_AMBIGUOUS"
  else
    case "$verdict" in
      ACCEPTED) result_class="ACCEPTED_RESEARCH_SIGNAL" ;;
      REJECTED) result_class="IMPLEMENTATION_BUG" ;;
      NEEDS_TAKARA) result_class="SPEC_AMBIGUOUS" ;;
      *) result_class="" ;;
    esac
  fi

  if [ -n "$result_class" ]; then
    gc bd update "$ROOT_ID" --set-metadata "gc.result_class=$result_class" >/dev/null || true
  fi
else
  result_class="$current_result"
fi

learning="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.learning_summary"] // empty')"
if [ -z "$learning" ]; then
  learning="$(python3 - "$review" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(errors="replace")
patterns = [
    r"root cause[^:\n]*:\s*(.+?)(?:\n\n|$)",
    r"Suggested delta.*?\n\n(.+?)(?:\n\n|$)",
    r"Verdict reasoning\s*\n\n(.+?)(?:\n\n|$)",
]
for pat in patterns:
    m = re.search(pat, text, re.I | re.S)
    if m:
        s = re.sub(r"\s+", " ", m.group(1)).strip(" -")
        print(s[:500])
        break
PY
)"
  if [ -n "$learning" ]; then
    gc bd update "$ROOT_ID" --set-metadata "gc.learning_summary=$learning" >/dev/null || true
  fi
fi

case "$RIG" in
  mjx-diffphysics) mayor="mjx-mayor" ;;
  park-manip) mayor="park-mayor" ;;
  robotics-bench) mayor="robotics-mayor" ;;
  *) mayor="$RIG-mayor" ;;
esac
synthesis_id="$RIG-mayor"
synthesis_dir="$HOME/bright-lights/research_threads/$synthesis_id"
mkdir -p "$synthesis_dir"
synthesis_file="$synthesis_dir/synthesis.md"
touch "$synthesis_file"
if ! grep -q "$ROOT_ID" "$synthesis_file"; then
  {
    echo
    echo "- \`$ROOT_ID\` — $THREAD_TITLE — \`${result_class:-UNCLASSIFIED}\`. ${learning:-See review.md for details.}"
  } >> "$synthesis_file"
fi

synthesis_bead="$(timeout 10s gc bd list --label kind:synthesis --metadata-field "gc.synthesis_scope=rig_mayor" --metadata-field "gc.rig=$RIG" --status open --limit 10 --json 2>/dev/null | jq -r '.[0].id // empty')"
synth_meta="$(jq -n --arg rig "$RIG" --arg mayor "$mayor" --arg sid "$synthesis_id" '{"gc.synthesis_scope":"rig_mayor","gc.synthesis_id":$sid,"gc.rig":$rig,"gc.rig_mayor":$mayor,"gc.kind":"rig_mayor_synthesis"}')"
if [ -z "$synthesis_bead" ]; then
  synthesis_bead="$(gc bd create "synthesis: $RIG rig mayor" --type decision \
    --body-file "$synthesis_file" \
    -l "kind:synthesis,status:active,rig:$RIG" \
    --metadata "$synth_meta" --json | jq -r '.id')"
else
  gc bd update "$synthesis_bead" --body-file "$synthesis_file" --metadata "$synth_meta" >/dev/null || true
fi
gc bd update "$ROOT_ID" --set-metadata "gc.rig_synthesis=$synthesis_bead" >/dev/null || true

# If the run has an actionable reviewer delta and no followup exists, file one
# same-thread proposal that asks the mayor/coordinator to address it. This
# avoids a dead-end where a useful research signal or implementation bug is
# captured but no next lever is put back into the Gas City queue.
current_followup="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.followup_proposal"] // empty')"
existing_followup=""
if [ -n "$current_followup" ]; then
  existing_followup="$(gc bd show "$current_followup" --json 2>/dev/null | jq -r '(if type == "array" then .[0] else . end).id // empty')"
fi
if [ -z "$existing_followup" ]; then
  existing_followup="$(timeout 10s gc bd list --all --sort updated --reverse --limit 50 --metadata-field "gc.parent_run=$ROOT_ID" --json 2>/dev/null | jq -r '
    .[]
    | select(
        ((.labels // []) | index("kind:proposal")) != null
        or .metadata["convergence.state"] != null
      )
    | .id
  ' | head -1)"
fi
if [ -n "$existing_followup" ] && [ -z "$current_followup" ]; then
  gc bd update "$ROOT_ID" --set-metadata "gc.followup_proposal=$existing_followup" >/dev/null || true
fi
should_file_followup=false
followup_reason=""
case "${result_class:-}" in
  NEGATIVE_RESEARCH_SIGNAL)
    should_file_followup=true
    followup_reason="Review accepted the run as NEGATIVE_RESEARCH_SIGNAL."
    ;;
  IMPLEMENTATION_BUG|INFRA_BLOCKED)
    should_file_followup=true
    followup_reason="Review rejected the run as ${result_class}; file exactly one bugfix/retry, not a new scientific branch."
    ;;
esac

if $should_file_followup && [ -z "$existing_followup" ]; then
  delta="$(awk '
    BEGIN{capture=0}
    /^## Suggested delta/{capture=1; next}
    capture && /^## /{exit}
    capture{print}
  ' "$review" | sed '/^[[:space:]]*$/d' | head -80)"
  [ -n "$delta" ] || delta="${learning:-Use review.md to choose the minimal next lever.}"
  title="$THREAD_TITLE followup: address reviewer delta"
  desc="Followup to $ROOT_ID. $followup_reason Minimal next experiment should address the reviewer delta without launching unrelated scientific branches.\n\nReviewer delta:\n$delta"
  depth="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end).metadata["gc.lineage_depth"] // "0"')"
  case "$depth" in ''|*[!0-9]*) depth=0 ;; esac
  child_depth=$((depth + 1))
  lineage_root="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end) as $b | $b.metadata["gc.lineage_root"] // $b.id // empty')"
  method="$(printf '%s\n' "$root_json" | jq -r '(if type == "array" then .[0] else . end) as $b | $b.metadata["gc.method_family"] // $b.metadata["gc.research_lane"] // empty')"
  meta="$(jq -n \
    --arg root "${lineage_root:-$ROOT_ID}" \
    --arg parent "$ROOT_ID" \
    --arg depth "$child_depth" \
    --arg desc "$desc" \
    --arg rig "$RIG" \
    --arg thread "$THREAD_ID" \
    --arg title "$THREAD_TITLE" \
    --arg method "${method:-unknown}" \
    '{"gc.lineage_root":$root,"gc.parent_run":$parent,"gc.lineage_depth":$depth,"gc.proposal_idea_desc":$desc,"gc.rig":$rig,"gc.thread_id":$thread,"gc.thread_title":$title,"gc.followup_kind":"bugfix","gc.method_family":$method}')"
  proposal="$(gc bd create "$title" -d "$desc" -l "kind:proposal,status:pending,rig:$RIG" --metadata "$meta" --json | jq -r '.id')"
  gc bd update "$ROOT_ID" --set-metadata "gc.followup_proposal=$proposal" >/dev/null || true
  {
    echo "# Followups for $ROOT_ID"
    echo
    echo "- $proposal — $title"
  } > "$RUN_DIR/followups.md"
fi
