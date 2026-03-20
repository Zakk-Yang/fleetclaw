#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Quick status report for all agents
# Shows: git activity, context usage, and last supervisor note
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

enable_yq_fallback
enable_jq_fallback

REPO_ROOT="$(resolve_scope_root "${SCRIPT_DIR}")"
SCOPE_FILE="${REPO_ROOT}/project-scope.yaml"
CHECK_CONTEXT_SCRIPT="${REPO_ROOT}/check-context.sh"
CHECK_MARKDOWN_BUDGET_SCRIPT="${REPO_ROOT}/check-markdown-budget.sh"

if [[ ! -f "$SCOPE_FILE" ]]; then
    echo "No project-scope.yaml found."
    exit 1
fi

require_cmds yq git

PROJECT_NAME=$(yq eval '.project.name' "$SCOPE_FILE")
PROJECT_REPO=$(yq eval '.project.repo' "$SCOPE_FILE")
AGENT_COUNT=$(yq eval '.agents | length' "$SCOPE_FILE")
OPENCLAW_PROFILE="$(resolve_openclaw_profile_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
WORKTREE_BASE="$(resolve_worktree_base_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
SUPERVISOR_WS="${WORKTREE_BASE}/supervisor-workspace"
PROJECT_ROOT="$(resolve_project_root_path "${PROJECT_REPO}" "${SCRIPT_DIR}")"
AGENTS_DIR="${PROJECT_ROOT}/.fleetclaw/agents"

read_status_field() {
    local field_name="$1"
    local status_file="$2"
    sed -n "s/^${field_name}: //p" "${status_file}" | head -1
}

if git -C "${PROJECT_ROOT}" rev-parse --show-toplevel >/dev/null 2>&1; then
    GIT_ROOT="$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel)"
else
    GIT_ROOT="${PROJECT_ROOT}"
fi

echo ""
echo "=========================================="
echo "  📊 Status: ${PROJECT_NAME}"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

echo "  Profile: ${OPENCLAW_PROFILE}"
echo "  Project root: ${PROJECT_ROOT}"

echo ""
echo "--- Shared Repo ---"
if git -C "${PROJECT_ROOT}" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "  Git root: ${GIT_ROOT}"
    echo "  Branch: $(git -C "${PROJECT_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

    COMMITS=$(git -C "${PROJECT_ROOT}" log --oneline -5 2>/dev/null || echo "  (no commits)")
    echo "  Recent commits:"
    echo "${COMMITS}" | sed 's/^/    /'

    DIFF_STAT=$(git -C "${PROJECT_ROOT}" diff --stat 2>/dev/null || true)
    UNTRACKED=$(git -C "${PROJECT_ROOT}" ls-files --others --exclude-standard 2>/dev/null || true)
    if [[ -n "${DIFF_STAT}" ]]; then
        echo "  Uncommitted changes:"
        echo "${DIFF_STAT}" | sed 's/^/    /'
    else
        echo "  Uncommitted changes: none"
    fi
    if [[ -n "${UNTRACKED}" ]]; then
        echo "  Untracked files:"
        echo "${UNTRACKED}" | sed 's/^/    /'
    fi
else
    echo "  ⚠️  Project root is not a git repository"
fi

# --- Per-agent checkpoints ---
for i in $(seq 0 $((AGENT_COUNT - 1))); do
    AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
    AGENT_DIR="${AGENTS_DIR}/${AGENT_ID}"
    STATUS_FILE="${AGENT_DIR}/STATUS.md"
    BLOCKERS_FILE="${AGENT_DIR}/BLOCKERS.md"

    echo ""
    echo "--- ${AGENT_ID} ---"

    if [[ ! -f "${STATUS_FILE}" ]]; then
        echo "  ⚠️  STATUS.md not found at ${STATUS_FILE}"
        continue
    fi

    STATE="$(read_status_field 'State' "${STATUS_FILE}")"
    SUMMARY="$(read_status_field 'Summary' "${STATUS_FILE}")"
    NEXT_STEP="$(read_status_field 'Next step' "${STATUS_FILE}")"
    BLOCKER="$(read_status_field 'Blocker' "${STATUS_FILE}")"
    FILES_TOUCHED="$(read_status_field 'Files touched' "${STATUS_FILE}")"
    TESTS="$(read_status_field 'Tests' "${STATUS_FILE}")"
    NEEDS_DECISION="$(read_status_field 'Needs supervisor decision' "${STATUS_FILE}")"
    LAST_UPDATED="$(read_status_field 'Last updated' "${STATUS_FILE}")"

    echo "  State: ${STATE:-unknown}"
    echo "  Summary: ${SUMMARY:-none}"
    echo "  Next step: ${NEXT_STEP:-none}"
    echo "  Blocker: ${BLOCKER:-none}"
    echo "  Files touched: ${FILES_TOUCHED:-none}"
    echo "  Tests: ${TESTS:-unknown}"
    echo "  Needs supervisor decision: ${NEEDS_DECISION:-unknown}"
    echo "  Last updated: ${LAST_UPDATED:-unknown}"

    # Check for BLOCKERS.md
    if [[ -f "${BLOCKERS_FILE}" ]]; then
        echo "  ⚠️  BLOCKERS.md exists:"
        tail -5 "${BLOCKERS_FILE}" | sed 's/^/    /'
    fi
done

# --- Supervisor's last notes ---
echo ""
echo "--- Supervisor Notes ---"
TODAY_LOG="${SUPERVISOR_WS}/memory/$(date +%Y-%m-%d).md"
if [[ -f "$TODAY_LOG" ]]; then
    echo "  Last entries from today:"
    tail -20 "$TODAY_LOG" | sed 's/^/    /'
else
    echo "  No notes for today yet."
fi

# --- Context usage ---
echo ""
if [[ ! -f "$CHECK_MARKDOWN_BUDGET_SCRIPT" ]]; then
    echo "Markdown budget unavailable: ${CHECK_MARKDOWN_BUDGET_SCRIPT} is missing."
else
    bash "${CHECK_MARKDOWN_BUDGET_SCRIPT}"
fi

echo ""
if [[ ! -x "$CHECK_CONTEXT_SCRIPT" ]]; then
    echo "Context usage unavailable: ${CHECK_CONTEXT_SCRIPT} is missing or not executable."
elif ! command -v openclaw >/dev/null 2>&1; then
    echo "Context usage unavailable: install openclaw to enable it."
else
    "${CHECK_CONTEXT_SCRIPT}"
fi
