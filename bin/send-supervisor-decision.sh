#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./fleetclaw-protocol-lib.sh
source "${SCRIPT_DIR}/fleetclaw-protocol-lib.sh"

fleetclaw_load_runtime_env

AGENT_ID=""
DECISION=""
EVENT_ID=""
NEXT_STEP=""
REASON=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-id)
            AGENT_ID="${2:-}"
            shift 2
            ;;
        --decision)
            DECISION="${2:-}"
            shift 2
            ;;
        --event-id)
            EVENT_ID="${2:-}"
            shift 2
            ;;
        --next)
            NEXT_STEP="${2:-}"
            shift 2
            ;;
        --reason)
            REASON="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${AGENT_ID}" || -z "${DECISION}" || -z "${EVENT_ID}" || -z "${NEXT_STEP}" ]]; then
    echo "Usage: $0 --agent-id <id> --decision <token> --event-id <id> --next <text> [--reason <text>]" >&2
    exit 1
fi

MESSAGE="$(python3 - "${FLEETCLAW_SUPERVISOR_REPLY_MAX_TOKENS}" "${DECISION}" "${EVENT_ID}" "${NEXT_STEP}" "${REASON}" <<'PY'
from __future__ import annotations

import sys

budget = int(sys.argv[1])
decision, event_id, next_step, reason = sys.argv[2:]
max_chars = max(budget * 4, 180)

parts = {
    "next": next_step.strip(),
    "reason": reason.strip(),
}

def build() -> str:
    lines = [
        f"SUPERVISOR_DECISION: {decision}",
        f"EVENT_ID: {event_id}",
        f"NEXT: {parts['next'] or 'n/a'}",
    ]
    if parts["reason"]:
        lines.append(f"REASON: {parts['reason']}")
    return "\n".join(lines)

while len(build()) > max_chars:
    reduced = False
    for key in ("reason", "next"):
        value = parts[key]
        if not value:
            continue
        if len(value) <= 12:
            parts[key] = value[: max(len(value) - 1, 0)]
        else:
            parts[key] = value[: max(len(value) - 8, 0)].rstrip(" ,.;") + "..."
        reduced = True
        if len(build()) <= max_chars:
            break
    if not reduced:
        break

message = build()
if len(message) > max_chars:
    raise SystemExit(f"Decision exceeds budget of about {budget} tokens")

print(message)
PY
)"

TARGET_RUNTIME_ID="${FLEETCLAW_PROJECT_SLUG}-${AGENT_ID}"
SESSION_KEY="agent:${TARGET_RUNTIME_ID}:main"
DECISION_KEY="${EVENT_ID}:decision:${DECISION}"
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if SEND_OUTPUT="$(fleetclaw_send_gateway_chat "${SESSION_KEY}" "${MESSAGE}" "${DECISION_KEY}" 2>&1)"; then
    ENTRY_JSON="$(python3 - "${CREATED_AT}" "${EVENT_ID}" "${DECISION}" "${AGENT_ID}" "${FLEETCLAW_SUPERVISOR_RUNTIME_ID}" "${TARGET_RUNTIME_ID}" "${NEXT_STEP}" "${REASON}" "${SEND_OUTPUT}" <<'PY'
from __future__ import annotations

import json
import sys

created_at, event_id, decision, agent_id, runtime_id, target_runtime_id, next_step, reason, send_output = sys.argv[1:]

parsed = json.loads(send_output)
entry = {
    "createdAt": created_at,
    "direction": "supervisor_to_agent",
    "eventId": event_id,
    "decision": decision,
    "agentId": agent_id,
    "runtimeId": runtime_id,
    "targetRuntimeId": target_runtime_id,
    "next": next_step,
    "reason": reason,
    "status": parsed.get("status", "started"),
    "runId": parsed.get("runId", event_id),
}
print(json.dumps(entry))
PY
)"
    fleetclaw_append_control_plane_log "${ENTRY_JSON}"
    printf 'Queued supervisor decision %s for %s\n' "${DECISION}" "${AGENT_ID}"
    exit 0
fi

ENTRY_JSON="$(python3 - "${CREATED_AT}" "${EVENT_ID}" "${DECISION}" "${AGENT_ID}" "${FLEETCLAW_SUPERVISOR_RUNTIME_ID}" "${TARGET_RUNTIME_ID}" "${NEXT_STEP}" "${REASON}" "${SEND_OUTPUT}" <<'PY'
from __future__ import annotations

import json
import sys

created_at, event_id, decision, agent_id, runtime_id, target_runtime_id, next_step, reason, error_text = sys.argv[1:]

entry = {
    "createdAt": created_at,
    "direction": "supervisor_to_agent",
    "eventId": event_id,
    "decision": decision,
    "agentId": agent_id,
    "runtimeId": runtime_id,
    "targetRuntimeId": target_runtime_id,
    "next": next_step,
    "reason": reason,
    "status": "dispatch-error",
    "error": error_text,
}
print(json.dumps(entry))
PY
)"
fleetclaw_append_control_plane_log "${ENTRY_JSON}"
printf 'Failed to send supervisor decision %s for %s\n' "${DECISION}" "${AGENT_ID}" >&2
printf '%s\n' "${SEND_OUTPUT}" >&2
exit 1
