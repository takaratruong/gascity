import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import Md from './Md';
import { useDash, type BeadPanelItem } from '../store';
import { getBead, readFile, listDir, binaryUrl, convergeStop, mayorForRig, type Bead } from '../api';

export default function ArtifactPanel() {
  const { city, rig, selectedBead, setSelectedBead, beadListPanel, setBeadListPanel, openFileIntent, setOpenFileIntent } = useDash();
  const [bead, setBead] = useState<Bead | null>(null);
  const [runDir, setRunDir] = useState<string | null>(null);
  const [files, setFiles] = useState<Array<{ name: string; isDir: boolean; path: string }>>([]);
  const [openFile, setOpenFile] = useState<{ name: string; content: string; type: 'text' | 'image' | 'video' } | null>(null);
  const [loading, setLoading] = useState(false);
  const [tailing, setTailing] = useState(false);

  useEffect(() => {
    // ALWAYS clear any open file on bead switch so stale file content from
    // the previous bead doesn't bleed through during the async reload.
    setOpenFile(null);
    setTailing(false);
    if (!selectedBead) { setBead(null); setRunDir(null); setFiles([]); return; }
    (async () => {
      setLoading(true);
      try {
        const b = await getBead(city, selectedBead);
        setBead(b);
        let rdir: string | null = null;
        if (!b) {
          setRunDir(null);
          setFiles([]);
          return;
        }
        // Preferred: worktree-isolated run dir (new path, post-worktree change).
        // Convergence roots often store the active wisp's worktree. In that
        // case artifacts are under run-<active_wisp>, not run-<root>.
        const activeWisp = b.metadata?.['convergence.active_wisp'] as string | undefined;
        const beadRig = (b?.metadata?.['var.rig'] || b?.metadata?.['gc.rig'] || rig) as string;
        const wt = (b.metadata?.['gc.worktree_dir'] as string | undefined) ||
          (activeWisp ? `/home/ubuntu/worktrees/${beadRig}/${activeWisp}` : undefined);
        if (wt) {
          const candidates = Array.from(new Set([
            activeWisp ? `${wt}/results/run-${activeWisp}` : null,
            `${wt}/results/run-${b.id}`,
          ].filter(Boolean) as string[]));
          for (const p of candidates) {
            try {
              const ls = await listDir(p);
              if (ls !== null) { rdir = p; break; }
            } catch { /* ignore */ }
          }
        }
        // Fallback 1: explicit gc.run_dir metadata.
        if (!rdir) {
          const rd = b?.metadata?.['gc.run_dir'] as string | undefined;
          if (rd) rdir = rd;
        }
        // Fallback 2: legacy shared-rig path (pre-worktree runs).
        if (!rdir && b && (b.metadata?.['convergence.formula'] || b.metadata?.['convergence.terminal_reason'])) {
          const candidates = Array.from(new Set([beadRig, rig, 'park-manip', 'mjx-diffphysics']));
          for (const rig of candidates) {
            const p = `/home/ubuntu/projects/${rig}/results/run-${b.id}`;
            try {
              const ls = await listDir(p);
              if (ls && ls.length) { rdir = p; break; }
            } catch { /* ignore */ }
          }
        }
        setRunDir(rdir);
        if (rdir) {
          try { setFiles(await listDir(rdir)); } catch { setFiles([]); }
        } else setFiles([]);
        setOpenFile(null);
      } finally { setLoading(false); }
    })();
  }, [city, selectedBead]);

  // Consume openFileIntent: if the heartbeat (or any caller) asked us to
  // open the newest log file on this bead, do it once files have loaded.
  useEffect(() => {
    if (!openFileIntent || !openFileIntent.preferLog) return;
    if (openFileIntent.beadId !== selectedBead) return;
    if (files.length === 0) return;
    // Find newest .log file in the run dir. Only use .log (not .md/.json).
    const logs = files.filter((f) => !f.isDir && f.name.toLowerCase().endsWith('.log'));
    if (logs.length === 0) { setOpenFileIntent(null); return; }
    // Prefer the one whose name sorts last (iter2_run.log > run.log) as a
    // proxy for "newest iteration". Tie-break on mtime would require extra
    // stat calls; filename is good enough for our naming convention.
    logs.sort((a, b) => a.name.localeCompare(b.name));
    const target = logs[logs.length - 1];
    (async () => {
      try {
        const text = await readFile(target.path);
        setOpenFile({ name: target.name, content: text, type: 'text' });
        setTailing(true);
      } catch { /* ignore */ }
      setOpenFileIntent(null);
    })();
  }, [openFileIntent, selectedBead, files, setOpenFileIntent]);

  // Live-tail effect: when tailing is on and a text file is open, re-read
  // it every 3s so running logs (run.log, kimodo_load_attempt.log, etc.)
  // update without manual refresh. Only text files — binaries/images stay
  // static.
  useEffect(() => {
    if (!tailing || !openFile || openFile.type !== 'text') return;
    // Find the file path from the current files list.
    const filePath = files.find((f) => f.name === openFile.name)?.path;
    if (!filePath) return;
    const interval = setInterval(async () => {
      try {
        const text = await readFile(filePath);
        setOpenFile((prev) => (prev && prev.name === openFile.name ? { ...prev, content: text } : prev));
      } catch { /* file vanished, ignore */ }
    }, 3000);
    return () => clearInterval(interval);
  }, [tailing, openFile?.name, openFile?.type, files]);

  async function openArtifact(f: { name: string; isDir: boolean; path: string }) {
    if (f.isDir) return; // could recurse; skip for now
    setTailing(false); // reset tail state when opening a new file
    const ext = f.name.split('.').pop()?.toLowerCase() ?? '';
    if (['png', 'jpg', 'jpeg', 'gif', 'svg'].includes(ext)) {
      setOpenFile({ name: f.name, content: binaryUrl(f.path), type: 'image' });
    } else if (['mp4', 'webm'].includes(ext)) {
      setOpenFile({ name: f.name, content: binaryUrl(f.path), type: 'video' });
    } else {
      try {
        const text = await readFile(f.path);
        setOpenFile({ name: f.name, content: text, type: 'text' });
      } catch (e) {
        setOpenFile({ name: f.name, content: 'Error: ' + String(e), type: 'text' });
      }
    }
  }

  async function stopConvergence() {
    if (!bead) return;
    if (!confirm(`Stop convergence ${bead.id}?`)) return;
    const r = await convergeStop(bead.id);
    if (r.code === 0) {
      alert(`stop requested for ${bead.id}`);
    } else {
      alert(`could not stop ${bead.id}:\n\n${(r.stderr || r.stdout || 'unknown error').trim()}`);
    }
  }

  if (beadListPanel) {
    return (
      <>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 8 }}>
          <h1 style={{ margin: 0 }}>{beadListPanel.title}</h1>
          <button className="secondary" style={{ fontSize: 11, padding: '3px 8px' }} onClick={() => setBeadListPanel(null)}>✕</button>
        </div>
        <div className="dim" style={{ fontSize: 11, marginTop: 6, marginBottom: 12 }}>
          {beadListPanel.items.length} beads in this run view
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {beadListPanel.items.map((item) => (
            <BeadListPanelRow key={item.id} item={item} rig={rig} onInspect={() => setSelectedBead(item.id)} />
          ))}
        </div>
      </>
    );
  }

  if (!selectedBead) {
    return <div className="empty">Select a bead to inspect.</div>;
  }

  const isConvergence = bead?.metadata?.['convergence.formula'] || bead?.metadata?.['convergence.terminal_reason'];
  const isActive = bead?.metadata?.['convergence.active_wisp'] && bead?.status === 'open';

  return (
    <>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
        <h1 style={{ margin: 0 }}>
          <span className="mono">{selectedBead}</span>
        </h1>
        <button className="secondary" style={{ fontSize: 11, padding: '3px 8px' }} onClick={() => setSelectedBead(null)}>✕</button>
      </div>

      {loading && <div className="empty">Loading…</div>}
      {!loading && bead && (
        <>
          <div style={{ marginTop: 8, marginBottom: 12 }}>
            <div style={{ marginBottom: 4 }}>{bead.title}</div>
            <div>
              <span className={`status-tag status-${bead.status}`}>{bead.status}</span>
              {' '}
              {(bead.labels ?? []).map((l) => <span key={l} className="label-tag">{l}</span>)}
            </div>
          </div>

          {bead.description && (
            <details>
              <summary className="dim" style={{ fontSize: 11, cursor: 'pointer' }}>description</summary>
              <div style={{ marginTop: 6 }}>
                <Md style={{ fontSize: 11 }}>{bead.description}</Md>
              </div>
            </details>
          )}

          {(() => {
            const lineageRoot = bead.metadata?.['gc.lineage_root'] as string | undefined;
            // Fall back to this bead itself if it's a depth-0 convergence root
            const isRootOfItsOwnLineage = bead.issue_type === 'convergence' &&
              (bead.metadata?.['gc.lineage_depth'] === '0' || !bead.metadata?.['gc.lineage_depth']);
            const root = lineageRoot ?? (isRootOfItsOwnLineage ? bead.id : undefined);
            if (!root) return null;
            return (
              <div style={{ marginTop: 10 }}>
                <Link to={`/thread/${root}`}>
                  <button className="secondary" style={{ fontSize: 11, padding: '4px 10px' }}>
                    Open run detail ({root})
                  </button>
                </Link>
              </div>
            );
          })()}

          {isConvergence && (
            <div style={{ marginTop: 14, padding: 10, background: 'var(--bg-3)', borderRadius: 4 }}>
              <div className="dim" style={{ fontSize: 11, marginBottom: 6 }}>Convergence</div>
              <div style={{ fontSize: 12 }}>
                state: {bead.metadata?.['convergence.state']} ·
                iter: {bead.metadata?.['convergence.iteration'] ?? '0'}/{bead.metadata?.['convergence.max_iterations']}
              </div>
              {bead.metadata?.['convergence.terminal_reason'] && (
                <div style={{ fontSize: 12, marginTop: 4 }}>
                  terminal: <b>{bead.metadata['convergence.terminal_reason']}</b>
                  {bead.metadata['convergence.gate_stdout'] && (
                    <div className="dim mono" style={{ fontSize: 11, marginTop: 3 }}>
                      {bead.metadata['convergence.gate_stdout'].trim()}
                    </div>
                  )}
                </div>
              )}
              {isActive && (
                <button className="danger" style={{ marginTop: 8, fontSize: 11, padding: '4px 8px' }} onClick={stopConvergence}>
                  Stop convergence
                </button>
              )}
            </div>
          )}

          {runDir && (
            <>
              <h2>Artifacts</h2>
              <div className="dim mono" style={{ fontSize: 10, marginBottom: 8 }}>{runDir}</div>
              {files.length === 0 ? <div className="empty">No files.</div> : (
                <ul style={{ listStyle: 'none', padding: 0, margin: 0 }}>
                  {files.map((f) => (
                    <li key={f.path}>
                      <button
                        className="secondary"
                        style={{ display: 'block', width: '100%', textAlign: 'left', padding: '5px 8px', margin: '2px 0', fontSize: 11 }}
                        onClick={() => openArtifact(f)}
                        disabled={f.isDir}
                      >
                        {f.isDir ? '📁 ' : '📄 '}{f.name}
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </>
          )}

          {openFile && (
            <div style={{ marginTop: 16, border: '1px solid var(--border)', borderRadius: 4, padding: 10 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8, alignItems: 'center', gap: 6 }}>
                <b style={{ fontSize: 12 }}>{openFile.name}</b>
                <div style={{ display: 'flex', gap: 6 }}>
                  {openFile.type === 'text' && (
                    <button
                      className="secondary"
                      style={{
                        fontSize: 11, padding: '2px 8px',
                        background: tailing ? 'var(--accept)' : undefined,
                        color: tailing ? '#000' : undefined,
                      }}
                      onClick={() => setTailing(!tailing)}
                      title={tailing ? 'Stop live tail' : 'Live-tail this file (refresh every 3s)'}
                    >
                      {tailing ? '● tailing' : '📡 tail'}
                    </button>
                  )}
                  <button className="secondary" style={{ fontSize: 11, padding: '2px 6px' }} onClick={() => { setTailing(false); setOpenFile(null); }}>close</button>
                </div>
              </div>
              {openFile.type === 'image' && <img src={openFile.content} style={{ maxWidth: '100%' }} alt={openFile.name} />}
              {openFile.type === 'video' && <video src={openFile.content} controls style={{ maxWidth: '100%' }} />}
              {openFile.type === 'text' && (openFile.name.endsWith('.md') ?
                <Md>{openFile.content}</Md> :
                <pre
                  ref={(el) => { if (el && tailing) el.scrollTop = el.scrollHeight; }}
                  style={{ whiteSpace: 'pre-wrap', fontSize: 11, margin: 0, maxHeight: 400, overflow: 'auto' }}
                >
                  {openFile.content}
                </pre>
              )}
            </div>
          )}

          <h2>CLI</h2>
          <div className="mono" style={{ fontSize: 11, padding: 8, background: 'var(--bg-3)', borderRadius: 3 }}>
            gc bd show {bead.id}
            <br />
            gc session attach {mayorForRig(rig)}
            {isConvergence && <><br />gc converge status {bead.id}</>}
          </div>
        </>
      )}
    </>
  );
}

function BeadListPanelRow({ item, rig, onInspect }: { item: BeadPanelItem; rig: string; onInspect: () => void }) {
  const md = item.metadata ?? {};
  const summary = beadSummary(item);
  const labels = item.labels ?? [];
  return (
    <div style={{ padding: 10, background: 'var(--bg-3)', border: '1px solid var(--border)', borderRadius: 4 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, alignItems: 'flex-start' }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ display: 'flex', gap: 8, alignItems: 'baseline', flexWrap: 'wrap' }}>
            <span className="mono" style={{ fontSize: 10, color: 'var(--fg-dim)' }}>{item.id}</span>
            <span className="dim" style={{ fontSize: 10 }}>{relAge(item.updated_at ?? item.closed_at ?? item.created_at)}</span>
          </div>
          <div style={{ fontSize: 12, fontWeight: 600, marginTop: 2 }}>{item.title || '(untitled)'}</div>
        </div>
        <button className="secondary" style={{ fontSize: 11, padding: '3px 8px', flex: '0 0 auto' }} onClick={onInspect}>
          inspect
        </button>
      </div>
      <div style={{ marginTop: 6, display: 'flex', gap: 4, flexWrap: 'wrap' }}>
        <span className={`status-tag status-${item.status}`}>{item.status}</span>
        {item.issue_type && <span className="label-tag">{item.issue_type}</span>}
        {labels.slice(0, 4).map((l) => <span key={l} className="label-tag">{l}</span>)}
      </div>
      <div className="dim" style={{ fontSize: 11, marginTop: 8, lineHeight: 1.4 }}>
        {summary}
      </div>
      <BeadMiniPreview item={item} rig={rig} />
      {(md['gc.role'] || md['gc.routed_to'] || item.assignee) && (
        <div className="dim mono" style={{ fontSize: 10, marginTop: 6 }}>
          {md['gc.role'] ? `role=${md['gc.role']} ` : ''}
          {md['gc.routed_to'] ? `routed=${md['gc.routed_to']} ` : ''}
          {item.assignee ? `assignee=${item.assignee}` : ''}
        </div>
      )}
    </div>
  );
}

function BeadMiniPreview({ item, rig }: { item: BeadPanelItem; rig: string }) {
  const [preview, setPreview] = useState<{ type: 'video' | 'image'; path: string; name: string } | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      for (const dir of runDirCandidates(item, rig)) {
        try {
          const files = await listDir(dir);
          const rootPreview = pickPreview(files);
          if (rootPreview) {
            if (!cancelled) setPreview(rootPreview);
            return;
          }
          const reviewDir = files.find((f) => f.isDir && f.name === 'review_artifacts');
          if (reviewDir) {
            const reviewFiles = await listDir(reviewDir.path);
            const nestedPreview = pickPreview(reviewFiles);
            if (nestedPreview) {
              if (!cancelled) setPreview(nestedPreview);
              return;
            }
          }
        } catch { /* try next candidate */ }
      }
      if (!cancelled) setPreview(null);
    })();
    return () => { cancelled = true; };
  }, [item.id, rig]);

  if (!preview) return null;
  const src = binaryUrl(preview.path);
  return (
    <div style={{ marginTop: 8, border: '1px solid var(--border)', borderRadius: 4, overflow: 'hidden', background: 'var(--bg-2)' }}>
      <div className="dim mono" style={{ fontSize: 9, padding: '3px 6px', borderBottom: '1px solid var(--border)' }}>
        {preview.name}
      </div>
      {preview.type === 'video' ? (
        <video src={src} muted preload="metadata" controls style={{ display: 'block', width: '100%', maxHeight: 130, background: '#000' }} />
      ) : (
        <img src={src} alt={preview.name} style={{ display: 'block', width: '100%', maxHeight: 130, objectFit: 'contain', background: '#000' }} />
      )}
    </div>
  );
}

function runDirCandidates(item: BeadPanelItem, rig: string): string[] {
  const md = item.metadata ?? {};
  const activeWisp = md['convergence.active_wisp'] as string | undefined;
  const beadRig = (md['var.rig'] || md['gc.rig'] || rig) as string;
  const wt = (md['gc.worktree_dir'] as string | undefined) ||
    (activeWisp ? `/home/ubuntu/worktrees/${beadRig}/${activeWisp}` : undefined);
  const candidates = [
    md['gc.run_dir'] as string | undefined,
    wt && activeWisp ? `${wt}/results/run-${activeWisp}` : undefined,
    wt ? `${wt}/results/run-${item.id}` : undefined,
    `/home/ubuntu/projects/${beadRig}/results/run-${item.id}`,
    `/home/ubuntu/projects/${rig}/results/run-${item.id}`,
  ].filter(Boolean) as string[];
  return Array.from(new Set(candidates));
}

function pickPreview(files: Array<{ name: string; isDir: boolean; path: string }>): { type: 'video' | 'image'; path: string; name: string } | null {
  const regular = files.filter((f) => !f.isDir);
  const video = regular.find((f) => f.name === 'rollout.mp4') ||
    regular.find((f) => f.name.toLowerCase().endsWith('.mp4'));
  if (video) return { type: 'video', path: video.path, name: video.name };

  const imagePrefs = [
    'topdown_isaaclab.png',
    'topdown.png',
    'metrics_comparison.png',
    'convergence.png',
    'grid_001.png',
    'human_001.png',
    'frame_001.png',
  ];
  for (const name of imagePrefs) {
    const hit = regular.find((f) => f.name === name);
    if (hit) return { type: 'image', path: hit.path, name: hit.name };
  }
  const image = regular.find((f) => /\.(png|jpe?g|gif|webp)$/i.test(f.name));
  return image ? { type: 'image', path: image.path, name: image.name } : null;
}

function relAge(s?: string): string {
  if (!s) return '';
  const d = new Date(s);
  const delta = Date.now() - d.getTime();
  if (!Number.isFinite(delta)) return '';
  if (delta < 60_000) return 'just now';
  if (delta < 3600_000) return `${Math.floor(delta / 60_000)}m ago`;
  if (delta < 86400_000) return `${Math.floor(delta / 3600_000)}h ago`;
  return `${Math.floor(delta / 86400_000)}d ago`;
}

function beadSummary(item: BeadPanelItem): string {
  const md = item.metadata ?? {};
  const role = md['gc.role'];
  const result = md['gc.result_class'];
  const routed = md['gc.routed_to'];
  const step = md['gc.step_ref'];
  const followup = md['gc.followup_kind'];
  const thread = md['gc.thread_title'];
  const pieces: string[] = [];
  if (result) pieces.push(`Result: ${result}.`);
  if (role) pieces.push(`Role: ${role}.`);
  if (step) pieces.push(`Step: ${step}.`);
  if (followup) pieces.push(`Follow-up: ${followup}.`);
  if (thread) pieces.push(`Run group: ${thread}.`);
  if (routed) pieces.push(`Routed to ${routed}.`);
  if (pieces.length > 0) return pieces.join(' ');
  const desc = (item.description ?? '').replace(/\s+/g, ' ').trim();
  if (desc) return desc.slice(0, 220) + (desc.length > 220 ? '...' : '');
  return 'No summary metadata or description available.';
}
