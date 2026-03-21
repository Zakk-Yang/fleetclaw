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
        warn "No project-scope.yaml found; skipping project status update"
    fi
    exit 0
fi

PROJECT_NAME="$(yq eval '.project.name' "${SCOPE_FILE}")"
PROJECT_REPO="$(yq eval '.project.repo' "${SCOPE_FILE}")"
PROJECT_ROOT="$(resolve_project_root_path "${PROJECT_REPO}" "${SCRIPT_DIR}")"
PROJECT_SLUG="$(slugify "${PROJECT_NAME}")"
PROJECT_PROFILE="$(resolve_openclaw_profile_from_scope "${SCOPE_FILE}" "${PROJECT_NAME}")"
PROGRESS_CRON_NAME="${PROJECT_SLUG}-supervisor-progress-check"

OPENCLAW_CRON_JSON="$(openclaw --profile "${PROJECT_PROFILE}" cron list --all --json 2>/dev/null || printf '{"jobs":[]}\n')"

OUTPUT="$(
OPENCLAW_CRON_JSON="${OPENCLAW_CRON_JSON}" python3 - "${PROJECT_ROOT}" "${SCOPE_FILE}" "${PROGRESS_CRON_NAME}" <<'PY'
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

project_root = Path(sys.argv[1])
scope_file = Path(sys.argv[2])
progress_cron_name = sys.argv[3]

scope = yaml.safe_load(scope_file.read_text(encoding="utf-8")) or {}
agents = scope.get("agents") or []
cron_payload = json.loads(os.environ.get("OPENCLAW_CRON_JSON") or '{"jobs":[]}')


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


def format_list(values: list[str], total: int) -> str:
    label = ", ".join(values) if values else "none"
    return f"{len(values)}/{total} ({label})"


done_ids: list[str] = []
blocked_ids: list[str] = []
pending_review_ids: list[str] = []
active_ids: list[str] = []
unknown_ids: list[str] = []

for agent in agents:
    agent_id = str(agent.get("id") or "").strip()
    if not agent_id:
        continue
    status_fields = parse_status_fields(project_root / ".fleetclaw" / "agents" / agent_id / "STATUS.md")
    state = status_fields.get("state", "").strip().lower()
    needs_decision = status_fields.get("needs supervisor decision", "").strip().lower()
    blocker = status_fields.get("blocker", "").strip().lower()

    is_blocked = state == "blocked" or (blocker not in {"", "none"})
    is_done = state == "done"
    is_pending_review = needs_decision == "yes" and not is_blocked and not is_done
    is_active = state in {"working", "ready-for-review"} and not is_pending_review

    if is_done:
        done_ids.append(agent_id)
    elif is_blocked:
        blocked_ids.append(agent_id)
    elif is_pending_review:
        pending_review_ids.append(agent_id)
    elif is_active:
        active_ids.append(agent_id)
    else:
        unknown_ids.append(agent_id)

total_agents = len([agent for agent in agents if str(agent.get("id") or "").strip()])

if total_agents == 0:
    overall_state = "idle"
elif len(done_ids) == total_agents:
    overall_state = "complete"
elif blocked_ids:
    overall_state = "blocked"
elif pending_review_ids:
    overall_state = "review-ready"
elif active_ids:
    overall_state = "active"
else:
    overall_state = "monitoring"

progress_job = None
for job in cron_payload.get("jobs", []):
    if job.get("name") == progress_cron_name:
        progress_job = job
        break

if progress_job is None:
    progress_cron = "missing"
elif progress_job.get("enabled", False):
    progress_cron = "enabled"
else:
    progress_cron = "disabled"

if total_agents == 0:
    progress_reason = "No coding agents are configured."
elif len(done_ids) == total_agents:
    progress_reason = "All coding agents are done, so the supervisor review cron can idle."
elif progress_cron == "enabled":
    progress_reason = "Active, blocked, or reviewable lanes remain."
elif progress_cron == "disabled":
    progress_reason = "Work remains, but the progress cron is disabled."
else:
    progress_reason = "Progress cron job not found."

review_url = str(scope.get("project", {}).get("review_url") or "").strip() or "not configured"
review_command = str(scope.get("project", {}).get("review_command") or "").strip() or "not configured"
completed_work = ", ".join(done_ids) if done_ids else "none yet"

if overall_state == "complete":
    summary = f"All {total_agents} lanes are done. Review at {review_url}."
    next_action = "Project complete. Review the build or reopen a lane only for follow-up work."
elif overall_state == "blocked":
    summary = f"{len(done_ids)}/{total_agents} lanes done. Blocked: {', '.join(blocked_ids)}."
    next_action = "Resolve the blocker, then send supervisor feedback so the blocked lane receives CONTINUE or ACCEPT_DONE."
elif overall_state == "review-ready":
    summary = f"{len(pending_review_ids)} lane(s) are waiting for supervisor review: {', '.join(pending_review_ids)}."
    next_action = "Let the supervisor review the pending lane(s) or inspect the current diff and review surface."
elif overall_state == "active":
    summary = f"{len(active_ids)} lane(s) are actively moving: {', '.join(active_ids)}."
    next_action = "Let active lanes continue, or intervene only if progress stalls or scope drifts."
elif overall_state == "idle":
    summary = "No coding lanes are configured yet."
    next_action = "Add at least one coding agent in project-scope.yaml."
else:
    summary = "FleetClaw is monitoring the project state."
    next_action = "Inspect lane status files and the review surface for the next action."

if unknown_ids:
    summary += f" Unknown lane state: {', '.join(unknown_ids)}."

timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
status_path = project_root / ".fleetclaw" / "PROJECT_STATUS.md"
status_path.parent.mkdir(parents=True, exist_ok=True)
status_path.write_text(
    "\n".join(
        [
            "# PROJECT_STATUS.md",
            f"State: {overall_state}",
            f"Supervisor progress cron: {progress_cron}",
            f"Supervisor progress reason: {progress_reason}",
            f"Lanes done: {format_list(done_ids, total_agents)}",
            f"Lanes active: {format_list(active_ids, total_agents)}",
            f"Lanes blocked: {format_list(blocked_ids, total_agents)}",
            f"Lanes pending review: {format_list(pending_review_ids, total_agents)}",
            f"Summary: {summary}",
            f"Completed work: {completed_work}",
            f"Where to review: {review_url}",
            f"Review command: {review_command}",
            f"Next action: {next_action}",
            f"Last updated: {timestamp}",
            "",
        ]
    ),
    encoding="utf-8",
)

print(summary)
PY
)"

if [[ "${QUIET}" -ne 1 && -n "${OUTPUT}" ]]; then
    printf '%s\n' "${OUTPUT}"
fi
