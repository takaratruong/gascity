#!/usr/bin/env bash
# Emit queryable curator events through Gas City's Event Bus.
# curator.log remains diagnostics only.

curator_event() {
  local category="$1"
  local target="${2:-}"
  local summary="${3:-$category}"
  local payload="${4:-{}}"
  gc event emit "curator.$category" \
    --actor "curator" \
    --subject "$target" \
    --message "$summary" \
    --payload "$payload" >/dev/null 2>&1 || true
}
