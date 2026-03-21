# FleetClaw

Multi-agent framework built on [OpenClaw](https://openclaw.ai). Deploys a supervisor + coding agents that iteratively build software with checkpoint-based coordination.

## How It Works

FleetClaw runs one supervisor and one or more coding agents against the same project workspace.

```mermaid
sequenceDiagram
    autonumber
    participant S as Supervisor
    participant W as Shared Project Workspace
    participant A as Coding Agent
    participant F as .fleetclaw/agents/<id>

    Note over A,F: Agent loop
    A->>F: Read SOUL.md, BRIEF.md, STATUS.md
    A->>W: Edit files in focus_dirs
    A->>W: Commit progress when appropriate
    A->>F: Update STATUS.md checkpoint
    A-->>S: Request decision when blocked, done, or review-ready

    Note over S,F: Supervisor loop
    S->>F: Read STATUS.md
    S->>W: Review shared git diff and recent changes
    S-->>A: CONTINUE / REDIRECT / STOP / ACCEPT_DONE / ESCALATE
```

**Key points**

- Agents edit the real project files directly in the shared project root
- There are no per-agent git worktrees and no merge-back step
- Each agent keeps its instructions and checkpoint files in `.fleetclaw/agents/<id>/`
- The supervisor wakes on a schedule, reviews checkpoints plus git state, and sends the next decision

Heartbeat keeps agent sessions alive between checks, and supervisor cron jobs trigger regular review cycles.
FleetClaw also runs a small status reconciler that can normalize stale `STATUS.md` files after a recorded supervisor acceptance.

## Quick Start

### 1. Add FleetClaw to your project

```bash
cp -r fleetclaw/ /path/to/your-project/fleetclaw/
cd /path/to/your-project/fleetclaw/
cp project-scope.example.yaml project-scope.yaml
```

### 2. Edit project-scope.yaml

Define your project, supervisor config, and coding agents with their tasks and focus directories.
Keep settings in `project-scope.yaml`, and move long prose into normal files with `*_file` keys when you do not want to paste it inline.

```yaml
project:
  name: "my-project"
  repo: "."
  description_file: "prompts/project.md"
  review_url: "http://127.0.0.1:4173/"
  review_command: "cd apps/web && npm run dev:collector -- --host 127.0.0.1 --port 4173"
  design_review_command: "cd apps/web && npm run dev -- --host 127.0.0.1 --port 4174"

supervisor:
  objective_file: "prompts/supervisor-objective.md"
  handoff_rules_file: "prompts/handoff-rules.md"
  status_reconcile_interval_secs: 30

agents:
  - id: "frontend"
    task_file: "tasks/frontend.md"
    focus_dirs: ["apps/web/"]
```

Relative `*_file` paths resolve from the `fleetclaw/` directory.

### 3. Setup & Launch

```bash
./setup.sh    # Creates agent configs, OpenClaw profile, cron jobs
./launch.sh   # Starts gateway, dashboard, cron-driven supervision, and agent sessions
./teardown.sh # Stops dashboard/reconciler and removes cron jobs
```

For a full runtime-state wipe without deleting your project files:

```bash
./teardown.sh --yes --purge-state
```

### 4. Monitor

- **OpenClaw UI**: http://localhost:{port}/ (port shown after launch)
- **FleetClaw Dashboard**: starts automatically during `launch.sh` and opens in your browser at the resolved project dashboard URL
- The dashboard now shows both estimated Markdown read-set percentages and live session context usage percentages
- The dashboard also shows compact control-plane traffic so you can inspect recent agent notifications and supervisor decisions
- The dashboard also includes a human feedback form that routes review notes into the supervisor loop by default and keeps a recent submission trail
- FleetClaw also starts a background status reconciler that watches recorded supervisor decisions and forces stale accepted checkpoints to `State: done`
- FleetClaw writes `.fleetclaw/PROJECT_STATUS.md` with an overall fleet summary and automatically idles the supervisor progress cron when every coding lane is done

## Authoring Model

FleetClaw now treats `project-scope.yaml` as the configuration source of truth.

- Keep project settings, models, cadence, and lane ownership in `project-scope.yaml`
- Keep notification and message-budget policy in the `protocol:` section of `project-scope.yaml`
- Declare the primary review surface with `project.review_url` / `project.review_command` when the accepted state depends on a specific runtime path
- Reference long-form prose with `project.description_file`, `supervisor.objective_file`, `supervisor.handoff_rules_file`, and `agents[].task_file`
- Override the built-in document templates with `advanced.template_dir` only if you need custom generated `SOUL.md` / `BRIEF.md` shapes
- Treat `.fleetclaw/agents/...` as generated runtime state, not setup-time authoring files

This means public users only need to maintain one config file plus any optional imported Markdown/text files they choose to reference.

If your project has both a mock/design mode and a live/integrated review mode, declare both in `project-scope.yaml`. FleetClaw will render the primary review surface into `PROJECT.md` and the supervisor prompt so acceptance decisions can target the right runtime.

## Architecture

```
your-project/
  fleetclaw/              # Framework (this repo)
    project-scope.yaml    # Your project config
    templates/            # Default templates for generated docs
    setup.sh              # Bootstrap everything
    launch.sh             # Start the fleet
    dashboard/            # Local monitoring UI
  .fleetclaw/             # Generated at setup (gitignored)
    PROJECT_STATUS.md     # Overall fleet summary + review guidance
    bin/                  # Compact notification helpers
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
- Agents notify the supervisor with compact `EVENT_ID`-backed messages via `.fleetclaw/bin/notify-supervisor.sh`
- Supervisor reads STATUS.md + git diff to make decisions
- Supervisor replies with compact decisions via `.fleetclaw/bin/send-supervisor-decision.sh`
- Decisions: `CONTINUE`, `REDIRECT`, `STOP`, `ACCEPT_DONE`, `ESCALATE`
- Polling remains the fallback while notification delivery is being proven
- If the agent misses an `ACCEPT_DONE` update, FleetClaw reconciles the checkpoint from recorded session history instead of waiting forever
- If an external blocker is later resolved, the supervisor should send a clearing decision so the lane can leave `blocked` and settle on `done` or the next active state
- There is no default coding-agent heartbeat; supervisor cron (configurable) is the periodic review loop
- When every coding lane reaches `done`, FleetClaw disables the supervisor progress cron until work is reopened

## Scripts

| Script | Purpose |
|--------|---------|
| `check-markdown-budget.sh` | Estimate the Markdown read-set load for supervisor/agents as a % of the context window |
| `check-context.sh` | Show live session token usage and context pressure from OpenClaw |
| `project-status.sh` | Write `.fleetclaw/PROJECT_STATUS.md` with overall fleet state, review surface, and next action |
| `reconcile-status.sh` | Reconcile stale agent checkpoints from recorded supervisor decisions |
| `reconcile-loop.sh` | Background loop that runs `reconcile-status.sh` automatically after launch |
| `review-runtime-settings.sh` | Inspect heartbeat, compaction, retention, and cron settings for the dedicated profile |
| `setup.sh` | Parse scope, create agent dirs, generate OpenClaw config, cron jobs |
| `sync-supervisor-cron.sh` | Disable the supervisor progress cron when all lanes are done, and re-enable it if work reopens |
| `launch.sh` | Start gateway, dashboard, install crons, and seed sessions |
| `status-report.sh` | Print agent checkpoints, supervisor notes, markdown budget, and live context usage |
| `sync.sh` | Summarize shared-repo state; no merge step is needed in direct-workspace mode |
| `teardown.sh` | Stop dashboard, remove crons, and clean generated files |

## Prerequisites

- [OpenClaw](https://openclaw.ai) CLI installed
- Node.js (for dashboard)
- Python 3 with PyYAML
- Git

## License

MIT
