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

REPO_ROOT="$(resolve_scope_root "${SCRIPT_DIR}")"
SCOPE_FILE="${REPO_ROOT}/project-scope.yaml"

if [[ ! -f "$SCOPE_FILE" ]]; then
    echo "No project-scope.yaml found."
    exit 1
fi

require_cmds yq openclaw

COMPACT_THRESHOLD=$(yq eval '.supervisor.context_compact_threshold // 70' "$SCOPE_FILE")
PROJECT_NAME=$(yq eval '.project.name' "$SCOPE_FILE")
OPENCLAW_PROFILE="$(resolve_openclaw_profile_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
DEFAULT_CONTEXT_LIMIT="$(resolve_context_limit_for_profile "${OPENCLAW_PROFILE}")"

echo ""
echo "Agent Context Usage (profile: ${OPENCLAW_PROFILE}, threshold: ${COMPACT_THRESHOLD}%)"
echo "==========================================================================="

SESSIONS_JSON="$(openclaw --profile "${OPENCLAW_PROFILE}" sessions --all-agents --json 2>/dev/null || true)"

python3 - "${COMPACT_THRESHOLD}" "${DEFAULT_CONTEXT_LIMIT}" "${SESSIONS_JSON}" <<'PY'
from __future__ import annotations

import json
import sys

threshold = int(sys.argv[1])
default_limit = int(sys.argv[2])
payload_raw = sys.argv[3]

try:
    payload = json.loads(payload_raw) if payload_raw else {}
except json.JSONDecodeError:
    payload = {}

sessions = payload.get("sessions") if isinstance(payload, dict) else []
if not isinstance(sessions, list) or not sessions:
    print("No active sessions found.")
    raise SystemExit(0)

rows = []
seen_session_refs = set()
for session in sessions:
    if not isinstance(session, dict):
        continue

    session_ref = (
        str(session.get("agentId") or "main"),
        str(session.get("sessionId") or session.get("key") or ""),
    )
    if session_ref in seen_session_refs:
        continue
    seen_session_refs.add(session_ref)

    total_tokens = session.get("totalTokens")
    if not isinstance(total_tokens, int) or total_tokens <= 0:
        continue

    context_limit = session.get("contextTokens")
    if not isinstance(context_limit, int) or context_limit <= 0:
        context_limit = default_limit

    agent_id = str(session.get("agentId") or "main")
    session_key = str(session.get("key") or "")
    session_label = session_key.split(f"agent:{agent_id}:", 1)[-1] if session_key.startswith(f"agent:{agent_id}:") else session_key
    usage_pct = (total_tokens / context_limit) * 100

    if usage_pct >= threshold:
        status = "COMPACT NOW"
    elif usage_pct >= max(threshold - 15, 0):
        status = "WARNING"
    else:
        status = "OK"

    rows.append((usage_pct, agent_id, session_label, total_tokens, context_limit, status))

if not rows:
    print("No sessions are reporting token usage yet.")
    raise SystemExit(0)

rows.sort(reverse=True)
print(f"{'AGENT':<24} {'SESSION':<22} {'TOKENS':>10} {'LIMIT':>10} {'USAGE':>8} STATUS")
print("---------------------------------------------------------------------------")
for usage_pct, agent_id, session_label, total_tokens, context_limit, status in rows:
    print(
        f"{agent_id:<24} {session_label[:22]:<22} {total_tokens:>10} "
        f"{context_limit:>10} {usage_pct:>7.2f}% {status}"
    )
PY

echo ""
