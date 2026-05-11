#!/usr/bin/env bash
# Deterministic helper operations for the evaluate-idea convergence formula.
#
# The coordinator owns orchestration, not experiment execution. Keep mechanical
# validation/finalization here so prompt text only describes the workflow.

set -euo pipefail

CITY_DIR="/home/ubuntu/bright-lights"

usage() {
  cat >&2 <<'EOF'
usage:
  evaluate_iteration_ops.sh validate-attempt ATTEMPT_DIR RIG
  evaluate_iteration_ops.sh promote-attempt ATTEMPT_DIR RUN_DIR ROOT_ID ATTEMPT
  evaluate_iteration_ops.sh sync-artifacts ROOT_ID ITERATION RUN_DIR VERDICT THREAD_ID THREAD_TITLE RIG
  evaluate_iteration_ops.sh finalize ROOT_ID ITERATION RUN_DIR VERDICT THREAD_ID THREAD_TITLE RIG STEP_BEAD WISP_ID
EOF
  exit 2
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

cd "$CITY_DIR"

policy_json_for_rig() {
  local rig="$1"
  gc bd list --label kind:policy --label "rig:$rig" --status open --json 2>/dev/null || printf '[]'
}

validate_attempt() {
  local attempt_dir="$1"
  local rig="$2"
  local reason=""
  local policy_json require_media require_visible_video

  policy_json="$(policy_json_for_rig "$rig")"
  require_media="$(printf '%s\n' "$policy_json" | jq -r '[.[]? | select(.metadata["gc.policy.require_media"] == true or .metadata["gc.policy.require_media"] == "true")] | length')"
  require_visible_video="$(printf '%s\n' "$policy_json" | jq -r '[.[]? | select(.metadata["gc.policy.require_visible_robot_video"] == true or .metadata["gc.policy.require_visible_robot_video"] == "true")] | length')"

  if [ ! -f "$attempt_dir/implementation.md" ] || [ ! -f "$attempt_dir/metrics.json" ] || [ ! -f "$attempt_dir/metrics.md" ]; then
    reason="missing required implementation.md, metrics.json, or metrics.md"
  fi

  if [ -z "$reason" ] && [ -f "$attempt_dir/metrics.json" ]; then
    local capacity_blocked
    capacity_blocked="$(jq -r '(.capacity_blocked == true) or ((.device // "") | test("capacity-blocked"))' "$attempt_dir/metrics.json" 2>/dev/null || echo false)"
    if [ "$capacity_blocked" = "true" ]; then
      reason="capacity-blocked: no free GPU available; see gpu_processes.csv"
    fi
  fi

  if [ -z "$reason" ] && [ "$rig" = "mjx-diffphysics" ]; then
    if [ ! -s "$attempt_dir/progress.jsonl" ]; then
      reason="mjx-diffphysics attempt missing progress.jsonl heartbeat"
    elif ! jq -e -s '
      length > 0 and
      all(.[]; (type == "object") and has("phase")) and
      any(.[]; .phase == "compile" or .phase == "smoke" or .phase == "train" or .phase == "done")
    ' "$attempt_dir/progress.jsonl" >/dev/null 2>&1; then
      reason="mjx-diffphysics progress.jsonl is not valid heartbeat JSONL"
    fi
  fi

  if [ -z "$reason" ] && [ "${require_media:-0}" -gt 0 ]; then
    local media_count
    media_count="$(find "$attempt_dir" -maxdepth 3 -type f \( -name '*.mp4' -o -name '*.webm' -o -name '*.gif' -o -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | wc -l | awk '{print $1}')"
    if [ "${media_count:-0}" -eq 0 ]; then
      reason="media required by active policy but no media/image files were produced"
    fi
  fi

  if [ -z "$reason" ] && [ "${require_visible_video:-0}" -gt 0 ]; then
    local video_count media_report
    video_count="$(find "$attempt_dir" -maxdepth 3 -type f \( -name '*.mp4' -o -name '*.webm' -o -name '*.gif' -o -name '*.mov' -o -name '*.mkv' \) | wc -l | awk '{print $1}')"
    if [ "${video_count:-0}" -eq 0 ]; then
      reason="visible robot video required by active policy but no video files were produced"
    elif ! python3 "$CITY_DIR/assets/scripts/convergence/make_video_contact_sheet.py" --run-dir "$attempt_dir" >/dev/null; then
      reason="could not create reviewer video contact sheets"
    else
      media_report="$attempt_dir/media_validation.json"
      if ! python3 "$CITY_DIR/assets/scripts/convergence/check_required_media.py" \
        --run-dir "$attempt_dir" \
        --require-media \
        --require-video \
        --require-visible-video >"$media_report"; then
        reason="visible robot video validation failed; see media_validation.json"
      fi
    fi
  fi

  if [ -z "$reason" ] && [ -f "$attempt_dir/metrics.json" ]; then
    local loss_bad finite_bad rollout_bad metric_null_bad
    loss_bad="$(jq -r 'if (.loss_reduction_pct? == null) then false else ((.loss_reduction_pct|tonumber) < 0) end' "$attempt_dir/metrics.json" 2>/dev/null || echo true)"
    if [ "$loss_bad" = "true" ]; then
      reason="metrics report negative loss_reduction_pct"
    fi
    finite_bad="$(jq -r '
      if has("finite_gradients") then (.finite_gradients != true)
      elif has("all_gradients_finite") then (.all_gradients_finite != true)
      else false end
    ' "$attempt_dir/metrics.json" 2>/dev/null || echo true)"
    if [ -z "$reason" ] && [ "$finite_bad" = "true" ]; then
      reason="metrics report non-finite gradients"
    fi
    if [ -z "$reason" ] && [ "$rig" = "mjx-diffphysics" ]; then
      rollout_bad="$(jq -r '
        if has("tracking_accuracy_pct") then (.tracking_accuracy_pct == null)
        elif has("root_rmse_m") then (.root_rmse_m == null)
        else false end
      ' "$attempt_dir/metrics.json" 2>/dev/null || echo true)"
      if [ "$rollout_bad" = "true" ]; then
        reason="mjx-diffphysics metrics report no valid rollout/tracking accuracy"
      fi
      metric_null_bad="$(jq -r '
        . as $m |
        reduce ["final_loss", "root_rmse_m", "joint_rmse_rad"][] as $k
          (false; . or (($m | has($k)) and ($m[$k] == null)))
      ' "$attempt_dir/metrics.json" 2>/dev/null || echo true)"
      if [ -z "$reason" ] && [ "$metric_null_bad" = "true" ]; then
        reason="mjx-diffphysics metrics contain null final tracking metrics"
      fi
    fi
  fi

  if [ -n "$reason" ]; then
    rm -f "$attempt_dir/validation_passed.txt"
    printf '%s\n' "$reason" > "$attempt_dir/validation_failed.txt"
    return 1
  fi

  rm -f "$attempt_dir/validation_failed.txt"
  printf 'validated attempt artifacts\n' > "$attempt_dir/validation_passed.txt"
}

promote_attempt() {
  local attempt_dir="$1"
  local run_dir="$2"
  local root_id="$3"
  local attempt="$4"

  cp -a "$attempt_dir"/. "$run_dir"/
  gc bd update "$root_id" \
    --set-metadata "gc.selected_attempt=$attempt" \
    --set-metadata "gc.selected_attempt_dir=$attempt_dir" >/dev/null 2>&1 || true
}

sync_artifacts() {
  local root_id="$1"
  local iteration="$2"
  local run_dir="$3"
  local verdict="$4"
  local thread_id="$5"
  local thread_title="$6"
  local rig="$7"

  bash "$CITY_DIR/assets/scripts/convergence/sync_artifact_index.sh" \
    "$root_id" "$iteration" "$run_dir" "$verdict" "$thread_id" "$thread_title" "$rig" >/dev/null 2>&1 || true
  bash "$CITY_DIR/assets/scripts/convergence/synthesize_review_result.sh" \
    "$root_id" "$run_dir" "$rig" "$thread_id" "$thread_title" >/dev/null 2>&1 || true
}

finalize_iteration() {
  local root_id="$1"
  local iteration="$2"
  local run_dir="$3"
  local verdict="$4"
  local thread_id="$5"
  local thread_title="$6"
  local rig="$7"
  local step_bead="$8"
  local wisp_id="$9"

  sync_artifacts "$root_id" "$iteration" "$run_dir" "$verdict" "$thread_id" "$thread_title" "$rig"
  gc bd update "$step_bead" --set-metadata "molecule_id=$wisp_id" >/dev/null 2>&1 || true
  gc bd close "$step_bead" --reason "iter $iteration complete after review.md verdict=$verdict; attached wisp will autoclose for gate"
}

case "$cmd" in
  validate-attempt)
    [ "$#" -eq 2 ] || usage
    validate_attempt "$1" "$2"
    ;;
  promote-attempt)
    [ "$#" -eq 4 ] || usage
    promote_attempt "$1" "$2" "$3" "$4"
    ;;
  sync-artifacts)
    [ "$#" -eq 7 ] || usage
    sync_artifacts "$@"
    ;;
  finalize)
    [ "$#" -eq 9 ] || usage
    finalize_iteration "$@"
    ;;
  *)
    usage
    ;;
esac
