#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# FleetClaw — Launch Script
# Starts the gateway, installs cron jobs, and kicks off all
# agents for the project. Run this after setup.sh.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

enable_yq_fallback
detect_platform

# --- Validate prerequisites ---
if [[ ! -f "$SCOPE_FILE" ]]; then
    err "project-scope.yaml not found. Run setup.sh first."
    exit 1
fi

if [[ ! -d "${SCRIPT_DIR}/generated" ]]; then
    err "generated/ directory not found. Run setup.sh first."
    exit 1
fi

require_cmds openclaw git python3

# --- Parse scope ---
yval() { yq eval "$1" "$SCOPE_FILE"; }
yval_default() { yq eval "$1 // \"$2\"" "$SCOPE_FILE"; }

PROJECT_NAME=$(yval '.project.name')
PROJECT_SLUG=$(slugify "${PROJECT_NAME}")
PROJECT_PROFILE="$(resolve_openclaw_profile_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
PROJECT_BRANCH=$(yval_default '.project.branch' 'main')

AGENT_COUNT=$(yq eval '.agents | length' "$SCOPE_FILE")
WORKTREE_BASE="$(resolve_worktree_base_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"

PROJECT_REPO=$(yval '.project.repo')
SUPERVISOR_THINKING=$(yval_default '.supervisor.thinking' '')
AUTO_OPEN_DASHBOARD="$(yval_default '.advanced.auto_open_dashboard' 'true')"
PROJECT_ROOT="$(resolve_project_root_path "${PROJECT_REPO}" "${SCRIPT_DIR}")"

# Derive gateway port (same logic as setup.sh)
CONFIGURED_PORT=$(yval_default '.advanced.gateway_port' '')
if [[ -n "${CONFIGURED_PORT}" && "${CONFIGURED_PORT}" != "null" ]]; then
    GATEWAY_PORT="${CONFIGURED_PORT}"
else
    SLOT=$(python3 - "${PROJECT_PROFILE}" <<'PY'
import hashlib, sys
digest = hashlib.sha1(sys.argv[1].encode()).hexdigest()
print(int(digest[:8], 16) % 400)
PY
)
    GATEWAY_PORT=$((19001 + SLOT * 20))
fi

OPENCLAW_CMD=(openclaw --profile "${PROJECT_PROFILE}")
SUPERVISOR_WS="${WORKTREE_BASE}/supervisor-workspace"
DASHBOARD_PORT="$(resolve_dashboard_port_from_scope "${SCOPE_FILE}" "${PROJECT_PROFILE}" "${GATEWAY_PORT}")"
DASHBOARD_DIR="${SCRIPT_DIR}/dashboard"
DASHBOARD_PID_FILE="${SCRIPT_DIR}/generated/dashboard.pid"
DASHBOARD_LOG_FILE="${SCRIPT_DIR}/generated/dashboard.log"
DASHBOARD_INSTALL_LOG_FILE="${SCRIPT_DIR}/generated/dashboard-install.log"
RECONCILE_INTERVAL_SECS="$(yval_default '.supervisor.status_reconcile_interval_secs' '30')"
RECONCILE_PID_FILE="${SCRIPT_DIR}/generated/reconcile.pid"
RECONCILE_LOG_FILE="${SCRIPT_DIR}/generated/reconcile.log"
DASHBOARD_URL="http://${FLEETCLAW_DASHBOARD_HOST}:${DASHBOARD_PORT}/"

agent_runtime_id() {
    printf '%s-%s\n' "${PROJECT_SLUG}" "$1"
}

resolve_thinking_level() {
    local expr="$1"
    local default_value="${2:-}"
    yq eval "${expr} // \"${default_value}\"" "$SCOPE_FILE"
}

dashboard_port_available() {
    python3 - "${FLEETCLAW_DASHBOARD_HOST}" "${DASHBOARD_PORT}" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind((host, port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

stop_dashboard_if_running() {
    if [[ ! -f "${DASHBOARD_PID_FILE}" ]]; then
        return 0
    fi

    local pid
    pid="$(cat "${DASHBOARD_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
        kill "${pid}" >/dev/null 2>&1 || true
        sleep 1
    fi
    rm -f "${DASHBOARD_PID_FILE}"
}

stop_reconciler_if_running() {
    if [[ ! -f "${RECONCILE_PID_FILE}" ]]; then
        return 0
    fi

    local pid
    pid="$(cat "${RECONCILE_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
        kill "${pid}" >/dev/null 2>&1 || true
        sleep 1
    fi
    rm -f "${RECONCILE_PID_FILE}"
}

ensure_dashboard_dependencies() {
    if [[ ! -d "${DASHBOARD_DIR}" ]]; then
        warn "Dashboard directory not found at ${DASHBOARD_DIR}"
        return 1
    fi

    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        warn "Node.js/npm not available — skipping automatic dashboard startup"
        return 1
    fi

    if [[ -d "${DASHBOARD_DIR}/node_modules" ]]; then
        return 0
    fi

    info "Installing dashboard dependencies..."
    if (cd "${DASHBOARD_DIR}" && npm ci --no-audit --no-fund >"${DASHBOARD_INSTALL_LOG_FILE}" 2>&1); then
        log "Dashboard dependencies installed"
        return 0
    fi

    warn "Dashboard dependency install failed — see ${DASHBOARD_INSTALL_LOG_FILE}"
    return 1
}

start_dashboard() {
    if ! ensure_dashboard_dependencies; then
        return 1
    fi

    stop_dashboard_if_running

    if ! dashboard_port_available; then
        if wait_for_http_url "${DASHBOARD_URL}" 4; then
            log "Dashboard already available at ${DASHBOARD_URL}"
            return 0
        fi

        warn "Dashboard port ${DASHBOARD_PORT} is already in use — skipping automatic startup"
        return 1
    fi

    python3 - "${DASHBOARD_DIR}" "${DASHBOARD_PORT}" "${FLEETCLAW_DASHBOARD_HOST}" "${DASHBOARD_LOG_FILE}" "${DASHBOARD_PID_FILE}" <<'PY'
import os
import subprocess
import sys

cwd, port, host, log_path, pid_path = sys.argv[1:]
env = dict(os.environ)
env["PORT"] = port
env["HOST"] = host

with open(log_path, "ab", buffering=0) as log_handle:
    proc = subprocess.Popen(
        ["node", "server.js"],
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=log_handle,
        stderr=log_handle,
        start_new_session=True,
        close_fds=True,
    )

with open(pid_path, "w", encoding="utf-8") as pid_handle:
    pid_handle.write(str(proc.pid))
PY

    local pid
    pid="$(cat "${DASHBOARD_PID_FILE}" 2>/dev/null || true)"
    if command -v lsof >/dev/null 2>&1; then
        local listening_pid
        listening_pid="$(lsof -ti "tcp:${DASHBOARD_PORT}" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
        if [[ -n "${listening_pid}" ]]; then
            pid="${listening_pid}"
            printf '%s\n' "${pid}" >"${DASHBOARD_PID_FILE}"
        fi
    fi
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1 && wait_for_http_url "${DASHBOARD_URL}" 10; then
        log "Dashboard started on ${DASHBOARD_URL}"
        return 0
    fi

    warn "Dashboard process exited early — see ${DASHBOARD_LOG_FILE}"
    rm -f "${DASHBOARD_PID_FILE}"
    return 1
}

start_reconciler() {
    if ! [[ "${RECONCILE_INTERVAL_SECS}" =~ ^[0-9]+$ ]] || [[ "${RECONCILE_INTERVAL_SECS}" -lt 1 ]]; then
        warn "Invalid supervisor.status_reconcile_interval_secs=${RECONCILE_INTERVAL_SECS}; skipping reconciler"
        return 1
    fi

    stop_reconciler_if_running

    nohup bash "${SCRIPT_DIR}/reconcile-loop.sh" "${RECONCILE_INTERVAL_SECS}" >"${RECONCILE_LOG_FILE}" 2>&1 &
    local pid=$!
    echo "${pid}" > "${RECONCILE_PID_FILE}"

    if kill -0 "${pid}" >/dev/null 2>&1; then
        log "Status reconciler started (${RECONCILE_INTERVAL_SECS}s cadence)"
        return 0
    fi

    warn "Status reconciler failed to stay running"
    rm -f "${RECONCILE_PID_FILE}"
    return 1
}

echo ""
echo "=========================================="
echo "  🚀 FleetClaw — Launch"
echo "=========================================="
echo ""
info "Project: ${PROJECT_NAME}"
info "Profile: ${PROJECT_PROFILE}"
info "Gateway port: ${GATEWAY_PORT}"
info "Agents: ${AGENT_COUNT}"
echo ""

# --- Step 1: Install and start gateway ---
echo "--- Step 1: Gateway ---"
"${OPENCLAW_CMD[@]}" gateway install --port "${GATEWAY_PORT}" 2>&1 | tail -1 || true
log "Gateway service installed"

"${OPENCLAW_CMD[@]}" gateway restart 2>&1 | tail -1 || true
log "Gateway started on port ${GATEWAY_PORT}"

# Wait briefly for gateway to come up
sleep 2

# Verify gateway is running
if "${OPENCLAW_CMD[@]}" gateway status 2>&1 | grep -q "Runtime: running"; then
    log "Gateway is running"
else
    warn "Gateway may not be fully started yet — check with: ${OPENCLAW_CMD[*]} gateway status"
fi
echo ""

# --- Step 2: Install cron jobs ---
echo "--- Step 2: Cron Jobs ---"
CRON_SCRIPT="${SCRIPT_DIR}/generated/openclaw-cron.sh"
if [[ -f "${CRON_SCRIPT}" ]]; then
    bash "${CRON_SCRIPT}" 2>&1
    log "Cron jobs installed"
else
    warn "No cron script found at ${CRON_SCRIPT}, skipping"
fi
echo ""

# --- Step 3: Ensure project root is a git repo ---
echo "--- Step 3: Git Bootstrap ---"
info "Project root: ${PROJECT_ROOT}"
if ! git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
    git -C "${PROJECT_ROOT}" init -q -b "${PROJECT_BRANCH}"
    git -C "${PROJECT_ROOT}" add -A 2>/dev/null || true
    git -C "${PROJECT_ROOT}" commit -q -m "FleetClaw: initialize project repo" 2>/dev/null || true
    log "Initialized git in project root"
else
    log "Git already initialized in project root"
fi
echo ""

# --- Step 4: Enable heartbeat ---
echo "--- Step 4: Heartbeat ---"
"${OPENCLAW_CMD[@]}" system heartbeat enable 2>&1 | tail -1 || true
log "Heartbeat enabled (gateway keeps all agents alive)"
echo ""

# --- Step 5: Seed agent sessions ---
# Send an initial message to each agent to create their session.
# The gateway heartbeat will keep them working continuously after this.
echo "--- Step 5: Seed Agent Sessions ---"
for i in $(seq 0 $((AGENT_COUNT - 1))); do
    AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
    AGENT_THINKING=$(resolve_thinking_level ".agents[$i].thinking // .advanced.default_agent_thinking" '')
    RUNTIME_ID="$(agent_runtime_id "${AGENT_ID}")"

    SEED_ARGS=("${OPENCLAW_CMD[@]}" agent --agent "${RUNTIME_ID}")
    if [[ -n "${AGENT_THINKING}" && "${AGENT_THINKING}" != "null" ]]; then
        SEED_ARGS+=(--thinking "${AGENT_THINKING}")
    fi
    SEED_ARGS+=(--message "Start working on your task. Read .fleetclaw/agents/${AGENT_ID}/SOUL.md, .fleetclaw/agents/${AGENT_ID}/BRIEF.md, and .fleetclaw/agents/${AGENT_ID}/STATUS.md first. Work directly in your focus directories.")

    info "Seeding session for ${AGENT_ID}..."
    nohup "${SEED_ARGS[@]}" >/dev/null 2>&1 &
    log "Agent ${AGENT_ID} seeded (heartbeat will keep it alive)"
done

# Seed supervisor
SUPERVISOR_RUNTIME_ID="$(agent_runtime_id "supervisor")"
SUPERVISOR_SEED_ARGS=("${OPENCLAW_CMD[@]}" agent --agent "${SUPERVISOR_RUNTIME_ID}")
if [[ -n "${SUPERVISOR_THINKING}" && "${SUPERVISOR_THINKING}" != "null" ]]; then
    SUPERVISOR_SEED_ARGS+=(--thinking "${SUPERVISOR_THINKING}")
fi
SUPERVISOR_SEED_ARGS+=(--message "Start your supervisor loop. Read SOUL.md and ROSTER.md first. Check all coding agents.")

info "Seeding supervisor session..."
nohup "${SUPERVISOR_SEED_ARGS[@]}" >/dev/null 2>&1 &
log "Supervisor seeded (heartbeat + cron will keep it active)"
echo ""

# --- Step 6: Start status reconciler ---
echo "--- Step 6: Status Reconciler ---"
RECONCILER_STARTED=0
if start_reconciler; then
    RECONCILER_STARTED=1
fi
echo ""

# --- Step 7: Start dashboard ---
echo "--- Step 7: Dashboard ---"
DASHBOARD_STARTED=0
if start_dashboard; then
    DASHBOARD_STARTED=1
fi
echo ""

# --- Summary ---
echo "=========================================="
echo "  ✅ Fleet Launched"
echo "=========================================="
echo ""
DASHBOARD_HOST="${FLEETCLAW_DASHBOARD_HOST}"

# Try to extract token from gateway status
GATEWAY_TOKEN=$("${OPENCLAW_CMD[@]}" gateway status 2>&1 | sed -n 's/.*token=\([a-f0-9]*\).*/\1/p' | head -1 || true)
if [[ -n "${GATEWAY_TOKEN}" ]]; then
    OPENCLAW_UI_URL="http://${DASHBOARD_HOST}:${GATEWAY_PORT}/#token=${GATEWAY_TOKEN}"
else
    OPENCLAW_UI_URL="http://${DASHBOARD_HOST}:${GATEWAY_PORT}/"
fi
if [[ "${DASHBOARD_STARTED}" -eq 1 ]]; then
    info "FleetClaw dashboard: ${DASHBOARD_URL}"
else
    warn "FleetClaw dashboard was not started automatically"
fi
if [[ "${RECONCILER_STARTED}" -ne 1 ]]; then
    warn "Status reconciler was not started automatically"
fi
info "OpenClaw UI: ${OPENCLAW_UI_URL}"
echo ""

if [[ "${DASHBOARD_STARTED}" -eq 1 ]] && is_truthy "${AUTO_OPEN_DASHBOARD}"; then
    if open_url_in_browser "${DASHBOARD_URL}"; then
        log "Opened FleetClaw dashboard in your browser"
    else
        warn "Could not auto-open the dashboard browser tab"
    fi
fi

echo "Agent sessions:"
for i in $(seq 0 $((AGENT_COUNT - 1))); do
    AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
    RUNTIME_ID="$(agent_runtime_id "${AGENT_ID}")"
    echo "  ${AGENT_ID}: http://${DASHBOARD_HOST}:${GATEWAY_PORT}/chat?session=agent:${RUNTIME_ID}:main"
done
echo "  supervisor: http://${DASHBOARD_HOST}:${GATEWAY_PORT}/chat?session=agent:${SUPERVISOR_RUNTIME_ID}:main"
echo ""
echo "Useful commands:"
echo "  ${OPENCLAW_CMD[*]} gateway status      # Check gateway health"
echo "  ${OPENCLAW_CMD[*]} agents list          # List registered agents"
echo "  ${OPENCLAW_CMD[*]} cron list            # List cron jobs"
echo "  tail -f ${DASHBOARD_LOG_FILE}           # Watch dashboard log"
echo "  tail -f ${RECONCILE_LOG_FILE}           # Watch status reconciler log"
echo "  ${OPENCLAW_CMD[*]} agent --agent ${SUPERVISOR_RUNTIME_ID} --message \"Check progress now\""
echo ""
echo "  Watch supervisor:"
echo "  tail -f ${SUPERVISOR_WS}/memory/\$(date +%Y-%m-%d).md"
echo ""
