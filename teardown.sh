#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

enable_yq_fallback
detect_platform

if [[ ! -f "$SCOPE_FILE" ]]; then
    echo "No project-scope.yaml found. Nothing to tear down."
    exit 0
fi

require_cmds git openclaw

AUTO_YES=0
PURGE_STATE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            AUTO_YES=1
            ;;
        --purge-state)
            PURGE_STATE=1
            ;;
        *)
            err "Unknown argument: $1"
            exit 1
            ;;
    esac
    shift
done

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
GATEWAY_PORT="$("${OPENCLAW_CMD[@]}" config get gateway.port 2>/dev/null || true)"
DASHBOARD_PORT="$(resolve_dashboard_port_from_scope "${SCOPE_FILE}" "${OPENCLAW_PROFILE}" "${GATEWAY_PORT}")"
DASHBOARD_URL="http://${FLEETCLAW_DASHBOARD_HOST}:${DASHBOARD_PORT}/"
DASHBOARD_PID_FILE="${SCRIPT_DIR}/generated/dashboard.pid"
RECONCILE_PID_FILE="${SCRIPT_DIR}/generated/reconcile.pid"

stop_dashboard_if_running() {
    local pid=""
    if [[ -f "${DASHBOARD_PID_FILE}" ]]; then
        pid="$(cat "${DASHBOARD_PID_FILE}" 2>/dev/null || true)"
    fi
    if [[ -z "${pid}" ]]; then
        pid="$(current_project_dashboard_pid "${DASHBOARD_URL}" "${OPENCLAW_PROFILE}" "${DASHBOARD_PORT}")"
    fi

    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
        kill "${pid}" >/dev/null 2>&1 || true
        sleep 1
        log "Dashboard stopped"
    elif [[ -f "${DASHBOARD_PID_FILE}" ]]; then
        warn "Dashboard pid file was stale"
    fi

    rm -f "${DASHBOARD_PID_FILE}"
}

stop_reconciler_if_running() {
    local pid=""
    if [[ -f "${RECONCILE_PID_FILE}" ]]; then
        pid="$(cat "${RECONCILE_PID_FILE}" 2>/dev/null || true)"
    fi

    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
        kill "${pid}" >/dev/null 2>&1 || true
        sleep 1
        log "Status reconciler stopped"
    elif [[ -f "${RECONCILE_PID_FILE}" ]]; then
        warn "Status reconciler pid file was stale"
    fi

    rm -f "${RECONCILE_PID_FILE}"
}

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

if [[ "${AUTO_YES}" -eq 1 ]]; then
    info "Auto-confirm enabled"
else
    read -p "This will stop the dashboard, disable heartbeat, remove cron jobs, and clean generated files. Continue? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Stop dashboard
warn "Stopping dashboard..."
stop_dashboard_if_running

# Stop reconciler
warn "Stopping status reconciler..."
stop_reconciler_if_running

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

if [[ "${PURGE_STATE}" -eq 1 ]]; then
    warn "Purging dedicated OpenClaw runtime state..."
    "${OPENCLAW_CMD[@]}" gateway uninstall >/dev/null 2>&1 || true
    rm -rf "${PROFILE_ROOT}"
    rm -rf "${WORKTREE_BASE}"
    log "Purged ${PROFILE_ROOT}"
    log "Purged ${WORKTREE_BASE}"
fi

echo ""
if [[ "${PURGE_STATE}" -eq 1 ]]; then
    echo "Done. Dedicated OpenClaw runtime state was removed."
    echo "Project workspace preserved at: ${PROJECT_ROOT}"
else
    echo "Done. Dedicated OpenClaw profile data was preserved at: ${PROFILE_ROOT}"
    echo "Shared project workspace preserved at: ${PROJECT_ROOT}"
    echo "Supervisor workspace preserved at: ${WORKTREE_BASE}/supervisor-workspace"
fi
echo ""
