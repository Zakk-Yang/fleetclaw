#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# FleetClaw — Launch Script
# Starts the gateway, installs cron jobs, and kicks off all
# agents for the project. Run this after setup.sh.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

# --- OS / platform detection ---
detect_platform() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        FLEETCLAW_PLATFORM="macos"
        FLEETCLAW_DASHBOARD_HOST="127.0.0.1"
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        FLEETCLAW_PLATFORM="wsl"
        FLEETCLAW_DASHBOARD_HOST="localhost"
    elif [[ "$(uname -s)" == "Linux" ]]; then
        FLEETCLAW_PLATFORM="linux"
        FLEETCLAW_DASHBOARD_HOST="127.0.0.1"
    elif [[ "$(uname -s)" =~ MINGW|MSYS|CYGWIN ]]; then
        FLEETCLAW_PLATFORM="windows"
        FLEETCLAW_DASHBOARD_HOST="127.0.0.1"
    else
        FLEETCLAW_PLATFORM="unknown"
        FLEETCLAW_DASHBOARD_HOST="127.0.0.1"
    fi
}

detect_platform

python_yaml_available() {
    python3 - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("yaml") else 1)
PY
}

# --- Fallback yq if not installed ---
if ! command -v yq &>/dev/null; then
    yq() {
        python3 - "$@" <<'PY'
import json
import re
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"PyYAML is required: {exc}")

args = sys.argv[1:]
if not args or args[0] != "eval":
    raise SystemExit("fallback yq only supports: yq eval <expr> <file>")

cursor = 1
if cursor < len(args) and args[cursor] == "-o=json":
    cursor += 1

if len(args) - cursor != 2:
    raise SystemExit("fallback yq expects: yq eval <expr> <file>")

expr = args[cursor]
path = args[cursor + 1]
with open(path, "r", encoding="utf-8") as handle:
    data = yaml.safe_load(handle) or {}

def lookup(node, token):
    if token == ".":
        return node
    if not token.startswith("."):
        raise KeyError(token)
    token = token[1:]
    if token == "":
        return node
    current = node
    for part in token.split("."):
        match = re.fullmatch(r"([^\[\]]+)(?:\[(\d+)\])?", part)
        if not match:
            raise KeyError(token)
        key = match.group(1)
        index = match.group(2)
        if not isinstance(current, dict) or key not in current:
            raise KeyError(token)
        current = current[key]
        if index is not None:
            idx = int(index)
            if not isinstance(current, list) or idx >= len(current):
                raise KeyError(token)
            current = current[idx]
    return current

parts = expr.split(" // ")
value = None
for part in parts:
    part = part.strip()
    if part.startswith('"') and part.endswith('"'):
        value = part[1:-1]
        break
    try:
        value = lookup(data, part)
        if value is not None:
            break
    except KeyError:
        continue

if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif isinstance(value, bool):
    print(str(value).lower())
elif value is None:
    print("null")
else:
    print(value)
PY
    }
fi

# --- Validate prerequisites ---
if [[ ! -f "$SCOPE_FILE" ]]; then
    err "project-scope.yaml not found. Run setup.sh first."
    exit 1
fi

if [[ ! -d "${SCRIPT_DIR}/generated" ]]; then
    err "generated/ directory not found. Run setup.sh first."
    exit 1
fi

for cmd in openclaw git python3; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Missing dependency: $cmd"
        exit 1
    fi
done

# --- Parse scope ---
yval() { yq eval "$1" "$SCOPE_FILE"; }
yval_default() { yq eval "$1 // \"$2\"" "$SCOPE_FILE"; }

PROJECT_NAME=$(yval '.project.name')
PROJECT_SLUG=$(slugify "${PROJECT_NAME}")
PROJECT_PROFILE_RAW=$(yval_default '.advanced.openclaw_profile' '')
if [[ -z "${PROJECT_PROFILE_RAW}" || "${PROJECT_PROFILE_RAW}" == "null" ]]; then
    PROJECT_PROFILE="${PROJECT_SLUG}"
else
    PROJECT_PROFILE="$(slugify "${PROJECT_PROFILE_RAW}")"
fi
if [[ -z "${PROJECT_PROFILE}" ]]; then
    PROJECT_PROFILE="${PROJECT_SLUG}"
fi

AGENT_COUNT=$(yq eval '.agents | length' "$SCOPE_FILE")
WORKTREE_BASE=$(yval_default '.advanced.worktree_base' "$HOME/.openclaw/projects/${PROJECT_NAME}")
if [[ -z "${WORKTREE_BASE}" || "${WORKTREE_BASE}" == "null" ]]; then
    WORKTREE_BASE="$HOME/.openclaw/projects/${PROJECT_NAME}"
fi

PROJECT_REPO=$(yval '.project.repo')
SUPERVISOR_THINKING=$(yval_default '.supervisor.thinking' '')

# --- Resolve project root (same logic as setup.sh) ---
expand_path() {
    local raw_path="$1"
    if [[ "${raw_path}" == "~" || "${raw_path}" == ~/* ]]; then
        printf '%s\n' "${raw_path/#\~/$HOME}"
    else
        printf '%s\n' "${raw_path}"
    fi
}

resolve_project_root() {
    local repo_source="$1"
    if [[ -z "${repo_source}" || "${repo_source}" == "null" || "${repo_source}" == "." ]]; then
        repo_source="${SCRIPT_DIR}"
    fi
    repo_source="$(expand_path "${repo_source}")"
    if [[ "${repo_source}" != /* ]]; then
        repo_source="${SCRIPT_DIR}/${repo_source}"
    fi
    if [[ "${repo_source}" == "${SCRIPT_DIR}" ]]; then
        local parent_dir
        parent_dir="$(dirname "${SCRIPT_DIR}")"
        if [[ -d "${parent_dir}" ]]; then
            printf '%s\n' "${parent_dir}"
            return 0
        fi
    fi
    if [[ -d "${repo_source}" ]]; then
        printf '%s\n' "${repo_source}"
        return 0
    fi
    return 1
}

PROJECT_ROOT="$(resolve_project_root "${PROJECT_REPO}")"

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

agent_runtime_id() {
    printf '%s-%s\n' "${PROJECT_SLUG}" "$1"
}

resolve_thinking_level() {
    local expr="$1"
    local default_value="${2:-}"
    yq eval "${expr} // \"${default_value}\"" "$SCOPE_FILE"
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
    git -C "${PROJECT_ROOT}" init -q
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

# --- Summary ---
echo "=========================================="
echo "  ✅ Fleet Launched"
echo "=========================================="
echo ""
DASHBOARD_HOST="${FLEETCLAW_DASHBOARD_HOST}"

# Try to extract token from gateway status
GATEWAY_TOKEN=$("${OPENCLAW_CMD[@]}" gateway status 2>&1 | sed -n 's/.*token=\([a-f0-9]*\).*/\1/p' | head -1 || true)
if [[ -n "${GATEWAY_TOKEN}" ]]; then
    DASHBOARD_URL="http://${DASHBOARD_HOST}:${GATEWAY_PORT}/#token=${GATEWAY_TOKEN}"
else
    DASHBOARD_URL="http://${DASHBOARD_HOST}:${GATEWAY_PORT}/"
fi

info "Dashboard: ${DASHBOARD_URL}"
echo ""
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
echo "  ${OPENCLAW_CMD[*]} agent --agent ${SUPERVISOR_RUNTIME_ID} --message \"Check progress now\""
echo ""
echo "  Watch supervisor:"
echo "  tail -f ${SUPERVISOR_WS}/memory/\$(date +%Y-%m-%d).md"
echo ""
