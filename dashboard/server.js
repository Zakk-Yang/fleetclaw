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
// --- Tuning constants -----------------------------------------------------------
// Cache TTL for the full dashboard payload (prevents shell-out thrashing on rapid refreshes).
const CACHE_TTL_MS = 3000;
// Maximum human-feedback entries returned to the UI.
const FEEDBACK_HISTORY_LIMIT = 12;
// Recent control-plane messages shown in the "Control plane" panel.
const CONTROL_PLANE_HISTORY_LIMIT = 20;
// Control-plane entries loaded for analytics (push-vs-poll, latency, etc.).
const CONTROL_PLANE_ANALYTICS_LIMIT = 500;
// Snapshot sampling interval — one row per minute → 720 rows = 12 hours of history.
const DASHBOARD_SNAPSHOT_HISTORY_LIMIT = 720;
const DASHBOARD_SNAPSHOT_INTERVAL_MS = 60 * 1000;
// Alert thresholds — tripped values surface in the "Project health" panel.
const HIGH_CONTEXT_ALERT_PCT = 80;        // main-session context above this → "High context" alert
const HIGH_SUPERVISOR_SHARE_PCT = 45;     // supervisor share of main tokens → "High coordination overhead"
const PUSH_DEGRADED_PCT = 50;             // push-triggered reviews below this → "Push degraded"
const STALE_ACCEPT_MINUTES = 120;         // minutes without an ACCEPT_DONE → "Stale work landing"
const BLOCKED_LANE_ALERT_MINUTES = 20;    // blocked lane age → "Blocked lane" alert
// Maximum size (bytes) for JSONL log files before rotation kicks in (~5 MB).
const LOG_MAX_BYTES = 5 * 1024 * 1024;
// Number of rotated log archives to keep (e.g. control-plane.1.jsonl … control-plane.3.jsonl).
const LOG_ROTATE_KEEP = 3;
const THINKING_LEVELS = ['off', 'minimal', 'low', 'medium', 'high', 'xhigh'];

// --- Agent state constants ------------------------------------------------------
const AGENT_STATES = Object.freeze({
  WORKING: 'working',
  BLOCKED: 'blocked',
  DONE: 'done',
  READY_FOR_REVIEW: 'ready-for-review',
  MONITORING: 'monitoring',
});
const SUPERVISOR_DECISIONS = Object.freeze({
  CONTINUE: 'CONTINUE',
  REDIRECT: 'REDIRECT',
  STOP: 'STOP',
  ACCEPT_DONE: 'ACCEPT_DONE',
  ESCALATE: 'ESCALATE',
});

// --- Derived paths ---------------------------------------------------------------
const GENERATED_DIR = path.join(SCRIPT_DIR, 'generated');
const FEEDBACK_LOG_FILE = path.join(GENERATED_DIR, 'human-feedback.jsonl');
const DASHBOARD_SNAPSHOT_FILE_NAME = 'dashboard-metrics.jsonl';
const PROJECT_STATUS_FILE_NAME = 'PROJECT_STATUS.md';
let cachedPayload = null;
let cachedAt = 0;

app.use(express.json({ limit: '64kb' }));

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

function writeScope(scope) {
  const dumped = yaml.dump(scope, {
    lineWidth: 120,
    noRefs: true,
    quotingType: '"',
  });
  fs.writeFileSync(SCOPE_FILE, `${dumped.trimEnd()}\n`, 'utf8');
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

function invalidateDashboardCache() {
  cachedPayload = null;
  cachedAt = 0;
}

function readMdFile(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.error(`[readMdFile] unexpected error reading ${filePath}: ${err.message}`);
    }
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

function startOfLocalDay(date = new Date()) {
  const copy = new Date(date);
  copy.setHours(0, 0, 0, 0);
  return copy;
}

function extractTextContent(content) {
  if (!Array.isArray(content)) return '';
  return content
    .filter((item) => item && item.type === 'text' && typeof item.text === 'string')
    .map((item) => item.text)
    .join('\n')
    .trim();
}

function safeSum(values) {
  return values.reduce((total, value) => total + (Number.isFinite(Number(value)) ? Number(value) : 0), 0);
}

function safeAverage(values) {
  const valid = values.map((value) => Number(value)).filter((value) => Number.isFinite(value));
  if (!valid.length) return null;
  return safeSum(valid) / valid.length;
}

function roundFinite(value, digits = 2) {
  const number = Number(value);
  if (!Number.isFinite(number)) return null;
  return Number(number.toFixed(digits));
}

function median(values) {
  const valid = values.map((value) => Number(value)).filter((value) => Number.isFinite(value)).sort((a, b) => a - b);
  if (!valid.length) return null;
  const middle = Math.floor(valid.length / 2);
  if (valid.length % 2 === 1) return valid[middle];
  return (valid[middle - 1] + valid[middle]) / 2;
}

function formatInt(value) {
  if (value === null || value === undefined || value === '') return 'warming up';
  const number = Number(value);
  if (!Number.isFinite(number)) return 'warming up';
  return Math.round(number).toLocaleString();
}

function formatPct(value, digits = 1) {
  if (value === null || value === undefined || value === '') return 'warming up';
  const number = Number(value);
  if (!Number.isFinite(number)) return 'warming up';
  return `${number.toFixed(digits)}%`;
}

function formatRate(value, unit = 'tok/hr') {
  if (value === null || value === undefined || value === '') return 'warming up';
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) return 'warming up';
  return `${formatInt(number)} ${unit}`;
}

function formatElapsedHours(value) {
  if (value === null || value === undefined || value === '') return 'warming up';
  const hours = Number(value);
  if (!Number.isFinite(hours) || hours < 0) return 'warming up';
  if (hours < (1 / 60)) return '<1 min';
  if (hours < 1) return `${Math.max(1, Math.round(hours * 60))} min`;
  if (hours < 10) return `${hours.toFixed(1)} hr`;
  return `${Math.round(hours)} hr`;
}

function formatTokenCount(value, unit = 'tok') {
  if (value === null || value === undefined || value === '') return 'warming up';
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) return 'warming up';
  return `${formatInt(number)} ${unit}`;
}

function formatDurationMinutes(value) {
  const minutes = Number(value);
  if (!Number.isFinite(minutes) || minutes < 0) return 'warming up';
  if (minutes < 1) return '<1 min';
  if (minutes < 60) return `${minutes.toFixed(minutes < 10 ? 1 : 0)} min`;
  const hours = minutes / 60;
  return `${hours.toFixed(hours < 10 ? 1 : 0)} hr`;
}

function normalizeRepoPath(value) {
  return String(value || '')
    .trim()
    .replace(/\\/g, '/')
    .replace(/^\.\//, '')
    .replace(/^\/+/, '');
}

function uniqueSorted(values) {
  return Array.from(new Set(values.filter(Boolean))).sort();
}

function estimateTokensFromText(text) {
  const value = trimString(String(text || ''), 20000);
  if (!value) return 0;
  return Math.max(1, Math.ceil(value.length / 4));
}

function parseFilesTouchedField(value) {
  if (typeof value !== 'string') return [];
  return uniqueSorted(
    value
      .split(/[\n,]/)
      .map((item) => normalizeRepoPath(item))
      .filter((item) => item && item.toLowerCase() !== 'none'),
  );
}

function isMetaOnlyPath(filePath) {
  const file = normalizeRepoPath(filePath);
  if (!file) return true;
  if (file.startsWith('.fleetclaw/')) return true;
  if (file.startsWith('.openclaw/')) return true;
  if (file.startsWith('fleetclaw/')) return true;
  return ['AGENTS.md', 'HEARTBEAT.md', 'IDENTITY.md', 'SOUL.md', 'TOOLS.md', 'USER.md'].includes(file);
}

function isAllowedAgentMetaPath(filePath, agentId) {
  const file = normalizeRepoPath(filePath);
  if (!file) return false;
  if (file.startsWith(`.fleetclaw/agents/${agentId}/`)) return true;
  if (file.startsWith('.fleetclaw/bin/')) return true;
  return file === '.fleetclaw/runtime.env';
}

function isWorkProductPath(filePath) {
  const file = normalizeRepoPath(filePath);
  return Boolean(file) && !isMetaOnlyPath(file);
}

function matchesFocusPath(filePath, focusPath) {
  const file = normalizeRepoPath(filePath);
  const focus = normalizeRepoPath(focusPath);
  if (!file || !focus) return false;
  if (focus.endsWith('/')) {
    const prefix = focus.replace(/\/+$/, '');
    return file === prefix || file.startsWith(`${prefix}/`);
  }
  return file === focus;
}

function matchesAgentScope(filePath, agent) {
  if (isAllowedAgentMetaPath(filePath, agent.id)) return true;
  const focusDirs = Array.isArray(agent.focusDirs) ? agent.focusDirs : [];
  return focusDirs.some((focusPath) => matchesFocusPath(filePath, focusPath));
}

function resolveWorkProductFiles(git) {
  const rows = [
    ...(Array.isArray(git?.modifiedFiles) ? git.modifiedFiles : []),
    ...(Array.isArray(git?.untrackedFiles) ? git.untrackedFiles : []),
  ];
  return uniqueSorted(
    rows
      .map((entry) => normalizeRepoPath(entry?.file))
      .filter((file) => isWorkProductPath(file)),
  );
}

function execText(command, options = {}) {
  try {
    return execSync(command, { encoding: 'utf8', timeout: 5000, ...options }).trim();
  } catch (err) {
    console.error(`[execText] command failed: ${command}: ${err.message}`);
    return '';
  }
}

function execRawText(command, options = {}) {
  try {
    return execSync(command, { encoding: 'utf8', timeout: 5000, ...options });
  } catch (err) {
    console.error(`[execRawText] command failed: ${command}: ${err.message}`);
    return '';
  }
}

function execFileText(command, args, options = {}) {
  try {
    return execFileSync(command, args, { encoding: 'utf8', timeout: 5000, ...options }).trim();
  } catch (err) {
    console.error(`[execFileText] command failed: ${command} ${args.join(' ')}: ${err.message}`);
    return '';
  }
}

function execFileJson(command, args, options = {}) {
  const raw = execFileText(command, args, options);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch (err) {
    console.error(`[execFileJson] JSON parse failed for ${command} ${args.join(' ')}: ${err.message}`);
    return null;
  }
}

function formatExecError(error) {
  const stderr = typeof error?.stderr === 'string' ? error.stderr : error?.stderr?.toString?.('utf8');
  const stdout = typeof error?.stdout === 'string' ? error.stdout : error?.stdout?.toString?.('utf8');
  return trimString(stderr || stdout || error?.message || 'Command failed', 4000);
}

function getFileMtime(filePath) {
  try {
    return fs.statSync(filePath).mtime.toISOString();
  } catch { /* file may not exist */
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

  // Fallback: read from control-plane.jsonl if session provenance is missing
  if (!latest) {
    const projectRoot = path.resolve(SCRIPT_DIR, '..');
    if (projectRoot) {
      const logFile = path.join(projectRoot, '.fleetclaw', 'logs', 'control-plane.jsonl');
      if (fs.existsSync(logFile)) {
        try {
          const lines = fs.readFileSync(logFile, 'utf8').split('\n');
          const targetRuntimeId = runtimeAgentId;
          for (const rawLine of lines) {
            if (!rawLine) continue;
            let entry;
            try { entry = JSON.parse(rawLine); } catch { continue; }
            if (entry.direction !== 'supervisor_to_agent') continue;
            if (entry.targetRuntimeId !== targetRuntimeId) continue;
            if (entry.status === 'dispatch-error') continue;
            const sentAt = parseTimestamp(entry.createdAt);
            if (!sentAt) continue;
            const text = `SUPERVISOR_DECISION: ${entry.decision}\nEVENT_ID: ${entry.eventId}\nNEXT: ${entry.next || 'n/a'}${entry.reason ? `\nREASON: ${entry.reason}` : ''}`;
            if (!latest || sentAt > latest.sentAt) {
              latest = { decision: entry.decision, text, sentAt, sourceSessionKey: 'control-plane-log' };
            }
          }
        } catch { /* ignore read errors */ }
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
    const portMatch = raw.match(/"?gateway"?\s*:\s*\{[\s\S]*?"?port"?\s*:\s*(\d+)/);
    const tokenMatch = raw.match(/"?gateway"?\s*:\s*\{[\s\S]*?"?auth"?\s*:\s*\{[\s\S]*?"?token"?\s*:\s*"([^"]+)"/);

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

function ensureParentDir(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function rotateLogFile(filePath) {
  try {
    const stat = fs.statSync(filePath);
    if (stat.size < LOG_MAX_BYTES) return;
  } catch {
    return;
  }
  for (let i = LOG_ROTATE_KEEP; i >= 1; i--) {
    const src = i === 1 ? filePath : `${filePath}.${i - 1}`;
    const dst = `${filePath}.${i}`;
    try {
      if (fs.existsSync(src)) fs.renameSync(src, dst);
    } catch (err) {
      console.error(`[log-rotate] failed to rename ${src} -> ${dst}: ${err.message}`);
    }
  }
}

function trimString(value, maxLength = 4000) {
  if (typeof value !== 'string') return '';
  return value.trim().slice(0, maxLength);
}

function normalizeFeedbackSeverity(value) {
  const normalized = String(value || '').toLowerCase();
  return ['note', 'issue', 'blocking'].includes(normalized) ? normalized : 'issue';
}

function normalizeFeedbackTarget(scope, value) {
  const target = String(value || 'supervisor').trim();
  if (target === 'supervisor') return 'supervisor';
  return (scope.agents || []).some((agent) => agent.id === target) ? target : null;
}

function resolveFeedbackTargets(scope) {
  const targets = [
    { id: 'supervisor', label: 'Supervisor', kind: 'supervisor', recommended: true },
  ];

  for (const agent of scope.agents || []) {
    targets.push({
      id: agent.id,
      label: agent.id,
      kind: 'agent',
      recommended: false,
    });
  }

  return targets;
}

function resolveFeedbackRuntimeId(scope, targetId) {
  const projectSlug = slugify(scope?.project?.name);
  if (targetId === 'supervisor') return `${projectSlug}-supervisor`;
  if ((scope.agents || []).some((agent) => agent.id === targetId)) {
    return `${projectSlug}-${targetId}`;
  }
  return null;
}

function sendGatewayChatMessage(profile, sessionKey, message, runId) {
  const params = JSON.stringify({
    sessionKey,
    message,
    idempotencyKey: runId,
  });

  try {
    const raw = execFileSync(
      'openclaw',
      ['--profile', profile, 'gateway', 'call', 'chat.send', '--json', '--params', params],
      { encoding: 'utf8', timeout: 10000 },
    );
    const parsed = JSON.parse(raw);
    return {
      ok: true,
      runId: parsed?.runId || runId,
      status: parsed?.status || 'started',
    };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

function appendFeedbackEntry(entry) {
  ensureParentDir(FEEDBACK_LOG_FILE);
  rotateLogFile(FEEDBACK_LOG_FILE);
  fs.appendFileSync(FEEDBACK_LOG_FILE, `${JSON.stringify(entry)}\n`, 'utf8');
}

function loadJsonlEntries(filePath, validator, limit) {
  if (!fs.existsSync(filePath)) return [];
  const rows = [];
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  for (const rawLine of lines) {
    if (!rawLine) continue;
    try {
      const parsed = JSON.parse(rawLine);
      if (validator(parsed)) {
        rows.push(parsed);
      }
    } catch { /* malformed JSONL line — skip */ }
  }

  rows.sort((left, right) => {
    const leftMs = parseTimestamp(left.createdAt)?.getTime() || 0;
    const rightMs = parseTimestamp(right.createdAt)?.getTime() || 0;
    return rightMs - leftMs;
  });

  return rows.slice(0, limit);
}

function loadFeedbackEntries(limit = FEEDBACK_HISTORY_LIMIT) {
  return loadJsonlEntries(
    FEEDBACK_LOG_FILE,
    (parsed) => parsed && typeof parsed === 'object' && typeof parsed.id === 'string',
    limit,
  );
}

function loadControlPlaneEntries(projectRoot, limit = CONTROL_PLANE_HISTORY_LIMIT) {
  const logFile = path.join(projectRoot, '.fleetclaw', 'logs', 'control-plane.jsonl');
  return {
    logFile,
    entries: loadJsonlEntries(
      logFile,
      (parsed) => parsed && typeof parsed === 'object' && typeof parsed.eventId === 'string',
      limit,
    ),
  };
}

function loadControlPlaneHistory(projectRoot, limit = CONTROL_PLANE_ANALYTICS_LIMIT) {
  const logFile = path.join(projectRoot, '.fleetclaw', 'logs', 'control-plane.jsonl');
  return loadJsonlEntries(
    logFile,
    (parsed) => parsed && typeof parsed === 'object' && typeof parsed.eventId === 'string',
    limit,
  ).reverse();
}

function resolveDashboardSnapshotLogFile(projectRoot) {
  return path.join(projectRoot, '.fleetclaw', 'logs', DASHBOARD_SNAPSHOT_FILE_NAME);
}

function loadDashboardSnapshots(projectRoot, limit = DASHBOARD_SNAPSHOT_HISTORY_LIMIT) {
  const logFile = resolveDashboardSnapshotLogFile(projectRoot);
  return {
    logFile,
    entries: loadJsonlEntries(
      logFile,
      (parsed) => parsed && typeof parsed === 'object' && typeof parsed.createdAt === 'string' && Number.isFinite(Number(parsed.totalTokens)),
      limit,
    ).reverse(),
  };
}

function appendDashboardSnapshot(projectRoot, entry) {
  const logFile = resolveDashboardSnapshotLogFile(projectRoot);
  ensureParentDir(logFile);
  rotateLogFile(logFile);
  fs.appendFileSync(logFile, `${JSON.stringify(entry)}\n`, 'utf8');
}

function maybeRecordDashboardSnapshot(projectRoot, entry, snapshots) {
  const existing = Array.isArray(snapshots) ? snapshots.slice() : [];
  const latest = existing[existing.length - 1] || null;
  const latestMs = parseTimestamp(latest?.createdAt)?.getTime() || 0;
  const currentMs = parseTimestamp(entry?.createdAt)?.getTime() || Date.now();

  if (!latest || (currentMs - latestMs) >= DASHBOARD_SNAPSHOT_INTERVAL_MS) {
    appendDashboardSnapshot(projectRoot, entry);
    existing.push(entry);
  }

  return existing.slice(-DASHBOARD_SNAPSHOT_HISTORY_LIMIT);
}

function countGitCommitsSince(projectRoot, sinceDate) {
  const sinceIso = sinceDate instanceof Date ? sinceDate.toISOString() : new Date(sinceDate).toISOString();
  const raw = execFileText('git', ['log', `--since=${sinceIso}`, '--oneline'], { cwd: projectRoot });
  if (!raw) return 0;
  return raw.split('\n').filter(Boolean).length;
}

function buildNotificationMessage(entry) {
  const lines = [
    `AGENT_EVENT: ${entry.eventType || 'CHECKPOINT'}`,
    `EVENT_ID: ${entry.eventId || '-'}`,
    `AGENT_ID: ${entry.agentId || '-'}`,
    `STATE: ${entry.state || '-'}`,
    `REQUEST: ${entry.request || '-'}`,
    `SUMMARY: ${entry.summary || 'n/a'}`,
  ];
  if (entry.blocker && String(entry.blocker).toLowerCase() !== 'none') {
    lines.push(`BLOCKER: ${entry.blocker}`);
  }
  return lines.join('\n');
}

function buildDecisionMessage(entry) {
  const lines = [
    `SUPERVISOR_DECISION: ${entry.decision || '-'}`,
    `EVENT_ID: ${entry.eventId || '-'}`,
    `NEXT: ${entry.next || 'n/a'}`,
  ];
  if (entry.reason) {
    lines.push(`REASON: ${entry.reason}`);
  }
  return lines.join('\n');
}

function dedupeControlPlaneEntries(entries, direction) {
  const deduped = new Map();

  for (const entry of Array.isArray(entries) ? entries : []) {
    if (!entry || typeof entry !== 'object') continue;
    if (direction && entry.direction !== direction) continue;

    const createdMs = parseTimestamp(entry.createdAt)?.getTime() || 0;
    const key = entry.direction === 'supervisor_to_agent'
      ? [entry.direction, entry.agentId || '', entry.eventId || '', entry.decision || ''].join(':')
      : [entry.direction, entry.agentId || '', entry.eventId || '', entry.eventType || entry.request || ''].join(':');

    const existing = deduped.get(key);
    if (!existing || createdMs < existing.createdMs) {
      deduped.set(key, { createdMs, entry });
    }
  }

  return Array.from(deduped.values())
    .sort((left, right) => left.createdMs - right.createdMs)
    .map((item) => item.entry);
}

function countDetectedCompactions(profile, runtimeIds, sinceDate) {
  const sinceMs = sinceDate instanceof Date ? sinceDate.getTime() : 0;
  const seen = new Set();

  for (const runtimeId of uniqueSorted(runtimeIds)) {
    const sessionDir = path.join(process.env.HOME, `.openclaw-${profile}`, 'agents', runtimeId, 'sessions');
    if (!fs.existsSync(sessionDir)) continue;

    let files = [];
    try {
      files = fs.readdirSync(sessionDir)
        .filter((name) => name.endsWith('.jsonl'))
        .sort()
        .reverse()
        .slice(0, 8);
    } catch {
      continue;
    }

    for (const fileName of files) {
      let lines = [];
      try {
        lines = fs.readFileSync(path.join(sessionDir, fileName), 'utf8').split('\n');
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

        const stamp = parseTimestamp(payload?.timestamp || payload?.message?.timestamp);
        if (!stamp || stamp.getTime() < sinceMs) continue;

        const message = payload?.message;
        if (!message || message.role !== 'user') continue;

        const text = extractTextContent(message.content).trim();
        if (!text.startsWith('/compact')) continue;

        seen.add(`${runtimeId}:${payload.id || stamp.toISOString()}`);
      }
    }
  }

  return seen.size;
}

function buildMetricCard(card) {
  return {
    id: card.id,
    label: card.label,
    value: card.value,
    secondary: card.secondary || '',
    definition: card.definition || '',
    formula: card.formula || '',
    breakdown: Array.isArray(card.breakdown) ? card.breakdown : [],
    tone: card.tone || 'info',
  };
}

function resolveModelContextLimit(profile) {
  const status = execFileJson('openclaw', ['--profile', profile, 'models', 'status', '--json']);
  const listing = execFileJson('openclaw', ['--profile', profile, 'models', 'list', '--json']);
  const defaultModel = String(status?.resolvedDefault || status?.defaultModel || '').trim();
  const models = Array.isArray(listing?.models) ? listing.models : [];
  if (!models.length) return null;

  const candidate = models.find((model) => String(model?.key || '') === defaultModel)
    || models.find((model) => Array.isArray(model?.tags) && model.tags.includes('default'));
  const contextWindow = Number(candidate?.contextWindow);
  return Number.isFinite(contextWindow) && contextWindow > 0 ? contextWindow : null;
}

function loadAvailableModels(profile) {
  const models = [];

  // 1. All models from openclaw (configured + discovered across all providers with auth)
  const listing = execFileJson('openclaw', ['--profile', profile, 'models', 'list', '--all', '--json']);
  if (Array.isArray(listing?.models)) {
    const allowedPrefixes = ['ollama/', 'openai/', 'openai-codex/'];
    for (const model of listing.models) {
      const key = trimString(model?.key, 200);
      if (key && allowedPrefixes.some((p) => key.startsWith(p))) {
        models.push(key);
      }
    }
  }

  // 2. Local Ollama models (fallback if openclaw list missed them)
  try {
    const raw = execSync('curl -s http://localhost:11434/api/tags', { encoding: 'utf8', timeout: 5000 });
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed?.models)) {
      for (const m of parsed.models) {
        if (m?.name) models.push(`ollama/${m.name}`);
      }
    }
  } catch { /* ollama not running or unreachable */ }

  return uniqueSorted(models.filter(Boolean));
}

function normalizeModelSetting(value) {
  return trimString(value, 200);
}

function normalizeThinkingSetting(value) {
  const normalized = trimString(value, 50);
  if (!normalized) return '';
  if (!THINKING_LEVELS.includes(normalized)) {
    throw new Error(`Thinking must be one of: ${THINKING_LEVELS.join(', ')}`);
  }
  return normalized;
}

function normalizeFrequencySetting(value) {
  const parsed = Number.parseInt(String(value ?? '').trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > 1440) return null;
  return parsed;
}

function normalizeRestartGatewaySetting(value) {
  return value === true || value === 'true' || value === 1 || value === '1';
}

function resolveRuntimeSettings(scope, profile) {
  return {
    note: 'Model changes are written to project-scope.yaml. Cadence updates reinstall supervisor cron. Restarting the gateway is optional and only needed when you want the next queued turn to pick up the refreshed agent registry immediately.',
    availableModels: loadAvailableModels(profile),
    availableThinkings: THINKING_LEVELS,
    supervisor: {
      model: scope?.supervisor?.model || '',
      checkIntervalMins: Number(scope?.supervisor?.check_interval_mins || 10),
      thinking: scope?.supervisor?.thinking || '',
    },
    agents: (scope?.agents || []).map((agent) => ({
      id: String(agent?.id || ''),
      model: agent?.model || '',
      thinking: agent?.thinking || '',
    })),
    restartGatewaySupported: true,
  };
}

function applyRuntimeSettings(scope, payload) {
  const supervisorModel = normalizeModelSetting(payload?.supervisor?.model ?? scope?.supervisor?.model);
  const checkIntervalMins = normalizeFrequencySetting(payload?.supervisor?.checkIntervalMins ?? scope?.supervisor?.check_interval_mins);
  const supervisorThinking = normalizeThinkingSetting(payload?.supervisor?.thinking ?? scope?.supervisor?.thinking ?? '');
  if (!supervisorModel) {
    throw new Error('Supervisor model is required.');
  }
  if (checkIntervalMins === null) {
    throw new Error('Supervisor check interval must be between 1 and 1440 minutes.');
  }

  const incomingAgents = new Map();
  if (Array.isArray(payload?.agents)) {
    for (const item of payload.agents) {
      const id = trimString(item?.id, 120);
      if (id) incomingAgents.set(id, item);
    }
  }

  scope.supervisor = scope.supervisor || {};
  scope.supervisor.model = supervisorModel;
  scope.supervisor.check_interval_mins = checkIntervalMins;
  scope.supervisor.thinking = supervisorThinking;

  for (const agent of scope.agents || []) {
    const incoming = incomingAgents.get(String(agent?.id || ''));
    const nextModel = normalizeModelSetting(incoming?.model ?? agent?.model);
    const nextThinking = normalizeThinkingSetting(incoming?.thinking ?? agent?.thinking ?? '');
    if (!nextModel) {
      throw new Error(`Agent model is required for ${agent?.id || 'unknown'}.`);
    }
    agent.model = nextModel;
    agent.thinking = nextThinking;
  }

  return {
    scope,
    supervisorThinking,
    restartGateway: normalizeRestartGatewaySetting(payload?.restartGateway),
  };
}

function runRuntimeRefresh(profile, { restartGateway = false } = {}) {
  execFileSync('bash', [path.join(SCRIPT_DIR, 'setup.sh')], {
    cwd: SCRIPT_DIR,
    encoding: 'utf8',
    timeout: 120000,
  });

  const cronScript = path.join(SCRIPT_DIR, 'generated', 'openclaw-cron.sh');
  if (fs.existsSync(cronScript)) {
    execFileSync('bash', [cronScript], {
      cwd: SCRIPT_DIR,
      encoding: 'utf8',
      timeout: 30000,
    });
  }

  execFileSync('bash', [path.join(SCRIPT_DIR, 'sync-supervisor-cron.sh'), '--quiet'], {
    cwd: SCRIPT_DIR,
    encoding: 'utf8',
    timeout: 30000,
  });

  execFileSync('bash', [path.join(SCRIPT_DIR, 'project-status.sh'), '--quiet'], {
    cwd: SCRIPT_DIR,
    encoding: 'utf8',
    timeout: 30000,
  });

  // Always restart gateway after setup to pick up new config (token + model changes)
  {
    execFileSync('openclaw', ['--profile', profile, 'gateway', 'restart'], {
      cwd: SCRIPT_DIR,
      encoding: 'utf8',
      timeout: 30000,
    });
  }
}

function buildOperationalMetrics(scope, projectRoot, profile, agents, live, git, controlPlaneEntries) {
  const now = new Date();
  const startOfDay = startOfLocalDay(now);
  const liveRows = Array.isArray(live?.rows) ? live.rows : [];
  const mainRows = liveRows.filter((row) => row.sessionKind === 'main');
  const agentMainRows = mainRows.filter((row) => row.displayAgentId !== 'supervisor');
  const supervisorMain = mainRows.find((row) => row.displayAgentId === 'supervisor') || null;
  const supervisorLiveRows = liveRows.filter((row) => row.displayAgentId === 'supervisor');
  const workerLiveRows = liveRows.filter((row) => row.displayAgentId !== 'supervisor');
  const runtimeIds = [
    ...(supervisorMain ? [supervisorMain.runtimeId] : []),
    ...agentMainRows.map((row) => row.runtimeId),
  ];

  const totalTokensCurrent = safeSum(liveRows.map((row) => row.totalTokens));
  const mainTokensCurrent = safeSum(mainRows.map((row) => row.totalTokens));
  const supervisorTokensCurrent = Number(supervisorMain?.totalTokens) || 0;
  const supervisorLiveTokensCurrent = safeSum(supervisorLiveRows.map((row) => row.totalTokens));
  const workerTokensCurrent = safeSum(workerLiveRows.map((row) => row.totalTokens));
  const supervisorTokensPct = mainTokensCurrent > 0 ? (supervisorTokensCurrent / mainTokensCurrent) * 100 : null;
  const supervisorLiveTokensPct = totalTokensCurrent > 0 ? (supervisorLiveTokensCurrent / totalTokensCurrent) * 100 : null;
  const avgMainContextPct = safeAverage(mainRows.map((row) => row.usagePct));
  const maxMainContextPct = mainRows.length ? Math.max(...mainRows.map((row) => Number(row.usagePct) || 0)) : 0;
  const maxLiveContextPct = liveRows.length ? Math.max(...liveRows.map((row) => Number(row.usagePct) || 0)) : 0;
  const roleDisplayOrder = ['supervisor', ...agents.map((agent) => agent.id)];
  const compareRoleLabels = (leftLabel, rightLabel) => {
    const leftIndex = roleDisplayOrder.indexOf(leftLabel);
    const rightIndex = roleDisplayOrder.indexOf(rightLabel);
    if (leftIndex !== -1 || rightIndex !== -1) {
      if (leftIndex === -1) return 1;
      if (rightIndex === -1) return -1;
      return leftIndex - rightIndex;
    }
    return String(leftLabel).localeCompare(String(rightLabel));
  };
  const roleTokenBuckets = liveRows.reduce((map, row) => {
    const label = String(row.displayAgentId || row.runtimeId || 'unknown');
    const existing = map.get(label) || {
      label,
      totalTokens: 0,
      totalContextTokens: 0,
      sessionCount: 0,
      mainCount: 0,
      cronCount: 0,
      otherCount: 0,
    };
    existing.totalTokens += Number(row.totalTokens) || 0;
    existing.totalContextTokens += Number(row.contextTokens) || 0;
    existing.sessionCount += 1;
    if (row.sessionKind === 'main') existing.mainCount += 1;
    else if (row.sessionKind === 'cron') existing.cronCount += 1;
    else existing.otherCount += 1;
    map.set(label, existing);
    return map;
  }, new Map());

  const activeAgents = agents.filter((agent) => {
    const state = String(agent.statusFields?.state || '').toLowerCase();
    return state === AGENT_STATES.WORKING || state.includes('review');
  }).length;
  const blockedAgents = agents.filter((agent) => {
    const state = String(agent.statusFields?.state || '').toLowerCase();
    const blocker = String(agent.statusFields?.blocker || '').toLowerCase();
    return state === AGENT_STATES.BLOCKED || (blocker && blocker !== 'none');
  });
  const pendingAgents = agents.filter((agent) => String(agent.statusFields?.['needs supervisor decision'] || '').toLowerCase() === 'yes');
  const allLanesDone = agents.length > 0 && agents.every((agent) => String(agent.statusFields?.state || '').toLowerCase() === AGENT_STATES.DONE);

  const notifications = dedupeControlPlaneEntries(controlPlaneEntries, 'agent_to_supervisor');
  const decisions = dedupeControlPlaneEntries(controlPlaneEntries, 'supervisor_to_agent');
  const notificationsToday = notifications.filter((entry) => {
    const stamp = parseTimestamp(entry.createdAt);
    return stamp && stamp >= startOfDay;
  });
  const decisionsToday = decisions.filter((entry) => {
    const stamp = parseTimestamp(entry.createdAt);
    return stamp && stamp >= startOfDay;
  });

  const earliestDecisionByEvent = new Map();
  for (const entry of decisions) {
    const createdMs = parseTimestamp(entry.createdAt)?.getTime() || 0;
    const existing = earliestDecisionByEvent.get(entry.eventId);
    if (!existing || createdMs < existing.createdMs) {
      earliestDecisionByEvent.set(entry.eventId, { createdMs, entry });
    }
  }

  let pushTriggeredCount = 0;
  let pollTriggeredCount = 0;
  const latencyMinutes = [];
  for (const entry of decisions) {
    const decisionMs = parseTimestamp(entry.createdAt)?.getTime() || 0;
    const notification = notifications.find((item) => item.eventId === entry.eventId && item.agentId === entry.agentId);
    if (notification) {
      const notifyMs = parseTimestamp(notification.createdAt)?.getTime() || 0;
      if (decisionMs >= notifyMs) {
        pushTriggeredCount += 1;
      }
    } else {
      pollTriggeredCount += 1;
    }
  }

  for (const entry of notifications) {
    const decisionMatch = earliestDecisionByEvent.get(entry.eventId);
    if (!decisionMatch) continue;
    const notifyMs = parseTimestamp(entry.createdAt)?.getTime() || 0;
    const decisionMs = decisionMatch.createdMs;
    if (decisionMs >= notifyMs) {
      latencyMinutes.push((decisionMs - notifyMs) / 60000);
    }
  }

  const acceptedDecisionIdsToday = uniqueSorted(
    decisionsToday
      .filter((entry) => entry.decision === SUPERVISOR_DECISIONS.ACCEPT_DONE)
      .map((entry) => `${entry.agentId}:${entry.eventId}`),
  );
  const acceptedTasksToday = acceptedDecisionIdsToday.length;

  const avgNotificationTokens = safeAverage(notifications.map((entry) => estimateTokensFromText(buildNotificationMessage(entry))));
  const avgDecisionTokens = safeAverage(decisions.map((entry) => estimateTokensFromText(buildDecisionMessage(entry))));
  const pushTotal = pushTriggeredCount + pollTriggeredCount;
  const pushPct = pushTotal > 0 ? (pushTriggeredCount / pushTotal) * 100 : null;
  const medianReviewLatency = median(latencyMinutes);

  const workProductFiles = resolveWorkProductFiles(git);
  const commitsToday = countGitCommitsSince(projectRoot, startOfDay);

  const diffAwaitingReviewFiles = uniqueSorted(
    pendingAgents.flatMap((agent) => parseFilesTouchedField(agent.statusFields?.['files touched']))
      .filter((file) => isWorkProductPath(file)),
  );

  const focusDirViolations = uniqueSorted(
    agents.flatMap((agent) => parseFilesTouchedField(agent.statusFields?.['files touched'])
      .filter((file) => isWorkProductPath(file) && !matchesAgentScope(file, agent))),
  );

  const compactionsToday = countDetectedCompactions(profile, runtimeIds, startOfDay);
  const tokensPerAcceptedTask = acceptedTasksToday > 0 ? totalTokensCurrent / acceptedTasksToday : null;
  const roleContextBreakdown = Array.from(roleTokenBuckets.values())
    .sort((left, right) => compareRoleLabels(left.label, right.label))
    .map((bucket) => {
      const usagePct = bucket.totalContextTokens > 0 ? (bucket.totalTokens / bucket.totalContextTokens) * 100 : null;
      const sessionParts = [];
      if (bucket.mainCount) sessionParts.push(bucket.mainCount === 1 ? 'main' : `${bucket.mainCount} main`);
      if (bucket.cronCount) sessionParts.push(bucket.cronCount === 1 ? 'cron' : `${bucket.cronCount} cron`);
      if (bucket.otherCount) sessionParts.push(bucket.otherCount === 1 ? '1 other' : `${bucket.otherCount} other`);
      return {
        ...bucket,
        usagePct,
        sessionMix: sessionParts.join(' + '),
        value: formatPct(usagePct),
        note: `${formatTokenCount(bucket.totalTokens)} / ${formatTokenCount(bucket.totalContextTokens)}${sessionParts.length ? ` · ${sessionParts.join(' + ')}` : ''}`,
      };
    });
  const avgRoleContextPct = safeAverage(roleContextBreakdown.map((item) => item.usagePct));
  const mainContextBreakdown = mainRows
    .slice()
    .sort((left, right) => compareRoleLabels(left.displayAgentId, right.displayAgentId))
    .map((row) => ({
      label: row.displayAgentId,
      value: formatPct(row.usagePct),
      note: `${formatTokenCount(row.totalTokens)} / ${formatTokenCount(row.contextTokens)} · ${row.sessionLabel}`,
    }));
  const contextWarning = [
    Number(avgRoleContextPct),
    Number(avgMainContextPct),
    Number(maxMainContextPct),
  ].some((value) => Number.isFinite(value) && value >= 70);

  const snapshotsState = loadDashboardSnapshots(projectRoot);
  const currentSnapshot = {
    createdAt: now.toISOString(),
    totalTokens: Math.round(totalTokensCurrent),
    mainTokens: Math.round(mainTokensCurrent),
    supervisorTokens: Math.round(supervisorTokensCurrent),
    avgContextPct: roundFinite(avgRoleContextPct),
    avgMainContextPct: roundFinite(avgMainContextPct),
    activeAgents,
    blockedAgents: blockedAgents.length,
    acceptedTasksToday,
    compactionsToday,
    pushReviews: pushTriggeredCount,
    pollReviews: pollTriggeredCount,
  };
  const snapshots = maybeRecordDashboardSnapshot(projectRoot, currentSnapshot, snapshotsState.entries);
  const todaySnapshots = snapshots.filter((entry) => {
    const stamp = parseTimestamp(entry.createdAt);
    return stamp && stamp >= startOfDay;
  });
  const firstSnapshotToday = todaySnapshots[0] || null;
  const tokensToday = todaySnapshots.length >= 2 && firstSnapshotToday
    ? Math.max(0, Math.round(totalTokensCurrent - Number(firstSnapshotToday.totalTokens || 0)))
    : null;

  const latestAcceptedDecision = decisions
    .filter((entry) => entry.decision === SUPERVISOR_DECISIONS.ACCEPT_DONE)
    .map((entry) => ({ entry, stamp: parseTimestamp(entry.createdAt) }))
    .filter((item) => item.stamp)
    .sort((left, right) => right.stamp.getTime() - left.stamp.getTime())[0] || null;

  const lifecycleStartCandidates = [
    ...controlPlaneEntries.map((entry) => parseTimestamp(entry.createdAt)),
    ...agents.map((agent) => parseTimestamp(agent.statusFields?.['last updated'])),
    ...snapshots.map((entry) => parseTimestamp(entry.createdAt)),
  ].filter(Boolean);
  const projectStartedAt = lifecycleStartCandidates.length
    ? lifecycleStartCandidates.reduce((earliest, stamp) => (stamp < earliest ? stamp : earliest))
    : null;

  let projectUntilAt = now;
  if (allLanesDone) {
    const completionCandidates = [
      ...agents
        .filter((agent) => String(agent.statusFields?.state || '').toLowerCase() === AGENT_STATES.DONE)
        .map((agent) => parseTimestamp(agent.statusFields?.['last updated'])),
      latestAcceptedDecision?.stamp || null,
    ].filter(Boolean);
    if (completionCandidates.length) {
      projectUntilAt = completionCandidates.reduce((latest, stamp) => (stamp > latest ? stamp : latest));
    }
  }

  const elapsedProjectHours = projectStartedAt
    ? Math.max(0, (projectUntilAt.getTime() - projectStartedAt.getTime()) / 3600000)
    : null;
  const projectHourlyTokens = Number.isFinite(Number(elapsedProjectHours)) && Number(elapsedProjectHours) > 0
    ? totalTokensCurrent / elapsedProjectHours
    : null;
  const workerHourlyTokens = Number.isFinite(Number(elapsedProjectHours)) && Number(elapsedProjectHours) > 0
    ? workerTokensCurrent / elapsedProjectHours
    : null;
  const supervisorHourlyTokens = Number.isFinite(Number(elapsedProjectHours)) && Number(elapsedProjectHours) > 0
    ? supervisorLiveTokensCurrent / elapsedProjectHours
    : null;
  const roleTokenBreakdown = roleContextBreakdown
    .map((bucket) => {
      const sharePct = totalTokensCurrent > 0 ? (bucket.totalTokens / totalTokensCurrent) * 100 : null;
      const hourlyTokens = Number.isFinite(Number(elapsedProjectHours)) && Number(elapsedProjectHours) > 0
        ? bucket.totalTokens / elapsedProjectHours
        : null;
      return {
        label: bucket.label,
        tokensValue: formatTokenCount(bucket.totalTokens),
        hourlyValue: formatRate(hourlyTokens),
        note: `${formatPct(sharePct)} of project tokens${bucket.sessionMix ? ` · ${bucket.sessionMix}` : ''}`,
      };
    });

  const alerts = [];
  const highContextRows = mainRows.filter((row) => Number(row.usagePct) >= HIGH_CONTEXT_ALERT_PCT);
  if (highContextRows.length) {
    alerts.push({
      level: 'danger',
      title: 'High context',
      detail: `${highContextRows.map((row) => `${row.displayAgentId} ${formatPct(row.usagePct)}`).join(' · ')} — forgetting risk is elevated.`,
    });
  }
  if (Number.isFinite(Number(supervisorTokensPct)) && Number(supervisorTokensPct) >= HIGH_SUPERVISOR_SHARE_PCT) {
    alerts.push({
      level: 'warning',
      title: 'High coordination overhead',
      detail: `Supervisor owns ${formatPct(supervisorTokensPct)} of main-session tokens — orchestration may be too heavy.`,
    });
  }
  if (Number.isFinite(Number(supervisorLiveTokensPct)) && supervisorLiveTokensPct >= 60) {
    alerts.push({
      level: 'warning',
      title: 'Supervisor cost dominates total spend',
      detail: `Supervisor owns ${formatPct(supervisorLiveTokensPct)} of all live-session tokens, likely driven by isolated cron review runs.`,
    });
  }
  if (pushTotal >= 4 && Number.isFinite(Number(pushPct)) && Number(pushPct) < PUSH_DEGRADED_PCT) {
    alerts.push({
      level: 'warning',
      title: 'Push degraded',
      detail: `${formatPct(pushPct)} of recent decisions were push-triggered; polling fallback is dominating.`,
    });
  }
  if (activeAgents > 0) {
    const staleAccept = latestAcceptedDecision
      ? ((now.getTime() - latestAcceptedDecision.stamp.getTime()) / 60000) >= STALE_ACCEPT_MINUTES
      : true;
    if (staleAccept) {
      alerts.push({
        level: 'warning',
        title: 'Stale work landing',
        detail: latestAcceptedDecision
          ? `No accepted task for ${formatDurationMinutes((now.getTime() - latestAcceptedDecision.stamp.getTime()) / 60000)}.`
          : 'No accepted task has landed yet in the sampled history.',
      });
    }
  }

  const blockedTooLong = blockedAgents
    .map((agent) => {
      const stamp = parseTimestamp(agent.statusFields?.['last updated']);
      if (!stamp) return null;
      const ageMinutes = (now.getTime() - stamp.getTime()) / 60000;
      return ageMinutes >= BLOCKED_LANE_ALERT_MINUTES ? { agent, ageMinutes } : null;
    })
    .filter(Boolean);
  if (blockedTooLong.length) {
    alerts.push({
      level: 'danger',
      title: 'Blocked lane',
      detail: blockedTooLong.map((item) => `${item.agent.id} ${formatDurationMinutes(item.ageMinutes)}`).join(' · '),
    });
  }
  if (!alerts.length) {
    alerts.push({
      level: 'ok',
      title: 'Stable',
      detail: 'No high-context, stale-output, push-degraded, or blocked-lane thresholds are currently tripped.',
    });
  }

  return {
    alerts,
    overview: {
      activeAgents,
      blockedAgents: blockedAgents.length,
      pendingReviews: pendingAgents.length,
      acceptedTasksToday,
      avgContextPct: avgRoleContextPct,
      avgRoleContextPct,
      avgMainContextPct,
      maxContextPct: maxMainContextPct,
      maxMainContextPct,
      maxLiveContextPct,
      projectTokensCurrent: totalTokensCurrent,
      projectTokensToday: tokensToday,
      projectHourlyTokens,
      projectElapsedHours: elapsedProjectHours,
      totalTokensCurrent,
      totalTokensToday: tokensToday,
      burnRate: projectHourlyTokens,
      elapsedProjectHours,
      supervisorTokensPct,
      supervisorLiveTokensPct,
      supervisorLiveTokensCurrent,
      workerTokensCurrent,
      workerHourlyTokens,
      supervisorHourlyTokens,
      pushTriggeredCount,
      pollTriggeredCount,
      workProductFiles: workProductFiles.length,
      diffAwaitingReviewFiles: diffAwaitingReviewFiles.length,
    },
    snapshot: {
      logFile: snapshotsState.logFile,
      sampleCount: snapshots.length,
      projectTokensCurrent: Math.round(totalTokensCurrent),
      projectTokensToday: tokensToday,
      projectHourlyTokens,
      projectElapsedHours: elapsedProjectHours,
      totalTokensCurrent: Math.round(totalTokensCurrent),
      totalTokensToday: tokensToday,
      burnRate: projectHourlyTokens,
      elapsedProjectHours,
      workerHourlyTokens,
      supervisorHourlyTokens,
    },
    sections: [
      {
        id: 'health',
        title: 'Project health',
        subtitle: 'Cost, load, and forgetting risk at the whole-fleet level.',
        metrics: [
          buildMetricCard({
            id: 'project-tokens',
            label: 'Project tokens',
            value: formatInt(totalTokensCurrent),
            secondary: Number.isFinite(Number(tokensToday))
              ? `Today +${formatInt(tokensToday)} · ${liveRows.length} live sessions`
              : `Current live footprint · ${liveRows.length} live sessions`,
            definition: 'Approximate token footprint across live sessions that currently report totals. The today delta uses dashboard snapshots, so it is sampled rather than billing-exact.',
            formula: 'sum(totalTokens across live sessions) and current total minus first dashboard snapshot of the day',
            breakdown: roleTokenBreakdown.map((item) => ({
              label: item.label,
              value: item.tokensValue,
              note: item.note,
            })),
            tone: 'info',
          }),
          buildMetricCard({
            id: 'project-hourly-tokens',
            label: 'Project hourly tokens',
            value: formatRate(projectHourlyTokens),
            secondary: `${allLanesDone ? 'Frozen at completion' : 'Using current project time'} · includes supervisor cron · elapsed ${formatElapsedHours(elapsedProjectHours)}`,
            definition: 'Average hourly token usage across the whole fleet lifecycle, including supervisor main and isolated cron sessions. This is cost-oriented, not a pure coding-throughput metric.',
            formula: 'project tokens / elapsed project hours',
            breakdown: roleTokenBreakdown.map((item) => ({
              label: item.label,
              value: item.hourlyValue,
              note: item.note,
            })),
            tone: Number.isFinite(Number(projectHourlyTokens)) && projectHourlyTokens > 12000 ? 'warning' : 'info',
          }),
          buildMetricCard({
            id: 'worker-hourly-tokens',
            label: 'Worker hourly tokens',
            value: formatRate(workerHourlyTokens),
            secondary: `${formatInt(workerLiveRows.length)} worker sessions · excludes supervisor main + cron`,
            definition: 'Average hourly token usage attributable to coding lanes only. Use this to judge implementation throughput without supervisor coordination overhead.',
            formula: 'worker live-session tokens / elapsed project hours',
            breakdown: roleTokenBreakdown
              .filter((item) => item.label !== 'supervisor')
              .map((item) => ({
                label: item.label,
                value: item.hourlyValue,
                note: item.note,
              })),
            tone: Number.isFinite(Number(workerHourlyTokens)) && workerHourlyTokens > 12000 ? 'warning' : 'info',
          }),
          buildMetricCard({
            id: 'active-agents',
            label: 'Active lanes',
            value: formatInt(activeAgents),
            secondary: `${formatInt(pendingAgents.length)} waiting for review · ${formatInt(blockedAgents.length)} blocked`,
            definition: 'Coding lanes currently moving work or waiting in a review state. Done lanes are excluded.',
            formula: 'count(STATUS state in {working, ready-for-review})',
            tone: activeAgents > 0 ? 'good' : 'info',
          }),
          buildMetricCard({
            id: 'blocked-agents',
            label: 'Blocked lanes',
            value: formatInt(blockedAgents.length),
            secondary: blockedAgents.length ? blockedAgents.map((agent) => agent.id).join(', ') : 'No open blockers',
            definition: 'Lanes that explicitly report a blocked state or a non-empty blocker field.',
            formula: 'count(agent where state = blocked or blocker != none)',
            tone: blockedAgents.length ? 'danger' : 'good',
          }),
          buildMetricCard({
            id: 'accepted-tasks',
            label: 'Accepted tasks',
            value: formatInt(acceptedTasksToday),
            secondary: 'Today only',
            definition: 'Unique supervisor acceptances that landed today. This is the clearest sign that work is actually being approved and closed.',
            formula: 'count(distinct ACCEPT_DONE decisions recorded today)',
            tone: acceptedTasksToday > 0 ? 'good' : 'warning',
          }),
          buildMetricCard({
            id: 'avg-context',
            label: 'Avg role context %',
            value: formatPct(avgRoleContextPct),
            secondary: `${formatInt(roleContextBreakdown.length)} roles · main avg ${formatPct(avgMainContextPct)} · max main ${formatPct(maxMainContextPct)}`,
            definition: 'Mean current context occupancy across roles. Each role aggregates its live sessions first, so the supervisor includes main plus cron capacity before being averaged with the agent roles.',
            formula: 'average(sum(role tokens) / sum(role context limits) across roles)',
            breakdown: roleContextBreakdown.map((item) => ({
              label: item.label,
              value: item.value,
              note: item.note,
            })),
            tone: contextWarning ? 'warning' : 'info',
          }),
          buildMetricCard({
            id: 'avg-main-context',
            label: 'Avg main context %',
            value: formatPct(avgMainContextPct),
            secondary: `${formatInt(mainRows.length)} main sessions · max ${formatPct(maxMainContextPct)} · live max ${formatPct(maxLiveContextPct)}`,
            definition: 'Mean current context occupancy across persistent main sessions only. This is the direct forgetting-risk view for the ongoing supervisor and agent conversations.',
            formula: 'average(totalTokens / contextTokens for main sessions)',
            breakdown: mainContextBreakdown,
            tone: contextWarning ? 'warning' : 'info',
          }),
          buildMetricCard({
            id: 'compactions',
            label: 'Compactions',
            value: formatInt(compactionsToday),
            secondary: 'Detected /compact commands today',
            definition: 'Observed compaction commands in local session history for the current day. This is a practical forgetting-pressure signal, not a perfect internal counter.',
            formula: 'count(user messages starting with /compact in today’s session history)',
            tone: compactionsToday > 0 ? 'warning' : 'good',
          }),
        ],
      },
      {
        id: 'coordination',
        title: 'Coordination efficiency',
        subtitle: 'Whether FleetClaw is staying lean or letting orchestration take over.',
        metrics: [
          buildMetricCard({
            id: 'supervisor-tokens-pct',
            label: 'Supervisor tokens %',
            value: formatPct(supervisorTokensPct),
            secondary: `${formatInt(supervisorTokensCurrent)} of ${formatInt(mainTokensCurrent)} main-session tokens`,
            definition: 'Share of main-session tokens currently sitting in the supervisor rather than in the worker lanes.',
            formula: 'supervisor main-session tokens / total main-session tokens',
            tone: Number.isFinite(Number(supervisorTokensPct)) && supervisorTokensPct >= HIGH_SUPERVISOR_SHARE_PCT ? 'warning' : 'info',
          }),
          buildMetricCard({
            id: 'coordination-overhead',
            label: 'Coordination overhead',
            value: formatPct(supervisorLiveTokensPct),
            secondary: `${formatInt(supervisorLiveTokensCurrent)} of ${formatInt(totalTokensCurrent)} all live tokens · includes cron`,
            definition: 'Share of all currently reported live-session tokens consumed by the supervisor, including isolated cron review runs. This is the best single metric for \"is the control plane too expensive?\"',
            formula: 'supervisor live-session tokens / total live-session tokens',
            tone: Number.isFinite(Number(supervisorLiveTokensPct)) && supervisorLiveTokensPct >= 50 ? 'warning' : 'info',
          }),
          buildMetricCard({
            id: 'push-vs-poll',
            label: 'Push vs poll reviews',
            value: Number.isFinite(Number(pushPct)) ? `${formatPct(pushPct)} push` : 'warming up',
            secondary: pushTotal > 0 ? `${formatInt(pushTriggeredCount)} push · ${formatInt(pollTriggeredCount)} poll/manual` : 'No sampled decisions yet',
            definition: 'How many review decisions were triggered by an agent checkpoint versus supervisor polling or manual intervention.',
            formula: 'share of supervisor decisions that match a prior agent notification for the same EVENT_ID',
            tone: Number.isFinite(Number(pushPct)) && pushPct < PUSH_DEGRADED_PCT ? 'warning' : 'good',
          }),
          buildMetricCard({
            id: 'avg-notification-size',
            label: 'Avg notification size',
            value: formatTokenCount(avgNotificationTokens),
            secondary: `${formatInt(notifications.length)} sampled agent notifications`,
            definition: 'Mean estimated size of agent -> supervisor control messages. Drift upward means the compact delta protocol is being ignored.',
            formula: 'average(estimated tokens of serialized AGENT_EVENT messages)',
            tone: Number.isFinite(Number(avgNotificationTokens)) && avgNotificationTokens > (scope?.protocol?.agent_to_supervisor_max_tokens || 80) ? 'warning' : 'info',
          }),
          buildMetricCard({
            id: 'avg-decision-size',
            label: 'Avg decision size',
            value: formatTokenCount(avgDecisionTokens),
            secondary: `${formatInt(decisions.length)} sampled supervisor decisions`,
            definition: 'Mean estimated size of supervisor -> agent decisions. Drift upward means the supervisor is re-expanding into rich chat.',
            formula: 'average(estimated tokens of serialized SUPERVISOR_DECISION messages)',
            tone: Number.isFinite(Number(avgDecisionTokens)) && avgDecisionTokens > (scope?.protocol?.supervisor_to_agent_max_tokens || 120) ? 'warning' : 'info',
          }),
          buildMetricCard({
            id: 'review-latency',
            label: 'Review latency',
            value: formatDurationMinutes(medianReviewLatency),
            secondary: `${formatInt(latencyMinutes.length)} matched checkpoints`,
            definition: 'Median wait time from an agent checkpoint notification to the first supervisor decision for the same event.',
            formula: 'median(supervisor decision time - matching agent notification time)',
            tone: Number.isFinite(Number(medianReviewLatency)) && medianReviewLatency > 10 ? 'warning' : 'good',
          }),
        ],
      },
      {
        id: 'output',
        title: 'Output and repo progress',
        subtitle: 'Whether the token spend is becoming visible repo movement.',
        metrics: [
          buildMetricCard({
            id: 'commits-today',
            label: 'Commits',
            value: formatInt(commitsToday),
            secondary: 'Today only',
            definition: 'Commits created in the project repo since the start of the current day.',
            formula: 'count(git commits since local day start)',
            tone: commitsToday > 0 ? 'good' : 'info',
          }),
          buildMetricCard({
            id: 'files-changed',
            label: 'Files changed',
            value: formatInt(workProductFiles.length),
            secondary: 'Work-product files only',
            definition: 'Current modified or untracked repo files, excluding FleetClaw framework state, OpenClaw runtime state, and generated scaffolding.',
            formula: 'count(unique modified/untracked files outside meta paths)',
            tone: workProductFiles.length > 0 ? 'info' : 'good',
          }),
          buildMetricCard({
            id: 'diff-awaiting-review',
            label: 'Diff awaiting review',
            value: formatInt(diffAwaitingReviewFiles.length),
            secondary: `${formatInt(pendingAgents.length)} lanes requesting a decision`,
            definition: 'Files explicitly named by lanes that are currently waiting on supervisor review or acceptance.',
            formula: 'count(unique files touched by agents with Needs supervisor decision = yes)',
            tone: diffAwaitingReviewFiles.length > 0 ? 'warning' : 'good',
          }),
          buildMetricCard({
            id: 'focus-violations',
            label: 'Focus-dir violations',
            value: formatInt(focusDirViolations.length),
            secondary: focusDirViolations.length ? focusDirViolations.join(', ') : 'No out-of-scope files reported',
            definition: 'Touched work-product files that fall outside the owning agent’s declared focus paths.',
            formula: 'count(files touched by an agent that do not match that agent’s focus_dirs)',
            tone: focusDirViolations.length ? 'danger' : 'good',
          }),
          buildMetricCard({
            id: 'tokens-per-accepted-task',
            label: 'Tokens / accepted task',
            value: formatTokenCount(tokensPerAcceptedTask, 'tok/task'),
            secondary: acceptedTasksToday > 0 ? `${formatInt(acceptedTasksToday)} accepted today` : 'Needs at least one accepted task today',
            definition: 'A simple efficiency proxy: how many currently reported live-session tokens you are carrying for each task that actually got accepted today.',
            formula: 'current total tokens / accepted tasks today',
            tone: Number.isFinite(Number(tokensPerAcceptedTask)) && tokensPerAcceptedTask > 50000 ? 'warning' : 'info',
          }),
        ],
      },
    ],
  };
}

function buildHumanFeedbackMessage(entry) {
  const header = `[${formatDashboardTimestamp(parseTimestamp(entry.createdAt)) || entry.createdAt}] HUMAN_FEEDBACK`;
  const lines = [
    header,
    `Target: ${entry.targetLabel}`,
    `Severity: ${entry.severity}`,
    `Blocks acceptance: ${entry.blocksAcceptance ? 'yes' : 'no'}`,
  ];

  if (entry.surface) {
    lines.push(`Review surface: ${entry.surface}`);
  }

  lines.push('');
  lines.push('Feedback:');
  lines.push(entry.message);
  lines.push('');

  if (entry.target === 'supervisor') {
    lines.push('Review this feedback, reproduce the issue if needed, and route the next decision to the correct lane.');
    if (entry.blocksAcceptance) {
      lines.push('Treat this as blocking review feedback and do not accept the current review build until it is resolved.');
    } else {
      lines.push('If this resolves an open blocker or environment issue, send the affected lane a follow-up decision immediately so it can leave blocked state.');
      lines.push('Use ACCEPT_DONE when the work was already acceptable and only the blocker remained; otherwise use CONTINUE or REDIRECT.');
    }
  } else {
    lines.push('Treat this as direct human feedback for your lane. If coordination is needed, update STATUS.md and request a supervisor decision before continuing.');
  }

  return lines.join('\n');
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
    } catch { /* config value not valid JSON — fall through */ }
  }

  const modelContextLimit = resolveModelContextLimit(profile);
  if (Number.isFinite(modelContextLimit) && modelContextLimit > 0) {
    return modelContextLimit;
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
  const projectStatusPath = path.join(projectRoot, '.fleetclaw', PROJECT_STATUS_FILE_NAME);
  const projectStatusRaw = readMdFile(projectStatusPath);
  const projectStatusFields = parseStatusFields(projectStatusRaw);
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
  const feedbackTargets = resolveFeedbackTargets(scope);
  const feedbackEntries = loadFeedbackEntries();
  const controlPlane = loadControlPlaneEntries(projectRoot);
  const controlPlaneHistory = loadControlPlaneHistory(projectRoot);
  const analytics = buildOperationalMetrics(scope, projectRoot, profile, agents, live, git, controlPlaneHistory);

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
      runtimeSettings: resolveRuntimeSettings(scope, profile),
      protocol: {
        pollingFallback: scope?.protocol?.polling_fallback ?? true,
        agentToSupervisorMaxTokens: scope?.protocol?.agent_to_supervisor_max_tokens || 80,
        supervisorToAgentMaxTokens: scope?.protocol?.supervisor_to_agent_max_tokens || 120,
      },
      status: {
        raw: projectStatusRaw,
        fields: projectStatusFields,
        lastUpdatedDisplay: resolveStatusLastUpdatedDisplay(projectStatusFields, projectStatusPath),
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
      analytics,
    },
    feedback: {
      entries: feedbackEntries,
      targets: feedbackTargets,
    },
    controlPlane,
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

app.post('/api/runtime-settings', (req, res) => {
  const scope = loadScope();
  if (!scope) return res.status(404).json({ error: 'project-scope.yaml not found' });

  const profile = resolveProfile(scope);

  try {
    const { scope: nextScope, restartGateway } = applyRuntimeSettings(scope, req.body || {});
    writeScope(nextScope);
    runRuntimeRefresh(profile, { restartGateway });
    invalidateDashboardCache();

    const refreshedScope = loadScope();
    return res.json({
      ok: true,
      runtimeSettings: resolveRuntimeSettings(refreshedScope || nextScope, profile),
      restartedGateway: restartGateway,
      note: restartGateway
        ? 'Settings saved, supervisor cron reinstalled, and the gateway was restarted to force the next queued turn onto the refreshed agent registry.'
        : 'Settings saved and supervisor cron reinstalled. If you need the very next queued turn to force-refresh its agent registry, apply again with gateway restart enabled.',
    });
  } catch (error) {
    return res.status(400).json({
      error: error instanceof Error ? formatExecError(error) : String(error),
    });
  }
});

app.post('/api/feedback', (req, res) => {
  const scope = loadScope();
  if (!scope) return res.status(404).json({ error: 'project-scope.yaml not found' });

  const target = normalizeFeedbackTarget(scope, req.body?.target);
  if (!target) return res.status(400).json({ error: 'Invalid feedback target' });

  const message = trimString(req.body?.message, 6000);
  if (!message) return res.status(400).json({ error: 'Feedback message is required' });

  const severity = normalizeFeedbackSeverity(req.body?.severity);
  const surface = trimString(req.body?.surface, 1000);
  const blocksAcceptance = Boolean(req.body?.blocksAcceptance);
  const runtimeId = resolveFeedbackRuntimeId(scope, target);
  if (!runtimeId) return res.status(400).json({ error: 'Could not resolve runtime target' });

  const targetInfo = resolveFeedbackTargets(scope).find((item) => item.id === target);
  const createdAt = new Date().toISOString();
  const entry = {
    id: `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    createdAt,
    target,
    targetLabel: targetInfo?.label || target,
    targetKind: targetInfo?.kind || 'agent',
    runtimeId,
    severity,
    blocksAcceptance,
    surface,
    message,
    status: 'started',
  };

  const profile = resolveProfile(scope);
  const delivery = sendGatewayChatMessage(
    profile,
    `agent:${runtimeId}:main`,
    buildHumanFeedbackMessage(entry),
    entry.id,
  );
  if (!delivery.ok) {
    entry.status = 'dispatch-error';
    entry.error = delivery.error;
    appendFeedbackEntry(entry);
    invalidateDashboardCache();
    return res.status(500).json({ error: delivery.error || 'Could not queue feedback message', entry });
  }

  entry.status = delivery.status || 'started';
  entry.runId = delivery.runId || entry.id;
  appendFeedbackEntry(entry);
  invalidateDashboardCache();

  // Wake up supervisor cron if project was marked complete
  if (target === 'supervisor' || targetInfo?.kind === 'supervisor') {
    try {
      const cronScript = path.join(SCRIPT_DIR, 'generated', 'openclaw-cron.sh');
      if (fs.existsSync(cronScript)) {
        execFileSync('bash', [cronScript], { cwd: SCRIPT_DIR, encoding: 'utf8', timeout: 30000 });
      }
      execFileSync('bash', [path.join(SCRIPT_DIR, 'sync-supervisor-cron.sh'), '--quiet'], {
        cwd: SCRIPT_DIR, encoding: 'utf8', timeout: 30000,
      });
    } catch { /* best-effort cron reinstall */ }
  }

  return res.json({ ok: true, entry });
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
