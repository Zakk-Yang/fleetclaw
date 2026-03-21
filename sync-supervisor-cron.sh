#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

enable_yq_fallback

QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)
            QUIET=1
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

if [[ ! -f "${SCOPE_FILE}" ]]; then
    if [[ "${QUIET}" -ne 1 ]]; then
        warn "No project-scope.yaml found; skipping supervisor cron sync"
    fi
    exit 0
fi

PROJECT_NAME="$(yq eval '.project.name' "${SCOPE_FILE}")"
PROJECT_REPO="$(yq eval '.project.repo' "${SCOPE_FILE}")"
PROJECT_ROOT="$(resolve_project_root_path "${PROJECT_REPO}" "${SCRIPT_DIR}")"
PROJECT_SLUG="$(slugify "${PROJECT_NAME}")"
PROJECT_PROFILE="$(resolve_openclaw_profile_from_scope "${SCOPE_FILE}" "${PROJECT_NAME}")"
PROGRESS_CRON_NAME="${PROJECT_SLUG}-supervisor-progress-check"

OUTPUT="$(
python3 - "${PROJECT_ROOT}" "${SCOPE_FILE}" "${PROJECT_PROFILE}" "${PROGRESS_CRON_NAME}" "${QUIET}" <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import yaml

project_root = Path(sys.argv[1])
scope_file = Path(sys.argv[2])
profile = sys.argv[3]
progress_cron_name = sys.argv[4]
quiet = sys.argv[5] == "1"

scope = yaml.safe_load(scope_file.read_text(encoding="utf-8")) or {}
agents = scope.get("agents") or []


def parse_status_fields(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    fields: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if ": " not in line:
            continue
        key, value = line.split(": ", 1)
        fields[key.strip().lower()] = value.strip()
    return fields


total_agents = 0
done_agents = 0
for agent in agents:
    agent_id = str(agent.get("id") or "").strip()
    if not agent_id:
        continue
    total_agents += 1
    status_fields = parse_status_fields(project_root / ".fleetclaw" / "agents" / agent_id / "STATUS.md")
    if status_fields.get("state", "").strip().lower() == "done":
        done_agents += 1

all_done = total_agents > 0 and done_agents == total_agents

try:
    listed = subprocess.run(
        ["openclaw", "--profile", profile, "cron", "list", "--all", "--json"],
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    )
except Exception as exc:  # pragma: no cover
    if not quiet:
        print(f"Could not inspect supervisor cron jobs: {exc}")
    raise SystemExit(0)

payload = json.loads(listed.stdout or '{"jobs":[]}')
job = None
for candidate in payload.get("jobs", []):
    if candidate.get("name") == progress_cron_name:
        job = candidate
        break

if not job:
    if not quiet:
        print("Progress cron job not found")
    raise SystemExit(0)

current_enabled = bool(job.get("enabled", False))
desired_enabled = total_agents > 0 and not all_done

if current_enabled == desired_enabled:
    if not quiet:
        if desired_enabled:
            print("Supervisor progress cron already enabled")
        else:
            print("Supervisor progress cron already disabled because all lanes are done")
    raise SystemExit(0)

command = "enable" if desired_enabled else "disable"
try:
    subprocess.run(
        ["openclaw", "--profile", profile, "cron", command, str(job.get("id", ""))],
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    )
except Exception as exc:  # pragma: no cover
    if not quiet:
        print(f"Could not {command} supervisor progress cron: {exc}")
    raise SystemExit(0)

if not quiet:
    if desired_enabled:
        print("Enabled supervisor progress cron because active work remains")
    else:
        print("Disabled supervisor progress cron because all lanes are done")
PY
)"

if [[ "${QUIET}" -ne 1 && -n "${OUTPUT}" ]]; then
    printf '%s\n' "${OUTPUT}"
fi
