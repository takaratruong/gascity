#!/usr/bin/env bash
# Reliability eval for the Gas City research loop. Read-only except for no-op
# logging; exits nonzero when invariants fail.

set -euo pipefail

CITY_DIR="${CITY_DIR:-/home/ubuntu/bright-lights}"
RIG="${1:-mjx-diffphysics}"
cd "$CITY_DIR"

failures=()
warnings=()

fail() { failures+=("$1"); }
warn() { warnings+=("$1"); }

json_or_empty() {
  "$@" 2>/dev/null || printf '[]'
}

status_json="$(timeout 20s gc status --json 2>/dev/null || true)"
if printf '%s\n' "$status_json" | jq -e '.controller.running == true and .controller.mode == "supervisor"' >/dev/null 2>&1; then
  :
else
  supervisor_status="$(timeout 12s gc supervisor status 2>/dev/null || true)"
  if printf '%s\n' "$supervisor_status" | grep -q 'Supervisor is running'; then
    warn "gc status --json did not report supervisor mode, but gc supervisor status is running"
  else
    fail "controller is not supervisor-managed/running"
  fi
fi
if printf '%s\n' "$status_json" | jq -e '.suspended == false' >/dev/null 2>&1; then
  :
else
  fail "city is suspended"
fi
if printf '%s\n' "$status_json" | jq -e --arg rig "$RIG" '[.rigs[]? | select(.name == $rig and (.suspended // false) == false)] | length > 0' >/dev/null 2>&1; then
  :
else
  fail "rig $RIG not visible in gc status"
fi

active_json="$(json_or_empty timeout 12s gc bd list --status open --has-metadata-key convergence.state --limit 200 --json)"
active_count="$(printf '%s\n' "$active_json" | jq --arg rig "$RIG" '[.[] | select((.metadata["gc.rig"] // .metadata["var.rig"] // "") == $rig) | select(.metadata["convergence.state"] == "active" or .metadata["convergence.state"] == "creating")] | length')"
if [ "${active_count:-0}" -gt 1 ]; then
  fail "$RIG has $active_count active/creating convergence roots; expected at most 1"
elif [ "${active_count:-0}" -eq 0 ]; then
  warn "$RIG has no active convergence root"
fi

active_root="$(printf '%s\n' "$active_json" | jq -r --arg rig "$RIG" '
  [.[] | select((.metadata["gc.rig"] // .metadata["var.rig"] // "") == $rig) | select(.metadata["convergence.state"] == "active" or .metadata["convergence.state"] == "creating")] | .[0].id // empty
')"

if [ -n "$active_root" ]; then
  root="$(gc bd show "$active_root" --json | jq '.[0]')"
  for key in gc.rig gc.rig_mayor gc.rig_coordinator gc.lineage_root gc.thread_id convergence.active_wisp convergence.target; do
    value="$(printf '%s\n' "$root" | jq -r --arg key "$key" '.metadata[$key] // empty')"
    [ -n "$value" ] || fail "$active_root missing metadata $key"
  done

  latest_impl="$(printf '%s\n' "$root" | jq -r '.metadata["gc.leg.latest_implement"] // empty')"
  latest_review="$(printf '%s\n' "$root" | jq -r '.metadata["gc.leg.latest_review"] // empty')"
  if [ -n "$latest_impl" ]; then
    impl="$(gc bd show "$latest_impl" --json 2>/dev/null | jq '.[0]' 2>/dev/null || printf '{}')"
    impl_status="$(printf '%s\n' "$impl" | jq -r '.status // empty')"
    attempt_dir="$(printf '%s\n' "$impl" | jq -r '.metadata["gc.attempt_run_dir"] // empty')"
    case "$impl_status" in open|in_progress|closed) ;; *) fail "$latest_impl has unexpected status '$impl_status'" ;; esac
    if [ -n "$attempt_dir" ]; then
      if [ ! -d "$attempt_dir" ]; then
        fail "$latest_impl attempt_dir does not exist: $attempt_dir"
      elif [ -f "$attempt_dir/.gc_attempt_finished" ] || [ -f "$attempt_dir/.gc_attempt_failed" ]; then
        [ -s "$attempt_dir/metrics.json" ] || fail "$latest_impl terminal attempt missing metrics.json"
        [ -s "$attempt_dir/progress.jsonl" ] || fail "$latest_impl terminal attempt missing progress.jsonl"
        if [ -f "$attempt_dir/.gc_attempt_finished" ] && [ -f "$attempt_dir/validation_failed.txt" ]; then
          warn "$latest_impl finished but validation_failed.txt exists"
        fi
      else
        child_pid="$(cat "$attempt_dir/.gc_attempt_child_pid" 2>/dev/null || true)"
        if [ -n "$child_pid" ] && ! kill -0 "$child_pid" 2>/dev/null; then
          fail "$latest_impl has nonterminal attempt with dead child pid $child_pid"
        fi
      fi
    fi
  else
    warn "$active_root has no latest implement bead yet"
  fi
  [ -z "$latest_review" ] || gc bd show "$latest_review" --json >/dev/null 2>&1 || fail "$active_root latest review bead $latest_review is not readable"
fi

bad_props="$(json_or_empty timeout 12s gc bd list --label kind:proposal --status open --sort updated --reverse --limit 500 --json | jq -r '
  .[]
  | select(
      (((.labels // []) | index("status:pending")) != null and (((.labels // []) | index("status:held")) != null or ((.labels // []) | index("status:promoted")) != null or ((.labels // []) | index("status:promotion-failed")) != null))
      or (((.labels // []) | index("status:dispatching")) != null and (((.labels // []) | index("status:promoted")) != null or ((.labels // []) | index("status:held")) != null))
    )
  | .id
' | paste -sd, -)"
[ -z "$bad_props" ] || fail "open proposals have contradictory status labels: $bad_props"

open_completed_curators="$(json_or_empty timeout 12s gc bd list --status open --has-metadata-key gc.routed_to --limit 500 --json | jq -r '
  .[]
  | select((.metadata["gc.routed_to"] // "") == "curator-decider")
  | select((.title // "") == "curator-decide")
  | .id
' | while read -r root; do
  [ -n "$root" ] || continue
  step_status="$(gc bd show "$root.1" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null || true)"
  [ "$step_status" = "closed" ] && printf '%s\n' "$root"
done | paste -sd, -)"
[ -z "$open_completed_curators" ] || fail "curator-decide roots remain open after closed step: $open_completed_curators"

closed_live_attempts="$(json_or_empty timeout 15s gc bd list --all --has-metadata-key gc.attempt_run_dir --sort updated --reverse --limit 500 --json | jq -r '
  .[]
  | select(.status == "closed")
  | [.id, (.metadata["gc.attempt_run_dir"] // "")] | @tsv
' | while IFS=$'\t' read -r bead dir; do
  [ -n "$dir" ] || continue
  child_pid="$(cat "$dir/.gc_attempt_child_pid" 2>/dev/null || true)"
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    printf '%s:%s\n' "$bead" "$child_pid"
  fi
done | paste -sd, -)"
[ -z "$closed_live_attempts" ] || fail "closed attempt beads still have live child processes: $closed_live_attempts"

printf 'research-loop-eval rig=%s active_root=%s failures=%d warnings=%d\n' "$RIG" "${active_root:-none}" "${#failures[@]}" "${#warnings[@]}"
if [ "${#warnings[@]}" -gt 0 ]; then
  printf 'warnings:\n'
  printf -- '- %s\n' "${warnings[@]}"
fi
if [ "${#failures[@]}" -gt 0 ]; then
  printf 'failures:\n'
  printf -- '- %s\n' "${failures[@]}"
  exit 1
fi

exit 0
