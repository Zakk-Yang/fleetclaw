const express = require('express');
const path = require('path');
const fs = require('fs');
const yaml = require('js-yaml');
const { execSync } = require('child_process');

const app = express();
const SCRIPT_DIR = path.resolve(__dirname, '..');
const SCOPE_FILE = path.join(SCRIPT_DIR, 'project-scope.yaml');

// Resolve project root from scope (same logic as setup.sh)
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

// --- Auto-discover project details from project-scope.yaml ---

function loadScope() {
  if (!fs.existsSync(SCOPE_FILE)) return null;
  return yaml.load(fs.readFileSync(SCOPE_FILE, 'utf8'));
}

function slugify(str) {
  return str.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').replace(/-+/g, '-');
}

function resolveProfile(scope) {
  const raw = scope.advanced?.openclaw_profile || '';
  return raw ? slugify(raw) : slugify(scope.project.name);
}

function resolveGatewayConfig(profile) {
  try {
    const get = (key) => execSync(
      `openclaw --profile ${profile} config get ${key} 2>/dev/null`,
      { encoding: 'utf8', timeout: 5000 }
    ).trim();
    return {
      gateway: {
        port: parseInt(get('gateway.port'), 10) || null,
        auth: { token: get('gateway.auth.token') || null },
      }
    };
  } catch { return null; }
}

function readMdFile(filePath) {
  try { return fs.readFileSync(filePath, 'utf8'); } catch { return null; }
}

function getGitInfo(projectRoot) {
  try {
    const log = execSync('git log --oneline -10', { cwd: projectRoot, encoding: 'utf8', timeout: 5000 });
    const branch = execSync('git rev-parse --abbrev-ref HEAD', { cwd: projectRoot, encoding: 'utf8', timeout: 5000 }).trim();

    // Get changed files with stat and per-file timestamps
    const diffNames = execSync('git diff --name-only', { cwd: projectRoot, encoding: 'utf8', timeout: 5000 }).trim();
    const untrackedRaw = execSync('git ls-files --others --exclude-standard', { cwd: projectRoot, encoding: 'utf8', timeout: 5000 }).trim();
    const diffStat = execSync('git diff --stat', { cwd: projectRoot, encoding: 'utf8', timeout: 5000 }).trim();

    const changedFiles = [];
    const allFiles = [...(diffNames ? diffNames.split('\n') : []), ...(untrackedRaw ? untrackedRaw.split('\n') : [])];
    const seen = new Set();
    for (const f of allFiles) {
      if (!f || seen.has(f)) continue;
      seen.add(f);
      const fullPath = path.join(projectRoot, f);
      let mtime = null;
      try { mtime = fs.statSync(fullPath).mtime.toISOString(); } catch {}
      const isUntracked = untrackedRaw.split('\n').includes(f);
      changedFiles.push({ file: f, mtime, untracked: isUntracked });
    }

    // Extract summary line from diff stat (e.g. "23 files changed, 38 deletions(-)")
    const statLines = diffStat.split('\n');
    const summaryLine = statLines.length > 0 ? statLines[statLines.length - 1] : '';

    return { branch, log: log.trim(), changedFiles, diffSummary: summaryLine, timestamp: new Date().toISOString() };
  } catch { return { branch: 'unknown', log: '', changedFiles: [], diffSummary: '', timestamp: new Date().toISOString() }; }
}

// --- API Routes ---

app.use(express.static(path.join(__dirname, 'public'), {
  etag: false,
  lastModified: false,
  setHeaders: (res) => { res.setHeader('Cache-Control', 'no-store'); }
}));

app.get('/api/project', (req, res) => {
  const scope = loadScope();
  if (!scope) return res.status(404).json({ error: 'project-scope.yaml not found' });

  const profile = resolveProfile(scope);
  const projectRoot = resolveProjectRoot(scope);
  const gatewayConfig = resolveGatewayConfig(profile);
  const git = getGitInfo(projectRoot);

  const port = gatewayConfig?.gateway?.port || scope.advanced?.gateway_port || null;
  const token = gatewayConfig?.gateway?.auth?.token || null;

  res.json({
    name: scope.project.name,
    description: scope.project.description,
    branch: scope.project.branch || 'main',
    profile,
    gateway: {
      port,
      token,
      url: port ? `http://localhost:${port}/` : null,
      dashboardUrl: port && token ? `http://localhost:${port}/#token=${token}` : null,
    },
    supervisor: {
      model: scope.supervisor?.model || 'unknown',
      checkInterval: scope.supervisor?.check_interval_mins || 10,
      thinking: scope.supervisor?.thinking || '',
    },
    git,
  });
});

app.get('/api/agents', (req, res) => {
  const scope = loadScope();
  if (!scope) return res.status(404).json({ error: 'project-scope.yaml not found' });

  const profile = resolveProfile(scope);
  const projectRoot = resolveProjectRoot(scope);
  const worktreeBase = resolveWorktreeBase(scope);
  const gatewayConfig = resolveGatewayConfig(profile);
  const port = gatewayConfig?.gateway?.port || null;
  const projectSlug = slugify(scope.project.name);
  const fleetclawDir = path.join(projectRoot, '.fleetclaw', 'agents');

  const agents = (scope.agents || []).map(agent => {
    const agentDir = path.join(fleetclawDir, agent.id);
    const runtimeId = `${projectSlug}-${agent.id}`;

    const status = readMdFile(path.join(agentDir, 'STATUS.md'));
    const brief = readMdFile(path.join(agentDir, 'BRIEF.md'));
    const plan = readMdFile(path.join(agentDir, 'PLAN.md'));
    const memory = readMdFile(path.join(agentDir, 'MEMORY.md'));
    const soul = readMdFile(path.join(agentDir, 'SOUL.md'));

    // Parse STATUS.md fields
    const statusFields = {};
    if (status) {
      for (const line of status.split('\n')) {
        const match = line.match(/^([A-Za-z ]+):\s*(.+)$/);
        if (match) statusFields[match[1].trim().toLowerCase()] = match[2].trim();
      }
    }

    return {
      id: agent.id,
      runtimeId,
      model: agent.model || scope.advanced?.default_agent_model || 'unknown',
      thinking: agent.thinking || scope.advanced?.default_agent_thinking || '',
      focusDirs: agent.focus_dirs || [],
      task: agent.task || '',
      sessionUrl: port ? `http://localhost:${port}/chat?session=agent:${runtimeId}:main` : null,
      statusFields,
      files: {
        status,
        brief,
        plan,
        memory,
        soul,
      },
    };
  });

  // Also gather supervisor info
  const supervisorWs = path.join(worktreeBase, 'supervisor-workspace');
  const supervisorRuntimeId = `${projectSlug}-supervisor`;
  const supervisorStatus = readMdFile(path.join(supervisorWs, 'STATUS.md'));
  const supervisorRoster = readMdFile(path.join(supervisorWs, 'ROSTER.md'));
  const supervisorMemoryDir = path.join(supervisorWs, 'memory');
  let supervisorLatestMemory = null;
  if (fs.existsSync(supervisorMemoryDir)) {
    const files = fs.readdirSync(supervisorMemoryDir).filter(f => f.endsWith('.md')).sort().reverse();
    if (files.length > 0) {
      supervisorLatestMemory = readMdFile(path.join(supervisorMemoryDir, files[0]));
    }
  }

  res.json({
    agents,
    supervisor: {
      runtimeId: supervisorRuntimeId,
      sessionUrl: port ? `http://localhost:${port}/chat?session=agent:${supervisorRuntimeId}:main` : null,
      status: supervisorStatus,
      roster: supervisorRoster,
      latestMemory: supervisorLatestMemory,
    },
  });
});

app.get('/api/agent/:id/file/:filename', (req, res) => {
  const scope = loadScope();
  if (!scope) return res.status(404).json({ error: 'project-scope.yaml not found' });

  const { id, filename } = req.params;
  const allowed = ['STATUS.md', 'BRIEF.md', 'PLAN.md', 'MEMORY.md', 'SOUL.md', 'PROJECT.md', 'BLOCKERS.md'];
  if (!allowed.includes(filename)) return res.status(400).json({ error: 'File not allowed' });

  const projectRoot = resolveProjectRoot(scope);
  const filePath = path.join(projectRoot, '.fleetclaw', 'agents', id, filename);
  const content = readMdFile(filePath);
  if (content === null) return res.status(404).json({ error: 'File not found' });
  res.type('text/plain').send(content);
});

app.get('/api/files', (req, res) => {
  const scope = loadScope();
  const projectRoot = scope ? resolveProjectRoot(scope) : path.resolve(SCRIPT_DIR, '..');
  try {
    const output = execSync('find . -maxdepth 3 -not -path "*/node_modules/*" -not -path "*/.git/*" -not -name ".*" -type f | sort', {
      cwd: projectRoot, encoding: 'utf8', timeout: 5000
    });
    res.json({ files: output.trim().split('\n').filter(Boolean) });
  } catch { res.json({ files: [] }); }
});

const PORT = parseInt(process.env.PORT || '3333', 10);
const HOST = process.env.HOST || '127.0.0.1';
app.listen(PORT, HOST, () => {
  const scope = loadScope();
  const projectRoot = scope ? resolveProjectRoot(scope) : 'unknown';
  console.log(`FleetClaw Dashboard running at http://localhost:${PORT}`);
  console.log(`Project root: ${projectRoot}`);
  console.log(`Scope file: ${SCOPE_FILE}`);
});
