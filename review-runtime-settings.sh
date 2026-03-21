#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

enable_yq_fallback

if [[ ! -f "${SCOPE_FILE}" ]]; then
    err "project-scope.yaml not found."
    exit 1
fi

require_cmds openclaw python3

PROJECT_NAME="$(yq eval '.project.name' "${SCOPE_FILE}")"
PROFILE="$(resolve_openclaw_profile_from_scope "${SCOPE_FILE}" "${PROJECT_NAME}")"
CRON_JSON="$(openclaw --profile "${PROFILE}" cron list --json 2>/dev/null || echo '{"jobs":[]}')"
HEARTBEAT_JSON="$(openclaw --profile "${PROFILE}" config get agents.defaults.heartbeat --json 2>/dev/null || echo 'null')"
COMPACTION_JSON="$(openclaw --profile "${PROFILE}" config get agents.defaults.compaction --json 2>/dev/null || echo 'null')"
CRON_RETENTION_JSON="$(openclaw --profile "${PROFILE}" config get cron.sessionRetention --json 2>/dev/null || echo 'null')"

echo ""
echo "=========================================="
echo "  🔎 FleetClaw Runtime Review"
echo "=========================================="
echo ""
info "Project: ${PROJECT_NAME}"
info "Profile: ${PROFILE}"
echo ""

python3 - "${HEARTBEAT_JSON}" "${COMPACTION_JSON}" "${CRON_RETENTION_JSON}" "${CRON_JSON}" <<'PY'
from __future__ import annotations

import json
import sys

def parse(raw: str):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw

heartbeat = parse(sys.argv[1])
compaction = parse(sys.argv[2])
cron_retention = parse(sys.argv[3])
cron_payload = parse(sys.argv[4]) if len(sys.argv) > 4 else {"jobs": []}
jobs = cron_payload.get("jobs") if isinstance(cron_payload, dict) else []
if not isinstance(jobs, list):
    jobs = []

print("Heartbeat:")
print(json.dumps(heartbeat, indent=2) if heartbeat not in (None, "null", "") else "  (unset)")
print("")
print("Compaction:")
print(json.dumps(compaction, indent=2) if compaction not in (None, "null", "") else "  (unset)")
print("")
print("Cron session retention:")
print(json.dumps(cron_retention, indent=2) if cron_retention not in (None, "null", "") else "  (unset)")
print("")
print("Cron jobs:")
if not jobs:
    print("  (none)")
else:
    for job in jobs:
        if not isinstance(job, dict):
            continue
        name = job.get("name", "(unnamed)")
        agent = job.get("agentId") or job.get("agent") or "-"
        session = job.get("sessionTarget") or job.get("session") or "-"
        enabled = job.get("enabled")
        light = job.get("lightContext")
        print(f"  - {name}: agent={agent} session={session} enabled={enabled} lightContext={light}")
PY

echo ""
