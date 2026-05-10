import { NavLink, Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { useEffect, useState } from 'react';
import { useDash } from './store';
import { listRigs, curatorStatus, curatorPause, curatorResume, warmRigCache, type Rig, type CuratorStatus } from './api';
import ThreadPage from './pages/ThreadPage';
import ThreadsPage from './pages/ThreadsPage';
import CharterPage from './pages/CharterPage';
import MayorPage from './pages/MayorPage';
import ArtifactPanel from './components/ArtifactPanel';
import SeedModal from './components/SeedModal';
import './app.css';

export default function App() {
  const { city, rig, setRig } = useDash();
  const [rigs, setRigs] = useState<Rig[]>([]);
  const [status, setStatus] = useState<CuratorStatus>({ soft: null, hard: null });
  const [showSeed, setShowSeed] = useState(false);
  const loc = useLocation();
  // Artifact panel appears on /thread/* (deep-dive mode). Kanban + charter
  // don't need it — more horizontal space for the actual content.
  const showArtifactPanel = loc.pathname.startsWith('/thread/');

  async function refreshStatus() {
    try {
      const [rigsData, statusData] = await Promise.all([listRigs(city), curatorStatus()]);
      setRigs(rigsData);
      warmRigCache(rigsData);
      setStatus(statusData);
    } catch (e) { console.error(e); }
  }

  useEffect(() => {
    refreshStatus();
    const t = setInterval(refreshStatus, 10000);
    return () => clearInterval(t);
  }, [city]);

  async function togglePause(hard: boolean) {
    const active = hard ? status.hard : status.soft;
    if (active) await curatorResume(hard);
    else await curatorPause(hard, `paused from dashboard at ${new Date().toLocaleString()}`);
    refreshStatus();
  }

  const curatorReason = (value: unknown) => {
    if (!value) return '';
    if (typeof value === 'string') return value.trim();
    if (typeof value === 'object' && value && 'title' in value) {
      return String((value as { title?: unknown }).title ?? '').trim();
    }
    return String(value).trim();
  };

  const handleRigSelect = (value: string) => {
    if (value && value !== rig) setRig(value);
  };

  return (
    <div className="app" style={{ gridTemplateColumns: showArtifactPanel ? '240px 1fr 420px' : '240px 1fr' }}>
      <aside className="sidebar">
        <div>
          <div className="brand-title">Gas City</div>
          <div className="brand-sub">city: {city}</div>
        </div>

        <div className="rig-picker">
          <label>Rig / Project</label>
          <select
            value={rig}
            onInput={(e) => handleRigSelect(e.currentTarget.value)}
            onChange={(e) => handleRigSelect(e.currentTarget.value)}
          >
            {rigs.length === 0 && <option value={rig}>{rig}</option>}
            {rigs.map((r) => (
              <option key={r.name} value={r.name}>{r.name}</option>
            ))}
          </select>
        </div>

        <button
          onClick={() => setShowSeed(true)}
          style={{
            width: '100%', padding: '10px 12px', fontSize: 13, fontWeight: 600,
            background: 'var(--accept)', color: '#000', border: 'none',
            borderRadius: 4, cursor: 'pointer', marginBottom: 4,
          }}
        >
          + Ask mayor
        </button>

        <nav className="nav">
          <NavLink to="/mayor">Mayor Chat</NavLink>
          <NavLink to="/threads">Research Runs</NavLink>
          <NavLink to="/charter">Charter</NavLink>
        </nav>

        <div className="curator-status">
          <div className="curator-title">Curator</div>
          {status.hard ? (
            <>
              <span className="pill bad">HARD PAUSED</span>
              <div className="curator-reason">{curatorReason(status.hard)}</div>
            </>
          ) : status.soft ? (
            <>
              <span className="pill warn">SOFT PAUSED</span>
              <div className="curator-reason">{curatorReason(status.soft)}</div>
            </>
          ) : (
            <span className="pill good">RUNNING</span>
          )}
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            <button className="secondary" style={{ fontSize: 11, padding: '4px 8px' }} onClick={() => togglePause(false)}>
              {status.soft ? 'Resume (soft)' : 'Soft pause'}
            </button>
            <button className="secondary" style={{ fontSize: 11, padding: '4px 8px' }} onClick={() => togglePause(true)}>
              {status.hard ? 'Resume (hard)' : 'Hard pause'}
            </button>
          </div>
          <button className="refresh-btn" onClick={refreshStatus}>↻ Refresh</button>
        </div>
      </aside>

      <main className="main">
        <Routes>
          <Route path="/" element={<Navigate to="/mayor" replace />} />
          <Route path="/threads" element={<ThreadsPage />} />
          <Route path="/mayor" element={<MayorPage />} />
          <Route path="/charter" element={<CharterPage />} />
          <Route path="/thread/:rootId" element={<ThreadPage />} />
        </Routes>
      </main>

      {showArtifactPanel && (
        <section className="artifact-panel">
          <ArtifactPanel />
        </section>
      )}

      {showSeed && <SeedModal onClose={() => setShowSeed(false)} />}
    </div>
  );
}
