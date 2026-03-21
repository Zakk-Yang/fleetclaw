#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${FLEETCLAW_PROTOCOL_LIB_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
FLEETCLAW_PROTOCOL_LIB_LOADED=1

FLEETCLAW_PROTOCOL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEETCLAW_RUNTIME_ENV="${FLEETCLAW_PROTOCOL_LIB_DIR}/../runtime.env"

fleetclaw_load_runtime_env() {
    if [[ ! -f "${FLEETCLAW_RUNTIME_ENV}" ]]; then
        echo "FleetClaw runtime env not found: ${FLEETCLAW_RUNTIME_ENV}" >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${FLEETCLAW_RUNTIME_ENV}"

    : "${FLEETCLAW_OPENCLAW_PROFILE:?}"
    : "${FLEETCLAW_PROJECT_ROOT:?}"
    : "${FLEETCLAW_PROJECT_SLUG:?}"
    : "${FLEETCLAW_SUPERVISOR_RUNTIME_ID:?}"
    : "${FLEETCLAW_CONTROL_PLANE_LOG:?}"
    : "${FLEETCLAW_AGENT_NOTIFY_MAX_TOKENS:?}"
    : "${FLEETCLAW_SUPERVISOR_REPLY_MAX_TOKENS:?}"
}

fleetclaw_generate_event_id() {
    python3 - "$1" <<'PY'
from __future__ import annotations

import re
import secrets
import sys
from datetime import datetime, timezone

agent_id = re.sub(r"[^a-zA-Z0-9._-]+", "-", sys.argv[1]).strip("-") or "agent"
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
print(f"{agent_id}-{stamp}-{secrets.token_hex(2)}")
PY
}

fleetclaw_status_get_field() {
    python3 - "$1" "$2" <<'PY'
from __future__ import annotations

import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
label = sys.argv[2].strip().lower()
if not status_path.exists():
    raise SystemExit(0)

for line in status_path.read_text(encoding="utf-8").splitlines():
    if ": " not in line:
        continue
    key, value = line.split(": ", 1)
    if key.strip().lower() == label:
        print(value.strip())
        break
PY
}

fleetclaw_status_set_field() {
    python3 - "$1" "$2" "$3" <<'PY'
from __future__ import annotations

import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
label = sys.argv[2]
value = sys.argv[3]
prefix = f"{label}:"
replacement = f"{label}: {value}"

if status_path.exists():
    lines = status_path.read_text(encoding="utf-8").splitlines()
else:
    status_path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# STATUS.md"]

for index, line in enumerate(lines):
    if line.startswith(prefix):
        lines[index] = replacement
        break
else:
    lines.append(replacement)

status_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

fleetclaw_send_gateway_chat() {
    local session_key="$1"
    local message="$2"
    local idempotency_key="$3"
    local params

    params="$(python3 - "$session_key" "$message" "$idempotency_key" <<'PY'
from __future__ import annotations

import json
import sys

print(json.dumps({
    "sessionKey": sys.argv[1],
    "message": sys.argv[2],
    "idempotencyKey": sys.argv[3],
}))
PY
)"

    openclaw --profile "${FLEETCLAW_OPENCLAW_PROFILE}" gateway call chat.send --json --params "${params}"
}

fleetclaw_append_control_plane_log() {
    local entry_json="$1"
    mkdir -p "$(dirname "${FLEETCLAW_CONTROL_PLANE_LOG}")"
    printf '%s\n' "${entry_json}" >> "${FLEETCLAW_CONTROL_PLANE_LOG}"
}
