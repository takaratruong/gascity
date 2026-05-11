#!/usr/bin/env bash
# Run exactly one artifact-writing command for an attempt directory.
#
# This is stronger than flock alone. flock prevents concurrent writers, but a
# worker can still rerun the script after a timeout and overwrite artifacts.
# The consumed sentinel makes reruns explicit failures.

set -u

if [ "$#" -lt 2 ]; then
  echo "usage: run_attempt_once.sh ATTEMPT_DIR COMMAND..." >&2
  exit 2
fi

attempt_dir="$1"
shift

mkdir -p "$attempt_dir"
lock="$attempt_dir/.gc_run.lock"
started="$attempt_dir/.gc_attempt_started"
finished="$attempt_dir/.gc_attempt_finished"
failed="$attempt_dir/.gc_attempt_failed"

ancestor_pids() {
  local p="$$"
  while [ -n "$p" ] && [ "$p" != "0" ]; do
    printf '%s\n' "$p"
    p="$(ps -o ppid= -p "$p" 2>/dev/null | awk '{print $1}')"
  done
}

find_existing_writer() {
  local dir="$1" ancestors="$2" pid cmd fd target cwd
  while read -r pid cmd; do
    [ -n "$pid" ] || continue
    case ",$ancestors," in *",$pid,"*) continue ;; esac
    case "$cmd" in
      *run_attempt_once.sh*|*"ps -eo"*|*"awk -v dir"*|*"flock -n 9"*) continue ;;
      *"$dir"*) ;;
      *) continue ;;
    esac
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    case "$cwd" in "$dir"|"$dir"/*) printf '%s\n' "$pid"; return 0 ;; esac
    for fd in /proc/"$pid"/fd/*; do
      [ -e "$fd" ] || continue
      target="$(readlink "$fd" 2>/dev/null || true)"
      case "$target" in "$dir"|"$dir"/*) printf '%s\n' "$pid"; return 0 ;; esac
    done
  done < <(ps -eo pid=,args= 2>/dev/null)
}

if [ -e "$started" ]; then
  echo "attempt already consumed: $started exists; inspect run.log instead of rerunning" >&2
  exit 64
fi

# Defensive guard for role-boundary failures: if some session bypassed this
# wrapper and is already running a command that references the same attempt
# directory, do not start a second writer. flock cannot see bypassed writers.
ANCESTORS="$(ancestor_pids | paste -sd, -)"
existing_writer="$(find_existing_writer "$attempt_dir" "$ANCESTORS")"
if [ -n "$existing_writer" ]; then
  echo "attempt writer already running outside wrapper for $attempt_dir (pid $existing_writer)" >&2
  exit 65
fi

(
  flock -n 9 || {
    echo "attempt writer already running for $attempt_dir" >&2
    exit 65
  }
  if [ -e "$started" ]; then
    echo "attempt already consumed after lock acquisition: $started exists" >&2
    exit 64
  fi
  ANCESTORS="$(ancestor_pids | paste -sd, -)"
  existing_writer="$(find_existing_writer "$attempt_dir" "$ANCESTORS")"
  if [ -n "$existing_writer" ]; then
    echo "attempt writer already running outside wrapper after lock for $attempt_dir (pid $existing_writer)" >&2
    exit 65
  fi
  date -Is > "$started"
	  log="$attempt_dir/run.log"
	  progress="$attempt_dir/progress.jsonl"
	  cancelled="$attempt_dir/.gc_attempt_cancelled"
	  heartbeat_interval="${GC_ATTEMPT_HEARTBEAT_SECONDS:-60}"
  argv=("$@")
  {
    printf 'started_at=%s\n' "$(date -Is)"
    printf 'command='
    for arg in "${argv[@]}"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  } >> "$log"
  start_epoch="$(date +%s)"
  export GC_ATTEMPT_DIR="$attempt_dir"
  if [ "${argv[0]:-}" = "bash" ] && [ "${argv[1]:-}" = "-lc" ] && [ "${#argv[@]}" -ge 3 ]; then
    # Attempts commonly tee logs. Without pipefail, `timeout cmd | tee log`
    # exits with tee's status and can mark killed runs as successful.
    bash -lc "set -o pipefail; ${argv[2]}" > >(tee -a "$log") 2> >(tee -a "$log" >&2) &
  else
    "${argv[@]}" > >(tee -a "$log") 2> >(tee -a "$log" >&2) &
  fi
  child_pid="$!"
  echo "$child_pid" > "$attempt_dir/.gc_attempt_child_pid"
	  (
	    while kill -0 "$child_pid" 2>/dev/null; do
	      now_epoch="$(date +%s)"
	      printf '{"elapsed_s": %s, "phase": "monitor", "child_pid": %s, "time": "%s"}\n' \
	        "$((now_epoch - start_epoch))" "$child_pid" "$(date -Is)" >> "$progress"
	      if [ -e "$cancelled" ]; then
	        printf 'cancelled_at=%s\n' "$(date -Is)" >> "$log"
	        child_pgid="$(ps -o pgid= -p "$child_pid" 2>/dev/null | awk '{print $1}')"
	        if [ -n "$child_pgid" ]; then
	          kill -TERM -- "-$child_pgid" 2>/dev/null || true
	          sleep 2
	          kill -KILL -- "-$child_pgid" 2>/dev/null || true
	        else
	          kill -TERM "$child_pid" 2>/dev/null || true
	          sleep 2
	          kill -KILL "$child_pid" 2>/dev/null || true
	        fi
	        break
	      fi
	      sleep "$heartbeat_interval"
	    done
	  ) &
  heartbeat_pid="$!"
  echo "$heartbeat_pid" > "$attempt_dir/.gc_attempt_heartbeat_pid"

	  wait "$child_pid"
	  rc=$?
	  if [ -e "$cancelled" ]; then
	    rc=130
	  fi
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true
  printf 'finished_at=%s\nexit_code=%s\n' "$(date -Is)" "$rc" >> "$log"
  if [ "$rc" -eq 0 ]; then
    date -Is > "$finished"
  else
    {
      date -Is
      echo "exit_code=$rc"
    } > "$failed"
  fi
  exit "$rc"
) 9>"$lock"
