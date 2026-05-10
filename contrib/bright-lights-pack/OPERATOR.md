# Operator controls

Quick reference for intervening in the autonomous research loop.
Durable state conventions are defined in `STATE_MODEL.md`.

## Pause curator (new work)

```bash
# Soft pause — finishes in-flight runs, just stops slinging NEW ones.
# Dead-end labeling still happens so memory stays current.
gc bd create "control: pause curator" \
  --type task \
  --labels kind:control,control:curator,status:active \
  --metadata '{"gc.control_type":"curator_pause","gc.pause_scope":"city","gc.pause_hard":"false","gc.reason":"operator pause","gc.created_by":"operator"}'

# Resume:
gc bd list --label kind:control --status open --json | jq -r '.[] | select(.metadata["gc.control_type"]=="curator_pause") | .id'
gc bd close <control-bead-id> --reason "operator resumed"
```

## Hard pause (full freeze)

```bash
# Curator does NOTHING: no slings, no labeling sweep, no mail processing.
# Use this when you want zero curator activity while you investigate.
gc bd create "control: hard pause curator" \
  --type task \
  --labels kind:control,control:curator,status:active \
  --metadata '{"gc.control_type":"curator_pause","gc.pause_scope":"city","gc.pause_hard":"true","gc.reason":"operator hard pause","gc.created_by":"operator"}'

# Resume:
gc bd close <control-bead-id> --reason "operator resumed"
```

## Pause one rig

```bash
gc bd create "control: pause park-manip curator promotions" \
  --type task \
  --labels kind:control,control:curator,status:active \
  --metadata '{"gc.control_type":"curator_pause","gc.pause_scope":"rig","gc.rig":"park-manip","gc.pause_hard":"false","gc.reason":"operator rig pause","gc.created_by":"operator"}'
```

## Message / redirect the curator

```bash
# Dashboard mayor/curator chat creates kind:directive beads automatically.
# CLI mail is conversational; create a directive bead for durable steering.
gc mail send curator "Please focus on root-guidance variants for now; ignore CMA-es replacements."
gc bd create "directive: curator skip inaccessible HF repos" \
  --type decision \
  --labels kind:directive,source:operator,status:active \
  --metadata '{"gc.kind":"operator_directive","gc.directive_to":"curator","gc.directive_status":"active","gc.source":"operator_cli"}' \
  --description "Skip any proposal that mentions Meta-Llama; we cannot access that HF repo."
```

## Promote a directive to policy

```bash
gc bd create "policy: <short rule>" \
  --type decision \
  --labels kind:policy,source:operator,status:active,rig:park-manip \
  --metadata '{"gc.kind":"operator_policy","gc.rig":"park-manip","gc.policy.match_regex":"<when this applies>","gc.policy.reject_regex":"<forbidden proposal regex>","gc.policy.reject_reason":"<short reason>"}' \
  --description "<human-readable policy>"

gc bd update <directive-id> \
  --set-metadata gc.directive_status=promoted-to-policy \
  --set-metadata gc.promoted_policy=<policy-id> \
  --remove-label status:active \
  --add-label status:promoted-to-policy
```

## Hold a specific proposal (don't promote it)

```bash
# Find the proposal bead, apply status:held. Curator will skip it.
gc bd list --label kind:proposal --status open
gc bd update <proposal-id> --add-label status:held
# To release:
gc bd update <proposal-id> --remove-label status:held
```

## Stop a single convergence loop

```bash
# Any root you want to kill mid-flight:
gc converge stop <convergence-root-id>
```

## Seed a new root idea

```bash
# The very first idea in a lineage. Curator will chain followups from here.
cd /home/ubuntu/bright-lights
gc converge create \
  --formula evaluate-idea \
  --target park-manip/workers.coordinator \
  --gate condition \
  --gate-condition prompts/convergence/gate.sh \
  --max-iterations 3 \
  --title "<short title>" \
  --var idea="<short title>" \
  --var idea_description="<full spec: scope + acceptance + files>" \
  --var rig="park-manip"
```

Use `--target mjx-diffphysics/workers.coordinator` with `--var rig="mjx-diffphysics"` for the MJX rig.
Do not seed new work with `--target mayor`; the generic mayor is legacy-only.

Preferred local helper, which also routes iteration 1 and stamps thread metadata:

```bash
assets/scripts/convergence/create_evaluate_idea.sh \
  --title "<short title>" \
  --idea-description "<full spec: scope + acceptance + files>" \
  --rig "park-manip" \
  --max-iterations 3
```

## See what's running

```bash
gc session list                              # which agents are up
gc converge list                             # active convergence loops
gc bd list --label kind:proposal --status open   # queued proposals
gc bd list --label status:accepted --limit 20    # accepted runs
gc bd list --label status:dead-end --limit 20    # dead ends
gc bd list --label kind:synthesis --limit 20     # thread summaries
gc events --type curator.dispatched-decide --since 1h  # event bus
tail -50 /home/ubuntu/bright-lights/curator.log   # diagnostics only
```

## Lineage view

```bash
# Every run in lineage rooted at <root-id>:
gc bd list --metadata-field "gc.lineage_root=<root-id>"

# A run's depth and lineage root:
gc bd show <root-id> --json | jq '.[0].metadata | {root: ."gc.lineage_root", depth: ."gc.lineage_depth", parent: ."gc.parent_run"}'
```

## GPU status

```bash
# Which GPUs are claimed and by which PID:
ls ~/.gc/gpu-locks/*.pid 2>/dev/null | while read f; do
  gpu=$(basename "$f" | sed 's/gpu-//;s/\.lock\.pid//')
  pid=$(cat "$f")
  ps -p "$pid" -o cmd= 2>/dev/null || echo "stale"
  echo "  gpu $gpu = pid $pid"
done
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
```
