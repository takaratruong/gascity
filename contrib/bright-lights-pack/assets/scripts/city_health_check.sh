#!/usr/bin/env bash
# Check and repair the small set of invariants the dashboard/mayors depend on.

set -u
cd "$HOME/bright-lights" || exit 0

LOG="$HOME/bright-lights/curator.log"
TS="$(date -Iseconds)"
LOCK="$HOME/bright-lights/.gc/city-health-check.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  city-health  skipped-overlap" >> "$LOG"
  exit 0
fi

mayor_for_rig() {
  case "$1" in
    mjx-diffphysics) printf '%s\n' "mjx-mayor" ;;
    park-manip) printf '%s\n' "park-mayor" ;;
    *) printf '%s\n' "$1-mayor" ;;
  esac
}

ensure_rig_synthesis() {
  local rig="$1" mayor sid dir doc bead meta title desc
  mayor="$(mayor_for_rig "$rig")"
  sid="$rig-mayor"
  dir="$HOME/bright-lights/research_threads/$sid"
  doc="$dir/synthesis.md"
  mkdir -p "$dir"
  if [ ! -s "$doc" ]; then
    cat > "$doc" <<EOF
# $rig rig-mayor synthesis

This is the durable rig-level synthesis for $mayor.

- Mayor chat is the operator-facing thread.
- Runs, proposals, policies, and artifact indexes are Beads underneath it.
- Per-run lineage remains in gc.lineage_root and gc.thread_id for compatibility.

Last initialized: $TS
EOF
  fi

	  bead="$(timeout 10s gc bd list --label kind:synthesis --metadata-field "gc.synthesis_scope=rig_mayor" --metadata-field "gc.rig=$rig" --status open --limit 10 --json 2>/dev/null | jq -r '.[0].id // empty')"
  meta="$(jq -n --arg rig "$rig" --arg mayor "$mayor" --arg sid "$sid" --arg doc "$doc" \
    '{"gc.synthesis_scope":"rig_mayor","gc.synthesis_id":$sid,"gc.rig":$rig,"gc.rig_mayor":$mayor,"gc.synthesis_doc":$doc}')"
  if [ -z "$bead" ]; then
    title="synthesis: $rig rig-mayor"
    desc="Rig-mayor synthesis mirror for $rig. Source document: $doc"
    bead="$(gc bd create "$title" --type task --priority 2 --description "$desc" --labels "kind:synthesis,rig:$rig,status:active" --metadata "$meta" --json 2>/dev/null | jq -r '.id // empty')"
    echo "$TS  city-health  created-rig-synthesis  $rig  $bead" >> "$LOG"
  else
    gc bd update "$bead" \
      --set-metadata "gc.synthesis_scope=rig_mayor" \
      --set-metadata "gc.synthesis_id=$sid" \
      --set-metadata "gc.rig=$rig" \
      --set-metadata "gc.rig_mayor=$mayor" \
      --set-metadata "gc.synthesis_doc=$doc" >/dev/null 2>&1 || true
  fi
}

repair_active_convergence_metadata() {
	  timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${CITY_HEALTH_ACTIVE_SCAN_LIMIT:-200}" --json 2>/dev/null | \
    jq -r '.[] | [
      .id,
      (.metadata["gc.rig"] // ""),
      (.metadata["var.rig"] // ""),
      (.metadata["gc.lineage_root"] // ""),
      (.metadata["gc.thread_id"] // ""),
      (.metadata["gc.parent_run"] // ""),
      (.metadata["gc.rig_mayor"] // ""),
      (.metadata["convergence.target"] // "")
    ] | @tsv' | while IFS=$'\t' read -r id gc_rig var_rig lineage thread parent mayor target; do
      [ -z "$id" ] && continue
      local_rig="${gc_rig:-$var_rig}"
      [ -z "$local_rig" ] && continue
      local_mayor="${mayor:-$(mayor_for_rig "$local_rig")}"
      changed=0
      args=(bd update "$id")
      if [ -z "$gc_rig" ]; then args+=(--set-metadata "gc.rig=$local_rig"); changed=1; fi
      if [ -z "$lineage" ]; then args+=(--set-metadata "gc.lineage_root=$id"); changed=1; fi
      if [ -z "$thread" ]; then args+=(--set-metadata "gc.thread_id=$id"); changed=1; fi
      if [ -z "$parent" ]; then args+=(--set-metadata "gc.parent_run="); changed=1; fi
      if [ -z "$mayor" ]; then args+=(--set-metadata "gc.rig_mayor=$local_mayor"); changed=1; fi
      if [ "$changed" -eq 1 ]; then
        gc "${args[@]}" >/dev/null 2>&1 || true
        echo "$TS  city-health  repaired-convergence-metadata  $id  rig=$local_rig" >> "$LOG"
      fi
    done
}

repair_convergence_method_metadata() {
  # Proposals already carry method/lane metadata. Convergence roots need the
  # same fields so Gas City bead queries can throttle duplicate research lanes.
	  timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${CITY_HEALTH_ACTIVE_SCAN_LIMIT:-200}" --json 2>/dev/null | \
    jq -r '.[] | select(.metadata["convergence.state"] == "active") | [
      .id,
      (.metadata["gc.promoted_from_proposal"] // ""),
      (.metadata["gc.method_family"] // .metadata["gc.research_lane"] // "")
    ] | @tsv' | while IFS=$'\t' read -r id proposal method; do
      [ -n "$id" ] || continue
      [ -n "$proposal" ] || continue
      [ -z "$method" ] || continue
      proposal_method="$(gc bd show "$proposal" --json 2>/dev/null | jq -r '.[0].metadata["gc.method_family"] // .[0].metadata["gc.research_lane"] // empty')"
      [ -n "$proposal_method" ] || continue
      gc bd update "$id" \
        --set-metadata "gc.method_family=$proposal_method" \
        --set-metadata "gc.research_lane=$proposal_method" >/dev/null 2>&1 || true
      echo "$TS  city-health  repaired-convergence-method  $id  proposal=$proposal  method=$proposal_method" >> "$LOG"
    done
}

flag_bad_directives() {
  local count
	  count="$(timeout 10s gc bd list --label kind:directive --status open --limit 200 --json 2>/dev/null | jq '[.[] | select(((.labels // []) | index("status:answered")) and (.metadata["gc.directive_status"] != "answered"))] | length')"
  if [ "${count:-0}" != "0" ]; then
    echo "$TS  city-health  directive-label-metadata-mismatch  count=$count" >> "$LOG"
  fi
}

release_closed_session_aliases() {
  # Closed/gc_swept pool session beads are historical records, not live alias
  # owners. If they retain alias metadata, the session reconciler can reject new
  # pool slots with "alias already exists" even though the old bead is closed.
	  timeout 12s gc bd list --label gc:session --all --sort updated --reverse --limit "${CITY_HEALTH_SESSION_SCAN_LIMIT:-300}" --json 2>/dev/null | jq -r '
    .[]
    | select(.status == "closed")
    | select((.metadata["alias"] // "") != "")
    | select((.metadata["state"] // "") == "gc_swept" or (.metadata["state"] // "") == "closed" or (.metadata["state"] // "") == "retired")
    | select((.metadata["template"] // "") | contains("/workers."))
    | select((.metadata["alias"] // "") | test("^mjx-diffphysics/workers\\.(coordinator|implementer|reviewer)-[0-9]+$|^park-manip/workers\\.(coordinator|implementer|reviewer)-[0-9]+$|^robotics-bench/workers\\.(coordinator|implementer|reviewer)-[0-9]+$"))
    | [.id, .metadata["alias"]] | @tsv
  ' | head -20 | while IFS=$'\t' read -r id alias; do
    [ -n "$id" ] || continue
    echo "$TS  city-health  release-closed-session-alias  session=$id  alias=$alias" >> "$LOG"
    gc bd update "$id" --unset-metadata alias >/dev/null 2>&1 || true
  done
}

close_open_children_of_terminal_convergences() {
  # Routed children must not outlive a terminal convergence root. Leaving them
  # open creates fake pool demand and makes the city appear to be doing stale
  # work after the actual run was stopped or accepted.
  local children roots root_json terminal_roots active_roots id id_root parent_run terminal_root
  children="$({
	    timeout 12s gc bd list --status open --has-metadata-key gc.routed_to --limit "${CITY_HEALTH_CHILD_SCAN_LIMIT:-500}" --json 2>/dev/null || printf '[]'
	    timeout 12s gc bd list --status in_progress --has-metadata-key gc.routed_to --limit "${CITY_HEALTH_CHILD_SCAN_LIMIT:-500}" --json 2>/dev/null || printf '[]'
  } | jq -sr '
    add
    | unique_by(.id)
    | .[]
    | select(.type != "convergence")
    | [
        .id,
        (.metadata["gc.parent_run"] // "")
      ] | @tsv
  ')"
  [ -n "$children" ] || return 0

  roots="$(printf '%s\n' "$children" | awk -F '\t' '
    {
      split($1, parts, ".")
      if (parts[1] != $1) print parts[1]
      if ($2 != "") print $2
    }
  ' | sort -u)"
  [ -n "$roots" ] || return 0

  root_json="$(printf '%s\n' "$roots" | xargs -r gc bd show --json 2>/dev/null || true)"
  [ -n "$root_json" ] || return 0

  terminal_roots="$(printf '%s\n' "$root_json" | jq -r '
    .[]
    | select(
        (.status == "closed")
        or ((.metadata["convergence.state"] // "") == "stopped")
        or ((.metadata["convergence.state"] // "") == "terminated")
      )
    | .id
  ')"
  [ -n "$terminal_roots" ] || return 0

  active_roots="$(printf '%s\n' "$root_json" | jq -r '
    .[]
    | select(.status == "open")
    | select((.metadata["convergence.state"] // "") == "active" or (.metadata["convergence.state"] // "") == "creating")
    | .id
  ')"

  while IFS=$'\t' read -r id parent_run; do
    [ -n "$id" ] || continue
    id_root="${id%%.*}"
    terminal_root=""
    if [ "$id_root" != "$id" ] && printf '%s\n' "$active_roots" | grep -Fxq "$id_root"; then
      continue
    fi
    if [ "$id_root" != "$id" ] && printf '%s\n' "$terminal_roots" | grep -Fxq "$id_root"; then
      terminal_root="$id_root"
    elif [ -n "$parent_run" ] && printf '%s\n' "$terminal_roots" | grep -Fxq "$parent_run"; then
      terminal_root="$parent_run"
    fi
    [ -n "$terminal_root" ] || continue
    echo "$TS  city-health  close-terminal-convergence-child  child=$id  root=$terminal_root" >> "$LOG"
    gc bd close "$id" --reason "city-health closed stale child of terminal convergence $terminal_root" >/dev/null 2>&1 || true
  done <<EOF
$children
EOF
}

repair_duplicate_active_convergences() {
  # Prompts should use create_evaluate_idea.sh, but raw gc converge create can
  # still happen. Treat exact same rig+title active roots as a city invariant
  # violation and stop all but the best rooted instance.
  local rows key id keep keep_score score title rig parent proposal worktree
	  rows="$(timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${CITY_HEALTH_ACTIVE_SCAN_LIMIT:-200}" --json 2>/dev/null | jq -r '
    .[]
    | select(.metadata["convergence.state"] == "active")
    | [
        (.metadata["gc.rig"] // .metadata["var.rig"] // ""),
        (.title // .metadata["var.idea"] // ""),
        .id,
        (.metadata["gc.parent_run"] // ""),
        (.metadata["gc.promoted_from_proposal"] // ""),
        (.metadata["gc.worktree_dir"] // "")
      ] | @tsv
  ')"
  [ -n "$rows" ] || return 0

  printf '%s\n' "$rows" | cut -f1,2 | sort | uniq -d | while IFS=$'\t' read -r rig title; do
    [ -n "$rig" ] || continue
    [ -n "$title" ] || continue
    keep=""
    keep_score=-1
    while IFS=$'\t' read -r row_rig row_title id parent proposal worktree; do
      [ "$row_rig" = "$rig" ] || continue
      [ "$row_title" = "$title" ] || continue
      score=0
      [ -n "$proposal" ] && score=$((score + 8))
      [ -n "$parent" ] && score=$((score + 4))
      [ -n "$worktree" ] && score=$((score + 2))
      if [ "$score" -gt "$keep_score" ] || { [ "$score" -eq "$keep_score" ] && { [ -z "$keep" ] || [ "$id" \< "$keep" ]; }; }; then
        keep="$id"
        keep_score="$score"
      fi
    done <<EOF
$rows
EOF

    [ -n "$keep" ] || continue
    while IFS=$'\t' read -r row_rig row_title id parent proposal worktree; do
      [ "$row_rig" = "$rig" ] || continue
      [ "$row_title" = "$title" ] || continue
      [ "$id" != "$keep" ] || continue
      echo "$TS  city-health  stop-duplicate-active-convergence  duplicate=$id  keep=$keep  rig=$rig  title=$title" >> "$LOG"
      gc bd update "$id" \
        --set-metadata convergence.state=stopped \
        --set-metadata convergence.terminal_actor=city-health \
        --set-metadata "convergence.terminal_reason=duplicate_of_$keep" \
        --set-metadata gc.result_class=DUPLICATE \
        --set-metadata "gc.duplicate_of=$keep" >/dev/null 2>&1 || true
      gc bd close "$id" --reason "city-health stopped duplicate of active convergence $keep" >/dev/null 2>&1 || true
	      timeout 10s gc bd list --metadata-field "gc.parent_run=$id" --status open --limit 100 --json 2>/dev/null | jq -r '.[].id' | while read -r child; do
        [ -n "$child" ] || continue
        gc bd close "$child" --reason "city-health stopped duplicate parent $id" >/dev/null 2>&1 || true
      done
      active_wisp="$(gc bd show "$id" --json 2>/dev/null | jq -r '.[0].metadata["convergence.active_wisp"] // empty')"
      if [ -n "$active_wisp" ]; then
        gc bd close "$active_wisp.1" --reason "city-health stopped duplicate parent $id" >/dev/null 2>&1 || true
        gc bd close "$active_wisp" --reason "city-health stopped duplicate parent $id" >/dev/null 2>&1 || true
      fi
    done <<EOF
$rows
EOF
  done
}

repair_duplicate_accepted_convergences() {
  # Exact rig+title duplicates of an accepted closed convergence are not useful
  # research parallelism. They burn workers rerunning a result the city already
  # accepted, so close the active duplicate and leave a durable pointer.
  local accepted_rows active_rows
	  accepted_rows="$(timeout 12s gc bd list --all --label status:accepted --has-metadata-key convergence.state --sort updated --reverse --limit "${CITY_HEALTH_ACCEPTED_SCAN_LIMIT:-300}" --json 2>/dev/null | jq -r '
    .[]
    | select(.status == "closed")
    | select(
        ((.labels // []) | index("status:accepted"))
        or (.metadata["gc.result_class"] == "ACCEPTED_RESEARCH_SIGNAL")
      )
    | [
        (.metadata["gc.rig"] // .metadata["var.rig"] // ""),
        (.title // .metadata["var.idea"] // ""),
        .id
      ] | @tsv
  ')"
  [ -n "$accepted_rows" ] || return 0

	  active_rows="$(timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit "${CITY_HEALTH_ACTIVE_SCAN_LIMIT:-200}" --json 2>/dev/null | jq -r '
    .[]
    | select(.metadata["convergence.state"] == "active")
    | [
        (.metadata["gc.rig"] // .metadata["var.rig"] // ""),
        (.title // .metadata["var.idea"] // ""),
        .id
      ] | @tsv
  ')"
  [ -n "$active_rows" ] || return 0

  while IFS=$'\t' read -r rig title active_id; do
    [ -n "$rig" ] || continue
    [ -n "$title" ] || continue
    [ -n "$active_id" ] || continue
    accepted_id="$(printf '%s\n' "$accepted_rows" | awk -F '\t' -v rig="$rig" -v title="$title" '$1 == rig && $2 == title { print $3; exit }')"
    [ -n "$accepted_id" ] || continue
    [ "$active_id" != "$accepted_id" ] || continue

    echo "$TS  city-health  stop-duplicate-accepted-convergence  duplicate=$active_id  accepted=$accepted_id  rig=$rig  title=$title" >> "$LOG"
    gc bd update "$active_id" \
      --set-metadata convergence.state=stopped \
      --set-metadata convergence.terminal_actor=city-health \
      --set-metadata "convergence.terminal_reason=duplicate_of_accepted_$accepted_id" \
      --set-metadata gc.result_class=DUPLICATE \
      --set-metadata "gc.duplicate_of=$accepted_id" >/dev/null 2>&1 || true
    gc bd close "$active_id" --reason "city-health stopped duplicate of accepted convergence $accepted_id" >/dev/null 2>&1 || true
	    timeout 10s gc bd list --metadata-field "gc.parent_run=$active_id" --status open --limit 100 --json 2>/dev/null | jq -r '.[].id' | while read -r child; do
      [ -n "$child" ] || continue
      gc bd close "$child" --reason "city-health stopped duplicate parent $active_id" >/dev/null 2>&1 || true
    done
    active_wisp="$(gc bd show "$active_id" --json 2>/dev/null | jq -r '.[0].metadata["convergence.active_wisp"] // empty')"
    if [ -n "$active_wisp" ]; then
      gc bd close "$active_wisp.1" --reason "city-health stopped duplicate parent $active_id" >/dev/null 2>&1 || true
      gc bd close "$active_wisp" --reason "city-health stopped duplicate parent $active_id" >/dev/null 2>&1 || true
    fi
  done <<EOF
$active_rows
EOF
}

ensure_rig_synthesis "mjx-diffphysics"
ensure_rig_synthesis "park-manip"
repair_active_convergence_metadata
repair_convergence_method_metadata
release_closed_session_aliases
close_open_children_of_terminal_convergences
repair_duplicate_active_convergences
repair_duplicate_accepted_convergences
flag_bad_directives

exit 0
