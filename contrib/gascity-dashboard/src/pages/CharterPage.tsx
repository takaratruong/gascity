import { useEffect, useState } from 'react';
import Md from '../components/Md';
import { useDash } from '../store';
import { getCharter, saveCharter } from '../api';

export default function CharterPage() {
  const { rig } = useDash();
  const [content, setContent] = useState('');
  const [serverContent, setServerContent] = useState('');
  const [path, setPath] = useState('');
  const [exists, setExists] = useState(false);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [mode, setMode] = useState<'view' | 'edit'>('view');
  const [error, setError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const r = await getCharter(rig);
      setContent(r.content);
      setServerContent(r.content);
      setPath(r.path);
      setExists(r.exists);
    } catch (e: any) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(); }, [rig]);

  async function save() {
    setSaving(true);
    setError(null);
    try {
      await saveCharter(rig, content);
      setServerContent(content);
      setExists(true);
      setSavedAt(Date.now());
      setMode('view');
    } catch (e: any) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  }

  const dirty = content !== serverContent;

  return (
    <>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 12 }}>
        <h1 style={{ margin: 0 }}>Charter — {rig}</h1>
        <div style={{ display: 'flex', gap: 8 }}>
          {mode === 'view' && (
            <button onClick={() => setMode('edit')} style={{ fontSize: 12 }}>
              {exists ? 'Edit' : 'Create PROJECT.md'}
            </button>
          )}
          {mode === 'edit' && (
            <>
              <button className="secondary" onClick={() => { setContent(serverContent); setMode('view'); }} style={{ fontSize: 12 }}>
                Cancel
              </button>
              <button onClick={save} disabled={saving || !dirty} style={{ fontSize: 12 }}>
                {saving ? 'Saving…' : 'Save'}
              </button>
            </>
          )}
        </div>
      </div>
      <div className="dim mono" style={{ fontSize: 10, marginBottom: 10 }}>{path}</div>

      <p className="dim" style={{ fontSize: 12, marginBottom: 14 }}>
        The project charter is read by mayor / implementer / reviewer before every run.
        Non-negotiables here are enforced — a run that violates one gets REJECTED regardless
        of bead-level acceptance. Edit this when the project direction changes, not per-idea.
      </p>

      {savedAt && <div style={{ fontSize: 11, color: 'var(--accept)', marginBottom: 8 }}>Saved — next run will pick up the new charter.</div>}
      {error && <div style={{ fontSize: 11, color: 'var(--reject)', marginBottom: 8 }}>Error: {error}</div>}

      {loading ? <div className="empty">Loading…</div> : !exists && mode === 'view' ? (
        <div className="empty" style={{ padding: 20 }}>
          No PROJECT.md at <span className="mono">{path}</span> yet. Click "Create" above to start one.
        </div>
      ) : mode === 'edit' ? (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, height: 'calc(100vh - 260px)' }}>
          <div style={{ display: 'flex', flexDirection: 'column' }}>
            <div className="dim" style={{ fontSize: 11, marginBottom: 4 }}>
              Markdown source {dirty && <span style={{ color: 'var(--pending)' }}>• unsaved</span>}
            </div>
            <textarea
              value={content}
              onChange={(e) => setContent(e.target.value)}
              style={{ flex: 1, fontFamily: 'ui-monospace, monospace', fontSize: 12, resize: 'none' }}
              spellCheck={false}
            />
          </div>
          <div style={{ overflow: 'auto', padding: 12, background: 'var(--bg-3)', borderRadius: 4 }}>
            <div className="dim" style={{ fontSize: 11, marginBottom: 6 }}>Live preview</div>
            <Md>{content}</Md>
          </div>
        </div>
      ) : (
        <div style={{ padding: 14, background: 'var(--bg-3)', borderRadius: 4 }}>
          <Md>{serverContent}</Md>
        </div>
      )}
    </>
  );
}
