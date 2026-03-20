#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# FleetClaw — Sync Script
# Direct-workspace mode does not need a merge/sync step.
# This command summarizes the shared repo state instead.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

enable_yq_fallback

# --- Validate ---
if [[ ! -f "$SCOPE_FILE" ]]; then
    err "project-scope.yaml not found."
    exit 1
fi

yval() { yq eval "$1" "$SCOPE_FILE"; }
yval_default() { yq eval "$1 // \"$2\"" "$SCOPE_FILE"; }

PROJECT_NAME=$(yval '.project.name')
PROJECT_BRANCH=$(yval_default '.project.branch' 'main')
PROJECT_REPO=$(yval '.project.repo')
PROJECT_ROOT="$(resolve_project_root_path "${PROJECT_REPO}" "${SCRIPT_DIR}")"

if ! git -C "${PROJECT_ROOT}" rev-parse --show-toplevel >/dev/null 2>&1; then
    err "Cannot find project git repo at ${PROJECT_ROOT}."
    exit 1
fi

GIT_ROOT="$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel)"
CURRENT_BRANCH="$(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD)"
RECENT_COMMITS="$(git -C "${PROJECT_ROOT}" log --oneline -5 2>/dev/null || true)"
DIFF_STAT="$(git -C "${PROJECT_ROOT}" diff --stat 2>/dev/null || true)"
UNTRACKED_FILES="$(git -C "${PROJECT_ROOT}" ls-files --others --exclude-standard 2>/dev/null || true)"
STATUS_OUTPUT="$(git -C "${PROJECT_ROOT}" status --short 2>/dev/null || true)"

echo ""
echo "=========================================="
echo "  🔄 FleetClaw — Sync"
echo "=========================================="
echo ""
info "Project: ${PROJECT_NAME}"
info "Project root: ${GIT_ROOT}"
info "Configured branch: ${PROJECT_BRANCH}"
info "Current branch: ${CURRENT_BRANCH}"
echo ""

log "Direct-workspace mode is active. Agents already work in the shared project root."
echo ""
echo "--- Recent Commits ---"
if [[ -n "${RECENT_COMMITS}" ]]; then
    echo "${RECENT_COMMITS}"
else
    echo "(no commits found)"
fi

echo ""
echo "--- Working Tree ---"
if [[ -n "${STATUS_OUTPUT}" ]]; then
    echo "${STATUS_OUTPUT}"
else
    echo "Working tree clean"
fi

if [[ -n "${DIFF_STAT}" ]]; then
    echo ""
    echo "--- Diff Stat ---"
    echo "${DIFF_STAT}"
fi

if [[ -n "${UNTRACKED_FILES}" ]]; then
    echo ""
    echo "--- Untracked Files ---"
    echo "${UNTRACKED_FILES}"
fi

echo ""
echo "Nothing to sync. Review and commit shared changes directly from: ${GIT_ROOT}"
echo "Use ./status-report.sh to inspect agent checkpoints."
echo ""
