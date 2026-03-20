#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Quick status report for all agents
# Shows: git activity, context usage, and last supervisor note
# ============================================================

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SELF_DIR}/project-scope.example.yaml" ]]; then
    REPO_ROOT="${SELF_DIR}"
else
    REPO_ROOT="$(cd "${SELF_DIR}/.." && pwd)"
fi
SCOPE_FILE="${REPO_ROOT}/project-scope.yaml"
CHECK_CONTEXT_SCRIPT="${REPO_ROOT}/check-context.sh"

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

if [[ ! -f "$SCOPE_FILE" ]]; then
    echo "No project-scope.yaml found."
    exit 1
fi

require_cmds yq git

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

PROJECT_NAME=$(yq eval '.project.name' "$SCOPE_FILE")
AGENT_COUNT=$(yq eval '.agents | length' "$SCOPE_FILE")
PROJECT_SLUG=$(slugify "${PROJECT_NAME}")
OPENCLAW_PROFILE=$(yq eval ".advanced.openclaw_profile // \"${PROJECT_SLUG}\"" "$SCOPE_FILE")
if [[ -z "${OPENCLAW_PROFILE}" || "${OPENCLAW_PROFILE}" == "null" ]]; then
    OPENCLAW_PROFILE="${PROJECT_SLUG}"
fi
WORKTREE_BASE=$(yq eval ".advanced.worktree_base // \"$HOME/.openclaw/projects/${PROJECT_NAME}\"" "$SCOPE_FILE")
SUPERVISOR_WS="${WORKTREE_BASE}/supervisor-workspace"

echo ""
echo "=========================================="
echo "  📊 Status: ${PROJECT_NAME}"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

echo "  Profile: ${OPENCLAW_PROFILE}"

# --- Per-agent git status ---
for i in $(seq 0 $((AGENT_COUNT - 1))); do
    AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
    WORKTREE_PATH="${WORKTREE_BASE}/${AGENT_ID}"

    echo ""
    echo "--- ${AGENT_ID} ---"

    if [[ ! -d "${WORKTREE_PATH}/.git" && ! -f "${WORKTREE_PATH}/.git" ]]; then
        echo "  ⚠️  Worktree not found at ${WORKTREE_PATH}"
        continue
    fi

    # Recent commits
    COMMITS=$(git -C "${WORKTREE_PATH}" log --oneline -5 2>/dev/null || echo "  (no commits)")
    echo "  Recent commits:"
    echo "$COMMITS" | sed 's/^/    /'

    # Uncommitted changes
    DIFF_STAT=$(git -C "${WORKTREE_PATH}" diff --stat 2>/dev/null || echo "  (clean)")
    if [[ -n "$DIFF_STAT" ]]; then
        echo "  Uncommitted changes:"
        echo "$DIFF_STAT" | sed 's/^/    /'
    else
        echo "  Uncommitted changes: none"
    fi

    # Check for BLOCKERS.md
    if [[ -f "${WORKTREE_PATH}/BLOCKERS.md" ]]; then
        echo "  ⚠️  BLOCKERS.md exists:"
        tail -5 "${WORKTREE_PATH}/BLOCKERS.md" | sed 's/^/    /'
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
if [[ ! -x "$CHECK_CONTEXT_SCRIPT" ]]; then
    echo "Context usage unavailable: ${CHECK_CONTEXT_SCRIPT} is missing or not executable."
elif ! command -v jq >/dev/null 2>&1 || ! command -v openclaw >/dev/null 2>&1; then
    echo "Context usage unavailable: install jq and openclaw to enable it."
else
    "${CHECK_CONTEXT_SCRIPT}"
fi
