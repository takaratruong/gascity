#!/usr/bin/env bash
# Clean stale proposal/curator bookkeeping that confuses the research loop.

set -euo pipefail

CITY_DIR="${CITY_DIR:-/home/ubuntu/bright-lights}"
LOG="$CITY_DIR/curator.log"
TS="$(date -Iseconds)"

cd "$CITY_DIR"

LOCK="$CITY_DIR/.gc/cleanup-research-backlog.lock"
exec 8>"$LOCK"
if command -v flock >/dev/null && ! flock -n 8; then
  echo "$TS  cleanup-research-backlog  skipped-overlap" >> "$LOG"
  exit 0
fi

log() {
  printf '%s  cleanup-research-backlog  %s\n' "$TS" "$*" >> "$LOG"
}

close_completed_curator_roots() {
  timeout 15s gc bd list --status open --has-metadata-key gc.routed_to --sort updated --reverse --limit 500 --json 2>/dev/null \
    | jq -r '
      .[]
      | select((.metadata["gc.routed_to"] // "") == "curator-decider")
      | select((.title // "") == "curator-decide")
      | .id
    ' | while read -r root; do
      [ -n "$root" ] || continue
      step="$root.1"
      step_status="$(gc bd show "$step" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null || true)"
      case "$step_status" in
        closed)
          if gc bd close "$root" --reason "cleanup: curator-decide step already closed" >/dev/null 2>&1; then
            log "closed-curator-root  $root"
          fi
          ;;
      esac
    done
}

normalize_open_proposals() {
  timeout 15s gc bd list --label kind:proposal --status open --sort updated --reverse --limit 500 --json 2>/dev/null \
    | jq -r '
      .[]
      | [
          .id,
          (.title // ""),
          ((.labels // []) | join(",")),
          (.metadata["gc.rig"] // ""),
          (.metadata["gc.parent_run"] // ""),
          (.metadata["gc.lineage_root"] // ""),
          (.metadata["gc.promoted_to"] // ""),
          (.metadata["gc.decision"] // "")
        ] | @tsv
    ' | while IFS=$'\t' read -r id title labels rig parent lineage promoted_to decision; do
      [ -n "$id" ] || continue

      # Promoted proposal beads are terminal bookkeeping. Leaving them open makes
      # the curator see already-launched work as candidate backlog.
      if [[ ",$labels," == *",status:promoted,"* ]] && [ "$decision" != "promoted" ] && [ -z "$promoted_to" ]; then
        gc bd update "$id" --remove-label status:promoted >/dev/null 2>&1 || true
        log "removed-bogus-promoted-label  $id"
        labels="$(printf '%s' "$labels" | sed 's/status:promoted//g; s/,,*/,/g; s/^,//; s/,$//')"
      fi

      if [ "$decision" = "promoted" ] || [ -n "$promoted_to" ]; then
        gc bd update "$id" \
          --remove-label status:pending \
          --remove-label status:dispatching \
          --add-label status:promoted >/dev/null 2>&1 || true
        gc bd close "$id" --reason "cleanup: proposal already promoted${promoted_to:+ to $promoted_to}" >/dev/null 2>&1 || true
        log "closed-promoted-proposal  $id  promoted_to=${promoted_to:-unknown}"
        continue
      fi

      # Held or failed proposals should not also be pending. That contradictory
      # state causes repeated redispatch attempts.
      if [[ ",$labels," == *",status:held,"* ]] || [[ ",$labels," == *",status:promotion-failed,"* ]]; then
        if [[ ",$labels," == *",status:pending,"* ]] || [[ ",$labels," == *",status:dispatching,"* ]]; then
          gc bd update "$id" --remove-label status:pending --remove-label status:dispatching >/dev/null 2>&1 || true
          log "removed-transient-from-held-or-failed  $id"
        fi
      fi

      # Current MJX priority is G1 motion tracking. Old proxy ball/pendulum
      # proposals should stay held, not keep competing with G1 work.
      if printf '%s\n' "$title" | grep -Eiq '(^|[^[:alnum:]])(ball|pendulum|cartpole|proxy)([^[:alnum:]]|$)'; then
        gc bd update "$id" \
          --remove-label status:pending \
          --remove-label status:dispatching \
          --add-label status:held \
          --set-metadata gc.decision=operator-held-proxy \
          --set-metadata "gc.decision_reason=cleanup held off-priority proxy task; current mjx priority is G1 motion tracking" >/dev/null 2>&1 || true
        log "held-off-priority-proxy  $id"
        continue
      fi

      # `bl-269ht99` accepted solver_iters=4/2 for lineage bl-76mzves. Old
      # pending same-lineage proposals from earlier parents that chase NaN or
      # stale LR/horizon variants should be skipped instead of replayed.
      if [ "$lineage" = "bl-76mzves" ] && [ "$parent" != "bl-269ht99" ]; then
        if [[ ",$labels," == *",status:pending,"* ]] && printf '%s\n' "$title" | grep -Eiq 'NaN|gradient smoothing|low-lr|warmup|cosine|delayed|batch|h200|10k|10000|lr=3e-4|random-start'; then
          meta="$(jq -n \
            --arg match "bl-269ht99" \
            --arg reason "cleanup skipped stale pre-accepted proposal; bl-269ht99 established solver_iters 4/2 as the current lineage baseline" \
            '{"gc.decision":"skipped-stale-lineage","gc.dedup_match":$match,"gc.decision_reason":$reason}')"
          gc bd update "$id" \
            --metadata "$meta" \
            --remove-label status:pending \
            --remove-label status:dispatching \
            --add-label status:skipped-stale-lineage \
            --add-label status:dead-end >/dev/null 2>&1 || true
          gc bd close "$id" --reason "cleanup: stale behind accepted bl-269ht99" >/dev/null 2>&1 || true
          log "closed-stale-lineage-proposal  $id  accepted=bl-269ht99"
        fi
      fi
    done
}

close_completed_curator_roots
normalize_open_proposals

exit 0
