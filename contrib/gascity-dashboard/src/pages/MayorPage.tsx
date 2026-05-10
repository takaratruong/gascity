import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import Md from '../components/Md';
import { useDash } from '../store';
import {
  listMail,
  mayorChat,
  mayorForRig,
  prefixForRig,
  rigActivity,
  subscribeEvents,
  type Bead,
  type MailItem,
  type ExecResult,
  type RigActivity,
} from '../api';

// Conversation view with the rig mayor. Mail remains the durable audit trail,
// but sends go through /exec/mayor/chat so the named mayor session receives the
// text immediately instead of only discovering it later through mail.
export default function MayorPage() {
  const { city, rig } = useDash();
  const mayor = mayorForRig(rig);
  const [mail, setMail] = useState<MailItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [body, setBody] = useState('');
  const [replyTarget, setReplyTarget] = useState<MailItem | null>(null);
  const [sending, setSending] = useState(false);
  const [result, setResult] = useState<ExecResult | null>(null);
  const [activity, setActivity] = useState<RigActivity | null>(null);
  const [activityLoading, setActivityLoading] = useState(true);
  const bottomRef = useRef<HTMLDivElement>(null);

  async function refresh() {
    setLoading(true);
    try {
      const all = await listMail(city);
      setMail(all);
    } catch (e) { console.error(e); }
    finally { setLoading(false); }
  }

  async function refreshActivity() {
    setActivityLoading(true);
    try {
      setActivity(await rigActivity(rig));
    } catch (e) { console.error(e); }
    finally { setActivityLoading(false); }
  }

  useEffect(() => {
    refresh();
    refreshActivity();
    const unsub = subscribeEvents(city, (e) => {
      if (e.type === 'mail.sent' || e.type === 'mail.read' || e.type === 'bead.created' || e.type === 'bead.updated') {
        refresh();
        refreshActivity();
      }
    });
    const t = setInterval(() => { refresh(); refreshActivity(); }, 15000);
    return () => { unsub(); clearInterval(t); };
  }, [city, rig]);

  // Filter mail: anything to/from mayor AND relevant to the current rig.
  // Rig relevance: mail subject/body mentions the rig name, the rig's bead
  // prefix, the rig's worktree path, OR the bead id is rig-prefixed.
  const visible = useMemo(() => {
    const ROUTINE = /^(dog[_\s-]?done|review complete|advance convergence|convergence terminated|new test bead|wake and work|ping|curator-decide|new convergence|retry test|autoloop|handoff:)/i;
    const prefix = prefixForRig(rig);
    const rigMatchers = [rig, `/${rig}/`, prefix ? `${prefix}-` : ''].filter(Boolean);
    const isMayor = (who: string) => who === mayor || who === 'mayor';

    return mail
      .filter((m) => {
        const to = (m.to ?? '').toLowerCase();
        const from = (m.from ?? '').toLowerCase();
        // Keep only human↔mayor — drop mayor→mayor HANDOFF self-talk.
        const humanToMayor = from === 'human' && isMayor(to);
        const mayorToHuman = isMayor(from) && to === 'human';
        if (!humanToMayor && !mayorToHuman) return false;
        if (ROUTINE.test(m.subject ?? '')) return false;
        // Match by direct rig token only. Mail thread labels are too broad for
        // mayor chat: one legacy generic-mayor thread can drift across rigs and
        // make park-manip messages appear in mjx-diffphysics.
        const hay = (m.subject ?? '') + '\n' + (m.body ?? '') + '\n' + m.id;
        return rigMatchers.some((s) => hay.includes(s));
      })
      .sort((a, z) => (a.created_at ?? '').localeCompare(z.created_at ?? ''));
  }, [mail, rig, mayor]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [visible.length]);

  async function send() {
    if (!body.trim()) return;
    setSending(true);
    setResult(null);
    try {
      const r = await mayorChat({
        rig,
        body,
        contextId: replyTarget?.id,
      });
      setResult(r);
      if (r.code === 0) {
        setBody('');
        setReplyTarget(null);
        setTimeout(refresh, 500);
      }
    } catch (err: any) {
      setResult({ stdout: '', stderr: String(err), code: -1 });
    } finally { setSending(false); }
  }

  function handleComposerKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key !== 'Enter' || e.shiftKey || e.metaKey || e.ctrlKey) return;
    e.preventDefault();
    if (!sending && body.trim()) void send();
  }

  return (
    <div className="mayor-chat">
      <div className="mayor-chat-head">
        <div>
          <h1>{mayor}</h1>
          <div className="dim mayor-chat-sub">#{rig}</div>
        </div>
        <button className="secondary" onClick={() => { refresh(); refreshActivity(); }} disabled={loading || activityLoading} title="Refresh chat and active work">
          refresh
        </button>
      </div>

      <RigActivityPanel activity={activity} loading={activityLoading} />

      <div className="mayor-chat-feed">
        {loading && visible.length === 0 ? <div className="empty">Loading…</div> :
         visible.length === 0 ? <div className="empty">No messages yet. Start the rig conversation below.</div> :
         visible.map((m) => {
          const fromHuman = m.from === 'human';
          const speaker = fromHuman ? 'You' : (m.from === mayor ? mayor : `legacy ${m.from || 'mayor'}`);
          const subject = (m.subject ?? '').replace(`[${rig}] chat`, '').trim();
          return (
            <div
              key={m.id}
              className={`chat-message ${fromHuman ? 'from-human' : 'from-mayor'}`}
            >
              <div className="chat-avatar">{fromHuman ? 'Y' : mayor.slice(0, 1).toUpperCase()}</div>
              <div className="chat-message-body">
                <div className="chat-message-meta">
                  <span className="chat-speaker">{speaker}</span>
                  <span>{(m.created_at ?? '').replace('T', ' ').slice(0, 19)}</span>
                  {subject && <span className="mono chat-subject">{subject}</span>}
                </div>
                <Md style={{ fontSize: 12 }}>{m.body ?? ''}</Md>
                <button
                  className="chat-reply"
                  onClick={() => setReplyTarget(m)}
                  title="Use this message as context"
                >
                  context
                </button>
              </div>
            </div>
          );
        })}
        <div ref={bottomRef} />
      </div>

      <div className="chat-composer">
        {replyTarget && (
          <div className="reply-context">
            <span>Using {replyTarget.id} as context</span>
            <button className="secondary" onClick={() => setReplyTarget(null)} title="Clear context">clear</button>
          </div>
        )}
        <textarea
          value={body}
          onChange={(e) => setBody(e.target.value)}
          onKeyDown={handleComposerKeyDown}
          rows={3}
          placeholder={`Message ${mayor}`}
        />
        <div className="chat-composer-actions">
          <span className="dim">Enter sends. Shift+Enter adds a line.</span>
          <button onClick={send} disabled={!body.trim() || sending} title="Send message">
            {sending ? 'Sending…' : 'Send'}
          </button>
        </div>
        {result && result.code !== 0 && (
          <div style={{ marginTop: 6, color: 'var(--reject)', fontSize: 11 }}>
            error: {result.stderr || result.stdout}
          </div>
        )}
      </div>
    </div>
  );
}

function RigActivityPanel({ activity, loading }: { activity: RigActivity | null; loading: boolean }) {
  const [expanded, setExpanded] = useState(false);
  const activeRuns = activity?.activeRuns ?? [];
  const staleRuns = activity?.staleRuns ?? [];
  const workBeads = activity?.workBeads ?? [];
  const proposals = activity?.proposals ?? [];
  const latestResults = activity?.latestResultRuns ?? [];
  const sessions = activity?.sessions ?? [];
  const hasWork = activeRuns.length > 0 || workBeads.length > 0 || proposals.some((p) => p.status === 'open');
  const currentStep = activity?.summary?.currentStep;
  const currentRun = activity?.summary?.currentRun;
  const currentRole = String(currentStep?.metadata?.['gc.routed_to'] ?? '').replace(/^.*\/workers\./, '');
  const currentState = currentStep?.ui_worker_state || currentStep?.status || (hasWork ? 'working' : 'idle');

  return (
    <div className={`mayor-work-panel ${expanded ? 'expanded' : 'compact'}`}>
      <div className="mayor-work-head">
        <div>
          <div className="mayor-work-title">Active Gas City Work</div>
          <div className="dim mayor-work-summary">
            <span>{activity?.summary?.nextAction ?? 'Runs, worker beads, proposals, and live sessions for this rig.'}</span>
            {currentRun?.id && <span className="mono">{currentRun.id}</span>}
            {currentRole && <span>{currentRole}</span>}
            {currentStep?.ui_worker_session && <span>{currentStep.ui_worker_session}</span>}
          </div>
        </div>
        <div className="mayor-work-actions">
          <span className={`pill ${hasWork ? 'warn' : 'good'}`}>{loading ? 'refreshing' : currentState}</span>
          <button className="secondary compact-toggle" onClick={() => setExpanded((v) => !v)} title={expanded ? 'Hide work details' : 'Show work details'}>
            {expanded ? 'Hide' : 'Details'}
          </button>
        </div>
      </div>

      {expanded && (
        <div className="mayor-work-details">
          <div className="mayor-work-grid">
            <WorkColumn title="Runs" count={activeRuns.length}>
              {activeRuns.length === 0 ? <div className="dim work-empty">No active convergence.</div> :
                activeRuns.slice(0, 4).map((b) => <RunWorkItem key={b.id} bead={b} />)}
            </WorkColumn>

            <WorkColumn title="Worker Beads" count={workBeads.length}>
              {workBeads.length === 0 ? <div className="dim work-empty">No open coordinator/implementer/reviewer bead.</div> :
                workBeads.slice(0, 5).map((b) => <BeadWorkItem key={b.id} bead={b} />)}
            </WorkColumn>

            <WorkColumn title="Proposals" count={proposals.filter((p) => p.status === 'open').length}>
              {proposals.length === 0 ? <div className="dim work-empty">No recent proposal.</div> :
                proposals.slice(0, 5).map((b) => <ProposalWorkItem key={b.id} bead={b} />)}
            </WorkColumn>

            <WorkColumn title="Research Signals" count={latestResults.length}>
              {latestResults.length === 0 ? <div className="dim work-empty">No reviewed result yet.</div> :
                latestResults.slice(0, 5).map((b) => <ResultWorkItem key={b.id} bead={b} />)}
            </WorkColumn>
          </div>

          {sessions.length > 0 && (
            <div className="session-row">
              {sessions.slice(0, 8).map((s) => (
                <span key={`${s.template}-${s.id}`} className="session-chip" title={s.last_active ?? ''}>
                  <span className={`session-dot ${s.state === 'active' ? 'active' : ''}`} />
                  {s.alias ?? s.template}
                </span>
              ))}
            </div>
          )}
        </div>
      )}

      {expanded && staleRuns.length > 0 && (
        <details className="stale-runs">
          <summary>{staleRuns.length} stale open run{staleRuns.length === 1 ? '' : 's'}</summary>
          {staleRuns.slice(0, 8).map((b) => (
            <Link key={b.id} className="stale-run" to={`/thread/${b.metadata?.['gc.thread_id'] || b.id}`}>
              <span className="mono">{b.id}</span>
              <span>{b.title}</span>
              <span className="dim">{ago(b.updated_at ?? b.created_at)}</span>
            </Link>
          ))}
        </details>
      )}
    </div>
  );
}

function WorkColumn({ title, count, children }: { title: string; count: number; children: ReactNode }) {
  return (
    <div className="work-column">
      <div className="work-column-head">
        <span>{title}</span>
        <span className="mono">{count}</span>
      </div>
      {children}
    </div>
  );
}

function RunWorkItem({ bead }: { bead: Bead }) {
  const md = bead.metadata ?? {};
  const iter = md['convergence.iteration'] ?? '0';
  const max = md['convergence.max_iterations'] ?? '?';
  const state = md['convergence.state'] ?? bead.status;
  return (
    <Link className="work-item" to={`/thread/${md['gc.thread_id'] || bead.id}`}>
      <div className="work-item-title">{bead.title}</div>
      <div className="work-item-meta">
        <span className="mono">{bead.id}</span>
        <span>{state}</span>
        <span>iter {iter}/{max}</span>
        <span>{ago(bead.updated_at ?? bead.created_at)}</span>
      </div>
    </Link>
  );
}

function BeadWorkItem({ bead }: { bead: Bead }) {
  const md = bead.metadata ?? {};
  const root = md['gc.thread_id'] || md['gc.parent_run'] || bead.id;
  const role = String(md['gc.routed_to'] ?? '').replace(/^.*\/workers\./, '');
  const workerState = bead.ui_worker_state || (bead.status === 'in_progress' ? 'claimed' : md['gc.routed_to'] ? 'queued' : bead.status);
  return (
    <Link className="work-item" to={`/thread/${root}`}>
      <div className="work-item-title">{bead.title}</div>
      <div className="work-item-meta">
        <span className="mono">{bead.id}</span>
        <span className={`work-state ${workerState}`}>{workerState}</span>
        <span>{role}</span>
        {(bead.ui_worker_session || bead.assignee) && <span>{bead.ui_worker_session || bead.assignee}</span>}
        <span>{ago(bead.updated_at ?? bead.created_at)}</span>
      </div>
    </Link>
  );
}

function ResultWorkItem({ bead }: { bead: Bead }) {
  const md = bead.metadata ?? {};
  const root = md['gc.thread_id'] || bead.id;
  const result = String(md['gc.result_class'] ?? md['convergence.terminal_reason'] ?? bead.status);
  const learning = String(md['gc.learning_summary'] ?? '').trim();
  return (
    <Link className="work-item" to={`/thread/${root}`}>
      <div className="work-item-title">{bead.title}</div>
      <div className="work-item-meta">
        <span className="mono">{bead.id}</span>
        <span className={`work-state ${result.includes('ACCEPTED') ? 'accepted' : result.includes('BUG') || result.includes('BLOCKED') ? 'blocked' : ''}`}>{result}</span>
        <span>{ago(bead.updated_at ?? bead.closed_at ?? bead.created_at)}</span>
      </div>
      {learning && <div className="work-item-note">{learning}</div>}
    </Link>
  );
}

function ProposalWorkItem({ bead }: { bead: Bead }) {
  const md = bead.metadata ?? {};
  const promoted = md['gc.promoted_to'];
  const root = promoted || md['gc.thread_id'] || md['gc.parent_run'] || bead.id;
  return (
    <Link className="work-item" to={`/thread/${root}`}>
      <div className="work-item-title">{bead.title}</div>
      <div className="work-item-meta">
        <span className="mono">{bead.id}</span>
        <span>{String(md['gc.decision'] ?? bead.status)}</span>
        {promoted && <span>to {promoted}</span>}
        <span>{ago(bead.updated_at ?? bead.created_at)}</span>
      </div>
    </Link>
  );
}

function ago(ts?: string): string {
  if (!ts) return '';
  const t = new Date(ts).getTime();
  if (!Number.isFinite(t)) return ts.replace('T', ' ').slice(11, 16);
  const sec = Math.max(0, Math.floor((Date.now() - t) / 1000));
  if (sec < 60) return `${sec}s ago`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  return `${Math.floor(min / 60)}h ago`;
}
