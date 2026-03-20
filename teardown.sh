#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

require_cmds() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

expand_path() {
    local raw_path="$1"
    if [[ "${raw_path}" == "~" || "${raw_path}" == ~/* ]]; then
        printf '%s\n' "${raw_path/#\~/$HOME}"
    else
        printf '%s\n' "${raw_path}"
    fi
}

resolve_local_repo_path() {
    local repo_source="$1"

    if [[ -z "${repo_source}" || "${repo_source}" == "null" || "${repo_source}" == "." ]]; then
        repo_source="${SCRIPT_DIR}"
    fi

    repo_source="$(expand_path "${repo_source}")"
    if [[ "${repo_source}" != /* ]]; then
        repo_source="${SCRIPT_DIR}/${repo_source}"
    fi

    if git -C "${repo_source}" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "${repo_source}" rev-parse --show-toplevel
        return 0
    fi

    return 1
}

if [[ ! -f "$SCOPE_FILE" ]]; then
    echo "No project-scope.yaml found. Nothing to tear down."
    exit 0
fi

require_cmds yq git openclaw

PROJECT_NAME=$(yq eval '.project.name' "$SCOPE_FILE")
PROJECT_REPO=$(yq eval '.project.repo' "$SCOPE_FILE")
AGENT_COUNT=$(yq eval '.agents | length' "$SCOPE_FILE")
WORKTREE_BASE=$(yq eval ".advanced.worktree_base // \"$HOME/.openclaw/projects/${PROJECT_NAME}\"" "$SCOPE_FILE")
REPO_DIR="${WORKTREE_BASE}/repo"
if LOCAL_REPO_DIR="$(resolve_local_repo_path "${PROJECT_REPO}")"; then
    REPO_DIR="${LOCAL_REPO_DIR}"
fi
PROJECT_SLUG=$(slugify "${PROJECT_NAME}")
OPENCLAW_PROFILE=$(yq eval ".advanced.openclaw_profile // \"${PROJECT_SLUG}\"" "$SCOPE_FILE")
if [[ -z "${OPENCLAW_PROFILE}" || "${OPENCLAW_PROFILE}" == "null" ]]; then
    OPENCLAW_PROFILE="${PROJECT_SLUG}"
fi
PROFILE_ROOT="${HOME}/.openclaw-${OPENCLAW_PROFILE}"
OPENCLAW_CMD=(openclaw --profile "${OPENCLAW_PROFILE}")
PROGRESS_CRON_NAME="${PROJECT_SLUG}-supervisor-progress-check"
MORNING_CRON_NAME="${PROJECT_SLUG}-supervisor-morning-report"

find_job_id() {
    local job_name="$1"
    local payload
    payload="$("${OPENCLAW_CMD[@]}" cron list --json 2>/dev/null || echo '{"jobs":[]}')"
    OPENCLAW_JSON_PAYLOAD="${payload}" python3 - "${job_name}" <<'PY'
import json
import os
import sys

job_name = sys.argv[1]
payload = json.loads(os.environ["OPENCLAW_JSON_PAYLOAD"])
for job in payload.get("jobs", []):
    if job.get("name") == job_name:
        print(job.get("id", ""))
        break
PY
}

echo ""
echo "=========================================="
echo "  🧹 Teardown: ${PROJECT_NAME}"
echo "=========================================="
echo ""
echo "OpenClaw profile: ${OPENCLAW_PROFILE}"
echo ""

read -p "This will remove agents, worktrees, and cron jobs. Continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Remove cron jobs
warn "Removing cron jobs..."
for job_name in \
    "${PROGRESS_CRON_NAME}" \
    "${MORNING_CRON_NAME}" \
    "supervisor-progress-check" \
    "supervisor-morning-report"; do
    job_id="$(find_job_id "${job_name}")"
    if [[ -n "${job_id}" ]]; then
        "${OPENCLAW_CMD[@]}" cron rm "${job_id}" >/dev/null 2>&1 || true
    fi
done
log "Cron jobs disabled"

# Remove git worktrees
if [[ -d "${REPO_DIR}/.git" ]]; then
    cd "${REPO_DIR}"
    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
        WORKTREE_PATH="${WORKTREE_BASE}/${AGENT_ID}"
        if [[ -d "${WORKTREE_PATH}" ]]; then
            git worktree remove "${WORKTREE_PATH}" --force 2>/dev/null || \
                warn "Could not remove worktree ${WORKTREE_PATH}"
            log "Removed worktree: ${AGENT_ID}"
        fi
    done
fi

# Clean generated files
rm -rf "${SCRIPT_DIR}/generated"
log "Cleaned generated files"

echo ""
echo "Done. Dedicated OpenClaw profile data was preserved at: ${PROFILE_ROOT}"
echo "Worktree base directory preserved at: ${WORKTREE_BASE}"
echo ""
