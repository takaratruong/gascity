// Thin wrapper around the dashboard backend. All data access goes through here.

import axios from 'axios';

// 20s is too tight for `/exec/*` routes that shell to gc: `mail reply --notify`
// to an asleep mayor routinely takes 30s+ while the session wakes. Read-side
// routes finish in <1s; this higher ceiling only matters for write endpoints.
const http = axios.create({ baseURL: '', timeout: 120000 });

// ── Types (thin; not exhaustive — we only pull fields we use)
export interface Bead {
  id: string;
  title: string;
  description?: string;
  status: string;
  issue_type?: string;
  priority?: number;
  created_at?: string;
  updated_at?: string;
  closed_at?: string;
  parent?: string | null;
  assignee?: string | null;
  labels?: string[];
  metadata?: Record<string, any>;
  ui_worker_state?: string | null;
  ui_worker_session?: string | null;
}

export interface City { name: string; path: string; running: boolean; }
export interface Rig { name: string; path?: string; prefix?: string; suspended?: boolean; }
export interface Agent { name: string; dir?: string; running_count?: number; min?: number; max?: number; }
export interface CuratorStatus { soft: string | null; hard: string | null; }

// ── Cities
export async function listCities(): Promise<City[]> {
  const { data } = await http.get('/api/v0/cities');
  return data.items ?? data ?? [];
}

// ── Rigs
export async function listRigs(city: string): Promise<Rig[]> {
  const { data } = await http.get(`/api/v0/city/${city}/rigs`);
  return data.items ?? data ?? [];
}

// ── Agents
export async function listAgents(city: string): Promise<Agent[]> {
  const { data } = await http.get(`/api/v0/city/${city}/agents`);
  return data.items ?? data ?? [];
}

// ── Beads (with optional filters)
// Prefer the native supervisor API for simple open/status-specific reads. Keep
// `/exec/bd/list` for metadata-field filters and closed-inclusive "all" reads:
// upstream currently has status/label/rig query params, but no metadata query
// and no "include open + closed" query knob.
async function listBeadsViaExec(
  opts: { status?: string; label?: string; limit?: number; rig?: string; all?: boolean; metadataField?: string } = {},
): Promise<Bead[]> {
  const params = new URLSearchParams();
  if (opts.status) params.set('status', opts.status);
  if (opts.label) params.set('label', opts.label);
  if (opts.limit) params.set('limit', String(opts.limit));
  if (opts.rig) params.set('rig', opts.rig);
  if (opts.all !== false) params.set('all', '1'); // default to --all so closed beads show up
  if (opts.metadataField) params.set('metadata-field', opts.metadataField);
  const qs = params.toString();
  const { data } = await http.get(`/exec/bd/list${qs ? '?' + qs : ''}`);
  return data.items ?? [];
}

export async function listBeads(
  city: string,
  opts: { status?: string; label?: string; limit?: number; rig?: string; all?: boolean; metadataField?: string } = {},
): Promise<Bead[]> {
  const wantsClosedInclusiveAll = opts.all !== false && !opts.status;
  const requiresExec = Boolean(opts.metadataField) || wantsClosedInclusiveAll || opts.all === true;
  if (!requiresExec) {
    const params = new URLSearchParams();
    if (opts.status) params.set('status', opts.status);
    if (opts.label) params.set('label', opts.label);
    if (opts.limit) params.set('limit', String(opts.limit));
    if (opts.rig) params.set('rig', opts.rig);
    try {
      const qs = params.toString();
      const { data } = await http.get(`/api/v0/city/${city}/beads${qs ? '?' + qs : ''}`);
      return data.items ?? data ?? [];
    } catch {
      // If the supervisor is still adopting sessions, preserve UI behavior by
      // falling back to the bd-backed route.
    }
  }
  const items = await listBeadsViaExec(opts);
  if (opts.rig) {
    const prefix = prefixForRig(opts.rig);
    if (prefix) return items.filter((b) => b.id.startsWith(prefix + '-'));
  }
  return items;
}

// Known-fallback map for rigs whose supervisor `/rigs` response omits the
// prefix field (happens on older rig registrations done before the prefix
// flag became routine). Most modern rigs report prefix directly.
const RIG_PREFIX_FALLBACK: Record<string, string> = {
  'park-manip': 'pm',
  'mjx-diffphysics': 'md',
  'robotics-bench': 'rb',
  'hello-world': 'hw',
};

// In-memory cache of the last listRigs() result — populated on first call,
// used by prefixForRig for synchronous lookup. UI refreshes it via
// warmRigCache() on app init and after rig config changes.
let RIG_CACHE: Rig[] = [];

export function warmRigCache(rigs: Rig[]): void {
  RIG_CACHE = rigs;
}

export function prefixForRig(rig: string): string {
  const hit = RIG_CACHE.find((r) => r.name === rig);
  if (hit?.prefix) return hit.prefix;
  if (RIG_PREFIX_FALLBACK[rig]) return RIG_PREFIX_FALLBACK[rig];
  // Last resort: name slice. Usually wrong for hyphenated names but
  // better than nothing.
  return rig.slice(0, 2);
}

export function mayorForRig(rig: string): string {
  switch (rig) {
    case 'mjx-diffphysics':
      return 'mjx-mayor';
    case 'park-manip':
      return 'park-mayor';
    case 'robotics-bench':
      return 'robotics-mayor';
    default:
      return `${rig}-mayor`;
  }
}

// Decide whether a bead "belongs to" a rig. Multiple signals, because a
// single prefix check is wrong for two important cases:
//   1. Convergence root beads are often `bl-*` (created city-level by
//      `gc converge create` or promoted from city-level proposals).
//      Their rig affinity is on the worktree path or the formula vars.
//   2. Step beads inherit prefix from their parent convergence, which
//      may or may not match the rig.
// Priority: explicit metadata > worktree path > prefix match.
export function beadBelongsToRig(b: Bead, rig: string): boolean {
  const md = b.metadata || {};
  // 1. Explicit worktree path
  const wt = md['gc.worktree_dir'] as string | undefined;
  if (wt && wt.includes(`/${rig}/`)) return true;
  // 2. Formula var.rig (set by evaluate-idea and similar)
  const varRig = md['var.rig'] as string | undefined;
  if (varRig === rig) return true;
  // 3. Retry-of chain: if we can only see the metadata of the current bead,
  //    at least recognize that a retry of a rig bead belongs to that rig.
  //    (Caller would resolve this via the parent convs pass; included here
  //    as a hint.)
  // 4. Bead prefix match
  const prefix = prefixForRig(rig);
  if (prefix && b.id.startsWith(prefix + '-')) return true;
  return false;
}

// ── Single bead fetch
export async function getBead(city: string, id: string, rig?: string): Promise<Bead | null> {
  try {
    const { data } = await http.get(`/api/v0/city/${city}/bead/${id}`);
    return data.bead ?? data ?? null;
  } catch {
    try {
      const params = rig ? `?rig=${encodeURIComponent(rig)}` : '';
      const { data } = await http.get(`/exec/bd/show/${id}${params}`);
      return data.bead ?? null;
    } catch {
      return null;
    }
  }
}

// ── Mail
export interface MailItem {
  id: string;
  from: string;
  to: string;
  subject?: string;
  body?: string;
  status?: string;
  created_at?: string;
  labels?: string[];
}
export async function listMail(city: string): Promise<MailItem[]> {
  // Union of two sources:
  //   1. Supervisor /v0/city/{name}/mail — fast but can drop state on restart.
  //   2. /exec/mail/list (bd source of truth via `gc bd list --type message`).
  // We prefer bd as primary since it's authoritative; supervisor is secondary
  // in case bd times out. Dedup by id.
  const [bdResp, supResp] = await Promise.all([
    http.get(`/exec/mail/list`).catch(() => ({ data: { items: [] } })),
    http.get(`/api/v0/city/${city}/mail`).catch(() => ({ data: { items: [] } })),
  ]);
  const bdItems: MailItem[] = bdResp.data.items ?? [];
  const supItems: MailItem[] = supResp.data.items ?? supResp.data ?? [];
  const byId = new Map<string, MailItem>();
  for (const m of supItems) byId.set(m.id, m);
  for (const m of bdItems) byId.set(m.id, m); // bd wins on conflict — it's the source of truth
  return Array.from(byId.values()).sort((a, z) =>
    (a.created_at ?? '').localeCompare(z.created_at ?? ''),
  );
}

// ── Convergence loops
export interface ConvergenceLoop {
  id: string;
  title?: string;
  state?: string;
  iteration?: number;
  max_iterations?: number;
  formula?: string;
  target?: string;
  active_wisp?: string;
  terminal?: string | null;
}
export async function listConvergence(city: string): Promise<ConvergenceLoop[]> {
  try {
    const { data } = await http.get(`/api/v0/city/${city}/convergence`);
    return data.items ?? data ?? [];
  } catch {
    return [];
  }
}

// ── Curator pause status
export async function curatorStatus(): Promise<CuratorStatus> {
  const { data } = await http.get('/status/curator');
  return data;
}

// ── Sessions (native gascity poll API)
// SessionResponse shape per /v0/city/{name}/session/{id} — we only use the
// fields that matter for the heartbeat strip. `activity` is the ground-truth
// signal: "in-turn" means the agent is actively processing, "idle" is between
// turns. No more ps/CPU guessing.
export interface GCSession {
  id: string;
  template?: string;
  alias?: string;
  state: string;
  running: boolean;
  activity?: 'idle' | 'in-turn' | string;
  last_active?: string;
  context_pct?: number;
  context_window?: number;
  model?: string;
}
export async function listSessions(city: string): Promise<GCSession[]> {
  const { data } = await http.get(`/api/v0/city/${city}/sessions`);
  return (data.items ?? data ?? []) as GCSession[];
}
export async function getSession(city: string, id: string): Promise<GCSession> {
  const { data } = await http.get(`/api/v0/city/${city}/session/${id}`);
  return data;
}

export interface RigActivity {
  rig: string;
  mayor: string;
  coordinator: string;
  activeRuns: Bead[];
  staleRuns?: Bead[];
  workBeads: Bead[];
  proposals: Bead[];
  acceptedRuns?: Bead[];
  latestResultRuns?: Bead[];
  summary?: {
    currentRun?: Bead | null;
    currentStep?: Bead | null;
    lastAccepted?: Bead | null;
    nextAction?: string;
  };
  sessions: Array<{
    id?: string;
    session_name?: string;
    template?: string;
    alias?: string;
    state?: string;
    last_active?: string;
    attached?: boolean;
  }>;
  errors?: Record<string, string | null>;
}
export async function rigActivity(rig: string): Promise<RigActivity> {
  const { data } = await http.get('/exec/rig/activity', { params: { rig } });
  return data;
}

// ── Project charter (per-rig PROJECT.md)
export async function getCharter(rig: string): Promise<{ path: string; content: string; exists: boolean }> {
  const { data } = await http.get(`/exec/charter/${encodeURIComponent(rig)}`);
  return data;
}
export async function saveCharter(rig: string, content: string): Promise<{ ok: boolean; path: string; bytes: number }> {
  const { data } = await http.post(`/exec/charter/${encodeURIComponent(rig)}`, { content });
  return data;
}

// ── Filesystem (artifacts)
export async function readFile(path: string): Promise<string> {
  const { data } = await http.get('/fs/read', { params: { path } });
  return typeof data === 'string' ? data : JSON.stringify(data);
}
export async function listDir(path: string): Promise<Array<{ name: string; isDir: boolean; path: string }>> {
  const { data } = await http.get('/fs/list', { params: { path } });
  return data;
}
export function binaryUrl(path: string): string {
  return '/fs/binary?path=' + encodeURIComponent(path);
}

// ── Actions (write side)
export interface ExecResult { stdout: string; stderr: string; code: number; }

export async function convergeCreate(args: {
  title: string;
  idea: string;
  idea_description: string;
  rig: string;
  maxIterations?: number;
}): Promise<ExecResult> {
  const { data } = await http.post('/exec/converge/create', args);
  return data;
}

export async function convergeStop(beadId: string): Promise<ExecResult> {
  const { data } = await http.post('/exec/converge/stop', { beadId });
  return data;
}

export async function mailSend(args: { to: string; subject?: string; body: string; notify?: boolean; rig?: string }): Promise<ExecResult> {
  const { data } = await http.post('/exec/mail/send', args);
  return data;
}

export async function mayorChat(args: { rig: string; body: string; contextId?: string }): Promise<ExecResult> {
  const { data } = await http.post('/exec/mayor/chat', args);
  return data;
}

export async function mailReply(args: { messageId: string; subject?: string; body: string; notify?: boolean }): Promise<ExecResult> {
  const { data } = await http.post('/exec/mail/reply', args);
  return data;
}

export async function mailMarkRead(messageId: string): Promise<ExecResult> {
  const { data } = await http.post('/exec/mail/mark-read', { messageId });
  return data;
}

export async function createProposal(args: {
  rig: string;
  title: string;
  description: string;
  parentRun?: string;
  lineageRoot?: string;
  threadId?: string;
  threadTitle?: string;
  followupKind?: 'same-thread' | 'new-thread' | 'bugfix' | 'cross-thread';
  depth?: number;
}): Promise<ExecResult> {
  const { data } = await http.post('/exec/bd/create-proposal', args);
  return data;
}

export async function beadComment(beadId: string, text: string): Promise<ExecResult> {
  const { data } = await http.post('/exec/bd/comment', { beadId, text });
  return data;
}

// Fetch beads where a given metadata key equals a value. Used for lineage walks.
export async function listBeadsByMetadata(city: string, key: string, value: string): Promise<Bead[]> {
  try {
    return await listBeads(city, {
      metadataField: `${key}=${value}`,
      limit: 500,
      all: true,
    });
  } catch {
    return [];
  }
}

// Fetch the full comments list for a bead (shells out to `bd comments <id> --json`).
export interface BdComment { author?: string; ts?: string; created_at?: string; body?: string; text?: string; }
export async function beadComments(id: string): Promise<BdComment[]> {
  try {
    const { data } = await http.get(`/exec/bd/comments/${id}`);
    return data.items ?? [];
  } catch { return []; }
}

// Fetch a bead fully (via bd show, richer than supervisor API).
export async function beadFull(id: string): Promise<Bead | null> {
  try {
    const { data } = await http.get(`/exec/bd/show/${id}`);
    return data.bead ?? null;
  } catch { return null; }
}

// ── Gascity event bus (SSE)
// gascity's native event stream. Every state change emits a typed event.
// Shape per engdocs/architecture/event-bus.md + api-control-plane.md §3/4.
export interface GCEvent {
  seq: number;
  type: string;           // e.g. bead.created, bead.closed, bead.updated, mail.sent, session.woke, convergence.advanced
  ts: string;
  actor: string;
  subject: string;        // bead id, session id, etc.
  message?: string;
  payload?: any;          // shape depends on .type — treat as loose bag
}

// Seed: fetch recent events for initial render.
export async function seedEvents(city: string, opts?: { since?: string; limit?: number }): Promise<GCEvent[]> {
  const params = new URLSearchParams();
  params.set('since', opts?.since ?? '1h');
  params.set('limit', String(opts?.limit ?? 500));
  const { data } = await http.get(`/api/v0/city/${city}/events?${params.toString()}`);
  return (data.items ?? data ?? []) as GCEvent[];
}

// Subscribe: open SSE stream; return an unsubscribe fn.
// onEvent fires per event envelope. Use the returned cleanup on unmount.
export function subscribeEvents(
  city: string,
  onEvent: (e: GCEvent) => void,
  onStatus?: (connected: boolean) => void,
): () => void {
  // EventSource auto-reconnects on drop, and sends Last-Event-ID so the
  // server resumes from our last seq. No manual retry logic needed.
  const url = `/api/v0/city/${encodeURIComponent(city)}/events/stream`;
  const es = new EventSource(url);
  es.onopen = () => onStatus?.(true);
  es.onerror = () => onStatus?.(false);
  // gascity frames each event as `event: event\ndata: {json}`. That maps to
  // addEventListener('event', ...) in EventSource, not onmessage. Listen on
  // both to be safe across supervisor versions.
  const handler = (ev: MessageEvent) => {
    try {
      const parsed = JSON.parse(ev.data) as GCEvent;
      onEvent(parsed);
    } catch { /* ignore malformed lines */ }
  };
  es.addEventListener('event', handler as EventListener);
  es.onmessage = handler;
  return () => { es.close(); onStatus?.(false); };
}

// ── Bead graph (native lineage)
// /v0/city/{name}/beads/graph/{rootID} returns root + all descendants with
// dependency edges. Replaces our recursive bd-list-parent walker.
export interface BeadGraph {
  root: Bead;
  beads: Bead[];
  deps?: any[];
}
export async function beadGraph(city: string, rootId: string): Promise<BeadGraph> {
  const { data } = await http.get(`/api/v0/city/${city}/beads/graph/${rootId}`);
  return data;
}

// List all beads of a given type (native)
export async function listBeadsByType(city: string, type: string, limit = 500): Promise<Bead[]> {
  const { data } = await http.get(`/api/v0/city/${city}/beads?type=${encodeURIComponent(type)}&limit=${limit}`);
  return (data.items ?? data ?? []) as Bead[];
}

// ── Mail thread (native)
export async function mailThread(city: string, threadId: string): Promise<MailItem[]> {
  const { data } = await http.get(`/api/v0/city/${city}/mail/thread/${threadId}`);
  return (data.items ?? data ?? []) as MailItem[];
}

export async function curatorPause(hard = false, reason?: string) {
  const { data } = await http.post('/exec/curator/pause', { hard, reason });
  return data;
}
export async function curatorResume(hard = false) {
  const { data } = await http.post('/exec/curator/resume', { hard });
  return data;
}
