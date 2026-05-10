# Research Threads

This directory holds human-readable synthesis for conceptual research topics.
Beads remain the registry and source of truth; these markdown files are memory
artifacts that mayors update before filing followups.

Metadata contract:

- `gc.lineage_root`: direct experiment ancestry.
- `gc.thread_id`: conceptual topic id. Usually the root convergence id.
- `gc.thread_role`: `root` for the topic root, `experiment` for child runs.
- `gc.parent_thread_id`: set when a substantially different idea spawns a new
  thread from an existing one.
- `gc.followup_kind`: `same-thread`, `new-thread`, `bugfix`, or `cross-thread`.
- Method families should usually be separate threads. For example, co-location,
  SHAC, and ASHAC are different conceptual threads even when tested on the same
  task or environment.
- `gc.result_class`: one of `ACCEPTED_RESEARCH_SIGNAL`,
  `NEGATIVE_RESEARCH_SIGNAL`, `IMPLEMENTATION_BUG`, `REVIEWER_BLOCKED`,
  `INFRA_BLOCKED`, `SPEC_AMBIGUOUS`.
- `gc.global_learning=true`: this run produced a reusable fix or lesson.
- `gc.learning_summary`: short description of that reusable learning.

Expected files per thread:

- `synthesis.md`: current state, facts, dead ends, best run, open questions,
  reusable learnings.
- `decision_log.md`: chronological why-we-chose-this-next-step entries.
