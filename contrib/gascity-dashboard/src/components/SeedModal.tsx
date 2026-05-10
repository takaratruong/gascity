import { useState } from 'react';
import { mayorChat, mayorForRig, type ExecResult } from '../api';
import { useDash } from '../store';

// New research ideas enter through the rig mayor. The mayor is the persistent
// research partner for the rig; proposals and convergences are Beads it creates
// or delegates, not a separate user-facing "thread" object.

export default function SeedModal({ onClose }: { onClose: () => void }) {
  const { rig } = useDash();
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<ExecResult | null>(null);

  async function submit() {
    if (!title.trim() || !body.trim()) {
      setResult({ stdout: '', stderr: 'title and body are required', code: 1 });
      return;
    }
    setBusy(true);
    setResult(null);
    try {
      const r = await mayorChat({
        rig,
        body: [
          `New research idea: ${title.trim()}`,
          '',
          body.trim(),
          '',
          'Please decide whether this should become a proposal, an immediate evaluate-idea run, a policy/directive update, or just discussion. Keep ownership in the rig mayor conversation and use Beads/formulas for durable work.',
        ].join('\n'),
      });
      setResult(r);
      if (r.code === 0) {
        setTimeout(onClose, 1200);
      }
    } catch (err: any) {
      setResult({ stdout: '', stderr: String(err), code: -1 });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.55)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        zIndex: 1000,
      }}
      onClick={onClose}
    >
      <div
        style={{
          background: 'var(--bg-2)', border: '1px solid var(--border)',
          borderRadius: 6, padding: 20, width: 640, maxWidth: '92vw',
          maxHeight: '90vh', overflow: 'auto',
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 14 }}>
          <h2 style={{ margin: 0 }}>Seed a new idea <span className="dim" style={{ fontSize: 12, fontWeight: 'normal' }}>→ rig: {rig}</span></h2>
          <button className="secondary" onClick={onClose} style={{ fontSize: 12 }}>✕</button>
        </div>

        <div className="form-row">
          <label>Send to</label>
          <div className="form-help" style={{ fontSize: 12 }}>
            {mayorForRig(rig)}. The mayor decides whether to file a proposal,
            launch a run, update policy, or ask a clarification.
          </div>
        </div>

        <div className="form-row">
          <label>Title</label>
          <input
            type="text"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="short, one-line summary"
            autoFocus
          />
        </div>

        <div className="form-row">
          <label>Description</label>
          <textarea
            value={body}
            onChange={(e) => setBody(e.target.value)}
            rows={12}
            placeholder="Goal, method family, acceptance criterion, files in scope, constraints, and what evidence you expect back."
          />
        </div>

        <div className="form-row horizontal">
          <button disabled={busy} onClick={submit}>
            {busy ? 'Sending…' : 'Send to mayor'}
          </button>
          <button className="secondary" onClick={onClose}>Cancel</button>
        </div>

        {result && (
          <div style={{ marginTop: 14, padding: 10, background: 'var(--bg-3)', borderRadius: 4 }}>
            <div className="dim" style={{ fontSize: 11, marginBottom: 4 }}>exit: {result.code}</div>
            {result.stdout && <pre style={{ margin: 0, whiteSpace: 'pre-wrap', fontSize: 11 }}>{result.stdout}</pre>}
            {result.stderr && <pre style={{ margin: 0, whiteSpace: 'pre-wrap', fontSize: 11, color: 'var(--reject)' }}>{result.stderr}</pre>}
          </div>
        )}
      </div>
    </div>
  );
}
