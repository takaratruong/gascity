import { useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useDash } from '../store';
import { listBeads, listMail, beadBelongsToRig, curatorStatus, subscribeEvents, type Bead, type MailItem } from '../api';

// Kanban columns over research runs. The mayor conversation is the persistent
// research thread; this page is the queue/result board for Beads that the mayor
// and workers create.
type Column = 'needs' | 'running' | 'done' | 'blocked';

export default function ThreadsPage() {
  const { city, rig } = useDash();
  const [roots, setRoots] = useState<Bead[]>([]);
  const [allConvs, setAllConvs] = useState<Bead[]>([]);
  const [mail, setMail] = useState<MailItem[]>([]);
  const [curatorPaused, setCuratorPaused] = useState(false);
  const [showInfraStale, setShowInfraStale] = useState(false);
  const [loading, setLoading] = useState(true);

  async function refresh() {
    setLoading(true);
    try {
      const [openBeads, accepted, deadEnd, stopped, mailItems, curator] = await Promise.all([
        listBeads(city, { status: 'open', limit: 500, all: true }),
        listBeads(city, { label: 'status:accepted', limit: 300 }),
        listBeads(city, { label: 'status:dead-end', limit: 300 }),
        listBeads(city, { label: 'status:operator-stopped', limit: 300 }),
        listMail(city),
        curatorStatus(),
      ]);
      setCuratorPaused(Boolean(curator.soft || curator.hard));
      const all = dedup([...openBeads, ...accepted, ...deadEnd, ...stopped]);
      // Scope to current rig using multi-signal affinity (see beadBelongsToRig).
      const scoped = all.filter((b) => beadBelongsToRig(b, rig));
      // Mail is filtered too — keep mail that mentions any in-scope bead id.
      const scopedIds = new Set(scoped.map((b) => b.id));
      const scopedMail = mailItems.filter((m) => {
        if (scopedIds.has(m.id)) return true;
        const h = (m.subject ?? '') + '\n' + (m.body ?? '');
        for (const id of scopedIds) if (h.includes(id)) return true;
        return false;
      });
      // Only convergence beads as nodes
      const convs = scoped.filter((b) => b.issue_type === 'convergence');
      // Roots: top-level research runs. `gc.thread_id` remains an internal
      // compatibility grouping key, but the user-facing thread is the rig
      // mayor conversation.
      // EXCLUDE retries — a convergence with gc.retry_of is a rerun of some
      // other root; showing it as its own thread creates confusing duplicates.
      // The original (retry_of target) already represents that idea on the
      // board, and its ThreadPage banner auto-surfaces the active retry.
      const rootSet = convs.filter((b) => {
        if (b.metadata?.['gc.retry_of']) return false;
        const tid = b.metadata?.['gc.thread_id'];
        const role = b.metadata?.['gc.thread_role'];
        if (role === 'root') return true;
        if (tid && tid === b.id) return true;
        if (tid && tid !== b.id) return false;
        const r = b.metadata?.['gc.lineage_root'];
        const d = b.metadata?.['gc.lineage_depth'];
        if (!r && !d) return true;
        if (r === b.id) return true;
        if (d === '0' || d === 0) return true;
        return false;
      });
      setRoots(rootSet);
      setAllConvs(convs);
      setMail(scopedMail);
    } catch (err) { console.error(err); }
    finally { setLoading(false); }
  }

  // Refresh strategy: initial load + event-driven reload on any convergence/
  // mail/bead event. Fall back to a slow poll (60s) so we recover even if
  // the event stream drops. Debounce bursty event floods to 500ms.
  const reloadPending = useRef(false);
  function scheduleRefresh() {
    if (reloadPending.current) return;
    reloadPending.current = true;
    setTimeout(() => { reloadPending.current = false; refresh(); }, 500);
  }
  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 60000); // safety net only
    const unsub = subscribeEvents(city, (e) => {
      // Any event that could change a thread's column classification.
      const interesting = (
        e.type.startsWith('bead.') ||
        e.type.startsWith('mail.') ||
        e.type.startsWith('convergence.') ||
        e.type.startsWith('message.')
      );
      if (interesting) scheduleRefresh();
    });
    return () => { clearInterval(t); unsub(); };
  }, [city, rig]);

  // Classify each root into a column
  const visibleRoots = useMemo(
    () => roots.filter((b) => showInfraStale || shouldShowThreadByDefault(b, rig)),
    [roots, rig, showInfraStale],
  );

  const classified = useMemo(() => {
    const cols: Record<Column, Bead[]> = { needs: [], running: [], done: [], blocked: [] };
    for (const b of visibleRoots) {
      const labels = b.labels ?? [];
      // If there's an ACTIVE retry of this bead, the thread is still running
      // regardless of the original's labels. Check first so an accepted/
      // rejected original doesn't land in Done while its retry runs.
      const threadId = b.metadata?.['gc.thread_id'] ?? b.id;
      const hasActiveThreadRun = allConvs.some(
        (c) =>
          c.id !== b.id &&
          (c.metadata?.['gc.thread_id'] ?? c.id) === threadId &&
          (c.status === 'open' || c.status === 'in_progress'),
      );
      const hasActiveRetry = allConvs.some(
        (c) => c.metadata?.['gc.retry_of'] === b.id &&
               (c.status === 'open' || c.status === 'in_progress'),
      );
      // Column priority:
      //   1. active retry → running (supersedes original's terminal state)
      //   2. accepted / dead-end → done / blocked (final; ignore stale mail)
      //   3. unanswered question from mayor → needs (catches post-stop
      //      escalations — operator-stopped is often "paused for a decision",
      //      not "done forever", and the question is still the point)
      //   4. operator-stopped with no live question → blocked
      //   5. open / in-progress → running
      if (hasActiveRetry || hasActiveThreadRun) cols.running.push(b);
      else if (isAccepted(labels)) cols.done.push(b);
      else if (isDeadEnd(labels)) cols.blocked.push(b);
      else if (needsAttention(b, mail, allConvs, curatorPaused)) cols.needs.push(b);
      else if (isStopped(labels)) cols.blocked.push(b);
      else if (b.status === 'open' || b.status === 'in_progress') cols.running.push(b);
      else cols.done.push(b); // fallback
    }
    // Sort each by most recently updated
    for (const k of Object.keys(cols) as Column[]) {
      cols[k].sort((a, b) => (b.updated_at ?? '').localeCompare(a.updated_at ?? ''));
    }
    return cols;
  }, [visibleRoots, mail, allConvs, curatorPaused]);

  return (
    <>
      <h1>Research Runs</h1>
      <p className="dim" style={{ fontSize: 12, marginBottom: 16 }}>
        The rig mayor conversation is the persistent research thread. This board shows the runs,
        proposals, and results created under that mayor, grouped by status.
      </p>
      {rig === 'park-manip' && (
        <label className="dim" style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, marginBottom: 12 }}>
          <input
            type="checkbox"
            checked={showInfraStale}
            onChange={(e) => setShowInfraStale(e.target.checked)}
          />
          Show infra/stale park-manip runs
        </label>
      )}
      {loading && visibleRoots.length === 0 && <div className="empty">Loading…</div>}
      {!loading && visibleRoots.length === 0 && <div className="empty">No research runs yet. Ask the mayor to start one.</div>}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12 }}>
        <ColumnView title="Needs your input" color="#fbbf24" beads={classified.needs} emptyHint="nothing waiting" />
        <ColumnView title="Running" color="#60a5fa" beads={classified.running} emptyHint="nothing active" />
        <ColumnView title="Done" color="#34d399" beads={classified.done} emptyHint="no accepted runs" />
        <ColumnView title="Blocked / dead-end" color="#9ca3af" beads={classified.blocked} emptyHint="none" />
      </div>
    </>
  );
}

function ColumnView({ title, color, beads, emptyHint }: { title: string; color: string; beads: Bead[]; emptyHint: string }) {
  return (
    <div style={{ minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8, paddingBottom: 6, borderBottom: `2px solid ${color}` }}>
        <span style={{ fontWeight: 600, fontSize: 12, color }}>{title}</span>
        <span className="dim" style={{ fontSize: 11 }}>({beads.length})</span>
      </div>
      {beads.length === 0 ? (
        <div className="dim" style={{ fontSize: 11, padding: '12px 4px' }}>{emptyHint}</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {beads.map((b) => <ThreadCard key={b.id} bead={b} accent={color} />)}
        </div>
      )}
    </div>
  );
}

function ThreadCard({ bead, accent }: { bead: Bead; accent: string }) {
  const terminal = bead.metadata?.['convergence.terminal_reason'] as string | undefined;
  const iter = bead.metadata?.['convergence.iteration'];
  const maxIter = bead.metadata?.['convergence.max_iterations'];
  const method = methodLabel(bead);
  const verdictText = terminal
    ? terminal.replace('no_convergence', 'REJECTED').replace('approved', 'ACCEPTED').replace('stopped', 'STOPPED')
    : (iter !== undefined ? `iter ${iter}/${maxIter ?? '?'}` : '');

  return (
    <Link to={`/thread/${bead.id}`} style={{ textDecoration: 'none', color: 'inherit' }}>
      <div style={{
        background: 'var(--bg-2)',
        border: '1px solid var(--border)',
        borderLeft: `3px solid ${accent}`,
        borderRadius: 4,
        padding: '9px 11px',
        cursor: 'pointer',
      }}>
        <div style={{ fontSize: 12, fontWeight: 500, lineHeight: 1.3 }}>
          {bead.title}
        </div>
        <div style={{ marginTop: 5, display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
          <span className="mono" style={{ fontSize: 10, color: 'var(--fg-dim)' }}>{bead.id}</span>
          <span className="dim" style={{ fontSize: 10 }}>{verdictText}</span>
        </div>
        {method && (
          <div className="dim" style={{ marginTop: 4, fontSize: 10 }}>
            lane: {method}
          </div>
        )}
      </div>
    </Link>
  );
}

function methodLabel(bead: Bead): string {
  const md = bead.metadata ?? {};
  const explicit = md['gc.method_family'] ?? md['gc.research_lane'];
  if (explicit) return String(explicit);
  const idea = md['var.idea'] ?? md['gc.proposal_idea_desc'];
  if (idea) return String(idea).slice(0, 48);
  return '';
}

// ── Classification helpers

function isAccepted(labels: string[]): boolean { return labels.includes('status:accepted'); }
function isDeadEnd(labels: string[]): boolean { return labels.includes('status:dead-end'); }
function isStopped(labels: string[]): boolean { return labels.includes('status:operator-stopped'); }

function shouldShowThreadByDefault(bead: Bead, rig: string): boolean {
  if (rig !== 'park-manip') return true;

  const title = bead.title ?? '';
  const md = bead.metadata ?? {};
  const labels = bead.labels ?? [];
  const threadId = md['gc.thread_id'] as string | undefined;
  const target = (md['convergence.target'] as string | undefined) ?? '';

  // The active research topic the user actually asked for.
  if (threadId === 'bl-au1p69') return true;

  // Historical evidence that should stay visible as successful baselines.
  if (['bl-k56u8', 'bl-fpwbb'].includes(bead.id)) return true;

  // Keep method-level scene-aware research visible. Hide replay/render/GPU/
  // camera/gating cleanup by default; it can still be shown with the checkbox.
  if (/narrow[_\s-]?hallway|scene-aware|kimodo|cma-?es|guidance|waypoint|sidestep|clutter|obstacle/i.test(title)) {
    return true;
  }

  // Old generic mayor roots are mostly pre-coordinator infrastructure debris.
  if (target === 'mayor' || target === 'park-mayor') return false;
  if (labels.includes('status:operator-stopped')) return false;

  return true;
}

function needsAttention(bead: Bead, allMail: MailItem[], allBeads: Bead[], curatorPaused: boolean): boolean {
  // Heuristic: a thread needs input if it's terminated with NEEDS_TAKARA
  // AND curator is paused (human has taken over), OR if there's unanswered
  // mail to the human that references it.
  //
  // With curator running, NEEDS_TAKARA is NOT a reason to flag attention —
  // the formula auto-fires followups and curator keeps the loop going.
  // Only when the human pauses curator does NEEDS_TAKARA become a halt.
  //
  // EXCEPTION: if there's an active retry of this bead, a rerun is in
  // flight — don't flag.
  const hasActiveRetry = allBeads.some(
    (b) =>
      b.issue_type === 'convergence' &&
      b.metadata?.['gc.retry_of'] === bead.id &&
      (b.status === 'open' || b.status === 'in_progress'),
  );
  if (hasActiveRetry) return false;

  const termReason = bead.metadata?.['convergence.terminal_reason'];
  const gateStdout = (bead.metadata?.['convergence.gate_stdout'] as string) ?? '';
  if (gateStdout.includes('NEEDS_TAKARA') && curatorPaused) return true;
  if (termReason === 'escalated') return true;

  // Unanswered mail to 'human' that's specifically about this bead.
  // "About this bead" = the bead id is in the subject line (mayor's
  // escalation mails follow `ESCALATION: bl-xxx ...` / `NEEDS_TAKARA: bl-xxx
  // ...` conventions). Body mentions don't count — mayor status replies
  // list many bead ids in prose and would falsely flag every one.
  const threadMail = allMail.filter((m) => {
    if (m.to !== 'human') return false;
    return (m.subject ?? '').includes(bead.id);
  });
  for (const m of threadMail) {
    if ((m.labels ?? []).includes('read')) continue;
    // Check if there's a human reply after this mail in the same thread
    const threadLabel = (m.labels ?? []).find((l) => l.startsWith('thread:'));
    if (threadLabel) {
      const humanReplyAfter = allMail.some((r) =>
        r.from === 'human' &&
        (r.labels ?? []).includes(threadLabel) &&
        (r.created_at ?? '') > (m.created_at ?? ''),
      );
      if (humanReplyAfter) continue;
    }
    return true;
  }
  return false;
}

function dedup(beads: Bead[]): Bead[] {
  const seen = new Set<string>();
  return beads.filter((b) => { if (seen.has(b.id)) return false; seen.add(b.id); return true; });
}
