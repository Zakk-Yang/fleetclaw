#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Check context window usage for all agents
# Outputs a table with agent ID, model, token usage, and %
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

enable_yq_fallback
enable_jq_fallback

REPO_ROOT="$(resolve_scope_root "${SCRIPT_DIR}")"
SCOPE_FILE="${REPO_ROOT}/project-scope.yaml"

if [[ ! -f "$SCOPE_FILE" ]]; then
    echo "No project-scope.yaml found."
    exit 1
fi

require_cmds yq jq openclaw

COMPACT_THRESHOLD=$(yq eval '.supervisor.context_compact_threshold // 70' "$SCOPE_FILE")
PROJECT_NAME=$(yq eval '.project.name' "$SCOPE_FILE")
OPENCLAW_PROFILE="$(resolve_openclaw_profile_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"

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
