// Dashboard backend. Binds to 127.0.0.1 only. No auth — local access via SSH tunnel.
// Three responsibilities:
//   1. /api/* → proxy to gc supervisor API
//   2. /fs/*  → read artifact files (scoped safe roots)
//   3. /exec/* → whitelist of gc commands

import express from 'express';
import cors from 'cors';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';

const SUPERVISOR_URL = 'http://127.0.0.1:8372';
const PORT = 5174;
const CITY_ROOT = '/home/ubuntu/bright-lights';
const PROJECTS_ROOT = '/home/ubuntu/projects';

const app = express();
app.use(cors());
app.use(express.json());

function rigMayorForRig(rig: string): string | null {
  switch (rig) {
    case 'park-manip':
      return 'park-mayor';
    case 'mjx-diffphysics':
      return 'mjx-mayor';
    case 'robotics-bench':
      return 'robotics-mayor';
    default:
      return /^[a-zA-Z0-9_-]+$/.test(rig) ? `${rig}-mayor` : null;
  }
}

function rigCoordinatorForRig(rig: string): string | null {
  switch (rig) {
    case 'park-manip':
      return 'park-manip/workers.coordinator';
    case 'mjx-diffphysics':
      return 'mjx-diffphysics/workers.coordinator';
    case 'robotics-bench':
      return 'robotics-bench/workers.coordinator';
    default:
      return /^[a-zA-Z0-9_-]+$/.test(rig) ? `${rig}/workers.coordinator` : null;
  }
}

// Request logger for /exec/* and /fs/* so we can see dashboard calls in
// the terminal. Silent for the noisy /api/* proxy.
app.use((req, _res, next) => {
  if (req.path.startsWith('/exec/') || req.path.startsWith('/fs/')) {
    const bodyStr = req.method === 'POST' ? JSON.stringify(req.body).slice(0, 200) : '';
    console.log(`[${new Date().toISOString()}] ${req.method} ${req.path}${bodyStr ? ' body=' + bodyStr : ''}`);
  }
  next();
});

// ───────────────────────────────────────────────────────────
// 1) Supervisor API passthrough.
//    Forward any /api/... to http://127.0.0.1:8372/... so the UI can read
//    beads, agents, convoys, mail, formulas, convergence, etc.
// ───────────────────────────────────────────────────────────
app.all('/api/{*rest}', async (req, res) => {
  const subpath = req.path.replace(/^\/api/, '');
  const url = SUPERVISOR_URL + subpath + (req.url.includes('?') ? '?' + req.url.split('?')[1] : '');
  // SSE endpoints need the response body piped, not buffered. Detect by
  // client Accept header OR by path heuristic (anything ending /stream).
  const wantsStream =
    (req.headers.accept || '').includes('text/event-stream') ||
    /\/stream\b/.test(subpath);
  try {
    const init: RequestInit = {
      method: req.method,
      headers: {
        'Content-Type': 'application/json',
        'X-GC-Request': 'dashboard',
        ...(wantsStream ? { Accept: 'text/event-stream' } : {}),
      },
    };
    if (req.method !== 'GET' && req.method !== 'HEAD' && req.body) {
      init.body = JSON.stringify(req.body);
    }
    const r = await fetch(url, init);
    res.status(r.status);
    const ct = r.headers.get('content-type');
    if (ct) res.set('content-type', ct);

    if (wantsStream && r.body) {
      // Pipe SSE body to client. Disable buffering hints, flush on each chunk.
      res.set('cache-control', 'no-cache, no-transform');
      res.set('connection', 'keep-alive');
      res.set('x-accel-buffering', 'no');
      res.flushHeaders?.();
      const reader = r.body.getReader();
      req.on('close', () => { try { reader.cancel(); } catch { /* ignore */ } });
      (async () => {
        try {
          for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            if (value) res.write(Buffer.from(value));
          }
        } catch { /* upstream closed */ }
        finally { try { res.end(); } catch { /* ignore */ } }
      })();
      return;
    }

    const text = await r.text();
    res.send(text);
  } catch (err: any) {
    res.status(502).json({ error: 'supervisor-unreachable', detail: String(err) });
  }
});

// ───────────────────────────────────────────────────────────
// 2) Artifact filesystem read. Safe roots only.
//    GET /fs/read?path=/home/ubuntu/projects/park-manip/results/run-bl-XXX/review.md
//    GET /fs/binary?path=...    (returns raw bytes for PNGs/MP4s)
//    GET /fs/list?path=...dir   (lists directory contents)
// ───────────────────────────────────────────────────────────
const WORKTREES_ROOT = '/home/ubuntu/worktrees';
function isPathSafe(p: string): boolean {
  const resolved = path.resolve(p);
  const safeRoots = [PROJECTS_ROOT, WORKTREES_ROOT, path.join(CITY_ROOT, 'results')];
  return safeRoots.some((root) => resolved.startsWith(root + path.sep) || resolved === root);
}

app.get('/fs/read', async (req, res) => {
  const p = String(req.query.path || '');
  if (!isPathSafe(p)) return res.status(403).json({ error: 'forbidden-path', path: p });
  try {
    const content = await fs.readFile(p, 'utf8');
    res.type('text/plain').send(content);
  } catch (err: any) {
    if (err.code === 'ENOENT') return res.status(404).json({ error: 'not-found', path: p });
    res.status(500).json({ error: String(err) });
  }
});

app.get('/fs/binary', async (req, res) => {
  const p = String(req.query.path || '');
  if (!isPathSafe(p)) return res.status(403).json({ error: 'forbidden-path' });
  try {
    const ext = path.extname(p).toLowerCase();
    const mime: Record<string, string> = {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.mp4': 'video/mp4',
      '.webm': 'video/webm',
      '.svg': 'image/svg+xml',
      '.json': 'application/json',
    };
    res.type(mime[ext] || 'application/octet-stream');
    const data = await fs.readFile(p);
    res.send(data);
  } catch (err: any) {
    if (err.code === 'ENOENT') return res.status(404).json({ error: 'not-found' });
    res.status(500).json({ error: String(err) });
  }
});

app.get('/fs/list', async (req, res) => {
  const p = String(req.query.path || '');
  if (!isPathSafe(p)) return res.status(403).json({ error: 'forbidden-path' });
  try {
    const entries = await fs.readdir(p, { withFileTypes: true });
    res.json(
      entries.map((e) => ({
        name: e.name,
        isDir: e.isDirectory(),
        path: path.join(p, e.name),
      })),
    );
  } catch (err: any) {
    if (err.code === 'ENOENT') return res.status(404).json({ error: 'not-found' });
    res.status(500).json({ error: String(err) });
  }
});

// ───────────────────────────────────────────────────────────
// 3) Whitelisted gc commands.
//    Each endpoint is an explicit, narrowly-typed action. No arbitrary shell.
// ───────────────────────────────────────────────────────────

// Helper: run `gc ...` with the city env.
function runGC(args: string[], opts: { input?: string } = {}): Promise<{ stdout: string; stderr: string; code: number }> {
  return new Promise((resolve) => {
    const child = spawn('gc', args, {
      env: {
        ...process.env,
        PATH: '/usr/local/go/bin:/home/ubuntu/go/bin:/usr/local/bin:/usr/bin:/bin',
      },
      cwd: CITY_ROOT,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d.toString()));
    child.stderr.on('data', (d) => (stderr += d.toString()));
    child.stdin.end(opts.input ?? '');
    child.on('close', (code) => resolve({ stdout, stderr, code: code ?? -1 }));
  });
}

function runCityScript(script: string, args: string[]): Promise<{ stdout: string; stderr: string; code: number }> {
  return new Promise((resolve) => {
    const child = spawn(script, args, {
      env: {
        ...process.env,
        HOME: '/home/ubuntu',
        PATH: '/usr/local/go/bin:/home/ubuntu/go/bin:/usr/local/bin:/usr/bin:/bin',
      },
      cwd: CITY_ROOT,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d.toString()));
    child.stderr.on('data', (d) => (stderr += d.toString()));
    child.on('close', (code) => resolve({ stdout, stderr, code: code ?? -1 }));
  });
}

type CuratorControlBead = {
  id?: string;
  title?: string;
  labels?: string[];
  metadata?: Record<string, string>;
};

type BeadLike = {
  id?: string;
  title?: string;
  status?: string;
  issue_type?: string;
  labels?: string[];
  metadata?: Record<string, any>;
  created_at?: string;
  updated_at?: string;
  closed_at?: string | null;
};

function beadBelongsToRig(item: BeadLike, rig: string): boolean {
  const md = item.metadata ?? {};
  const hay = [
    item.id,
    item.title,
    md['gc.rig'],
    md['var.rig'],
    md['gc.worktree_dir'],
    md['convergence.target'],
    md['gc.routed_to'],
    ...(item.labels ?? []),
  ].filter(Boolean).join('\n');
  return hay.includes(rig);
}

function parseJSONItems(stdout: string): any[] {
  const parsed = JSON.parse(stdout.trim() || '[]');
  return Array.isArray(parsed) ? parsed : (parsed.items ?? parsed.sessions ?? []);
}

function ageMs(ts?: string): number {
  if (!ts) return Number.POSITIVE_INFINITY;
  const t = Date.parse(ts);
  return Number.isFinite(t) ? Date.now() - t : Number.POSITIVE_INFINITY;
}

async function listCuratorPauseControls(): Promise<CuratorControlBead[]> {
  const result = await runGC(['bd', 'list', '--label', 'kind:control', '--status', 'open', '--json']);
  if (result.code !== 0) return [];
  try {
    const parsed = JSON.parse(result.stdout.trim() || '[]');
    const items = Array.isArray(parsed) ? parsed : (parsed.items ?? []);
    return items.filter((item: CuratorControlBead) => {
      const labels = item.labels ?? [];
      const metadata = item.metadata ?? {};
      return labels.includes('control:curator') && metadata['gc.control_type'] === 'curator_pause';
    });
  } catch {
    return [];
  }
}

function pauseControlMatches(
  item: CuratorControlBead,
  opts: { hard?: boolean; rig?: string; cityOnly?: boolean },
): boolean {
  const metadata = item.metadata ?? {};
  if (opts.hard !== undefined && metadata['gc.pause_hard'] !== String(Boolean(opts.hard))) return false;
  if (opts.rig) {
    return metadata['gc.pause_scope'] === 'rig' && metadata['gc.rig'] === opts.rig;
  }
  if (opts.cityOnly) return metadata['gc.pause_scope'] === 'city';
  return true;
}

// POST /exec/converge/create { title, idea, idea_description, rig, maxIterations? }
app.post('/exec/converge/create', async (req, res) => {
  const { title, idea, idea_description, rig, maxIterations } = req.body;
  if (!title || !idea || !idea_description || !rig) {
    return res.status(400).json({ error: 'missing-required' });
  }
  const rigMayor = rigMayorForRig(String(rig));
  if (!rigMayor) return res.status(400).json({ error: 'unknown-rig', rig });
  const rigCoordinator = rigCoordinatorForRig(String(rig));
  if (!rigCoordinator) return res.status(400).json({ error: 'unknown-rig', rig });
  const result = await runCityScript('/home/ubuntu/bright-lights/assets/scripts/convergence/create_evaluate_idea.sh', [
    '--title', String(title),
    '--idea', String(idea),
    '--idea-description', String(idea_description || idea),
    '--rig', String(rig),
    '--max-iterations', String(maxIterations || 3),
    '--followup-kind', 'new-thread',
  ]);
  let parsed: any = {};
  try {
    parsed = JSON.parse(result.stdout.trim() || '{}');
  } catch {
    parsed = {};
  }
  res.json({
    ...result,
    ...parsed,
    target: parsed.target || rigCoordinator,
    mayor: parsed.mayor || rigMayor,
    root: parsed.root || '',
  });
});

// ───────────────────────────────────────────────────────────
// Project charter: read/write the rig's PROJECT.md.
// Scoped narrowly — only writes to <PROJECTS_ROOT>/<rig>/PROJECT.md.
// ───────────────────────────────────────────────────────────
function charterPath(rig: string): string | null {
  if (!/^[a-zA-Z0-9_-]+$/.test(rig)) return null; // reject path traversal
  return path.join(PROJECTS_ROOT, rig, 'PROJECT.md');
}

app.get('/exec/charter/:rig', async (req, res) => {
  const p = charterPath(String(req.params.rig));
  if (!p) return res.status(400).json({ error: 'bad-rig' });
  try {
    const content = await fs.readFile(p, 'utf8');
    res.json({ path: p, content, exists: true });
  } catch (err: any) {
    if (err.code === 'ENOENT') return res.json({ path: p, content: '', exists: false });
    res.status(500).json({ error: String(err) });
  }
});

app.post('/exec/charter/:rig', async (req, res) => {
  const p = charterPath(String(req.params.rig));
  if (!p) return res.status(400).json({ error: 'bad-rig' });
  const { content } = req.body;
  if (typeof content !== 'string') return res.status(400).json({ error: 'missing-content' });
  try {
    await fs.mkdir(path.dirname(p), { recursive: true });
    await fs.writeFile(p, content, 'utf8');
    res.json({ ok: true, path: p, bytes: content.length });
  } catch (err: any) {
    res.status(500).json({ error: String(err) });
  }
});

// POST /exec/converge/stop { beadId }
app.post('/exec/converge/stop', async (req, res) => {
  const { beadId } = req.body;
  if (!beadId) return res.status(400).json({ error: 'missing-beadId' });
  const result = await runGC(['converge', 'stop', String(beadId)]);
  res.json(result);
});

// GET /exec/mail/list — full mail history from bd (not the flaky supervisor cache).
// Supervisor /mail can drop state across restarts; bd is the source of truth.
app.get('/exec/mail/list', async (_req, res) => {
  const result = await runGC(['bd', 'list', '--type', 'message', '--all', '--json']);
  if (result.code !== 0) return res.json({ items: [], error: result.stderr });
  try {
    const parsed = JSON.parse(result.stdout.trim() || '[]');
    const raw = Array.isArray(parsed) ? parsed : (parsed.items ?? []);
    const items = raw.map((b: any) => {
      const md = b.metadata || {};
      // Prefer display names over session-ids: replies land with
      // assignee=<session-id> and metadata.mail.to_display=<role-name>.
      // If we use assignee as `to` we get "bl-o5a8nm" instead of "mayor"
      // and the rig/mayor filters miss it.
      return {
        id: b.id,
        subject: b.title || '',
        body: b.description || '',
        from: md['mail.from_display'] || md.from || '',
        to: md['mail.to_display'] || b.assignee || '',
        created_at: b.created_at,
        labels: b.labels || [],
      };
    });
    res.json({ items });
  } catch { res.json({ items: [], raw: result.stdout }); }
});

// POST /exec/mail/send { to, subject, body, notify?, rig? }
// If `rig` is provided, the mail bead is created in that rig (e.g. md-wisp-*).
// Otherwise defaults to city-level (bl-wisp-*).
app.post('/exec/mail/send', async (req, res) => {
  const { to, subject, body, notify, rig } = req.body;
  if (!to || !body) return res.status(400).json({ error: 'missing-required' });
  const requestedRecipient = String(to);
  let recipient = String(to);
  if (recipient === 'mayor') {
    if (!rig) return res.status(400).json({ error: 'generic-mayor-disabled', detail: 'include rig so mail can route to the rig mayor' });
    const rigMayor = rigMayorForRig(String(rig));
    if (!rigMayor) return res.status(400).json({ error: 'unknown-rig', rig });
    recipient = rigMayor;
  }
  const args: string[] = [];
  if (rig && typeof rig === 'string' && /^[a-zA-Z0-9_-]+$/.test(rig)) {
    args.push('--rig', rig);
  }
  args.push('mail', 'send', recipient);
  if (subject) args.push('-s', String(subject));
  args.push('-m', String(body));
  if (notify) args.push('--notify');
  const result = await runGC(args);
  const directiveTargets = new Set(['mayor', 'park-mayor', 'mjx-mayor', 'curator']);
  let directive: { stdout: string; stderr: string; code: number } | null = null;
  if (result.code === 0 && directiveTargets.has(requestedRecipient)) {
    const directiveRig = rig && typeof rig === 'string' ? rig : '';
    const metadata: Record<string, string> = {
      'gc.kind': 'operator_directive',
      'gc.directive_to': recipient,
      'gc.directive_status': 'active',
      'gc.source': 'dashboard_chat',
    };
    if (directiveRig) metadata['gc.rig'] = directiveRig;
    const firstLine = String(body).split('\n').find((line) => line.trim()) || String(subject || 'operator directive');
    const title = `directive: ${directiveRig || recipient}: ${firstLine.slice(0, 80)}`;
    const labels = ['kind:directive', 'source:operator', 'status:active'];
    if (directiveRig) labels.push(`rig:${directiveRig}`);
    directive = await runGC([
      'bd', 'create', title,
      '--type', 'decision',
      '--description', String(body),
      '--labels', labels.join(','),
      '--metadata', JSON.stringify(metadata),
      '--json',
    ]);
  }
  res.json({ ...result, directive });
});

// POST /exec/mayor/chat { rig, body, contextId? }
//
// Mayor chat has two jobs:
//   1. create durable mail/directive beads so operator steering is searchable;
//   2. submit the same text to the named mayor session so it behaves like chat.
//
// Mail is the audit trail. `gc session submit` is the live interaction path.
app.post('/exec/mayor/chat', async (req, res) => {
  const { rig, body, contextId } = req.body;
  if (!rig || !body) return res.status(400).json({ error: 'missing-required' });
  const rigName = String(rig);
  if (!/^[a-zA-Z0-9_-]+$/.test(rigName)) return res.status(400).json({ error: 'bad-rig' });
  const mayor = rigMayorForRig(rigName);
  if (!mayor) return res.status(400).json({ error: 'unknown-rig', rig });

  const text = contextId
    ? `Context: ${String(contextId)}\n\n${String(body)}`
    : String(body);

  const mail = await runGC([
    '--rig', rigName,
    'mail', 'send', mayor,
    '-s', `[${rigName}] chat`,
    '-m', text,
    '--notify',
  ]);

  const metadata: Record<string, string> = {
    'gc.kind': 'operator_directive',
    'gc.directive_to': mayor,
    'gc.directive_status': 'active',
    'gc.source': 'dashboard_chat',
    'gc.rig': rigName,
  };
  if (contextId) metadata['gc.context_id'] = String(contextId);
  const firstLine = text.split('\n').find((line) => line.trim()) || 'operator directive';
  const directive = await runGC([
    'bd', 'create', `directive: ${rigName}: ${firstLine.slice(0, 80)}`,
    '--type', 'decision',
    '--description', text,
    '--labels', `kind:directive,source:operator,status:active,rig:${rigName}`,
    '--metadata', JSON.stringify(metadata),
    '--json',
  ]);

  let directiveId = '';
  try {
    const parsed = JSON.parse(directive.stdout || '{}');
    directiveId = String(parsed.id || '');
  } catch {
    directiveId = '';
  }

  const submit = await runGC([
    'session', 'submit', mayor,
    `Operator message for ${rigName}. This message was also recorded as mail/directive beads.\n\nDirective bead: ${directiveId || '(create failed)'}\n\n${text}`,
    '--intent', 'follow_up',
  ]);

  const code = mail.code === 0 && directive.code === 0 && submit.code === 0 ? 0 : 1;
  res.json({
    code,
    stdout: [mail.stdout, directive.stdout, submit.stdout].filter(Boolean).join('\n'),
    stderr: [mail.stderr, directive.stderr, submit.stderr].filter(Boolean).join('\n'),
    mail,
    directive,
    submit,
    mayor,
  });
});

// POST /exec/directive/resolve { directiveId, status?, reason? }
app.post('/exec/directive/resolve', async (req, res) => {
  const { directiveId, status, reason } = req.body;
  if (!directiveId) return res.status(400).json({ error: 'missing-directiveId' });
  const nextStatus = String(status || 'answered');
  const result = await runGC([
    'bd', 'update', String(directiveId),
    '--set-metadata', `gc.directive_status=${nextStatus}`,
    '--set-metadata', `gc.directive_resolution=${String(reason || nextStatus)}`,
    '--remove-label', 'status:active',
    '--add-label', `status:${nextStatus}`,
  ]);
  res.json(result);
});

// POST /exec/directive/promote-policy { directiveId, rig?, title?, matchRegex?, rejectRegex?, requireMedia? }
app.post('/exec/directive/promote-policy', async (req, res) => {
  const { directiveId, rig, title, matchRegex, rejectRegex, rejectReason, requireMedia } = req.body;
  if (!directiveId) return res.status(400).json({ error: 'missing-directiveId' });
  const show = await runGC(['bd', 'show', String(directiveId), '--json']);
  if (show.code !== 0) return res.status(404).json({ error: show.stderr || 'directive not found' });
  let directive: any;
  try {
    const parsed = JSON.parse(show.stdout.trim());
    directive = Array.isArray(parsed) ? parsed[0] : parsed;
  } catch {
    return res.status(500).json({ error: 'parse-failed', raw: show.stdout });
  }
  const md = directive.metadata || {};
  const policyRig = String(rig || md['gc.rig'] || '');
  if (!policyRig) return res.status(400).json({ error: 'missing-rig' });
  const policyTitle = String(title || `policy: ${directive.title || directiveId}`.slice(0, 120));
  const metadata: Record<string, string> = {
    'gc.kind': 'operator_policy',
    'gc.rig': policyRig,
    'gc.policy_source_directive': String(directiveId),
    'gc.created_by': 'dashboard',
  };
  if (matchRegex) metadata['gc.policy.match_regex'] = String(matchRegex);
  if (rejectRegex) metadata['gc.policy.reject_regex'] = String(rejectRegex);
  if (rejectReason) metadata['gc.policy.reject_reason'] = String(rejectReason);
  if (requireMedia) {
    metadata['gc.policy.require_media'] = 'true';
    metadata['gc.policy.required_artifact_exts'] = 'mp4,webm,gif,png,jpg,jpeg';
  }
  const create = await runGC([
    'bd', 'create', policyTitle,
    '--type', 'decision',
    '--description', String(directive.description || ''),
    '--labels', `kind:policy,source:operator,status:active,rig:${policyRig}`,
    '--metadata', JSON.stringify(metadata),
    '--json',
  ]);
  if (create.code !== 0) return res.status(500).json({ error: create.stderr || create.stdout });
  let policyId = '';
  try {
    const parsed = JSON.parse(create.stdout.trim());
    policyId = (Array.isArray(parsed) ? parsed[0] : parsed).id || '';
  } catch { /* keep raw only */ }
  await runGC([
    'bd', 'update', String(directiveId),
    '--set-metadata', 'gc.directive_status=promoted-to-policy',
    ...(policyId ? ['--set-metadata', `gc.promoted_policy=${policyId}`] : []),
    '--remove-label', 'status:active',
    '--add-label', 'status:promoted-to-policy',
  ]);
  res.json({ ok: true, policyId, raw: create.stdout });
});

// POST /exec/mail/reply { messageId, subject?, body, notify? }
app.post('/exec/mail/reply', async (req, res) => {
  const { messageId, subject, body, notify } = req.body;
  if (!messageId || !body) return res.status(400).json({ error: 'missing-required' });
  const args = ['mail', 'reply', String(messageId)];
  if (subject) args.push('-s', String(subject));
  args.push('-m', String(body));
  if (notify) args.push('--notify');
  const result = await runGC(args);
  res.json(result);
});

// POST /exec/mail/mark-read { messageId }
app.post('/exec/mail/mark-read', async (req, res) => {
  const { messageId } = req.body;
  if (!messageId) return res.status(400).json({ error: 'missing-required' });
  const result = await runGC(['mail', 'mark-read', String(messageId)]);
  res.json(result);
});

// POST /exec/bd/create-proposal { rig, title, description, parentRun?, lineageRoot?, threadId?, followupKind?, depth? }
// "Propose" mode: make a kind:proposal bead that the curator picks up.
app.post('/exec/bd/create-proposal', async (req, res) => {
  const { rig, title, description, parentRun, lineageRoot, threadId, threadTitle, followupKind, depth } = req.body;
  if (!rig || !title || !description) return res.status(400).json({ error: 'missing-required' });
  const allowedKinds = new Set(['same-thread', 'new-thread', 'bugfix', 'cross-thread']);
  const kind = String(followupKind || (parentRun ? '' : 'new-thread'));
  if (parentRun && (!threadId || !kind)) {
    return res.status(400).json({
      error: 'missing-thread-metadata',
      detail: 'followup proposals must include threadId and followupKind',
    });
  }
  if (parentRun && !lineageRoot) {
    return res.status(400).json({
      error: 'missing-lineage-root',
      detail: 'followup proposals must include lineageRoot',
    });
  }
  if (kind && !allowedKinds.has(kind)) {
    return res.status(400).json({ error: 'invalid-followup-kind', followupKind: kind });
  }
  const activePolicies = await runGC(['bd', 'list', '--label', 'kind:policy', '--label', `rig:${String(rig)}`, '--status', 'open', '--json']);
  let requiresMedia = false;
  if (activePolicies.code === 0) {
    try {
      const parsed = JSON.parse(activePolicies.stdout.trim() || '[]');
      const items = Array.isArray(parsed) ? parsed : (parsed.items ?? []);
      requiresMedia = items.some((item: any) => item.metadata?.['gc.policy.require_media'] === 'true');
    } catch { /* ignore policy parse failure */ }
  }
  const meta: Record<string, string> = {
    'gc.proposal_idea_desc': String(description),
    'gc.lineage_depth': String(depth ?? 0),
    // Stamp rig so curator-decide promotes to the correct rig when this
    // proposal is picked up. Otherwise curator-decide defaults to park-manip.
    'gc.rig': String(rig),
  };
  if (kind) meta['gc.followup_kind'] = kind;
  if (requiresMedia) meta['gc.acceptance_artifacts'] = 'media';
  if (parentRun) meta['gc.parent_run'] = String(parentRun);
  if (lineageRoot) meta['gc.lineage_root'] = String(lineageRoot);
  if (threadId) meta['gc.thread_id'] = String(threadId);
  if (threadTitle) meta['gc.thread_title'] = String(threadTitle);

  const args = [
    'bd', '--rig', String(rig), 'create', String(title),
    '-d', String(description),
    '-l', 'kind:proposal,status:pending',
    '--metadata', JSON.stringify(meta),
    '--json',
  ];
  const result = await runGC(args);
  res.json(result);
});

// POST /exec/bd/comment { beadId, text }
app.post('/exec/bd/comment', async (req, res) => {
  const { beadId, text } = req.body;
  if (!beadId || !text) return res.status(400).json({ error: 'missing-required' });
  const result = await runGC(['bd', 'comment', String(beadId), String(text)]);
  res.json(result);
});

// GET /exec/bd/comments/:beadId → [{ author, ts, body }]
// Comments live in beads (bd storage), not supervisor API, so we shell out.
app.get('/exec/bd/comments/:beadId', async (req, res) => {
  const beadId = req.params.beadId;
  if (!beadId) return res.status(400).json({ error: 'missing-beadId' });
  const result = await runGC(['bd', 'comments', String(beadId), '--json']);
  if (result.code !== 0) {
    return res.json({ items: [], error: result.stderr });
  }
  try {
    const parsed = JSON.parse(result.stdout.trim() || '[]');
    // bd sometimes returns {comments: [...]} or just [...]
    const items = Array.isArray(parsed) ? parsed : (parsed.comments ?? parsed.items ?? []);
    res.json({ items });
  } catch {
    res.json({ items: [], raw: result.stdout });
  }
});

// GET /exec/bd/show/:beadId → { bead + full metadata + comments }
// One shot for the thread view.
app.get('/exec/bd/show/:beadId', async (req, res) => {
  const beadId = req.params.beadId;
  const args = ['bd'];
  if (req.query.rig) args.push('--rig', String(req.query.rig));
  args.push('show', String(beadId), '--json');
  const showResult = await runGC(args);
  if (showResult.code !== 0) return res.json({ error: showResult.stderr });
  try {
    const parsed = JSON.parse(showResult.stdout.trim());
    const bead = Array.isArray(parsed) ? parsed[0] : parsed;
    res.json({ bead });
  } catch (err) {
    res.json({ error: 'parse-failed', raw: showResult.stdout });
  }
});

// GET /exec/bd/list?label=&status=&all=1  (backdoor since the supervisor API
// silently ignores label/metadata filters on closed beads)
app.get('/exec/bd/list', async (req, res) => {
  const args = ['bd', 'list', '--json'];
  if (req.query.all === '1' || req.query.all === 'true') args.push('--all');
  if (req.query.label) args.push('--label', String(req.query.label));
  if (req.query.status) args.push('--status', String(req.query.status));
  if (req.query.rig) args.splice(1, 0, '--rig', String(req.query.rig));
  if (req.query.limit) args.push('--limit', String(req.query.limit));
  if (req.query['has-metadata-key']) args.push('--has-metadata-key', String(req.query['has-metadata-key']));
  if (req.query['metadata-field']) args.push('--metadata-field', String(req.query['metadata-field']));
  const result = await runGC(args);
  if (result.code !== 0) return res.json({ items: [], error: result.stderr });
  try {
    const parsed = JSON.parse(result.stdout.trim() || '[]');
    const items = Array.isArray(parsed) ? parsed : (parsed.items ?? []);
    res.json({ items });
  } catch { res.json({ items: [], raw: result.stdout }); }
});

// GET /exec/rig/activity?rig=mjx-diffphysics
// Mayor chat should show the Gas City work chain directly. This endpoint is a
// read-only composition of bd + session primitives: no dashboard registry.
app.get('/exec/rig/activity', async (req, res) => {
  const rig = String(req.query.rig || '');
  if (!rig) return res.status(400).json({ error: 'missing-rig' });
  const mayor = rigMayorForRig(rig);
  const coordinator = rigCoordinatorForRig(rig);
  if (!mayor || !coordinator) return res.status(400).json({ error: 'unknown-rig', rig });

  try {
    const result = await runCityScript('/home/ubuntu/bright-lights/assets/scripts/maintenance/rig_research_status.sh', [rig]);
    if (result.code !== 0) {
      return res.status(500).json({ error: result.stderr || result.stdout || `rig status exited ${result.code}` });
    }
    res.type('application/json').send(result.stdout);
  } catch (err: any) {
    res.status(500).json({ error: String(err) });
  }
});

// POST /exec/curator/pause { hard?, rig?, reason? } → create visible control bead
// POST /exec/curator/resume { hard?, rig? } → close matching control beads
app.post('/exec/curator/pause', async (req, res) => {
  const hard = Boolean(req.body.hard);
  const rig = req.body.rig ? String(req.body.rig) : '';
  const reason = String(req.body.reason || 'paused via dashboard');
  const scope = rig ? 'rig' : 'city';
  try {
    const existing = (await listCuratorPauseControls()).find((item) =>
      pauseControlMatches(item, { hard, rig: rig || undefined, cityOnly: !rig }),
    );
    if (existing?.id) return res.json({ ok: true, bead: existing, created: false });

    const metadata = JSON.stringify({
      'gc.control_type': 'curator_pause',
      'gc.pause_scope': scope,
      'gc.rig': rig,
      'gc.pause_hard': String(hard),
      'gc.reason': reason,
      'gc.created_by': 'dashboard',
    });
    const title = rig
      ? `control: pause ${rig} curator promotions`
      : `control: ${hard ? 'hard ' : ''}pause curator`;
    const result = await runGC([
      'bd', 'create', title,
      '--type', 'task',
      '--description', reason,
      '--labels', 'kind:control,control:curator,status:active',
      '--metadata', metadata,
      '--json',
    ]);
    if (result.code !== 0) return res.status(500).json({ error: result.stderr || result.stdout });
    res.json({ ok: true, created: true, raw: result.stdout });
  } catch (err: any) {
    res.status(500).json({ error: String(err) });
  }
});
app.post('/exec/curator/resume', async (req, res) => {
  const hard = req.body.hard === undefined ? undefined : Boolean(req.body.hard);
  const rig = req.body.rig ? String(req.body.rig) : '';
  try {
    const controls = await listCuratorPauseControls();
    const matched = controls.filter((item) =>
      pauseControlMatches(item, { hard, rig: rig || undefined, cityOnly: !rig }),
    );
    const closed: string[] = [];
    for (const item of matched) {
      if (!item.id) continue;
      const close = await runGC(['bd', 'close', item.id, '--reason', 'resumed via dashboard']);
      if (close.code === 0) closed.push(item.id);
    }
    res.json({ ok: true, closed });
  } catch (err: any) {
    res.status(500).json({ error: String(err) });
  }
});

// GET /status/curator → which pause control beads are active
app.get('/status/curator', async (_req, res) => {
  const controls = await listCuratorPauseControls();
  res.json({
    soft: controls.find((item) => item.metadata?.['gc.pause_scope'] === 'city' && item.metadata?.['gc.pause_hard'] !== 'true') ?? null,
    hard: controls.find((item) => item.metadata?.['gc.pause_scope'] === 'city' && item.metadata?.['gc.pause_hard'] === 'true') ?? null,
    controls,
  });
});



// Simple health endpoint.
app.get('/health', (_req, res) => res.json({ ok: true }));

app.listen(PORT, '127.0.0.1', () => {
  console.log(`dashboard backend listening on http://127.0.0.1:${PORT}`);
  console.log(`  → /api/*  proxied to ${SUPERVISOR_URL}`);
  console.log(`  → /fs/*   serves artifacts under ${PROJECTS_ROOT} and ${CITY_ROOT}/results`);
  console.log(`  → /exec/* whitelist of gc commands`);
});
