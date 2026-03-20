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

function resolveScopeText(rawText, rawFilePath) {
  if (rawFilePath && typeof rawFilePath === 'string') {
    const expanded = rawFilePath.startsWith('~') ? rawFilePath.replace('~', process.env.HOME) : rawFilePath;
    const resolved = path.isAbsolute(expanded) ? expanded : path.join(SCRIPT_DIR, expanded);
    const content = readMdFile(resolved);
    if (content) return content.trim();
  }
  return typeof rawText === 'string' ? rawText.trim() : '';
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

function parseTimestamp(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === 'number' && Number.isFinite(value)) {
    return new Date(value);
  }
  if (typeof value === 'string' && value) {
    const normalized = value.endsWith('Z') ? value : value.replace(' ', 'T');
    const parsed = new Date(normalized);
    if (!Number.isNaN(parsed.getTime())) return parsed;
  }
  return null;
}

function extractTextContent(content) {
  if (!Array.isArray(content)) return '';
  return content
    .filter((item) => item && item.type === 'text' && typeof item.text === 'string')
    .map((item) => item.text)
    .join('\n')
    .trim();
}

function execText(command, options = {}) {
  try {
    return execSync(command, { encoding: 'utf8', timeout: 5000, ...options }).trim();
  } catch {
    return '';
  }
}

function execRawText(command, options = {}) {
  try {
    return execSync(command, { encoding: 'utf8', timeout: 5000, ...options });
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

function getFileMtime(filePath) {
  try {
    return fs.statSync(filePath).mtime.toISOString();
  } catch {
    return null;
  }
}

function isEmbeddedGitRepo(filePath) {
  try {
    return fs.statSync(filePath).isDirectory() && fs.existsSync(path.join(filePath, '.git'));
  } catch {
    return false;
  }
}

function parseGitStatus(statusRaw, repoRoot, prefix = '') {
  const modifiedFiles = [];
  const untrackedFiles = [];
  const seen = new Set();

  for (const rawLine of statusRaw ? statusRaw.split('\n') : []) {
    if (!rawLine) continue;

    const indexStatus = rawLine[0];
    const worktreeStatus = rawLine[1];
    let file = rawLine.slice(3).trim();
    if (!file) continue;
    if (file.includes(' -> ')) {
      file = file.split(' -> ').pop();
    }

    const relativeFile = prefix
      ? path.posix.join(prefix.replace(/\\/g, '/'), file.replace(/\\/g, '/'))
      : file;
    const dedupeKey = `${indexStatus}${worktreeStatus}:${relativeFile}`;
    if (!relativeFile || seen.has(dedupeKey)) continue;
    seen.add(dedupeKey);

    const entry = {
      file: relativeFile,
      mtime: getFileMtime(path.join(repoRoot, file)),
      indexStatus,
      worktreeStatus,
    };

    if (indexStatus === '?' && worktreeStatus === '?') {
      untrackedFiles.push({ file: relativeFile, mtime: entry.mtime, untracked: true });
      continue;
    }

    modifiedFiles.push(entry);
  }

  return { modifiedFiles, untrackedFiles };
}

function findLatestSupervisorDecision(profile, runtimeAgentId, supervisorRuntimeId) {
  const sessionDir = path.join(process.env.HOME, `.openclaw-${profile}`, 'agents', runtimeAgentId, 'sessions');
  if (!fs.existsSync(sessionDir)) return null;

  const files = fs.readdirSync(sessionDir)
    .filter((name) => name.endsWith('.jsonl'))
    .sort();

  let latest = null;
  const supervisorPrefix = `agent:${supervisorRuntimeId}:`;

  for (const fileName of files) {
    const filePath = path.join(sessionDir, fileName);
    let lines = [];
    try {
      lines = fs.readFileSync(filePath, 'utf8').split('\n');
    } catch {
      continue;
    }

    for (const rawLine of lines) {
      if (!rawLine) continue;

      let payload;
      try {
        payload = JSON.parse(rawLine);
      } catch {
        continue;
      }

      const message = payload?.message;
      if (!message || typeof message !== 'object') continue;
      if (message.role !== 'user') continue;

      const provenance = message.provenance;
      if (!provenance || typeof provenance !== 'object') continue;
      if (provenance.kind !== 'inter_session') continue;
      if (typeof provenance.sourceSessionKey !== 'string' || !provenance.sourceSessionKey.startsWith(supervisorPrefix)) continue;

      const text = extractTextContent(message.content);
      if (!text) continue;

      const match = text.match(/SUPERVISOR_DECISION:\s*([A-Z_]+)/);
      if (!match) continue;

      const sentAt = parseTimestamp(payload.timestamp) || parseTimestamp(message.timestamp);
      if (!sentAt) continue;

      if (!latest || sentAt > latest.sentAt) {
        latest = {
          decision: match[1],
          text,
          sentAt,
          sourceSessionKey: provenance.sourceSessionKey,
        };
      }
    }
  }

  if (!latest) return null;
  return {
    decision: latest.decision,
    text: latest.text,
    sentAt: latest.sentAt.toISOString(),
    sourceSessionKey: latest.sourceSessionKey,
  };
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
    const statusRaw = execRawText('git status --porcelain=v1 --untracked-files=all', { cwd: projectRoot });
    const diffStat = execText('git diff --stat', { cwd: projectRoot });
    const parsedRootStatus = parseGitStatus(statusRaw, projectRoot);
    const modifiedFiles = [];
    const untrackedFiles = [...parsedRootStatus.untrackedFiles];

    for (const entry of parsedRootStatus.modifiedFiles) {
      const fullPath = path.join(projectRoot, entry.file);
      if (!isEmbeddedGitRepo(fullPath)) {
        modifiedFiles.push(entry);
        continue;
      }

      const nestedStatusRaw = execRawText('git status --porcelain=v1 --untracked-files=all', { cwd: fullPath });
      const nestedStatus = parseGitStatus(nestedStatusRaw, fullPath, entry.file);
      if (nestedStatus.modifiedFiles.length > 0) {
        modifiedFiles.push(...nestedStatus.modifiedFiles);
      } else {
        modifiedFiles.push(entry);
      }
      untrackedFiles.push(...nestedStatus.untrackedFiles);
    }

    const statLines = diffStat ? diffStat.split('\n') : [];
    const summaryLine = statLines.length > 0 ? statLines[statLines.length - 1] : '';

    return {
      branch,
      log,
      changedFiles: modifiedFiles,
      modifiedFiles,
      untrackedFiles,
      modifiedCount: modifiedFiles.length,
      untrackedCount: untrackedFiles.length,
      diffSummary: summaryLine,
      timestamp: new Date().toISOString(),
    };
  } catch {
    return {
      branch: 'unknown',
      log: '',
      changedFiles: [],
      modifiedFiles: [],
      untrackedFiles: [],
      modifiedCount: 0,
      untrackedCount: 0,
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

function formatDashboardTimestamp(date) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) return null;
  return date.toISOString().slice(0, 16).replace('T', ' ') + ' UTC';
}

function resolveStatusLastUpdatedDisplay(statusFields, statusFilePath) {
  const rawValue = statusFields?.['last updated'] || '';
  const parsedRaw = parseTimestamp(rawValue);
  const parsedMtime = parseTimestamp(getFileMtime(statusFilePath));
  const nowMs = Date.now();
  // Keep a small skew allowance, but reject minute-rounded future timestamps.
  const toleranceMs = 5 * 1000;

  if (parsedRaw) {
    const rawMs = parsedRaw.getTime();
    const aheadOfNow = rawMs > nowMs + toleranceMs;
    const aheadOfFile = parsedMtime ? rawMs > parsedMtime.getTime() + toleranceMs : false;
    if (!aheadOfNow && !aheadOfFile) {
      return rawValue;
    }
  }

  return formatDashboardTimestamp(parsedMtime) || rawValue || '-';
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
  const supervisorRuntimeId = `${projectSlug}-supervisor`;
  const agents = (scope.agents || []).map((agent) => {
    const agentDir = path.join(fleetclawDir, agent.id);
    const runtimeId = `${projectSlug}-${agent.id}`;
    const statusPath = path.join(agentDir, 'STATUS.md');
    const status = readMdFile(statusPath);
    const brief = readMdFile(path.join(agentDir, 'BRIEF.md'));
    const plan = readMdFile(path.join(agentDir, 'PLAN.md'));
    const memory = readMdFile(path.join(agentDir, 'MEMORY.md'));
    const soul = readMdFile(path.join(agentDir, 'SOUL.md'));
    const statusFields = parseStatusFields(status);

    return {
      id: agent.id,
      runtimeId,
      model: agent.model || scope?.advanced?.default_agent_model || 'unknown',
      thinking: agent.thinking || scope?.advanced?.default_agent_thinking || '',
      focusDirs: agent.focus_dirs || [],
      task: agent.task || '',
      sessionUrl: gateway.port ? `/openclaw/agent/${encodeURIComponent(agent.id)}` : null,
      statusFields,
      lastUpdatedDisplay: resolveStatusLastUpdatedDisplay(statusFields, statusPath),
      latestSupervisorDecision: findLatestSupervisorDecision(profile, runtimeId, supervisorRuntimeId),
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
      description: resolveScopeText(scope.project.description, scope.project.description_file),
      branch: scope.project.branch || 'main',
      profile,
      review: {
        url: scope.project.review_url || '',
        command: scope.project.review_command || '',
        designCommand: scope.project.design_review_command || '',
        notes: scope.project.review_notes || '',
      },
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
        statusReconcileIntervalSecs: scope.supervisor?.status_reconcile_interval_secs || 30,
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
