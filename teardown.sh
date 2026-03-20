#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

enable_yq_fallback

if [[ ! -f "$SCOPE_FILE" ]]; then
    echo "No project-scope.yaml found. Nothing to tear down."
    exit 0
fi

require_cmds git openclaw

PROJECT_NAME=$(yq eval '.project.name' "$SCOPE_FILE")
PROJECT_REPO=$(yq eval '.project.repo' "$SCOPE_FILE")
WORKTREE_BASE="$(resolve_worktree_base_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
PROJECT_ROOT="$(resolve_project_root_path "${PROJECT_REPO}" "${SCRIPT_DIR}")"
PROJECT_SLUG=$(slugify "${PROJECT_NAME}")
OPENCLAW_PROFILE="$(resolve_openclaw_profile_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
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
echo "Project root: ${PROJECT_ROOT}"
echo ""

read -p "This will disable heartbeat, remove cron jobs, and clean generated files. Continue? (y/N) " -n 1 -r
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

# Disable heartbeat
warn "Disabling heartbeat..."
if "${OPENCLAW_CMD[@]}" system heartbeat disable >/dev/null 2>&1; then
    log "Heartbeat disabled"
else
    warn "Could not disable heartbeat automatically"
fi

# Clean generated files
rm -rf "${SCRIPT_DIR}/generated"
log "Cleaned generated files"

echo ""
echo "Done. Dedicated OpenClaw profile data was preserved at: ${PROFILE_ROOT}"
echo "Shared project workspace preserved at: ${PROJECT_ROOT}"
echo "Supervisor workspace preserved at: ${WORKTREE_BASE}/supervisor-workspace"
echo ""
