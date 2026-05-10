import { useDash } from '../store';
import { type Bead } from '../api';

interface Props {
  bead: Bead;
  showStatus?: boolean;
  showLabels?: boolean;
  showDepth?: boolean;
}

function ts(s?: string) {
  if (!s) return '';
  const d = new Date(s);
  const delta = Date.now() - d.getTime();
  if (delta < 60_000) return 'just now';
  if (delta < 3600_000) return Math.floor(delta / 60_000) + 'm';
  if (delta < 86400_000) return Math.floor(delta / 3600_000) + 'h';
  return Math.floor(delta / 86400_000) + 'd';
}

export default function BeadRow({ bead, showStatus = false, showLabels = false, showDepth = true }: Props) {
  const { selectedBead, setSelectedBead } = useDash();
  const isSelected = selectedBead === bead.id;
  const depth = bead.metadata?.['gc.lineage_depth'];

  return (
    <tr
      onClick={() => setSelectedBead(bead.id)}
      style={{ cursor: 'pointer', background: isSelected ? 'var(--bg-3)' : undefined }}
    >
      <td className="mono">{bead.id}</td>
      <td>{bead.title}</td>
      {showStatus && <td><span className={`status-tag status-${bead.status}`}>{bead.status}</span></td>}
      {showLabels && (
        <td>
          {(bead.labels ?? []).slice(0, 3).map((l) => <span key={l} className="label-tag">{l}</span>)}
        </td>
      )}
      {showDepth && <td className="dim">{depth ?? ''}</td>}
      <td className="dim">{ts(bead.updated_at ?? bead.created_at)}</td>
    </tr>
  );
}
