const express = require('express');
const path = require('path');
const fs = require('fs');
const yaml = require('js-yaml');
const { execSync, execFileSync } = require('child_process');

const app = express();
const SCRIPT_DIR = path.resolve(__dirname, '..');
const SCOPE_FILE = path.join(SCRIPT_DIR, 'project-scope.yaml');
const PORT = parseInt(process.env.PORT || '3333', 10);
const HOST = process.env.HOST || '127.0.0.1';
const CACHE_TTL_MS = 3000;

let cachedPayload = null;
let cachedAt = 0;

function resolveProjectRoot(scope) {
  const repo = scope?.project?.repo || '.';
  if (!repo || repo === 'null' || repo === '.') {
    return path.resolve(SCRIPT_DIR, '..');
  }
  const expanded = repo.startsWith('~') ? repo.replace('~', process.env.HOME) : repo;
  return path.isAbsolute(expanded) ? expanded : path.resolve(SCRIPT_DIR, expanded);
}

function resolveWorktreeBase(scope) {
  const base = scope?.advanced?.worktree_base;
  if (base && base !== 'null') {
    const expanded = base.startsWith('~') ? base.replace('~', process.env.HOME) : base;
    return path.isAbsolute(expanded) ? expanded : path.resolve(SCRIPT_DIR, expanded);
  }
  return path.join(process.env.HOME, '.openclaw', 'projects', scope.project.name);
}

function loadScope() {
  if (!fs.existsSync(SCOPE_FILE)) return null;
  return yaml.load(fs.readFileSync(SCOPE_FILE, 'utf8'));
}

function slugify(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/-+/g, '-');
}

function resolveProfile(scope) {
  const raw = scope?.advanced?.openclaw_profile || '';
  return raw ? slugify(raw) : slugify(scope?.project?.name);
}

function resolveProfileConfigPath(profile) {
  return path.join(process.env.HOME, `.openclaw-${profile}`, 'openclaw.json');
}

function readMdFile(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }
}

function execText(command, options = {}) {
  try {
    return execSync(command, { encoding: 'utf8', timeout: 5000, ...options }).trim();
  } catch {
    return '';
  }
}

function execFileText(command, args, options = {}) {
  try {
    return execFileSync(command, args, { encoding: 'utf8', timeout: 5000, ...options }).trim();
  } catch {
    return '';
  }
}

function execFileJson(command, args, options = {}) {
  const raw = execFileText(command, args, options);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function resolveGatewayConfigFromProfileFile(profile) {
  const profileConfigPath = resolveProfileConfigPath(profile);
  if (!fs.existsSync(profileConfigPath)) return null;

  try {
    const raw = fs.readFileSync(profileConfigPath, 'utf8');
    const portMatch = raw.match(/\bgateway:\s*\{[\s\S]*?\bport:\s*(\d+)/);
    const tokenMatch = raw.match(/\bgateway:\s*\{[\s\S]*?\bauth:\s*\{[\s\S]*?\btoken:\s*"([^"]+)"/);

    return {
      gateway: {
        port: portMatch ? parseInt(portMatch[1], 10) : null,
        auth: { token: tokenMatch ? tokenMatch[1] : null },
      }
    };
  } catch {
    return null;
  }
}

function resolveGatewayConfig(profile) {
  const fromProfileFile = resolveGatewayConfigFromProfileFile(profile);
  if (fromProfileFile) return fromProfileFile;

  const token = execFileText('openclaw', ['--profile', profile, 'config', 'get', 'gateway.auth.token']);
  const portRaw = execFileText('openclaw', ['--profile', profile, 'config', 'get', 'gateway.port']);

  return {
    gateway: {
      port: parseInt(portRaw, 10) || null,
      auth: { token: token && token !== '__OPENCLAW_REDACTED__' ? token : null },
    }
  };
}

function resolveGatewayState(scope) {
  const profile = resolveProfile(scope);
  const gatewayConfig = resolveGatewayConfig(profile);
  return {
    profile,
    port: gatewayConfig?.gateway?.port || scope?.advanced?.gateway_port || null,
    token: gatewayConfig?.gateway?.auth?.token || null,
  };
}

function buildGatewayUrl(port, token, pathname = '/', params = null) {
  if (!port) return null;
  const url = new URL(`http://localhost:${port}${pathname}`);
  if (params) {
    for (const [key, value] of Object.entries(params)) {
      if (value !== null && value !== undefined && value !== '') {
        url.searchParams.set(key, value);
      }
    }
  }
  if (token) {
    url.hash = `token=${encodeURIComponent(token)}`;
  }
  return url.toString();
}

function sendBrowserRedirect(res, target) {
  const escapedTarget = JSON.stringify(target);
  res
    .status(200)
    .type('html')
    .send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Redirecting...</title>
  <meta http-equiv="refresh" content="0;url=${target}">
</head>
<body>
  <p>Redirecting...</p>
  <p><a href="${target}">Continue</a></p>
  <script>
    window.location.replace(${escapedTarget});
  </script>
</body>
</html>`);
}

function getGitInfo(projectRoot) {
  try {
    const log = execText('git log --oneline -10', { cwd: projectRoot });
    const branch = execText('git rev-parse --abbrev-ref HEAD', { cwd: projectRoot }) || 'unknown';
    const diffNames = execText('git diff --name-only', { cwd: projectRoot });
    const untrackedRaw = execText('git ls-files --others --exclude-standard', { cwd: projectRoot });
    const diffStat = execText('git diff --stat', { cwd: projectRoot });

    const changedFiles = [];
    const allFiles = [
      ...(diffNames ? diffNames.split('\n') : []),
      ...(untrackedRaw ? untrackedRaw.split('\n') : []),
    ];
    const seen = new Set();
    const untrackedSet = new Set(untrackedRaw ? untrackedRaw.split('\n').filter(Boolean) : []);

    for (const file of allFiles) {
      if (!file || seen.has(file)) continue;
      seen.add(file);
      const fullPath = path.join(projectRoot, file);
      let mtime = null;
      try {
        mtime = fs.statSync(fullPath).mtime.toISOString();
      } catch {}
      changedFiles.push({ file, mtime, untracked: untrackedSet.has(file) });
    }

    const statLines = diffStat ? diffStat.split('\n') : [];
    const summaryLine = statLines.length > 0 ? statLines[statLines.length - 1] : '';

    return {
      branch,
      log,
      changedFiles,
      diffSummary: summaryLine,
      timestamp: new Date().toISOString(),
    };
  } catch {
    return {
      branch: 'unknown',
      log: '',
      changedFiles: [],
      diffSummary: '',
      timestamp: new Date().toISOString(),
    };
  }
}

function parseStatusFields(status) {
  const fields = {};
  if (!status) return fields;

  for (const line of status.split('\n')) {
    const match = line.match(/^([A-Za-z ]+):\s*(.+)$/);
    if (match) {
      fields[match[1].trim().toLowerCase()] = match[2].trim();
    }
  }
  return fields;
}

function uniqueExistingPaths(paths) {
  const seen = new Set();
  return paths.filter((filePath) => {
    if (!filePath || seen.has(filePath) || !fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
      return false;
    }
    seen.add(filePath);
    return true;
  });
}

function estimateTokensFromPaths(paths) {
  if (!paths.length) return 0;
  const text = paths
    .map((filePath) => {
      try {
        return fs.readFileSync(filePath, 'utf8');
      } catch {
        return '';
      }
    })
    .join('\n\n');

  return Math.round(text.length / 4);
}

function loadOpenClawSessions(profile) {
  const payload = execFileJson('openclaw', ['--profile', profile, 'sessions', '--all-agents', '--json']);
  return Array.isArray(payload?.sessions) ? payload.sessions : [];
}

function resolveContextLimit(profile, sessions) {
  const sessionLimits = [];
  for (const session of sessions) {
    const value = Number(session?.contextTokens);
    if (Number.isFinite(value) && value > 0) sessionLimits.push(value);
  }

  if (sessionLimits.length > 0) {
    return Math.max(...sessionLimits);
  }

  const raw = execFileText('openclaw', ['--profile', profile, 'config', 'get', 'agents.defaults.contextTokens', '--json']);
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      const limit = Number(parsed);
      if (Number.isFinite(limit) && limit > 0) return limit;
    } catch {}
  }

  return 200000;
}

function extractSessionLabel(agentId, key) {
  const prefix = `agent:${agentId}:`;
  if (typeof key === 'string' && key.startsWith(prefix)) {
    return key.slice(prefix.length) || 'main';
  }
  return typeof key === 'string' && key ? key : 'unknown';
}

function mapRuntimeAgentIdToDisplayId(scope, runtimeId) {
  const projectSlug = slugify(scope?.project?.name);
  if (runtimeId === `${projectSlug}-supervisor`) return 'supervisor';
  const prefix = `${projectSlug}-`;
  if (runtimeId.startsWith(prefix)) return runtimeId.slice(prefix.length);
  return runtimeId;
}

function statusLabelForUsage(usagePct, threshold) {
  if (usagePct >= threshold) return 'COMPACT NOW';
  if (usagePct >= Math.max(threshold - 15, 0)) return 'WARNING';
  return 'OK';
}

function buildLiveContextMetrics(scope, sessions, contextLimit, threshold) {
  const rows = [];
  const seenRefs = new Set();

  for (const session of sessions) {
    if (!session || typeof session !== 'object') continue;

    const runtimeId = String(session.agentId || 'main');
    const sessionRef = `${runtimeId}:${String(session.sessionId || session.key || '')}`;
    if (seenRefs.has(sessionRef)) continue;
    seenRefs.add(sessionRef);

    const totalTokens = Number(session.totalTokens);
    if (!Number.isFinite(totalTokens) || totalTokens <= 0) continue;

    const rowContextLimit = Number(session.contextTokens) > 0 ? Number(session.contextTokens) : contextLimit;
    const usagePct = (totalTokens / rowContextLimit) * 100;
    const sessionLabel = extractSessionLabel(runtimeId, session.key);

    rows.push({
      runtimeId,
      displayAgentId: mapRuntimeAgentIdToDisplayId(scope, runtimeId),
      sessionLabel,
      sessionKind: sessionLabel === 'main' ? 'main' : (sessionLabel.startsWith('cron:') ? 'cron' : 'other'),
      totalTokens,
      contextTokens: rowContextLimit,
      usagePct: Number(usagePct.toFixed(2)),
      status: statusLabelForUsage(usagePct, threshold),
      model: session.model || null,
    });
  }

  rows.sort((left, right) => right.usagePct - left.usagePct);

  return {
    threshold,
    contextLimit,
    maxUsagePct: rows.length > 0 ? rows[0].usagePct : 0,
    rows,
  };
}

function buildMarkdownBudget(scope, projectRoot, worktreeBase, contextLimit) {
  const sharedFiles = Array.isArray(scope?.advanced?.shared_files)
    ? scope.advanced.shared_files.map((value) => String(value))
    : [];
  const rows = [];
  const supervisorWorkspace = path.join(worktreeBase, 'supervisor-workspace');

  const supervisorCore = uniqueExistingPaths([
    path.join(supervisorWorkspace, 'SOUL.md'),
    path.join(supervisorWorkspace, 'ROSTER.md'),
  ]);
  const supervisorWithShared = uniqueExistingPaths([
    ...supervisorCore,
    path.join(supervisorWorkspace, 'PROJECT.md'),
    ...sharedFiles
      .filter((value) => value !== 'PROJECT.md')
      .map((value) => path.join(supervisorWorkspace, value)),
  ]);

  const pushRow = (roleId, roleType, readSet, paths) => {
    const tokens = estimateTokensFromPaths(paths);
    rows.push({
      roleId,
      roleType,
      readSet,
      fileCount: paths.length,
      tokens,
      contextLimit,
      usagePct: contextLimit > 0 ? Number(((tokens / contextLimit) * 100).toFixed(2)) : 0,
    });
  };

  pushRow('supervisor', 'supervisor', 'core_loop', supervisorCore);
  pushRow('supervisor', 'supervisor', 'with_shared', supervisorWithShared);

  for (const agent of scope.agents || []) {
    const agentId = String(agent.id || 'unknown');
    const agentDir = path.join(projectRoot, '.fleetclaw', 'agents', agentId);
    const startup = uniqueExistingPaths([
      path.join(agentDir, 'SOUL.md'),
      path.join(agentDir, 'BRIEF.md'),
      path.join(agentDir, 'STATUS.md'),
    ]);
    const withShared = uniqueExistingPaths([
      ...startup,
      path.join(agentDir, 'PROJECT.md'),
      ...sharedFiles
        .filter((value) => value !== 'PROJECT.md')
        .map((value) => path.join(agentDir, value)),
    ]);

    pushRow(agentId, 'agent', 'startup', startup);
    pushRow(agentId, 'agent', 'with_shared', withShared);
  }

  const maxUsagePct = rows.length > 0 ? Math.max(...rows.map((row) => row.usagePct)) : 0;
  return {
    estimator: 'chars/4',
    contextLimit,
    maxUsagePct: Number(maxUsagePct.toFixed(2)),
    rows,
  };
}

function buildDashboardPayload() {
  const scope = loadScope();
  if (!scope) return null;

  const projectRoot = resolveProjectRoot(scope);
  const worktreeBase = resolveWorktreeBase(scope);
  const gateway = resolveGatewayState(scope);
  const git = getGitInfo(projectRoot);
  const profile = gateway.profile;
  const sessions = loadOpenClawSessions(profile);
  const contextLimit = resolveContextLimit(profile, sessions);
  const threshold = Number(scope?.supervisor?.context_compact_threshold || 70);
  const markdown = buildMarkdownBudget(scope, projectRoot, worktreeBase, contextLimit);
  const live = buildLiveContextMetrics(scope, sessions, contextLimit, threshold);

  const mainSessionsByAgent = new Map();
  for (const row of live.rows) {
    if (row.sessionLabel === 'main' && !mainSessionsByAgent.has(row.displayAgentId)) {
      mainSessionsByAgent.set(row.displayAgentId, row);
    }
  }

  const markdownByRole = new Map();
  for (const row of markdown.rows) {
    markdownByRole.set(`${row.roleId}:${row.readSet}`, row);
  }

  const projectSlug = slugify(scope.project.name);
  const fleetclawDir = path.join(projectRoot, '.fleetclaw', 'agents');
  const agents = (scope.agents || []).map((agent) => {
    const agentDir = path.join(fleetclawDir, agent.id);
    const runtimeId = `${projectSlug}-${agent.id}`;
    const status = readMdFile(path.join(agentDir, 'STATUS.md'));
    const brief = readMdFile(path.join(agentDir, 'BRIEF.md'));
    const plan = readMdFile(path.join(agentDir, 'PLAN.md'));
    const memory = readMdFile(path.join(agentDir, 'MEMORY.md'));
    const soul = readMdFile(path.join(agentDir, 'SOUL.md'));

    return {
      id: agent.id,
      runtimeId,
      model: agent.model || scope?.advanced?.default_agent_model || 'unknown',
      thinking: agent.thinking || scope?.advanced?.default_agent_thinking || '',
      focusDirs: agent.focus_dirs || [],
      task: agent.task || '',
      sessionUrl: gateway.port ? `/openclaw/agent/${encodeURIComponent(agent.id)}` : null,
      statusFields: parseStatusFields(status),
      instructionBudget: {
        startup: markdownByRole.get(`${agent.id}:startup`) || null,
        withShared: markdownByRole.get(`${agent.id}:with_shared`) || null,
      },
      mainSession: mainSessionsByAgent.get(agent.id) || null,
      files: {
        status,
        brief,
        plan,
        memory,
        soul,
      },
    };
  });

  const supervisorWorkspace = path.join(worktreeBase, 'supervisor-workspace');
  const supervisorRuntimeId = `${projectSlug}-supervisor`;
  const supervisorStatus = readMdFile(path.join(supervisorWorkspace, 'STATUS.md'));
  const supervisorRoster = readMdFile(path.join(supervisorWorkspace, 'ROSTER.md'));
  const supervisorMemoryDir = path.join(supervisorWorkspace, 'memory');
  let supervisorLatestMemory = null;
  if (fs.existsSync(supervisorMemoryDir)) {
    const files = fs.readdirSync(supervisorMemoryDir).filter((name) => name.endsWith('.md')).sort().reverse();
    if (files.length > 0) {
      supervisorLatestMemory = readMdFile(path.join(supervisorMemoryDir, files[0]));
    }
  }

  const supervisorCronRows = live.rows
    .filter((row) => row.displayAgentId === 'supervisor' && row.sessionKind === 'cron')
    .slice(0, 5);

  return {
    project: {
      name: scope.project.name,
      description: scope.project.description,
      branch: scope.project.branch || 'main',
      profile,
      gateway: {
        port: gateway.port,
        url: gateway.port ? `http://localhost:${gateway.port}/` : null,
        openclawUrl: gateway.port ? '/openclaw' : null,
      },
      dashboard: {
        host: HOST,
        port: PORT,
        url: `http://${HOST}:${PORT}/`,
      },
      supervisor: {
        model: scope.supervisor?.model || 'unknown',
        checkInterval: scope.supervisor?.check_interval_mins || 10,
        thinking: scope.supervisor?.thinking || '',
      },
      git,
    },
    agents,
    supervisor: {
      runtimeId: supervisorRuntimeId,
      sessionUrl: gateway.port ? '/openclaw/supervisor' : null,
      status: supervisorStatus,
      roster: supervisorRoster,
      latestMemory: supervisorLatestMemory,
      instructionBudget: {
        coreLoop: markdownByRole.get('supervisor:core_loop') || null,
        withShared: markdownByRole.get('supervisor:with_shared') || null,
      },
      mainSession: mainSessionsByAgent.get('supervisor') || null,
      cronSessions: supervisorCronRows,
    },
    metrics: {
      markdown,
      live,
    },
  };
}

function getDashboardPayload() {
  const now = Date.now();
  if (cachedPayload && (now - cachedAt) < CACHE_TTL_MS) {
    return cachedPayload;
  }

  cachedPayload = buildDashboardPayload();
  cachedAt = now;
  return cachedPayload;
}

app.use(express.static(path.join(__dirname, 'public'), {
  etag: false,
  lastModified: false,
  setHeaders: (res) => {
    res.setHeader('Cache-Control', 'no-store');
  }
}));

app.get('/api/dashboard', (req, res) => {
  const payload = getDashboardPayload();
  if (!payload) return res.status(404).json({ error: 'project-scope.yaml not found' });
  res.json(payload);
});

app.get('/api/project', (req, res) => {
  const payload = getDashboardPayload();
  if (!payload) return res.status(404).json({ error: 'project-scope.yaml not found' });
  res.json(payload.project);
});

app.get('/api/agents', (req, res) => {
  const payload = getDashboardPayload();
  if (!payload) return res.status(404).json({ error: 'project-scope.yaml not found' });
  res.json({
    agents: payload.agents,
    supervisor: payload.supervisor,
  });
});

app.get('/api/metrics', (req, res) => {
  const payload = getDashboardPayload();
  if (!payload) return res.status(404).json({ error: 'project-scope.yaml not found' });
  res.json(payload.metrics);
});

app.get('/openclaw', (req, res) => {
  const scope = loadScope();
  if (!scope) return res.status(404).send('project-scope.yaml not found');

  const gateway = resolveGatewayState(scope);
  const target = buildGatewayUrl(gateway.port, gateway.token);
  if (!target) return res.status(503).send('OpenClaw gateway is not configured');
  sendBrowserRedirect(res, target);
});

app.get('/openclaw/agent/:id', (req, res) => {
  const scope = loadScope();
  if (!scope) return res.status(404).send('project-scope.yaml not found');

  const { id } = req.params;
  if (!/^[a-zA-Z0-9._-]+$/.test(id)) return res.status(400).send('Invalid agent id');

  const agentExists = (scope.agents || []).some((agent) => agent.id === id);
  if (!agentExists) return res.status(404).send('Agent not found');

  const gateway = resolveGatewayState(scope);
  const runtimeId = `${slugify(scope.project.name)}-${id}`;
  const target = buildGatewayUrl(gateway.port, gateway.token, '/chat', { session: `agent:${runtimeId}:main` });

  if (!target) return res.status(503).send('OpenClaw gateway is not configured');
  sendBrowserRedirect(res, target);
});

app.get('/openclaw/supervisor', (req, res) => {
  const scope = loadScope();
  if (!scope) return res.status(404).send('project-scope.yaml not found');

  const gateway = resolveGatewayState(scope);
  const runtimeId = `${slugify(scope.project.name)}-supervisor`;
  const target = buildGatewayUrl(gateway.port, gateway.token, '/chat', { session: `agent:${runtimeId}:main` });

  if (!target) return res.status(503).send('OpenClaw gateway is not configured');
  sendBrowserRedirect(res, target);
});

app.get('/api/agent/:id/file/:filename', (req, res) => {
  const scope = loadScope();
  if (!scope) return res.status(404).json({ error: 'project-scope.yaml not found' });

  const { id, filename } = req.params;
  if (!/^[a-zA-Z0-9._-]+$/.test(id)) return res.status(400).json({ error: 'Invalid agent id' });
  const allowed = ['STATUS.md', 'BRIEF.md', 'PLAN.md', 'MEMORY.md', 'SOUL.md', 'PROJECT.md', 'BLOCKERS.md'];
  if (!allowed.includes(filename)) return res.status(400).json({ error: 'File not allowed' });

  const projectRoot = resolveProjectRoot(scope);
  const agentsDir = path.join(projectRoot, '.fleetclaw', 'agents');
  const filePath = path.resolve(agentsDir, id, filename);
  if (!filePath.startsWith(agentsDir + path.sep)) return res.status(400).json({ error: 'Invalid path' });
  const content = readMdFile(filePath);
  if (content === null) return res.status(404).json({ error: 'File not found' });
  res.type('text/plain').send(content);
});

app.get('/api/files', (req, res) => {
  const scope = loadScope();
  const projectRoot = scope ? resolveProjectRoot(scope) : path.resolve(SCRIPT_DIR, '..');
  try {
    const output = execText('find . -maxdepth 3 -not -path "*/node_modules/*" -not -path "*/.git/*" -not -name ".*" -type f | sort', {
      cwd: projectRoot,
    });
    res.json({ files: output ? output.split('\n').filter(Boolean) : [] });
  } catch {
    res.json({ files: [] });
  }
});

app.listen(PORT, HOST, () => {
  const scope = loadScope();
  const projectRoot = scope ? resolveProjectRoot(scope) : 'unknown';
  console.log(`FleetClaw Dashboard running at http://${HOST}:${PORT}`);
  console.log(`Project root: ${projectRoot}`);
  console.log(`Scope file: ${SCOPE_FILE}`);
});
