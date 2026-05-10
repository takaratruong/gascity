#!/usr/bin/env bash
# Create self-maintenance work when core Gas City mechanics fail.

set -euo pipefail

CITY_DIR="/home/ubuntu/bright-lights"
LOG="$CITY_DIR/curator.log"
TS="$(date -Iseconds)"

cd "$CITY_DIR"

LOCK="$CITY_DIR/.gc/city-maintenance-canary.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  city-maintenance-canary  skipped-overlap" >> "$LOG"
  exit 0
fi

failures=()

record_failure() {
  failures+=("$1")
}

if ! timeout 20s gc beads health >/dev/null 2>&1; then
  if timeout 120s gc dolt start >/dev/null 2>&1 && timeout 30s gc beads health >/dev/null 2>&1; then
    echo "$TS  city-maintenance-canary  recovered-via-gc-dolt-start" >> "$LOG"
  elif ! timeout 240s assets/scripts/maintenance/recover_dolt_runtime.sh >/dev/null 2>&1; then
    record_failure "gc beads health failed and upstream gc dolt start plus recover_dolt_runtime.sh could not restore it"
  fi
fi

city_dolt_count=0
while read -r pid; do
  [ -n "$pid" ] || continue
  cwd="$(pwdx "$pid" 2>/dev/null | sed 's/^[^:]*: //')" || true
  if [ "$cwd" = "$CITY_DIR/.beads/dolt" ]; then
    city_dolt_count=$((city_dolt_count + 1))
  fi
done < <(pgrep -f 'dolt sql-server' 2>/dev/null || true)
[ "${city_dolt_count:-0}" -le 1 ] || record_failure "multiple managed Dolt sql-server processes for this city ($city_dolt_count)"

timeout 45s gc formula show evaluate-idea >/dev/null 2>&1 || record_failure "gc formula show evaluate-idea failed or timed out"
timeout 45s gc order list >/dev/null 2>&1 || record_failure "gc order list failed or timed out"
timeout 45s gc session list >/dev/null 2>&1 || record_failure "gc session list failed or timed out"
timeout 45s gc converge list >/dev/null 2>&1 || record_failure "gc converge list failed or timed out"
timeout 20s bash -n \
  assets/scripts/convergence/evaluate_iteration_ops.sh \
  assets/scripts/convergence/create_evaluate_idea.sh \
  assets/scripts/convergence/worker_work_query.sh \
  assets/scripts/convergence/repair_routing.sh \
  assets/scripts/curator/dispatch_proposals.sh \
  assets/scripts/curator/label_runs.sh \
  assets/scripts/maintenance/recover_dolt_runtime.sh >/dev/null 2>&1 || record_failure "core shell syntax check failed"
# Supervisor-managed cities do not expose reload on the city socket;
# route through gc supervisor reload when that mode is detected.
# Note: avoid `grep -q` in a pipeline under pipefail — SIGPIPE race.
_reload_ok=false
_city_status="$(gc status 2>/dev/null || true)"
if [[ "$_city_status" == *supervisor-managed* ]]; then
  timeout 15s gc supervisor reload >/dev/null 2>&1 && _reload_ok=true
else
  for _i in 1 2 3; do
    if timeout 10s gc reload --async >/dev/null 2>&1; then
      _reload_ok=true
      break
    fi
    sleep 3
  done
fi
$_reload_ok || record_failure "gc reload did not complete within timeout"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'implementation\n' > "$tmp/implementation.md"
printf '{"loss_reduction_pct":1,"finite_gradients":true}\n' > "$tmp/metrics.json"
printf 'metrics\n' > "$tmp/metrics.md"
if ! timeout 30s assets/scripts/convergence/evaluate_iteration_ops.sh validate-attempt "$tmp" "__canary_no_policy__" >/dev/null 2>&1; then
  record_failure "evaluate_iteration_ops validate-attempt failed on minimal valid artifact set"
fi

attempt_tmp="$(mktemp -d)"
if ! timeout 30s assets/scripts/convergence/run_attempt_once.sh "$attempt_tmp" bash -lc 'echo canary-ok; echo canary-err >&2' >/dev/null 2>&1; then
  record_failure "run_attempt_once failed on canary command"
elif [ ! -f "$attempt_tmp/run.log" ] || [ ! -f "$attempt_tmp/.gc_attempt_finished" ]; then
  record_failure "run_attempt_once did not write run.log and .gc_attempt_finished"
elif ! grep -q 'canary-ok' "$attempt_tmp/run.log" || ! grep -q 'canary-err' "$attempt_tmp/run.log"; then
  record_failure "run_attempt_once did not capture stdout/stderr in run.log"
fi
rm -rf "$attempt_tmp"

doctor_out="$(mktemp)"
if ! timeout 180s gc doctor --verbose >"$doctor_out" 2>&1; then
  record_failure "gc doctor --verbose failed or timed out"
elif grep -E '^[[:space:]]*[✗xX]' "$doctor_out" | grep -qv 'dolt-noms-size'; then
  record_failure "gc doctor reports at least one failing check"
fi

if [ "${#failures[@]}" -eq 0 ]; then
  echo "$TS  city-maintenance-canary  ok" >> "$LOG"
  exit 0
fi

summary="$(printf '%s\n' "${failures[@]}" | sed 's/^/- /')"
title="maintenance: Gas City canary failed"

existing="$(gc bd list --label kind:maintenance --label status:active --status open --json 2>/dev/null | jq -r --arg title "$title" '.[]? | select((.title // "") == $title) | .id' | head -1)"
if [ -n "$existing" ]; then
  gc bd update "$existing" \
    --set-metadata "gc.maintenance_last_failure_at=$TS" \
    --append-notes "Canary failed again at $TS"$'\n'"$summary" >/dev/null 2>&1 || true
  timeout 20s gc sling city-maintainer "$existing" --nudge --no-convoy --force >/dev/null 2>&1 || true
  echo "$TS  city-maintenance-canary  updated-existing  $existing" >> "$LOG"
  exit 0
fi

body="$(cat <<EOF
The Gas City maintenance canary failed.

Failures:
$summary

Required action:
1. Inspect the failing primitive(s).
2. Patch the city pack/scripts/formulas/prompts as needed.
3. Run:
   - bash -n for changed shell scripts
   - gc formula show evaluate-idea
   - gc order list
   - gc doctor --verbose
4. Close this bead with the fix summary and validation.

Do not launch research experiments from this bead.
EOF
)"

meta="$(jq -n --arg routed "city-maintainer" --arg at "$TS" \
  '{"gc.routed_to":$routed,"gc.kind":"city_maintenance","gc.maintenance_status":"active","gc.maintenance_source":"city_maintenance_canary","gc.maintenance_last_failure_at":$at}')"

bead="$(gc bd create "$title" \
  --type task \
  --priority 1 \
  --description "$body" \
  --labels "kind:maintenance,status:active" \
  --metadata "$meta" \
  --json | jq -r '.id')"

timeout 20s gc sling city-maintainer "$bead" --nudge --no-convoy --force >/dev/null 2>&1 || true
timeout 20s gc event emit "maintenance.canary_failed" \
  --actor "city-maintenance-canary" \
  --subject "$bead" \
  --message "$title" \
  --payload "$(jq -n --argjson failures "$(printf '%s\n' "${failures[@]}" | jq -R . | jq -s .)" '{failures:$failures}')" >/dev/null 2>&1 || true

echo "$TS  city-maintenance-canary  created  $bead" >> "$LOG"
