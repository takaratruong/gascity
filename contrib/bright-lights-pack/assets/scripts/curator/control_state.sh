#!/usr/bin/env bash
# Shared helpers for curator control state.
# Control state lives in beads, not hidden files. Open beads with:
#   labels: kind:control, control:curator
#   metadata:
#     gc.control_type=curator_pause
#     gc.pause_scope=city|rig
#     gc.rig=<rig>              # for rig scope
#     gc.pause_hard=true|false
#     gc.reason=<operator note>

curator_pause_rows() {
  local rig="${1:-}"
  gc bd list --label kind:control --status open --json 2>/dev/null | jq -r --arg rig "$rig" '
    .[]? |
    select((.labels // []) | index("control:curator")) |
    select(.metadata["gc.control_type"] == "curator_pause") |
    select(
      .metadata["gc.pause_scope"] == "city" or
      ($rig != "" and .metadata["gc.pause_scope"] == "rig" and .metadata["gc.rig"] == $rig)
    ) |
    [.id, (.metadata["gc.pause_hard"] // "false"), (.metadata["gc.reason"] // .title)] |
    @tsv
  '
}

curator_pause_active() {
  local rig="${1:-}"
  [ -n "$(curator_pause_rows "$rig" | head -1)" ]
}

curator_hard_pause_active() {
  local rig="${1:-}"
  [ -n "$(curator_pause_rows "$rig" | awk -F'\t' '$2 == "true" {print; exit}')" ]
}

curator_pause_reason() {
  local rig="${1:-}"
  curator_pause_rows "$rig" | head -1
}
