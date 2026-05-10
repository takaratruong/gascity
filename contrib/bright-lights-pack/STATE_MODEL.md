# Gas City State Model

This city follows Gas City's documented primitive model:

- Beads are the durable domain state.
- Events are append-only observations in the Event Bus.
- Mail is conversation and is implemented as message beads.
- Formulas and orders are workflow definitions.
- Files under run directories are artifacts.
- Logs are diagnostics.

Do not add a new registry when labels, metadata, mail, formulas, orders, or
events already represent the concept.

## Bead Labels

Use labels for coarse grouping:

- `kind:directive` - operator steering that may affect future behavior
- `kind:policy` - durable behavior rule
- `kind:proposal` - curator input
- `kind:synthesis` - thread summary bead
- `kind:artifact-index` - index bead for run artifacts
- `kind:control` - operator control such as curator pause
- `kind:maintenance` - Gas City self-maintenance and reliability work

Do not use `kind:event`; operational observations belong in `gc event emit`
and are read through `gc events`.

## Metadata

Use `gc.*` metadata for structured state. Followups must include:

- `gc.rig`
- `gc.proposal_idea_desc`
- `gc.parent_run`
- `gc.lineage_root`
- `gc.thread_id`
- `gc.followup_kind=same-thread|new-thread|bugfix|cross-thread`
- `gc.method_family` or `gc.research_lane` for method/lane throttling

Thread fields:

- `gc.lineage_root` is causal ancestry.
- `gc.thread_id` is conceptual topic grouping.
- `gc.parent_run` is the immediate parent.
- `gc.followup_kind` explains how a proposal relates to its thread.

Directive lifecycle:

- `gc.directive_status=active`
- `gc.directive_status=answered`
- `gc.directive_status=promoted-to-policy`
- `gc.directive_status=superseded`

Mayor chat directives are operator messages recorded as beads. When a mayor
answers one in mail, it must update the matching directive bead from
`gc.directive_status=active` to `gc.directive_status=answered` and move the
label from `status:active` to `status:answered`. If the directive becomes a
standing behavioral rule, create or update a `kind:policy` bead and mark the
directive `gc.directive_status=promoted-to-policy`.

Rig-mayor synthesis:

- `kind:synthesis`
- `gc.synthesis_scope=rig_mayor`
- `gc.synthesis_id=<rig>-mayor`
- `gc.rig=<rig>`
- `gc.rig_mayor=<mayor>`

There should be one open rig-mayor synthesis bead per rig. Topic/thread
synthesis beads may exist for compatibility, but the mayor conversation is the
operator-facing thread and the rig-mayor synthesis is the durable cross-run
memory.

Policy enforcement metadata:

- `gc.policy.match_regex`
- `gc.policy.reject_regex`
- `gc.policy.reject_reason`
- `gc.policy.require_media=true`
- `gc.policy.required_artifact_exts=mp4,webm,gif,png,jpg,jpeg`

Artifact index metadata:

- `gc.kind=artifact_index`
- `gc.run_id`
- `gc.thread_id`
- `gc.rig`
- `gc.run_dir`
- `gc.verdict`
- optional `gc.artifact_missing=media`

Curator control metadata:

- `gc.control_type=curator_pause`
- `gc.pause_scope=city|rig`
- `gc.rig=<rig>` for rig scope
- `gc.pause_hard=true|false`
- `gc.reason=<reason>`

Curator hold metadata:

- `gc.active_sibling=<convergence-id>` for one-active-child-per-parent holds
- `gc.active_method_sibling=<convergence-id>` for one-active-run-per-method holds
- `gc.method_family=<lane>` / `gc.research_lane=<lane>`

## Events

Emit only state-changing operational events:

- `curator.dispatched-decide`
- `curator.repaired-stale-dispatching`
- `curator.sling-failed`
- `curator.labeled-accepted`
- `curator.labeled-dead-end`
- `curator.labeled-operator-stopped`
- `curator_decide.held`
- `curator_decide.operator-rejected`
- `curator_decide.skipped-dedup`
- `curator_decide.promoted`
- `curator_decide.promotion-failed`
- `maintenance.canary_failed`

Pause skip ticks and overlap skips stay in `curator.log`.
