import { useEffect, useState } from 'react';
import { listSessions, mayorForRig, type GCSession } from '../api';
import { useDash } from '../store';

// Heartbeat strip — live agent status from gascity's native session API.
//
// We poll /v0/city/{name}/sessions every 3s and pick the session(s) likely
// to be working this convergence. gascity itself emits `session.*` events
// but the poll endpoint already has computed `activity` / `state` /
// `context_pct` so we don't need to aggregate events here.
//
// Rules for "is it working":
//   - any active session with activity="in-turn" → RUNNING
//   - any active session idle < 5 min ago → WARM (recently worked)
//   - else → QUIET

type Verdict = 'running' | 'warm' | 'quiet' | 'loading';
function verdictStyle(v: Verdict): { color: string; label: string; dot: string } {
  switch (v) {
    case 'running': return { color: 'var(--accept)', label: 'WORKING', dot: '●' };
    case 'warm':    return { color: 'var(--pending)', label: 'IDLE', dot: '◐' };
    case 'quiet':   return { color: 'var(--fg-dim)', label: 'QUIET', dot: '○' };
    default:        return { color: 'var(--fg-dim)', label: '…', dot: '·' };
  }
}

// Map last_active ISO to minutes since now (for display).
function minutesSince(iso?: string): number | null {
  if (!iso) return null;
  const ms = Date.now() - new Date(iso).getTime();
  if (ms < 0 || !isFinite(ms)) return null;
  return ms / 60_000;
}
function formatAge(mins: number | null): string {
  if (mins == null) return '—';
  if (mins < 1) return `${Math.round(mins * 60)}s`;
  if (mins < 60) return `${Math.round(mins)}m`;
  return `${Math.round(mins / 60)}h`;
}

export default function HeartbeatStrip({ beadId: _beadId }: { beadId: string }) {
  const { city, rig, setSelectedBead, setOpenFileIntent } = useDash();
  const [sessions, setSessions] = useState<GCSession[]>([]);
  const [err, setErr] = useState<string | null>(null);

  async function poll() {
    try {
      const ss = await listSessions(city);
      setSessions(ss);
      setErr(null);
    } catch (e: any) { setErr(String(e)); }
  }
  useEffect(() => {
    poll();
    const t = setInterval(poll, 3000);
    return () => clearInterval(t);
  }, [city]);

  // Pick the pool workers most likely to be on research work.
  const rigMayor = mayorForRig(rig);
  const relevant = sessions.filter(
    (s) => s.running && (
      s.template === rigMayor ||
      (s.template ?? '').includes('implementer') ||
      (s.template ?? '').includes('reviewer')
    ),
  );
  const busy = relevant.filter((s) => s.activity === 'in-turn');
  const warmRecent = relevant.filter((s) => (minutesSince(s.last_active) ?? Infinity) < 5);

  let verdict: Verdict = 'loading';
  let reason = 'loading…';
  if (sessions.length === 0 && !err) { verdict = 'loading'; }
  else if (busy.length > 0) {
    verdict = 'running';
    const agents = busy.map((s) => s.alias || s.template).join(', ');
    reason = `${busy.length} agent${busy.length > 1 ? 's' : ''} in-turn (${agents})`;
  } else if (warmRecent.length > 0) {
    verdict = 'warm';
    const youngest = warmRecent
      .map((s) => minutesSince(s.last_active))
      .filter((m): m is number => m != null)
      .sort((a, b) => a - b)[0];
    reason = `recently active — last ${formatAge(youngest)} ago`;
  } else {
    verdict = 'quiet';
    reason = 'no agents currently in-turn';
  }

  const s = verdictStyle(verdict);

  return (
    <div style={{ fontSize: 11 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 12 }}>
        <div style={{ display: 'flex', gap: 10, alignItems: 'baseline', flexWrap: 'wrap' }}>
          <span style={{ color: s.color, fontWeight: 700 }}>{s.dot} {s.label}</span>
          <span className="dim">{reason}</span>
        </div>
        <button
          className="secondary"
          onClick={() => { setSelectedBead(_beadId); setOpenFileIntent({ beadId: _beadId, preferLog: true }); }}
          style={{ fontSize: 10, padding: '2px 8px' }}
          title="Open newest .log with live tail"
        >
          📡 log
        </button>
      </div>
      {relevant.length > 0 && (
        <div style={{ display: 'flex', gap: 12, marginTop: 4, flexWrap: 'wrap', fontSize: 10 }}>
          {relevant.map((ss) => (
            <span key={ss.id} className="mono" style={{ color: ss.activity === 'in-turn' ? 'var(--accept)' : 'var(--fg-dim)' }}>
              {ss.alias || ss.template}: {ss.activity ?? '?'}
              {ss.context_pct != null && ` · ctx ${ss.context_pct}%`}
              {' · '}last {formatAge(minutesSince(ss.last_active))} ago
            </span>
          ))}
        </div>
      )}
      {err && <div style={{ color: 'var(--reject)', fontSize: 10, marginTop: 4 }}>{err}</div>}
    </div>
  );
}
