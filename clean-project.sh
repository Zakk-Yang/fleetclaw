#!/usr/bin/env bash
set -euo pipefail

# Usage: bash clean-project.sh <project-dir>
# Fully purges a FleetClaw project so it can be recreated from scratch.

PROJECT_DIR="${1:?Usage: clean-project.sh <project-dir>}"
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd || echo "$PROJECT_DIR")"

if [[ ! -d "$PROJECT_DIR/fleetclaw" ]]; then
    echo "Error: $PROJECT_DIR does not look like a FleetClaw project (no fleetclaw/ dir)"
    exit 1
fi

# 1. Read project name from scope
PROJECT_NAME=""
if [[ -f "$PROJECT_DIR/fleetclaw/project-scope.yaml" ]]; then
    PROJECT_NAME="$(python3 -c "
import yaml
with open('$PROJECT_DIR/fleetclaw/project-scope.yaml') as f:
    print(yaml.safe_load(f).get('project',{}).get('name',''))
" 2>/dev/null || true)"
fi

if [[ -z "$PROJECT_NAME" ]]; then
    echo "Error: Could not read project name from project-scope.yaml"
    exit 1
fi

PROFILE_DIR="$HOME/.openclaw-${PROJECT_NAME}"
WORKTREE_DIR="$HOME/.openclaw/projects/${PROJECT_NAME}"

echo "Cleaning project: $PROJECT_NAME"
echo "  Project dir:  $PROJECT_DIR"
echo "  Profile dir:  $PROFILE_DIR"
echo "  Worktree dir: $WORKTREE_DIR"
echo ""

# 2. Stop gateway service
echo "[1/6] Stopping gateway..."
systemctl --user stop "openclaw-gateway-${PROJECT_NAME}.service" 2>/dev/null || true
systemctl --user disable "openclaw-gateway-${PROJECT_NAME}.service" 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/openclaw-gateway-${PROJECT_NAME}.service" 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

# 3. Kill all related processes
echo "[2/6] Killing processes..."
pkill -f "$PROJECT_NAME" 2>/dev/null || true
# Kill by port if we can find it
if [[ -f "$PROJECT_DIR/.fleetclaw/runtime.env" ]]; then
    source "$PROJECT_DIR/.fleetclaw/runtime.env" 2>/dev/null || true
    for port_var in FLEETCLAW_GATEWAY_PORT; do
        port="${!port_var:-}"
        if [[ -n "$port" ]]; then
            lsof -ti:"$port" 2>/dev/null | xargs kill 2>/dev/null || true
            # Dashboard port = gateway + 1
            lsof -ti:"$((port + 1))" 2>/dev/null | xargs kill 2>/dev/null || true
        fi
    done
fi
sleep 1

# 4. Remove OpenClaw profile state
echo "[3/6] Removing profile state ($PROFILE_DIR)..."
rm -rf "$PROFILE_DIR"

# 5. Remove worktree state
echo "[4/6] Removing worktree state ($WORKTREE_DIR)..."
rm -rf "$WORKTREE_DIR"

# 6. Remove cron jobs
echo "[5/6] Removing cron jobs..."
openclaw --profile "$PROJECT_NAME" cron list --json 2>/dev/null | \
    python3 -c "
import json, sys, subprocess
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, list):
        jobs = data
    else:
        jobs = data if isinstance(data, list) else []
    for job in jobs:
        jid = job.get('id','')
        if jid:
            subprocess.run(['openclaw','--profile','$PROJECT_NAME','cron','delete',jid], capture_output=True)
            print(f'  Deleted cron: {jid}')
except:
    pass
" 2>/dev/null || true

# 7. Remove project directory
echo "[6/6] Removing project directory ($PROJECT_DIR)..."
rm -rf "$PROJECT_DIR"

# Verify
echo ""
if [[ -d "$PROJECT_DIR" ]] || [[ -d "$PROFILE_DIR" ]] || [[ -d "$WORKTREE_DIR" ]]; then
    echo "WARNING: Some directories still exist. Manual cleanup may be needed."
    [[ -d "$PROJECT_DIR" ]] && echo "  Still exists: $PROJECT_DIR"
    [[ -d "$PROFILE_DIR" ]] && echo "  Still exists: $PROFILE_DIR"
    [[ -d "$WORKTREE_DIR" ]] && echo "  Still exists: $WORKTREE_DIR"
else
    echo "Clean! Project '$PROJECT_NAME' fully purged."
fi
