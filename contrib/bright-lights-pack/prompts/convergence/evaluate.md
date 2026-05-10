# Convergence Evaluate — evaluate-idea loop

You are the evaluate step of a convergence loop. The wisp just closed. Your
job is to read `review.md`, extract the reviewer's verdict, and record it as
`convergence.agent_verdict` so the gate can decide whether to iterate or stop.

You do NOT re-review. The reviewer already did that. You are translating
their verdict from `ACCEPTED / REJECTED / NEEDS_TAKARA` into convergence
vocabulary: `approve / approve-with-risks / block`.

## Locate the review file

The convergence root bead ID is in `GC_BEAD_ID`. The rig from the formula var
is in `$rig` (or check the run.json).

```bash
ROOT="${GC_BEAD_ID}"
# Find the rig by walking children (or use the metadata). Simplest:
# the run dir lives at results/run-<ROOT> in exactly one rig under ~/projects/.
for r in /home/ubuntu/projects/*/results/run-"$ROOT"; do
  [ -d "$r" ] && RUN_DIR="$r" && break
done
```

If `RUN_DIR` isn't found, that's a fatal inconsistency — set verdict to `block`
and exit (the gate will iterate or max-out; a human will look).

## Read the reviewer's VERDICT line

```bash
if [ ! -f "$RUN_DIR/review.md" ]; then
  echo "no review.md — block"
  bd meta set "$GC_BEAD_ID" convergence.agent_verdict block
  exit 0
fi

REVIEWER_VERDICT=$(grep -E '^VERDICT:' "$RUN_DIR/review.md" | tail -1 | awk '{print $2}')
```

## Translate to convergence verdict

Mapping:
- `ACCEPTED` → `approve`
- `NEEDS_TAKARA` → `approve-with-risks` (loop terminates, human takes it from here; the "risks" flag signals to the operator that this needs attention)
- `REJECTED` → `block` (loop iterates)
- Anything else → `block` (defensive)

```bash
case "$REVIEWER_VERDICT" in
  ACCEPTED)     CONV_VERDICT=approve ;;
  NEEDS_TAKARA) CONV_VERDICT=approve-with-risks ;;
  REJECTED)     CONV_VERDICT=block ;;
  *)            CONV_VERDICT=block ;;
esac
```

## Record the verdict

This is the line convergence reads. Use `bd meta set` exactly as shown:

```bash
bd meta set "$GC_BEAD_ID" convergence.agent_verdict "$CONV_VERDICT"
```

That write is what the gate condition script will read as `GC_AGENT_VERDICT`.

## Done

Print a one-line summary to stdout (for the iteration audit trail), then exit
0. Do not edit any other file. Do not close any bead.

```bash
echo "iter=${GC_ITERATION} reviewer=${REVIEWER_VERDICT:-none} convergence=${CONV_VERDICT}"
```
