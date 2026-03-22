#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./fleetclaw-protocol-lib.sh
source "${SCRIPT_DIR}/fleetclaw-protocol-lib.sh"

fleetclaw_load_runtime_env

AGENT_ID=""
EVENT_TYPE="CHECKPOINT"
STATE=""
REQUEST=""
SUMMARY=""
BLOCKER="none"
STATUS_FILE=""
EVENT_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-id)
            AGENT_ID="${2:-}"
            shift 2
            ;;
        --event-type)
            EVENT_TYPE="${2:-}"
            shift 2
            ;;
        --state)
            STATE="${2:-}"
            shift 2
            ;;
        --request)
            REQUEST="${2:-}"
            shift 2
            ;;
        --summary)
            SUMMARY="${2:-}"
            shift 2
            ;;
        --blocker)
            BLOCKER="${2:-}"
            shift 2
            ;;
        --status-file)
            STATUS_FILE="${2:-}"
            shift 2
            ;;
        --event-id)
            EVENT_ID="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${AGENT_ID}" || -z "${STATE}" || -z "${REQUEST}" || -z "${SUMMARY}" ]]; then
    echo "Usage: $0 --agent-id <id> --state <state> --request <request> --summary <text> [--event-type CHECKPOINT] [--blocker <text>] [--status-file <path>] [--event-id <id>]" >&2
    exit 1
fi

if [[ -n "${STATUS_FILE}" && -f "${STATUS_FILE}" && -z "${EVENT_ID}" ]]; then
    EXISTING_EVENT_ID="$(fleetclaw_status_get_field "${STATUS_FILE}" "Last event id" || true)"
    if [[ -n "${EXISTING_EVENT_ID}" && "${EXISTING_EVENT_ID}" != "none" ]]; then
        EVENT_ID="${EXISTING_EVENT_ID}"
    fi
fi

if [[ -z "${EVENT_ID}" ]]; then
    EVENT_ID="$(fleetclaw_generate_event_id "${AGENT_ID}")"
fi

if [[ -n "${STATUS_FILE}" ]]; then
    fleetclaw_status_set_field "${STATUS_FILE}" "Last event id" "${EVENT_ID}"
fi

MESSAGE="$(python3 - "${FLEETCLAW_AGENT_NOTIFY_MAX_TOKENS}" "${EVENT_TYPE}" "${EVENT_ID}" "${AGENT_ID}" "${STATE}" "${REQUEST}" "${SUMMARY}" "${BLOCKER}" <<'PY'
from __future__ import annotations

import sys

budget = int(sys.argv[1])
event_type, event_id, agent_id, state, request, summary, blocker = sys.argv[2:]
max_chars = max(budget * 4, 160)

parts = {
    "summary": summary.strip(),
    "blocker": blocker.strip(),
}

def build() -> str:
    lines = [
        f"AGENT_EVENT: {event_type}",
        f"EVENT_ID: {event_id}",
        f"AGENT_ID: {agent_id}",
        f"STATE: {state}",
        f"REQUEST: {request}",
        f"SUMMARY: {parts['summary'] or 'n/a'}",
    ]
    blocker_value = parts["blocker"]
    if blocker_value and blocker_value.lower() != "none":
        lines.append(f"BLOCKER: {blocker_value}")
    return "\n".join(lines)

while len(build()) > max_chars:
    reduced = False
    for key in ("summary", "blocker"):
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
    raise SystemExit(f"Notification exceeds budget of about {budget} tokens")

print(message)
PY
)"

SESSION_KEY="agent:${FLEETCLAW_SUPERVISOR_RUNTIME_ID}:main"
RUNTIME_ID="${FLEETCLAW_PROJECT_SLUG}-${AGENT_ID}"
CREATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

MAX_RETRIES="${FLEETCLAW_NOTIFY_RETRIES:-2}"
RETRY_DELAY=2
SEND_OUTPUT=""
SEND_OK=false

for (( attempt = 0; attempt <= MAX_RETRIES; attempt++ )); do
    if (( attempt > 0 )); then
        printf 'Retry %d/%d after %ds...\n' "${attempt}" "${MAX_RETRIES}" "${RETRY_DELAY}" >&2
        sleep "${RETRY_DELAY}"
        RETRY_DELAY=$(( RETRY_DELAY * 2 ))
    fi
    if SEND_OUTPUT="$(fleetclaw_send_gateway_chat "${SESSION_KEY}" "${MESSAGE}" "${EVENT_ID}" 2>&1)"; then
        SEND_OK=true
        break
    fi
done

if "${SEND_OK}"; then
    ENTRY_JSON="$(python3 - "${CREATED_AT}" "${EVENT_ID}" "${EVENT_TYPE}" "${AGENT_ID}" "${RUNTIME_ID}" "${FLEETCLAW_SUPERVISOR_RUNTIME_ID}" "${STATE}" "${REQUEST}" "${SUMMARY}" "${BLOCKER}" "${SEND_OUTPUT}" <<'PY'
from __future__ import annotations

import json
import sys

created_at, event_id, event_type, agent_id, runtime_id, target_runtime_id, state, request, summary, blocker, send_output = sys.argv[1:]

parsed = json.loads(send_output)
entry = {
    "createdAt": created_at,
    "direction": "agent_to_supervisor",
    "eventId": event_id,
    "eventType": event_type,
    "agentId": agent_id,
    "runtimeId": runtime_id,
    "targetRuntimeId": target_runtime_id,
    "state": state,
    "request": request,
    "summary": summary,
    "blocker": blocker,
    "status": parsed.get("status", "started"),
    "runId": parsed.get("runId", event_id),
}
print(json.dumps(entry))
PY
)"
    fleetclaw_append_control_plane_log "${ENTRY_JSON}"
    printf 'Queued supervisor notification %s (%s)\n' "${EVENT_ID}" "${SESSION_KEY}"
    exit 0
fi

ENTRY_JSON="$(python3 - "${CREATED_AT}" "${EVENT_ID}" "${EVENT_TYPE}" "${AGENT_ID}" "${RUNTIME_ID}" "${FLEETCLAW_SUPERVISOR_RUNTIME_ID}" "${STATE}" "${REQUEST}" "${SUMMARY}" "${BLOCKER}" "${SEND_OUTPUT}" <<'PY'
from __future__ import annotations

import json
import sys

created_at, event_id, event_type, agent_id, runtime_id, target_runtime_id, state, request, summary, blocker, error_text = sys.argv[1:]

entry = {
    "createdAt": created_at,
    "direction": "agent_to_supervisor",
    "eventId": event_id,
    "eventType": event_type,
    "agentId": agent_id,
    "runtimeId": runtime_id,
    "targetRuntimeId": target_runtime_id,
    "state": state,
    "request": request,
    "summary": summary,
    "blocker": blocker,
    "status": "dispatch-error",
    "error": error_text,
}
print(json.dumps(entry))
PY
)"
fleetclaw_append_control_plane_log "${ENTRY_JSON}"
printf 'Failed to notify supervisor for %s\n' "${EVENT_ID}" >&2
printf '%s\n' "${SEND_OUTPUT}" >&2
exit 1
