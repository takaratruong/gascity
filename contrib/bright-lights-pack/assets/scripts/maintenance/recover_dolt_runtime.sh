#!/usr/bin/env bash
# Recover the managed city Dolt server when runtime state and live processes drift.

set -euo pipefail

CITY_DIR="${CITY_DIR:-/home/ubuntu/bright-lights}"
DATA_DIR="$CITY_DIR/.beads/dolt"
LOG="${LOG:-$CITY_DIR/curator.log}"
TS="$(date -Iseconds)"

cd "$CITY_DIR"

log() {
  printf '%s  recover-dolt-runtime  %s\n' "$TS" "$*" >> "$LOG"
}

city_dolt_pids() {
  (pgrep -f 'dolt sql-server' 2>/dev/null || true) | while read -r pid; do
    [ -n "$pid" ] || continue
    cwd="$(pwdx "$pid" 2>/dev/null | sed 's/^[^:]*: //')" || true
    if [ "$cwd" = "$DATA_DIR" ]; then
      printf '%s\n' "$pid"
    fi
  done
}

if timeout 20s gc beads health >/dev/null 2>&1; then
  log "healthy"
  exit 0
fi

mapfile -t pids < <(city_dolt_pids)
if [ "${#pids[@]}" -gt 0 ]; then
  log "terminating-city-dolt-pids ${pids[*]}"
  kill -TERM "${pids[@]}" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    live=()
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        live+=("$pid")
      fi
    done
    [ "${#live[@]}" -eq 0 ] && break
    sleep 1
  done
  if [ "${#live[@]}" -gt 0 ]; then
    log "force-terminating-city-dolt-pids ${live[*]}"
    kill -KILL "${live[@]}" 2>/dev/null || true
  fi
else
  log "no-city-dolt-pids"
fi

timeout 120s gc dolt start >/dev/null
timeout 30s gc beads health >/dev/null
timeout 180s gc doctor --verbose >/dev/null
log "recovered"
