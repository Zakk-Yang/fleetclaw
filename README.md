# FleetClaw

Multi-agent framework built on [OpenClaw](https://openclaw.ai). Deploys a supervisor + coding agents that iteratively build software with checkpoint-based coordination.

## How It Works

```
Supervisor (every 5 min)          Coding Agent (heartbeat every 2 min)
  |                                  |
  |-- reads STATUS.md ------------->  |-- reads SOUL.md, BRIEF.md
  |-- checks git diff               |-- works in focus_dirs/
  |-- sends CONTINUE/REDIRECT/STOP  |-- commits with [agent-id] prefix
  |                                  |-- updates STATUS.md at checkpoints
  |-- ACCEPT_DONE when satisfied     |-- requests supervisor decision when needed
```

Agents work directly in your project directory. No worktrees, no sync step. Files appear immediately.

## Quick Start

### 1. Add FleetClaw to your project

```bash
cp -r fleetclaw/ /path/to/your-project/fleetclaw/
cd /path/to/your-project/fleetclaw/
cp project-scope.example.yaml project-scope.yaml
```

### 2. Edit project-scope.yaml

Define your project, supervisor config, and coding agents with their tasks and focus directories.

### 3. Setup & Launch

```bash
./setup.sh    # Creates agent configs, OpenClaw profile, cron jobs
./launch.sh   # Starts gateway, enables heartbeat, seeds agent sessions
```

### 4. Monitor

- **OpenClaw UI**: http://localhost:{port}/ (port shown after launch)
- **FleetClaw Dashboard**: `cd dashboard && npm install && node server.js` → http://localhost:3333

## Architecture

```
your-project/
  fleetclaw/              # Framework (this repo)
    project-scope.yaml    # Your project config
    setup.sh              # Bootstrap everything
    launch.sh             # Start the fleet
    dashboard/            # Local monitoring UI
  .fleetclaw/             # Generated at setup (gitignored)
    agents/
      <agent-id>/         # Per-agent config files
        SOUL.md           # Agent personality & workflow
        BRIEF.md          # Task assignment
        STATUS.md         # Live checkpoint (agent updates this)
        PLAN.md           # Agent's implementation plan
        MEMORY.md         # Durable decisions & lessons
        memory/           # Daily logs
  src/                    # Your project code (agents work here)
```

## Agent Coordination

- **STATUS.md** is the checkpoint contract between agent and supervisor
- Agents update STATUS.md after each logical unit of work
- Supervisor reads STATUS.md + git diff to make decisions
- Decisions: `CONTINUE`, `REDIRECT`, `STOP`, `ACCEPT_DONE`, `ESCALATE`
- Heartbeat (2 min) keeps agents alive via the gateway — no timeout deaths
- Supervisor cron (configurable) runs periodic review cycles

## Scripts

| Script | Purpose |
|--------|---------|
| `setup.sh` | Parse scope, create agent dirs, generate OpenClaw config, cron jobs |
| `launch.sh` | Start gateway, install crons, enable heartbeat, seed sessions |
| `sync.sh` | Merge agent work back (legacy, not needed with direct workspace) |
| `teardown.sh` | Stop gateway, remove crons, clean up |

## Prerequisites

- [OpenClaw](https://openclaw.ai) CLI installed
- Node.js (for dashboard)
- Python 3 with PyYAML
- Git

## License

MIT
