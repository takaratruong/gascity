#!/usr/bin/env bash
# Pick a free GPU (skip 0 — reserved for remote desktop). Used by
# implementer sessions as a pre-start hook to set CUDA_VISIBLE_DEVICES.
#
# Strategy: try flock on each GPU lock file under ~/.gc/gpu-locks/. First
# one we can lock, we claim via CUDA_VISIBLE_DEVICES. The lock is held
# for the lifetime of this shell (so: export is intended to persist via
# sourcing into the session shell). Skips GPU 0.
#
# This script PRINTS the chosen GPU to stdout (0-7) and nothing else.
# Caller is expected to: GPU=$(pick_gpu.sh) && export CUDA_VISIBLE_DEVICES=$GPU
#
# If all GPUs 1..7 are locked, prints nothing and exits 1.

set -u

LOCK_DIR="${HOME}/.gc/gpu-locks"
mkdir -p "$LOCK_DIR"

# Try GPUs 1..7 in order. flock -n = non-blocking.
for gpu in 1 2 3 4 5 6 7; do
  if command -v nvidia-smi >/dev/null; then
    BUSY_PIDS="$(nvidia-smi -i "$gpu" --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | awk 'NF' | paste -sd, -)"
    if [ -n "$BUSY_PIDS" ]; then
      continue
    fi
  fi
  LOCK_FILE="$LOCK_DIR/gpu-$gpu.lock"
  # Open FD 9 on the lock file; try non-blocking lock.
  # If successful, we hold the lock for the lifetime of this shell.
  exec 9>"$LOCK_FILE"
  if flock -n 9; then
    # Record PID for observability.
    echo "$$" > "$LOCK_FILE.pid"
    echo "$gpu"
    # Keep FD 9 open — lock releases when this process exits.
    # Caller must `source` this script (or exec into a shell that keeps FD 9).
    # If the caller runs this as a subprocess, the lock releases when it exits
    # and the next process can claim the same GPU. That's the intended behavior
    # for pool workers: the lock lives for the duration of the session.
    exit 0
  fi
  exec 9>&-  # close FD if lock failed
done

# Nothing free.
exit 1
