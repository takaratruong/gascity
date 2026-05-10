import { useEffect, useMemo, useRef, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import Md from '../components/Md';
import HeartbeatStrip from '../components/HeartbeatStrip';
import { useDash } from '../store';
import { useThreadEvents } from '../hooks/useThreadEvents';
import {
  beadGraph, beadComments, readFile, listMail, listBeads, listBeadsByType,
  convergeStop, mailReply, mayorChat, getBead,
  type Bead, type BdComment, type MailItem, type ExecResult,
} from '../api';

// Narrative view of a run lineage: top banner = where this idea is right now,
// feed = significant events (seed/verdict/your replies/agent mail/branches),
// branches = inline expandable groups when a run fans out into followups.

function relTs(s?: string): string {
  if (!s) return '';
  const d = new Date(s);
  const delta = Date.now() - d.getTime();
  if (delta < 60_000) return 'just now';
  if (delta < 3600_000) return Math.floor(delta / 60_000) + 'm ago';
  if (delta < 86400_000) return Math.floor(delta / 3600_000) + 'h ago';
  return Math.floor(delta / 86400_000) + 'd ago';
}
function runDir(rig: string, bead: Bead | string): string {
  // Prefer the worktree path stashed by the init-run step; fall back to the
  // shared rig checkout for legacy runs that predate worktree isolation.
  if (typeof bead !== 'string') {
    const activeWisp = bead.metadata?.['convergence.active_wisp'] as string | undefined;
    const beadRig = (bead.metadata?.['var.rig'] || bead.metadata?.['gc.rig'] || rig) as string;
    const wt = (bead.metadata?.['gc.worktree_dir'] as string | undefined) ||
      (activeWisp ? `/home/ubuntu/worktrees/${beadRig}/${activeWisp}` : undefined);
    if (wt) return `${wt}/results/run-${activeWisp ?? bead.id}`;
    return `/home/ubuntu/projects/${rig}/results/run-${bead.id}`;
  }
  return `/home/ubuntu/projects/${rig}/results/run-${bead}`;
}

const ROUTINE_MAIL_PATTERNS = [
  /^dog[_\s-]?done/i,
  /^review complete/i,
  /^advance convergence/i,
  /^convergence terminated/i,
  /^new test bead/i,
  /^wake and work/i,
  /^ping/i,
  /^curator-decide/i,
  /^new convergence/i,
  /^retry test/i,
  /^autoloop/i,
];
function isRoutineMail(m: MailItem): boolean {
  const s = m.subject ?? '';
  return ROUTINE_MAIL_PATTERNS.some((r) => r.test(s));
}

// A "significant" event on the feed. We intentionally DON'T show every
// plan-dispatch / impl-dispatch / review-dispatch step bead — those collapse
// into the parent convergence's verdict. Keep the story readable.
type FeedEvt =
  | { kind: 'seed'; ts: string; bead: Bead }
  | { kind: 'verdict'; ts: string; bead: Bead; verdict: string; reviewExcerpt?: string }
  | { kind: 'branches'; ts: string; parentBead: Bead; proposals: Bead[]; promoted: Bead[]; skipped: Bead[] }
  | { kind: 'mail'; ts: string; mail: MailItem }
  | { kind: 'comment'; ts: string; beadId: string; author: string; body: string }
  | { kind: 'terminated'; ts: string; bead: Bead }
  | { kind: 'progress'; ts: string; convergenceBead: Bead; iteration: number; steps: Bead[] }
  | { kind: 'retry'; ts: string; bead: Bead; retryOf: string; reason: string };

export default function ThreadPage() {
  const { rootId } = useParams<{ rootId: string }>();
  const { city, rig, setSelectedBead, setBeadListPanel } = useDash();

  // Auto-select the run root on navigation so the artifact panel has
  // something to show. Users can click other convergences to re-scope.
  useEffect(() => {
    if (rootId) setSelectedBead(rootId);
  }, [rootId, setSelectedBead]);

  const [beads, setBeads] = useState<Bead[]>([]);
  const [comments, setComments] = useState<Record<string, BdComment[]>>({});
  const [verdicts, setVerdicts] = useState<Record<string, string>>({});
  const [reviewExcerpts, setReviewExcerpts] = useState<Record<string, string>>({});
  const [mail, setMail] = useState<MailItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [hideNoisyComments, setHideNoisyComments] = useState(true);

  // reply state keyed by target (bead id or mail id)
  const [reply, setReply] = useState<{ targetKind: 'convergence' | 'mail' | 'followup' | 'root' | 'mayor_direct'; targetId: string; body: string; sending?: boolean; result?: ExecResult } | null>(null);

  async function load() {
    if (!rootId) return;
    setLoading(true);
    try {
      // Native gascity: beads graph (root + all descendants in one call).
      const graph = await beadGraph(city, rootId);
      const all: Bead[] = [graph.root, ...(graph.beads ?? [])];
      const threadId = graph.root.metadata?.['gc.thread_id'] ?? rootId;
      const threadBeads = threadId
        ? await listBeads(city, { metadataField: `gc.thread_id=${threadId}`, limit: 500 }).catch(() => [] as Bead[])
        : [];

      // Also pull retries of the root — they have their own graphs. We find
      // them by scanning every open/closed convergence whose gc.retry_of
      // metadata points at any id in `all`. That's a small scan (convergences
      // are the root of each thread and there are usually few).
      const lineageSet = new Set(all.map((b) => b.id));
      const allConvs = await listBeadsByType(city, 'convergence', 500).catch(() => [] as Bead[]);
      const retryIds = allConvs
        .filter((c) => {
          const rid = c.metadata?.['gc.retry_of'];
          return typeof rid === 'string' && lineageSet.has(rid);
        })
        .map((c) => c.id);
      const retrySubgraphs = await Promise.all(
        retryIds.map((rid) => beadGraph(city, rid).catch(() => null)),
      );
      const retryBeads = retrySubgraphs.flatMap((g) => g ? [g.root, ...(g.beads ?? [])] : []);
      const provisional = [...all, ...threadBeads, ...retryBeads];

      // Specialist implementation/review beads live in the rig Beads DB
      // (e.g. md-*), while convergence roots live in the city DB (bl-*).
      // Beads cannot parent across DBs, so graph() cannot show these legs.
      // Stitch them in from convergence metadata first. run.json remains a
      // compatibility fallback for older runs.
      const convsForLegs = provisional.filter((b) => b.issue_type === 'convergence');
      const legIds = new Set<string>();
      for (const b of convsForLegs) {
        const md = b.metadata ?? {};
        for (const [key, value] of Object.entries(md)) {
          if (key.startsWith('gc.leg.') && typeof value === 'string' && value) legIds.add(value);
        }
      }
      await Promise.all(convsForLegs.map(async (b) => {
        try {
          const text = await readFile(runDir(rig, b) + '/run.json');
          const run = JSON.parse(text);
          for (const id of Object.values(run.legs ?? {})) {
            if (typeof id === 'string') legIds.add(id);
          }
        } catch { /* run not initialized yet */ }
      }));
      const legBeads = await Promise.all(
        Array.from(legIds).map((id) => getBead(city, id, rig).catch(() => null)),
      );
      const dedup = new Map<string, Bead>();
      for (const b of [...provisional, ...legBeads.filter(Boolean) as Bead[]]) dedup.set(b.id, b);
      const allBeads = Array.from(dedup.values());
      setBeads(allBeads);

      // Comments per bead (still a loop — no batch endpoint)
      const commentMap: Record<string, BdComment[]> = {};
      await Promise.all(allBeads.map(async (b) => {
        commentMap[b.id] = await beadComments(b.id);
      }));
      setComments(commentMap);

      // Verdicts + review excerpts: read review.md off disk per convergence
      const convs = allBeads.filter((b) => b.issue_type === 'convergence');
      const verdictMap: Record<string, string> = {};
      const excerptMap: Record<string, string> = {};
      await Promise.all(convs.map(async (b) => {
        try {
          const md = await readFile(runDir(rig, b) + '/review.md');
          const line = md.split(/\r?\n/).reverse().find((l) => l.startsWith('VERDICT:'));
          if (line) verdictMap[b.id] = line.replace('VERDICT:', '').trim();
          const firstPara = md.split(/\n\n/).slice(0, 3).join('\n\n').slice(0, 400);
          excerptMap[b.id] = firstPara;
        } catch { /* no review yet */ }
      }));
      setVerdicts(verdictMap);
      setReviewExcerpts(excerptMap);

      // Mail: list all city mail, then filter to messages actually addressed
      // to this run. "Addressed to" = the mail bead IS in lineage, OR its
      // subject names a lineage bead, OR it's a reply in a mail thread we're
      // already tracking. Body-prose mentions don't count — mayor status
      // mail often lists many bead ids in prose ("active convergences: X, Y")
      // and that would pull unrelated chat into every thread.
      const allMail = await listMail(city);
      const lineageIds = new Set(allBeads.map((b) => b.id));
      const threadLabels = new Set<string>();
      for (const m of allMail) {
        const subj = m.subject ?? '';
        const hitsId = [...lineageIds].some((id) => subj.includes(id));
        if (lineageIds.has(m.id) || hitsId) {
          for (const l of m.labels ?? []) if (l.startsWith('thread:')) threadLabels.add(l);
        }
      }
      const relevant = allMail.filter((m) => {
        if (lineageIds.has(m.id)) return true;
        const subj = m.subject ?? '';
        for (const id of lineageIds) if (subj.includes(id)) return true;
        for (const l of m.labels ?? []) if (threadLabels.has(l)) return true;
        return false;
      });
      setMail(relevant);
    } catch (err) { console.error(err); }
    finally { setLoading(false); }
  }
  useEffect(() => { load(); }, [rootId, rig, city]);

  // Live event stream: whenever gascity emits an event relevant to this
  // thread (a new bead created under our lineage, a step closing, a mail
  // landing, etc.), re-fetch the lineage. This replaces a time-based
  // polling loop with push-driven updates — the feed becomes fresh within
  // seconds of bead state changing instead of the next poll interval.
  const lineageSet = useMemo(() => {
    const s = new Set<string>();
    if (rootId) s.add(rootId);
    beads.forEach((b) => s.add(b.id));
    return s;
  }, [beads, rootId]);
  const { events: liveEvents, connected: streamConnected, addLineageId } = useThreadEvents(
    city, rootId ?? '', lineageSet,
  );
  // On each new relevant event, schedule a reload. Debounce (500ms) so a
  // burst of closely-spaced events only triggers one refresh.
  const reloadPending = useRef(false);
  const lastSeenSeq = useRef(0);
  useEffect(() => {
    if (!liveEvents.length) return;
    const latest = liveEvents[liveEvents.length - 1].seq;
    if (latest <= lastSeenSeq.current) return;
    lastSeenSeq.current = latest;
    // Opportunistic: if a new convergence event mentions a bead we haven't
    // seen, add it to the lineage set so subsequent events on it match.
    for (const e of liveEvents) {
      if (e.subject && !lineageSet.has(e.subject)) {
        const md = (e.payload as any)?.metadata || {};
        if (md['gc.retry_of'] && lineageSet.has(md['gc.retry_of'])) addLineageId(e.subject);
        if (md['gc.lineage_root'] && lineageSet.has(md['gc.lineage_root'])) addLineageId(e.subject);
      }
    }
    if (reloadPending.current) return;
    reloadPending.current = true;
    setTimeout(() => {
      reloadPending.current = false;
      load();
    }, 500);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [liveEvents]);

  // ── Build the feed ───────────────────────────────────────────────────
  const feed: FeedEvt[] = useMemo(() => {
    const out: FeedEvt[] = [];

    // Index beads by ID + classify
    const convs = beads.filter((b) => b.issue_type === 'convergence');
    const proposals = beads.filter((b) => (b.labels ?? []).includes('kind:proposal'));

    // Index molecule wisps (iteration containers) and step tasks (children of wisps).
    const molecules = beads.filter((b) => b.issue_type === 'molecule');
    const stepTasks = beads.filter((b) => b.issue_type === 'task' && !(b.labels ?? []).includes('kind:proposal'));

    // For each convergence bead, emit: seed/verdict/branches/terminated.
    // Branches events only fire for the root — depth>0 convergences' branches
    // are rendered nested inside their parent's branch card.
    for (const b of convs) {
      const depth = Number(b.metadata?.['gc.lineage_depth'] ?? 0);
      const retryOf = b.metadata?.['gc.retry_of'] as string | undefined;
      if (retryOf) {
        // Operator-triggered retry after NEEDS_TAKARA / external blocker.
        // Show a distinct RETRY marker instead of another SEED so the
        // thread reads naturally: "we kicked a rerun after you unblocked X".
        out.push({
          kind: 'retry',
          ts: b.created_at ?? '',
          bead: b,
          retryOf,
          reason: (b.metadata?.['gc.retry_reason'] as string) || '',
        });
      } else if (depth === 0 || b.id === rootId) {
        out.push({ kind: 'seed', ts: b.created_at ?? '', bead: b });
      }
      // Active / recent iterations — emit a progress event per wisp so the
      // user can see planning / implementing / reviewing as it happens.
      const myWisps = molecules.filter((m) => m.id.startsWith(b.id + '.'));
      for (const w of myWisps) {
        const mySteps = stepTasks
          .filter((s) =>
            s.id.startsWith(w.id + '.') ||
            s.metadata?.['gc.parent_run'] === b.id
          )
          .sort((a, z) => a.id.localeCompare(z.id));
        if (mySteps.length === 0) continue;
        // Iteration number is the trailing number of the wisp id (e.g. bl-x.1 → 1)
        const iterMatch = w.id.match(/\.(\d+)$/);
        const iteration = iterMatch ? Number(iterMatch[1]) : 1;
        out.push({
          kind: 'progress',
          ts: w.created_at ?? b.created_at ?? '',
          convergenceBead: b,
          iteration,
          steps: mySteps,
        });
      }
      // Verdict event — emitted for every depth so the chronological feed
      // still shows the full march of decisions.
      const v = verdicts[b.id];
      if (v) {
        out.push({ kind: 'verdict', ts: b.closed_at ?? b.updated_at ?? '', bead: b, verdict: v, reviewExcerpt: reviewExcerpts[b.id] });
      }
      // Branches: only at the root level. Children render nested.
      const isRootHere = b.id === rootId || depth === 0;
      const myProps = proposals.filter((p) => p.metadata?.['gc.parent_run'] === b.id);
      if (myProps.length > 0 && isRootHere) {
        const promotedBeadIds = new Set(
          myProps
            .filter((p) => (p.labels ?? []).includes('status:promoted'))
            .map((p) => {
              const child = convs.find((c) => c.metadata?.['gc.promoted_from_proposal'] === p.id);
              return child?.id ?? null;
            })
            .filter(Boolean) as string[],
        );
        const promoted = convs.filter((c) => promotedBeadIds.has(c.id));
        const skipped = myProps.filter((p) =>
          (p.labels ?? []).includes('status:skipped-dedup') ||
          (p.labels ?? []).includes('status:skipped-duplicate'),
        );
        out.push({
          kind: 'branches',
          ts: myProps[0].created_at ?? b.closed_at ?? '',
          parentBead: b,
          proposals: myProps,
          promoted,
          skipped,
        });
      }
      // Terminal marker (only for root-depth, to avoid redundancy)
      if (b.metadata?.['convergence.terminal_reason'] && depth === 0) {
        // Already captured by verdict; suppress unless it's a non-accepted terminal
        const term = b.metadata['convergence.terminal_reason'];
        if (term !== 'approved') {
          out.push({ kind: 'terminated', ts: b.closed_at ?? '', bead: b });
        }
      }
    }

    // Comments on any bead in lineage (if not routine)
    if (!hideNoisyComments) {
      for (const [beadId, cs] of Object.entries(comments)) {
        for (const c of cs) {
          const body = c.body ?? c.text ?? '';
          out.push({
            kind: 'comment',
            ts: c.ts ?? c.created_at ?? '',
            beadId,
            author: c.author ?? 'agent',
            body,
          });
        }
      }
    }

    // Mail relevant to lineage
    const lineageIds = new Set(beads.map((b) => b.id));
    const relevant = mail.filter((m) => {
      if (lineageIds.has(m.id)) return true;
      const h = (m.subject ?? '') + '\n' + (m.body ?? '');
      for (const id of lineageIds) if (h.includes(id)) return true;
      return false;
    });
    for (const m of relevant) {
      if (isRoutineMail(m)) continue;
      out.push({ kind: 'mail', ts: m.created_at ?? '', mail: m });
    }

    out.sort((a, b) => (a.ts || '').localeCompare(b.ts || ''));
    return out;
  }, [beads, comments, verdicts, reviewExcerpts, mail, hideNoisyComments, rootId]);

  // ── Banner: where is this idea right now? ────────────────────────────
  // If there's an active retry of the original root, the banner should
  // reflect the retry's state (that's "where the idea is now"), with a
  // pointer back to the root title.
  const rootBead = beads.find((b) => b.id === rootId);
  const banner = useMemo(() => {
    if (!rootBead) return null;
    // Prefer the newest active retry as the banner source of truth.
    const retries = beads
      .filter((b) => b.issue_type === 'convergence' && b.metadata?.['gc.retry_of'] === rootId)
      .sort((a, z) => (z.created_at ?? '').localeCompare(a.created_at ?? ''));
    const activeRetry = retries.find((b) => b.status === 'open' || b.status === 'in_progress');
    const focalBead = activeRetry ?? rootBead;

    const v = verdicts[focalBead.id];
    const term = focalBead.metadata?.['convergence.terminal_reason'];
    const iter = focalBead.metadata?.['convergence.iteration'];
    const maxIter = focalBead.metadata?.['convergence.max_iterations'];
    const running = focalBead.status === 'open' || (focalBead.status === 'in_progress');
    let state: string;
    let color: string;
    if (running) { state = `RUNNING (iter ${iter}/${maxIter})`; color = 'var(--pending)'; }
    else if (v === 'ACCEPTED' || term === 'approved') { state = 'ACCEPTED'; color = 'var(--accept)'; }
    else if (v === 'NEEDS_TAKARA') { state = 'NEEDS YOUR INPUT'; color = 'var(--pending)'; }
    else if (term === 'no_convergence') { state = 'DEAD END'; color = 'var(--reject)'; }
    else if (term === 'stopped') { state = 'STOPPED'; color = 'var(--neutral)'; }
    else { state = focalBead.status; color = 'var(--fg-dim)'; }
    if (activeRetry) state = state + ' (retry)';
    return {
      state,
      color,
      iter,
      maxIter,
      verdict: v,
      title: rootBead.title ?? '',
      running,
      focalBeadId: focalBead.id,
    };
  }, [rootBead, beads, verdicts]);

  async function doStop() {
    // Stop the currently-running convergence, which may be a retry of rootId.
    const targetId = banner?.focalBeadId ?? rootId;
    if (!targetId) return;
    if (!confirm(`Stop this convergence (${targetId})?`)) return;
    const r = await convergeStop(targetId);
    if (r.code !== 0) {
      alert(`could not stop ${targetId}:\n\n${(r.stderr || r.stdout || 'unknown error').trim()}`);
      return;
    }
    setTimeout(load, 1200);
  }

  async function submitReply() {
    if (!reply || !reply.body.trim()) return;
    setReply({ ...reply, sending: true, result: undefined });
    try {
      let r: ExecResult;
      if (reply.targetKind === 'mail') {
        r = await mailReply({ messageId: reply.targetId, body: reply.body, notify: true });
      } else if (reply.targetKind === 'mayor_direct') {
        r = await mayorChat({ rig, contextId: rootId, body: `About run ${rootId}:\n\n${reply.body}` });
      } else if (reply.targetKind === 'convergence' || reply.targetKind === 'followup' || reply.targetKind === 'root') {
        r = await mayorChat({
          rig,
          contextId: reply.targetId,
          body: [
            `I want to branch or redirect from run/bead ${reply.targetId}.`,
            '',
            reply.body,
            '',
            'Please decide whether this should become a proposal, a rerun, a policy/directive update, or a clarification. Keep the rig mayor conversation as the user-facing thread.',
          ].join('\n'),
        });
      } else {
        r = { stdout: '', stderr: 'unknown target kind', code: 1 };
      }
      setReply({ ...reply, sending: false, result: r });
      if (r.code === 0) {
        setTimeout(() => { setReply(null); load(); }, 900);
      }
    } catch (err: any) {
      setReply({ ...reply, sending: false, result: { stdout: '', stderr: String(err), code: -1 } });
    }
  }

  if (!rootId) return <div className="empty">No root specified.</div>;

  return (
    <>
      {/* Banner — includes the live heartbeat strip inline when running */}
      {banner && (
        <div style={{
          background: 'var(--bg-2)', border: `1px solid var(--border)`, borderLeft: `4px solid ${banner.color}`,
          borderRadius: 4, padding: '14px 18px', marginBottom: 18,
        }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
            <div>
              <div style={{ fontSize: 10, letterSpacing: '0.06em', color: banner.color, fontWeight: 700 }}>{banner.state}</div>
              <h1 style={{ margin: '4px 0 0 0' }}>{banner.title}</h1>
              <div className="dim mono" style={{ fontSize: 11, marginTop: 4 }}>{rootId}</div>
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              {banner.running && <button className="danger" onClick={doStop} style={{ fontSize: 11 }}>Stop</button>}
              <button
                className="secondary"
                onClick={() => setReply({ targetKind: 'mayor_direct', targetId: rootId!, body: '' })}
                style={{ fontSize: 11 }}
                title="Send a message to this rig's mayor about this run (steering, questions, context)"
              >
                Message mayor
              </button>
              <button className="secondary" onClick={() => setReply({ targetKind: 'root', targetId: rootId, body: '' })} style={{ fontSize: 11 }}>
                Ask next
              </button>
            </div>
          </div>
          {reply?.targetKind === 'root' && reply.targetId === rootId && <ReplyInline reply={reply} setReply={setReply} submit={submitReply} />}
          {reply?.targetKind === 'mayor_direct' && reply.targetId === rootId && <ReplyInline reply={reply} setReply={setReply} submit={submitReply} />}
          {/* Live activity signal inline in the banner when convergence is active */}
          {banner.running && banner.focalBeadId && (
            <div style={{ marginTop: 10, paddingTop: 10, borderTop: '1px solid var(--border)' }}>
              <HeartbeatStrip beadId={banner.focalBeadId} />
            </div>
          )}
        </div>
      )}

      <div style={{ marginBottom: 14, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div>
          <Link to="/threads" className="dim" style={{ fontSize: 11 }}>‹ back to research runs</Link>
          <button
            className="link-button dim"
            style={{ fontSize: 11, marginLeft: 12, padding: 0 }}
            onClick={() => setBeadListPanel({
              title: `${rootId} beads`,
              items: beads
                .slice()
                .sort((a, z) => beadSortKey(z).localeCompare(beadSortKey(a)))
                .map((b) => ({
                  id: b.id,
                  title: b.title,
                  status: b.status,
                  issue_type: b.issue_type,
                  labels: b.labels,
                  description: b.description,
                  assignee: b.assignee,
                  created_at: b.created_at,
                  updated_at: b.updated_at,
                  closed_at: b.closed_at,
                  metadata: b.metadata,
                })),
            })}
            title="Show all beads in the detail panel"
          >
            {beads.length} beads
          </button>
          <span className="dim" style={{ fontSize: 11 }}> · {feed.length} events</span>
          <span
            style={{ marginLeft: 12, fontSize: 10, color: streamConnected ? 'var(--accept)' : 'var(--fg-dim)' }}
            title={streamConnected ? 'Live — subscribed to gascity event stream' : 'Not connected to event stream'}
          >
            {streamConnected ? '● live' : '○ offline'}
            {liveEvents.length > 0 && (
              <span className="dim" style={{ marginLeft: 6 }}>({liveEvents.length} streamed)</span>
            )}
          </span>
        </div>
        <div style={{ display: 'flex', gap: 10 }}>
          <label style={{ fontSize: 11, display: 'flex', gap: 4, alignItems: 'center' }}>
            <input type="checkbox" checked={hideNoisyComments} onChange={(e) => setHideNoisyComments(e.target.checked)} /> hide noisy comments
          </label>
          <button className="secondary" onClick={load} style={{ fontSize: 11, padding: '2px 8px' }}>↻</button>
        </div>
      </div>

      {loading && feed.length === 0 && <div className="empty">Loading…</div>}

      {/* Feed */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {feed.map((evt, i) => (
          <FeedItem
            key={`${i}-${evtKey(evt)}`}
            evt={evt}
            reply={reply}
            setReply={setReply}
            submitReply={submitReply}
            rig={rig}
            allBeads={beads}
            verdicts={verdicts}
          />
        ))}
      </div>
    </>
  );
}

function evtKey(e: FeedEvt): string {
  if (e.kind === 'seed' || e.kind === 'verdict' || e.kind === 'terminated' || e.kind === 'retry') return e.bead.id;
  if (e.kind === 'branches') return e.parentBead.id;
  if (e.kind === 'mail') return e.mail.id;
  if (e.kind === 'comment') return e.beadId + e.ts;
  if (e.kind === 'progress') return e.convergenceBead.id + '.' + e.iteration;
  return 'u';
}

function beadSortKey(b: Bead): string {
  return `${b.updated_at ?? b.closed_at ?? b.created_at ?? ''}:${b.id}`;
}

// ── Feed item rendering ──────────────────────────────────────────────

function FeedItem({ evt, reply, setReply, submitReply, rig, allBeads, verdicts }: {
  evt: FeedEvt;
  reply: any;
  setReply: (r: any) => void;
  submitReply: () => void;
  rig: string;
  allBeads: Bead[];
  verdicts: Record<string, string>;
}) {
  const { setSelectedBead } = useDash();
  // Branches and progress default to open so users can see tree shape
  // and step-by-step state at a glance; other cards stay collapsed.
  const [expanded, setExpanded] = useState(evt.kind === 'branches' || evt.kind === 'progress');

  if (evt.kind === 'seed') {
    // Slim marker only — full idea description lives in the inspector.
    return (
      <div className="feed-card" style={{ borderLeftColor: '#8b5cf6' }}>
        <div className="feed-head">
          <span className="feed-kind" style={{ color: '#8b5cf6' }}>🌱 SEED</span>
          <span className="dim" style={{ fontSize: 10 }}>{relTs(evt.ts)}</span>
        </div>
        <div className="feed-title" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 8 }}>
          <span>{evt.bead.title}</span>
          <button className="secondary" style={{ fontSize: 11, padding: '2px 8px' }}
            onClick={() => setSelectedBead(evt.bead.id)}>
            🔎
          </button>
        </div>
      </div>
    );
  }

  if (evt.kind === 'retry') {
    // A new convergence spun up to retry a prior run after an external
    // blocker got resolved. Show it prominently so the thread reads as
    // one continuous story even though the bead id changed.
    return (
      <div className="feed-card" style={{ borderLeftColor: '#f59e0b' }}>
        <div className="feed-head">
          <span className="feed-kind" style={{ color: '#f59e0b' }}>↻ RETRY of <span className="mono">{evt.retryOf}</span></span>
          <span className="dim" style={{ fontSize: 10 }}>{relTs(evt.ts)}</span>
        </div>
        <div className="feed-title" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 8 }}>
          <span>
            <span className="mono" style={{ fontSize: 10, color: 'var(--fg-dim)' }}>{evt.bead.id}</span>
            {' '}{evt.bead.title}
          </span>
          <button className="secondary" style={{ fontSize: 11, padding: '2px 8px' }}
            onClick={() => setSelectedBead(evt.bead.id)}>
            🔎
          </button>
        </div>
        {evt.reason && (
          <div className="dim" style={{ fontSize: 11, marginTop: 6, fontStyle: 'italic' }}>
            reason: {evt.reason}
          </div>
        )}
      </div>
    );
  }

  if (evt.kind === 'verdict') {
    // Slim marker only — review.md + implementation.md are in the inspector.
    const accent = evt.verdict === 'ACCEPTED' ? 'var(--accept)' : evt.verdict === 'REJECTED' ? 'var(--reject)' : 'var(--pending)';
    const icon = evt.verdict === 'ACCEPTED' ? '✓' : evt.verdict === 'REJECTED' ? '✗' : '⚑';
    const iter = evt.bead.metadata?.['convergence.iteration'];
    const maxIter = evt.bead.metadata?.['convergence.max_iterations'];
    return (
      <div className="feed-card" style={{ borderLeftColor: accent }}>
        <div className="feed-head">
          <span className="feed-kind" style={{ color: accent }}>{icon} {evt.verdict}</span>
          <span className="dim" style={{ fontSize: 10 }}>{relTs(evt.ts)}</span>
        </div>
        <div className="feed-title" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 8 }}>
          <span>
            {evt.bead.title} {iter !== undefined && <span className="dim" style={{ fontSize: 11 }}>(iter {iter}/{maxIter})</span>}
          </span>
          <span style={{ display: 'flex', gap: 6 }}>
            <button className="secondary" onClick={() => setSelectedBead(evt.bead.id)} style={{ fontSize: 11, padding: '2px 8px' }}>
              🔎
            </button>
            <button className="secondary" onClick={() => setReply({ targetKind: 'convergence', targetId: evt.bead.id, body: '' })} style={{ fontSize: 11, padding: '2px 8px' }}>
              Branch
            </button>
          </span>
        </div>
        {reply?.targetKind === 'convergence' && reply.targetId === evt.bead.id && <ReplyInline reply={reply} setReply={setReply} submit={submitReply} />}
      </div>
    );
  }

  if (evt.kind === 'branches') {
    const n = evt.proposals.length;
    const p = evt.promoted.length;
    const s = evt.skipped.length;
    return (
      <div className="feed-card" style={{ borderLeftColor: '#a78bfa' }}>
        <div className="feed-head">
          <span className="feed-kind" style={{ color: '#a78bfa' }}>💭 {n} FOLLOWUPS</span>
          <span className="dim" style={{ fontSize: 10 }}>{relTs(evt.ts)}</span>
        </div>
        <div className="feed-title">
          {p} promoted · {s} skipped · {n - p - s} pending
        </div>
        <button className="secondary" onClick={() => setExpanded(!expanded)} style={{ fontSize: 11, padding: '3px 8px', marginTop: 8 }}>
          {expanded ? 'Hide' : 'Show branches'}
        </button>
        {expanded && (
          <BranchList
            proposals={evt.proposals}
            promoted={evt.promoted}
            skipped={evt.skipped}
            allBeads={allBeads}
            verdicts={verdicts}
            depth={0}
            rig={rig}
          />
        )}
      </div>
    );
  }

  if (evt.kind === 'mail') {
    const m = evt.mail;
    const body = m.body ?? '';
    return (
      <div className="feed-card" style={{ borderLeftColor: '#93c5fd' }}>
        <div className="feed-head">
          <span className="feed-kind" style={{ color: '#93c5fd' }}>✉ MAIL</span>
          <span className="dim" style={{ fontSize: 10 }}>
            <span className="mono">{m.from}</span> → <span className="mono">{m.to}</span> · {relTs(evt.ts)}
          </span>
        </div>
        <div className="feed-title">{m.subject || '(no subject)'}</div>
        {!expanded && body && (
          <div className="dim" style={{ fontSize: 11, marginTop: 4 }}>
            <Md style={{ fontSize: 11 }}>{body.slice(0, 400) + (body.length > 400 ? '…' : '')}</Md>
          </div>
        )}
        {expanded && (
          <div style={{ marginTop: 8, padding: 8, background: 'var(--bg-3)', borderRadius: 3, maxHeight: 500, overflow: 'auto' }}>
            <Md style={{ fontSize: 11 }}>{body}</Md>
          </div>
        )}
        <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
          <button className="secondary" onClick={() => setExpanded(!expanded)} style={{ fontSize: 11, padding: '3px 8px' }}>{expanded ? 'Collapse' : 'Expand'}</button>
          <button className="secondary" onClick={() => setReply({ targetKind: 'mail', targetId: m.id, body: '' })} style={{ fontSize: 11, padding: '3px 8px' }}>↩ Reply</button>
        </div>
        {reply?.targetKind === 'mail' && reply.targetId === m.id && <ReplyInline reply={reply} setReply={setReply} submit={submitReply} />}
      </div>
    );
  }

  if (evt.kind === 'comment') {
    return (
      <div className="feed-card" style={{ borderLeftColor: '#9ca3af', background: 'transparent', fontSize: 11 }}>
        <div className="feed-head">
          <span className="feed-kind" style={{ color: '#9ca3af' }}>💬 COMMENT on <span className="mono">{evt.beadId}</span></span>
          <span className="dim" style={{ fontSize: 10 }}>by {evt.author} · {relTs(evt.ts)}</span>
        </div>
        <div style={{ marginTop: 4 }}>
          <Md style={{ fontSize: 11 }}>{evt.body.slice(0, 800) + (evt.body.length > 800 ? '…' : '')}</Md>
        </div>
      </div>
    );
  }

  if (evt.kind === 'terminated') {
    return (
      <div className="feed-card" style={{ borderLeftColor: '#fb923c' }}>
        <div className="feed-head">
          <span className="feed-kind" style={{ color: '#fb923c' }}>■ TERMINATED</span>
          <span className="dim" style={{ fontSize: 10 }}>{relTs(evt.ts)}</span>
        </div>
        <div className="feed-title">{evt.bead.metadata?.['convergence.terminal_reason'] ?? 'unknown'}</div>
      </div>
    );
  }

  if (evt.kind === 'progress') {
    const closed = evt.steps.filter((s) => s.status === 'closed').length;
    const total = evt.steps.length;
    const active = evt.steps.find((s) => s.status !== 'closed');
    return (
      <div className="feed-card" style={{ borderLeftColor: '#fbbf24' }}>
        <div className="feed-head">
          <span className="feed-kind" style={{ color: '#fbbf24' }}>⚙ ITER {evt.iteration} · {closed}/{total} steps</span>
          <span className="dim" style={{ fontSize: 10 }}>{relTs(evt.ts)}</span>
        </div>
        <div className="feed-title">
          {active ? <>currently: <b>{active.title}</b></> : 'all steps closed'}
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
          <button className="secondary" onClick={() => setExpanded(!expanded)} style={{ fontSize: 11, padding: '3px 8px' }}>
            {expanded ? 'Hide steps' : 'Show steps'}
          </button>
          <button className="secondary" onClick={() => setSelectedBead(evt.convergenceBead.id)} style={{ fontSize: 11, padding: '3px 8px' }}>
            🔎 inspect
          </button>
        </div>
        {expanded && (
          <ol style={{ marginTop: 8, paddingLeft: 18, fontSize: 11 }}>
            {evt.steps.map((s) => (
              <li key={s.id} style={{ marginBottom: 4, opacity: s.status === 'closed' ? 0.6 : 1 }}>
                <span style={{ color: s.status === 'closed' ? 'var(--accept)' : 'var(--pending)' }}>
                  {s.status === 'closed' ? '✓' : '◐'}
                </span>
                {' '}
                <span className="mono" style={{ fontSize: 10, color: 'var(--fg-dim)' }}>{s.id}</span>
                {' '}{s.title}
              </li>
            ))}
          </ol>
        )}
      </div>
    );
  }

  return null;
}

// ── Expanded run details (artifacts + verdict review) ────────────────

function ExpandedRun({ bead, rig }: { bead: Bead; rig: string }) {
  const [reviewMd, setReviewMd] = useState<string | null>(null);
  const [implMd, setImplMd] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      let rev: string | null = null;
      let imp: string | null = null;
      try { rev = await readFile(runDir(rig, bead) + '/review.md'); } catch { /* no review */ }
      try { imp = await readFile(runDir(rig, bead) + '/implementation.md'); } catch { /* no impl */ }
      if (cancelled) return;
      setReviewMd(rev);
      setImplMd(imp);
      setLoaded(true);
    })();
    return () => { cancelled = true; };
  }, [bead.id, rig]);

  if (!loaded) return <div className="dim" style={{ fontSize: 11, marginTop: 8 }}>Loading…</div>;
  if (!reviewMd && !implMd) {
    return (
      <div className="dim" style={{ fontSize: 11, marginTop: 8, padding: 8, background: 'var(--bg-3)', borderRadius: 3 }}>
        No review or implementation artifacts on disk for this run.
        <div className="mono" style={{ fontSize: 10, marginTop: 4 }}>expected: {runDir(rig, bead)}</div>
      </div>
    );
  }
  return (
    <div style={{ marginTop: 10, padding: 10, background: 'var(--bg-3)', borderRadius: 3 }}>
      {reviewMd && (
        <details open>
          <summary className="dim" style={{ fontSize: 11, cursor: 'pointer' }}>review.md</summary>
          <Md style={{ fontSize: 11, marginTop: 6 }}>{reviewMd}</Md>
        </details>
      )}
      {implMd && (
        <details>
          <summary className="dim" style={{ fontSize: 11, cursor: 'pointer', marginTop: 8 }}>implementation.md</summary>
          <Md style={{ fontSize: 11, marginTop: 6 }}>{implMd}</Md>
        </details>
      )}
      <div className="dim mono" style={{ fontSize: 10, marginTop: 10 }}>run dir: {runDir(rig, bead)}</div>
    </div>
  );
}

// ── Branch list (inline followups) ───────────────────────────────────

function BranchList({ proposals, promoted, skipped, allBeads, verdicts, depth, rig }: {
  proposals: Bead[];
  promoted: Bead[];
  skipped: Bead[];
  allBeads: Bead[];
  verdicts: Record<string, string>;
  depth: number;
  rig: string;
}) {
  const skippedIds = new Set(skipped.map((s) => s.id));
  // Cap recursion defensively; real lineages are shallow.
  const MAX_DEPTH = 6;

  return (
    <div style={{
      marginTop: 10, display: 'flex', flexDirection: 'column', gap: 6,
      marginLeft: depth > 0 ? 14 : 0,
      borderLeft: depth > 0 ? '2px solid var(--border)' : undefined,
      paddingLeft: depth > 0 ? 10 : 0,
    }}>
      {proposals.map((p) => {
        const isSkipped = skippedIds.has(p.id);
        const promotedTo = promoted.find((c) => c.metadata?.['gc.promoted_from_proposal'] === p.id);
        const isPromoted = !!promotedTo;
        const pending = !isSkipped && !isPromoted;
        return (
          <BranchItem
            key={p.id}
            proposal={p}
            promotedTo={promotedTo}
            isSkipped={isSkipped}
            isPromoted={isPromoted}
            pending={pending}
            allBeads={allBeads}
            verdicts={verdicts}
            depth={depth}
            maxDepth={MAX_DEPTH}
            rig={rig}
          />
        );
      })}
    </div>
  );
}

function BranchItem({ proposal, promotedTo, isSkipped, isPromoted, pending, allBeads, verdicts, depth, maxDepth, rig }: {
  proposal: Bead;
  promotedTo: Bead | undefined;
  isSkipped: boolean;
  isPromoted: boolean;
  pending: boolean;
  allBeads: Bead[];
  verdicts: Record<string, string>;
  depth: number;
  maxDepth: number;
  rig: string;
}) {
  const { setSelectedBead } = useDash();
  // If this branch got promoted to a child convergence, compute its own followups.
  const { childProposals, childPromoted, childSkipped } = useMemo(() => {
    if (!promotedTo) return { childProposals: [] as Bead[], childPromoted: [] as Bead[], childSkipped: [] as Bead[] };
    const convs = allBeads.filter((b) => b.issue_type === 'convergence');
    const myProps = allBeads
      .filter((b) => (b.labels ?? []).includes('kind:proposal'))
      .filter((p) => p.metadata?.['gc.parent_run'] === promotedTo.id);
    const promotedChildren = convs.filter((c) =>
      myProps.some((mp) => c.metadata?.['gc.promoted_from_proposal'] === mp.id),
    );
    const skippedChildren = myProps.filter((p) =>
      (p.labels ?? []).includes('status:skipped-dedup') ||
      (p.labels ?? []).includes('status:skipped-duplicate'),
    );
    return { childProposals: myProps, childPromoted: promotedChildren, childSkipped: skippedChildren };
  }, [promotedTo, allBeads]);

  const hasChildren = childProposals.length > 0;
  const [open, setOpen] = useState(depth < 1); // auto-expand first nested layer
  const [outcomeOpen, setOutcomeOpen] = useState(false);
  const childVerdict = promotedTo ? verdicts[promotedTo.id] : undefined;

  return (
    <div style={{
      padding: 8, background: 'var(--bg-3)', borderRadius: 3,
      borderLeft: `3px solid ${isPromoted ? 'var(--accept)' : isSkipped ? 'var(--fg-dim)' : 'var(--pending)'}`,
      opacity: isSkipped ? 0.6 : 1,
    }}>
      <div style={{ fontSize: 11, display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 8 }}>
        <span>
          {isPromoted && '↗ '}
          {isSkipped && '⊘ '}
          {pending && '⏳ '}
          <span className="mono" style={{ fontSize: 10, color: 'var(--fg-dim)' }}>{proposal.id}</span>
          {' '}{proposal.title}
          {childVerdict && (
            <span style={{
              fontSize: 10, marginLeft: 6, padding: '1px 5px', borderRadius: 2,
              background: childVerdict === 'ACCEPTED' ? 'var(--accept)' : 'var(--reject)',
              color: '#000',
            }}>
              {childVerdict}
            </span>
          )}
        </span>
        <span style={{ display: 'flex', gap: 6, alignItems: 'baseline' }}>
          {promotedTo && (
            <>
              <button
                className="secondary"
                style={{ fontSize: 10, padding: '1px 6px' }}
                onClick={() => setOutcomeOpen(!outcomeOpen)}
              >
                {outcomeOpen ? '▼' : '▶'} outcome
              </button>
              <button
                className="secondary"
                style={{ fontSize: 10, padding: '1px 6px' }}
                onClick={() => setSelectedBead(promotedTo.id)}
                title="Show artifacts in side panel"
              >
                🔎
              </button>
            </>
          )}
          {hasChildren && depth < maxDepth && (
            <button
              className="secondary"
              style={{ fontSize: 10, padding: '1px 6px' }}
              onClick={() => setOpen(!open)}
            >
              {open ? '▼' : '▶'} {childProposals.length} sub
            </button>
          )}
        </span>
      </div>
      {isSkipped && <div className="dim" style={{ fontSize: 10, marginTop: 2 }}>skipped — matched dead-end</div>}
      {promotedTo && outcomeOpen && (
        <ExpandedRun bead={promotedTo} rig={rig} />
      )}
      {hasChildren && open && depth < maxDepth && (
        <BranchList
          proposals={childProposals}
          promoted={childPromoted}
          skipped={childSkipped}
          allBeads={allBeads}
          verdicts={verdicts}
          depth={depth + 1}
          rig={rig}
        />
      )}
    </div>
  );
}

// ── Reply widget ─────────────────────────────────────────────────────

function ReplyInline({ reply, setReply, submit }: { reply: any; setReply: any; submit: () => void }) {
  const hint =
    reply.targetKind === 'mail' ? 'Reply to this mail thread.' :
    reply.targetKind === 'mayor_direct' ? "Send this rig's mayor a message about this run. Use this to steer, ask, redirect, or add context. Does not spawn new work." :
    reply.targetKind === 'root' ? 'Your reply becomes a new branch (proposal under curator review).' :
    reply.targetKind === 'convergence' ? 'Branch from this result — creates a new proposal referencing it.' :
    '';
  return (
    <div style={{ marginTop: 10, padding: 10, background: 'var(--bg-3)', borderRadius: 3 }} onClick={(e) => e.stopPropagation()}>
      <div className="dim" style={{ fontSize: 11, marginBottom: 6 }}>{hint}</div>
      <textarea
        value={reply.body}
        onChange={(e) => setReply({ ...reply, body: e.target.value })}
        rows={4}
        placeholder={
          reply.targetKind === 'mail' ? 'Your reply…' :
          reply.targetKind === 'mayor_direct' ? 'Message to rig mayor - steering, question, context...' :
          'Describe the branch or redirection…'
        }
      />
      <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
        <button disabled={reply.sending} onClick={submit} style={{ fontSize: 11, padding: '4px 10px' }}>
          {reply.sending ? 'Sending…' : 'Send'}
        </button>
        <button className="secondary" onClick={() => setReply(null)} style={{ fontSize: 11, padding: '4px 10px' }}>Cancel</button>
      </div>
      {reply.result && (
        <div className="dim" style={{ fontSize: 10, marginTop: 6 }}>
          exit: {reply.result.code}
          {reply.result.stderr && <div style={{ color: 'var(--reject)' }}>{reply.result.stderr.slice(0, 200)}</div>}
        </div>
      )}
    </div>
  );
}
