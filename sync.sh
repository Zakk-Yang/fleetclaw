#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# FleetClaw — Sync Script
# Merges completed agent work from worktrees back into the
# project's main branch so results appear in the project root.
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

python_yaml_available() {
    python3 - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("yaml") else 1)
PY
}

# --- Fallback yq ---
if ! command -v yq &>/dev/null; then
    yq() {
        python3 - "$@" <<'PY'
import json, re, sys, yaml
args = sys.argv[1:]
if not args or args[0] != "eval": raise SystemExit("fallback yq: yq eval <expr> <file>")
expr, path = args[1], args[2]
with open(path) as f: data = yaml.safe_load(f) or {}
parts = expr.split(" // ")
for p in parts:
    p = p.strip()
    if p.startswith('"') and p.endswith('"'): print(p[1:-1]); sys.exit()
    try:
        cur = data
        for k in p.lstrip('.').split('.'):
            m = re.fullmatch(r'([^\[\]]+)(?:\[(\d+)\])?', k)
            cur = cur[m.group(1)]
            if m.group(2) is not None: cur = cur[int(m.group(2))]
        if cur is not None: print(cur if not isinstance(cur,(dict,list)) else json.dumps(cur)); sys.exit()
    except (KeyError, TypeError, IndexError): continue
print("null")
PY
    }
fi

# --- Validate ---
if [[ ! -f "$SCOPE_FILE" ]]; then
    err "project-scope.yaml not found."
    exit 1
fi

yval() { yq eval "$1" "$SCOPE_FILE"; }
yval_default() { yq eval "$1 // \"$2\"" "$SCOPE_FILE"; }

PROJECT_NAME=$(yval '.project.name')
PROJECT_BRANCH=$(yval_default '.project.branch' 'main')
PROJECT_SLUG=$(slugify "${PROJECT_NAME}")
AGENT_COUNT=$(yq eval '.agents | length' "$SCOPE_FILE")
WORKTREE_BASE=$(yval_default '.advanced.worktree_base' "$HOME/.openclaw/projects/${PROJECT_NAME}")
if [[ -z "${WORKTREE_BASE}" || "${WORKTREE_BASE}" == "null" ]]; then
    WORKTREE_BASE="$HOME/.openclaw/projects/${PROJECT_NAME}"
fi

# Find the project repo root
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
if ! git -C "${PROJECT_ROOT}" rev-parse --show-toplevel >/dev/null 2>&1; then
    # Try the fleetclaw dir itself
    if git -C "${SCRIPT_DIR}" rev-parse --show-toplevel >/dev/null 2>&1; then
        PROJECT_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
    else
        err "Cannot find project git repo."
        exit 1
    fi
fi

echo ""
echo "=========================================="
echo "  🔄 FleetClaw — Sync"
echo "=========================================="
echo ""
info "Project: ${PROJECT_NAME}"
info "Project root: ${PROJECT_ROOT}"
info "Target branch: ${PROJECT_BRANCH}"
echo ""

SYNCED=0

for i in $(seq 0 $((AGENT_COUNT - 1))); do
    AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
    WORKTREE_PATH="${WORKTREE_BASE}/${AGENT_ID}"
    BRANCH_NAME="fleetclaw-${PROJECT_SLUG}-${AGENT_ID}"

    if [[ ! -d "${WORKTREE_PATH}" ]]; then
        warn "Worktree not found for ${AGENT_ID}, skipping"
        continue
    fi

    # Check if agent has commits ahead of the base branch
    AHEAD=$(git -C "${WORKTREE_PATH}" rev-list "${PROJECT_BRANCH}..HEAD" --count 2>/dev/null || echo "0")

    if [[ "${AHEAD}" == "0" ]]; then
        info "${AGENT_ID}: no new commits to sync"
        continue
    fi

    # Check STATUS.md for agent state
    AGENT_STATE="unknown"
    if [[ -f "${WORKTREE_PATH}/STATUS.md" ]]; then
        AGENT_STATE=$(grep -oP 'State: \K.*' "${WORKTREE_PATH}/STATUS.md" 2>/dev/null || echo "unknown")
    fi

    info "${AGENT_ID}: ${AHEAD} commits ahead (state: ${AGENT_STATE})"

    # Only auto-merge if done or ready-for-review
    if [[ "${AGENT_STATE}" != "done" && "${AGENT_STATE}" != "ready-for-review" ]]; then
        warn "${AGENT_ID}: state is '${AGENT_STATE}', skipping auto-merge (use --force to override)"
        if [[ "${1:-}" == "--force" ]]; then
            info "Force flag set, merging anyway"
        else
            continue
        fi
    fi

    info "Merging ${BRANCH_NAME} → ${PROJECT_BRANCH}..."
    cd "${PROJECT_ROOT}"

    if git merge "${BRANCH_NAME}" --no-edit -m "FleetClaw: merge ${AGENT_ID} work into ${PROJECT_BRANCH}" 2>&1; then
        log "${AGENT_ID}: merged successfully"
        SYNCED=$((SYNCED + 1))
    else
        err "${AGENT_ID}: merge conflict — resolve manually"
        git merge --abort 2>/dev/null || true
    fi
done

echo ""
if [[ ${SYNCED} -gt 0 ]]; then
    echo "=========================================="
    echo "  ✅ Synced ${SYNCED} agent(s)"
    echo "=========================================="
else
    echo "=========================================="
    echo "  ℹ️  Nothing to sync"
    echo "=========================================="
fi
echo ""
echo "Project root: ${PROJECT_ROOT}"
echo "Use --force to sync agents that aren't in done/ready-for-review state."
echo ""
