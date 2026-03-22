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

import importlib.util
import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
label = sys.argv[2].strip().lower()
json_path = status_path.with_name("state.json")
lib_path = status_path.parents[2] / "bin" / "fleetclaw-state.py"

spec = importlib.util.spec_from_file_location("fleetclaw_state", lib_path)
if spec is None or spec.loader is None:
    raise SystemExit(0)
state_lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state_lib)
state = state_lib.sync_markdown_and_json(
    status_path,
    json_path,
    "# STATUS.md",
    state_lib.AGENT_PREFERRED_ORDER,
)
value = state.get(state_lib.normalize_key(label), "")
if value:
    print(value)
PY
}

fleetclaw_status_set_field() {
    python3 - "$1" "$2" "$3" <<'PY'
from __future__ import annotations

import importlib.util
import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
label = sys.argv[2]
value = sys.argv[3]
json_path = status_path.with_name("state.json")
lib_path = status_path.parents[2] / "bin" / "fleetclaw-state.py"

spec = importlib.util.spec_from_file_location("fleetclaw_state", lib_path)
if spec is None or spec.loader is None:
    raise SystemExit(1)
state_lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state_lib)
state_lib.sync_markdown_and_json(
    status_path,
    json_path,
    "# STATUS.md",
    state_lib.AGENT_PREFERRED_ORDER,
    {label: value},
)
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

FLEETCLAW_LOG_MAX_BYTES="${FLEETCLAW_LOG_MAX_BYTES:-5242880}"
FLEETCLAW_LOG_ROTATE_KEEP="${FLEETCLAW_LOG_ROTATE_KEEP:-3}"

fleetclaw_rotate_log() {
    local log_file="$1"
    if [[ ! -f "${log_file}" ]]; then
        return 0
    fi
    local size
    size="$(stat --printf='%s' "${log_file}" 2>/dev/null || stat -f '%z' "${log_file}" 2>/dev/null || echo 0)"
    if (( size < FLEETCLAW_LOG_MAX_BYTES )); then
        return 0
    fi
    local i
    for (( i = FLEETCLAW_LOG_ROTATE_KEEP; i >= 1; i-- )); do
        local src dst
        if (( i == 1 )); then
            src="${log_file}"
        else
            src="${log_file}.$((i - 1))"
        fi
        dst="${log_file}.${i}"
        if [[ -f "${src}" ]]; then
            mv "${src}" "${dst}" 2>/dev/null || true
        fi
    done
}

fleetclaw_append_control_plane_log() {
    local entry_json="$1"
    local log_dir
    log_dir="$(dirname "${FLEETCLAW_CONTROL_PLANE_LOG}")"
    mkdir -p "${log_dir}"
    local lock_file="${FLEETCLAW_CONTROL_PLANE_LOG}.lock"
    (
        flock -w 5 200 2>/dev/null || true
        fleetclaw_rotate_log "${FLEETCLAW_CONTROL_PLANE_LOG}"
        printf '%s\n' "${entry_json}" >> "${FLEETCLAW_CONTROL_PLANE_LOG}"
    ) 200>"${lock_file}"
}
