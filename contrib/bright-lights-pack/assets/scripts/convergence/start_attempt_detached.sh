#!/usr/bin/env bash
# Start exactly one long-running attempt command in a detached monitor.
#
# This exists for provider shells with short command timeouts. The detached
# monitor owns the attempt sentinels, so a provider timeout cannot kill the
# training process or leave the attempt without a terminal marker.

set -u

if [ "$#" -lt 2 ]; then
  echo "usage: start_attempt_detached.sh ATTEMPT_DIR COMMAND..." >&2
  exit 2
fi

attempt_dir="$1"
shift

mkdir -p "$attempt_dir"
lock="$attempt_dir/.gc_run.lock"
started="$attempt_dir/.gc_attempt_started"
finished="$attempt_dir/.gc_attempt_finished"
failed="$attempt_dir/.gc_attempt_failed"
cmdfile="$attempt_dir/.gc_attempt_command.sh"
monitor_log="$attempt_dir/.gc_attempt_monitor.log"

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
      *start_attempt_detached.sh*|*"ps -eo"*|*"awk -v dir"*) continue ;;
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

ANCESTORS="$(ancestor_pids | paste -sd, -)"
existing_writer="$(find_existing_writer "$attempt_dir" "$ANCESTORS")"
if [ -n "$existing_writer" ]; then
  echo "attempt writer already running outside wrapper for $attempt_dir (pid $existing_writer)" >&2
  exit 65
fi

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -o pipefail\n'
  if [ "${1:-}" = "bash" ] && [ "${2:-}" = "-lc" ] && [ "$#" -ge 3 ]; then
    printf '%s\n' "$3"
  else
    printf 'exec'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  fi
} > "$cmdfile"
chmod +x "$cmdfile"

setsid bash -c '
  set -u
  attempt_dir="$1"
  lock="$attempt_dir/.gc_run.lock"
  started="$attempt_dir/.gc_attempt_started"
  finished="$attempt_dir/.gc_attempt_finished"
  failed="$attempt_dir/.gc_attempt_failed"
	  cmdfile="$attempt_dir/.gc_attempt_command.sh"
	  log="$attempt_dir/run.log"
	  monitor_log="$attempt_dir/.gc_attempt_monitor.log"
	  progress="$attempt_dir/progress.jsonl"
	  cancelled="$attempt_dir/.gc_attempt_cancelled"
	  heartbeat_interval="${GC_ATTEMPT_HEARTBEAT_SECONDS:-60}"

  {
    flock -n 9 || {
      echo "attempt writer already running for $attempt_dir" >&2
      exit 65
    }
    if [ -e "$started" ]; then
      echo "attempt already consumed after lock acquisition: $started exists" >&2
      exit 64
    fi
    date -Is > "$started"
    echo "$$" > "$attempt_dir/.gc_attempt_monitor_pid"
    {
      printf "started_at=%s\n" "$(date -Is)"
      printf "detached_monitor_pid=%s\n" "$$"
      printf "command_file=%s\n" "$cmdfile"
    } >> "$log"

    start_epoch="$(date +%s)"
    bash "$cmdfile" > >(tee -a "$log") 2> >(tee -a "$log" >&2) &
    child_pid="$!"
    echo "$child_pid" > "$attempt_dir/.gc_attempt_child_pid"

	    (
	      while kill -0 "$child_pid" 2>/dev/null; do
	        now_epoch="$(date +%s)"
	        printf "{\"elapsed_s\": %s, \"phase\": \"monitor\", \"child_pid\": %s, \"time\": \"%s\"}\n" \
	          "$((now_epoch - start_epoch))" "$child_pid" "$(date -Is)" >> "$progress"
	        if [ -e "$cancelled" ]; then
	          printf "cancelled_at=%s\n" "$(date -Is)" >> "$log"
	          child_pgid="$(ps -o pgid= -p "$child_pid" 2>/dev/null | awk "{print \$1}")"
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
    printf "finished_at=%s\nexit_code=%s\n" "$(date -Is)" "$rc" >> "$log"
    if [ "$rc" -eq 0 ]; then
      date -Is > "$finished"
    else
      {
        date -Is
        echo "exit_code=$rc"
      } > "$failed"
    fi
    exit "$rc"
  } 9>"$lock"
' start_attempt_detached "$attempt_dir" >>"$monitor_log" 2>&1 &

monitor_pid=$!
echo "$monitor_pid" > "$attempt_dir/.gc_attempt_launcher_pid"
echo "detached attempt monitor launched: pid=$monitor_pid attempt_dir=$attempt_dir"
exit 0
