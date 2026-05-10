#!/usr/bin/env bash
# Source this file in a session shell to:
#   1. Flock a free GPU (skipping GPU 0) for the lifetime of this shell
#   2. Export CUDA_VISIBLE_DEVICES to that GPU index
#
# Must be sourced (not executed) so the flocked FD stays open in the shell.

# Don't set -e: this runs under `source` and a failure shouldn't kill the shell.

_GCGPU_LOCK_DIR="${HOME}/.gc/gpu-locks"
mkdir -p "$_GCGPU_LOCK_DIR"

_GCGPU_CLAIMED=""
for _gpu in 1 2 3 4 5 6 7; do
  if command -v nvidia-smi >/dev/null; then
    _busy_pids="$(nvidia-smi -i "$_gpu" --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | awk 'NF' | paste -sd, -)"
    if [ -n "$_busy_pids" ]; then
      echo "[gpu-claim] GPU $_gpu has active compute pid(s): $_busy_pids; skipping"
      continue
    fi
  fi
  _lock_file="$_GCGPU_LOCK_DIR/gpu-$_gpu.lock"
  exec 9>"$_lock_file"
  if command -v flock >/dev/null && flock -n 9; then
    _GCGPU_CLAIMED="$_gpu"
    echo "$$" > "$_lock_file.pid"
    break
  fi
  exec 9>&-
done

if [ -n "$_GCGPU_CLAIMED" ]; then
  export CUDA_VISIBLE_DEVICES="$_GCGPU_CLAIMED"
  echo "[gpu-claim] session $$ claimed GPU $_GCGPU_CLAIMED (CUDA_VISIBLE_DEVICES=$_GCGPU_CLAIMED)"
else
  # All 7 GPUs locked by other sessions. Don't set CUDA_VISIBLE_DEVICES;
  # implementer prompt should detect and wait.
  export CUDA_VISIBLE_DEVICES=""
  echo "[gpu-claim] session $$ could NOT claim a GPU; CUDA_VISIBLE_DEVICES is empty — implementer should wait"
fi

# Cleanup variables that aren't CUDA_VISIBLE_DEVICES.
unset _GCGPU_LOCK_DIR _gpu _lock_file _GCGPU_CLAIMED _busy_pids
