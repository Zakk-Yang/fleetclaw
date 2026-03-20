#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Check context window usage for all agents
# Outputs a table with agent ID, model, token usage, and %
# ============================================================

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SELF_DIR}/project-scope.example.yaml" ]]; then
    REPO_ROOT="${SELF_DIR}"
else
    REPO_ROOT="$(cd "${SELF_DIR}/.." && pwd)"
fi
SCOPE_FILE="${REPO_ROOT}/project-scope.yaml"

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

require_cmds yq jq openclaw

COMPACT_THRESHOLD=$(yq eval '.supervisor.context_compact_threshold // 70' "$SCOPE_FILE")
PROJECT_NAME=$(yq eval '.project.name' "$SCOPE_FILE")
PROJECT_SLUG=$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')
OPENCLAW_PROFILE=$(yq eval ".advanced.openclaw_profile // \"${PROJECT_SLUG}\"" "$SCOPE_FILE")
if [[ -z "${OPENCLAW_PROFILE}" || "${OPENCLAW_PROFILE}" == "null" ]]; then
    OPENCLAW_PROFILE="${PROJECT_SLUG}"
fi

echo ""
echo "Agent Context Usage (profile: ${OPENCLAW_PROFILE}, threshold: ${COMPACT_THRESHOLD}%)"
echo "================================================"
printf "%-20s %-12s %-12s %-8s %s\n" "AGENT" "TOKENS" "LIMIT" "USAGE" "STATUS"
echo "------------------------------------------------"

# Get sessions data
SESSIONS=$(openclaw --profile "${OPENCLAW_PROFILE}" sessions list --json 2>/dev/null || echo "[]")

if [[ "$SESSIONS" == "[]" || -z "$SESSIONS" ]]; then
    echo "No active sessions found."
    exit 0
fi

# Parse each session
echo "$SESSIONS" | jq -r '.[] | [.agentId // "main", (.totalTokens // 0 | tostring), (.contextTokens // 200000 | tostring), .key] | @tsv' | \
while IFS=$'\t' read -r agent_id total_tokens context_limit _session_key; do
    if [[ "$total_tokens" == "0" || -z "$total_tokens" ]]; then
        continue
    fi

    pct=$((total_tokens * 100 / context_limit))

    if [[ $pct -ge $COMPACT_THRESHOLD ]]; then
        status="⚠️  COMPACT NOW"
    elif [[ $pct -ge $((COMPACT_THRESHOLD - 15)) ]]; then
        status="🟡 WARNING"
    else
        status="🟢 OK"
    fi

    printf "%-20s %-12s %-12s %-8s %s\n" \
        "$agent_id" \
        "${total_tokens}" \
        "${context_limit}" \
        "${pct}%" \
        "$status"
done

echo ""
