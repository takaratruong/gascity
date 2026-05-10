#!/usr/bin/env bash
# Tear down everything gen_stress.sh created. Deletes every bead labeled
# kind:test-stress plus any orphan mail referencing stress titles.

set -euo pipefail
cd "$HOME/bright-lights"

STRESS_IDS=$(gc bd list --label kind:test-stress --all --json 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); items=d if isinstance(d,list) else d.get('items',[]); print(' '.join(b['id'] for b in items))")

if [ -n "$STRESS_IDS" ]; then
  echo "deleting $(echo $STRESS_IDS | wc -w) stress beads…"
  bd delete $STRESS_IDS --force 2>&1 | tail -3
else
  echo "no kind:test-stress beads found"
fi

# Belt-and-suspenders: mail beads that slipped past the label (e.g. mail
# sent before the script's --from fix) are caught by subject substring.
ORPHAN_MAIL=$(gc bd list --type message --all --json 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); items=d if isinstance(d,list) else d.get('items',[]); print(' '.join(b['id'] for b in items if 'stress' in (b.get('title') or '').lower()))")

if [ -n "$ORPHAN_MAIL" ]; then
  echo "deleting $(echo $ORPHAN_MAIL | wc -w) orphan stress mail…"
  bd delete $ORPHAN_MAIL --force 2>&1 | tail -3
fi

# Flush supervisor mail cache so the dashboard updates immediately.
gc supervisor reload >/dev/null 2>&1 || true
echo "done."
