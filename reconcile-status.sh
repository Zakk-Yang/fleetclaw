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
        warn "No project-scope.yaml found; skipping reconciliation"
    fi
    exit 0
fi

PROJECT_NAME="$(yq eval '.project.name' "${SCOPE_FILE}")"
PROJECT_REPO="$(yq eval '.project.repo' "${SCOPE_FILE}")"
PROJECT_ROOT="$(resolve_project_root_path "${PROJECT_REPO}" "${SCRIPT_DIR}")"
PROJECT_SLUG="$(slugify "${PROJECT_NAME}")"
OPENCLAW_PROFILE="$(resolve_openclaw_profile_from_scope "${SCOPE_FILE}" "${PROJECT_NAME}")"
PROFILE_ROOT="${HOME}/.openclaw-${OPENCLAW_PROFILE}"

OUTPUT="$(
python3 - "${PROJECT_ROOT}" "${PROFILE_ROOT}" "${PROJECT_SLUG}" "${SCOPE_FILE}" <<'PY'
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

project_root = Path(sys.argv[1])
profile_root = Path(sys.argv[2])
project_slug = sys.argv[3]
scope_file = Path(sys.argv[4])

scope = yaml.safe_load(scope_file.read_text(encoding="utf-8")) or {}
agents = scope.get("agents") or []
supervisor_runtime_id = f"{project_slug}-supervisor"
decision_pattern = re.compile(r"SUPERVISOR_DECISION:\s*([A-Z_]+)")


def parse_dt(value: object) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(float(value) / 1000.0, tz=timezone.utc).astimezone().replace(tzinfo=None)
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        try:
            return datetime.strptime(value, "%Y-%m-%d %H:%M")
        except ValueError:
            return None
    if parsed.tzinfo is not None:
        return parsed.astimezone().replace(tzinfo=None)
    return parsed


def extract_status_fields(lines: list[str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in lines:
        if ": " not in line:
            continue
        key, value = line.split(": ", 1)
        fields[key] = value
    return fields


def set_field(lines: list[str], label: str, value: str) -> None:
    prefix = f"{label}:"
    replacement = f"{label}: {value}"
    for index, line in enumerate(lines):
        if line.startswith(prefix):
            lines[index] = replacement
            return
    lines.append(replacement)


def latest_supervisor_decision(runtime_agent_id: str) -> tuple[str, datetime] | None:
    session_dir = profile_root / "agents" / runtime_agent_id / "sessions"
    if not session_dir.is_dir():
        return None

    latest: tuple[str, datetime] | None = None
    supervisor_prefix = f"agent:{supervisor_runtime_id}:"

    for session_file in sorted(session_dir.glob("*.jsonl")):
        try:
            raw_lines = session_file.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue

        for raw_line in raw_lines:
            if not raw_line.strip():
                continue
            try:
                payload = json.loads(raw_line)
            except json.JSONDecodeError:
                continue

            message = payload.get("message")
            if not isinstance(message, dict):
                continue
            if message.get("role") != "user":
                continue

            provenance = message.get("provenance")
            if not isinstance(provenance, dict):
                continue
            if provenance.get("kind") != "inter_session":
                continue
            if not str(provenance.get("sourceSessionKey", "")).startswith(supervisor_prefix):
                continue

            content = message.get("content")
            if not isinstance(content, list):
                continue

            text = "\n".join(
                str(item.get("text", ""))
                for item in content
                if isinstance(item, dict) and item.get("type") == "text"
            )
            match = decision_pattern.search(text)
            if not match:
                continue

            when = parse_dt(payload.get("timestamp")) or parse_dt(message.get("timestamp"))
            if when is None:
                continue

            decision = match.group(1)
            if latest is None or when > latest[1]:
                latest = (decision, when)

    return latest


def append_memory_note(memory_path: Path, note: str) -> None:
    memory_path.parent.mkdir(parents=True, exist_ok=True)
    if not memory_path.exists():
        memory_path.write_text(f"# {memory_path.stem}\n\n", encoding="utf-8")
    existing = memory_path.read_text(encoding="utf-8")
    if note in existing:
        return
    with memory_path.open("a", encoding="utf-8") as handle:
        if not existing.endswith("\n"):
            handle.write("\n")
        handle.write(note + "\n")


changes: list[str] = []
now = datetime.now()
now_stamp = now.strftime("%Y-%m-%d %H:%M")
today_name = now.strftime("%Y-%m-%d")
time_label = now.strftime("%H:%M")

for agent in agents:
    agent_id = agent.get("id")
    if not agent_id:
        continue

    runtime_agent_id = f"{project_slug}-{agent_id}"
    decision = latest_supervisor_decision(runtime_agent_id)
    if decision is None or decision[0] != "ACCEPT_DONE":
        continue

    decision_name, decision_time = decision
    agent_dir = project_root / ".fleetclaw" / "agents" / agent_id
    status_path = agent_dir / "STATUS.md"
    if not status_path.is_file():
        continue

    lines = status_path.read_text(encoding="utf-8").splitlines()
    fields = extract_status_fields(lines)
    state = fields.get("State", "").strip().lower()
    needs_decision = fields.get("Needs supervisor decision", "").strip().lower()
    requested_decision = fields.get("Requested decision", "").strip().lower()
    last_updated = parse_dt(fields.get("Last updated"))

    should_normalize = False
    if state != "done" or needs_decision != "no" or requested_decision != "none":
        if last_updated is None or decision_time > last_updated:
            should_normalize = True

    if not should_normalize:
        continue

    set_field(lines, "State", "done")
    set_field(lines, "Needs supervisor decision", "no")
    set_field(lines, "Requested decision", "none")
    set_field(lines, "Next step", "Wait for follow-up requests or reopened work.")
    set_field(lines, "Last updated", now_stamp)
    status_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    memory_note = (
        f"- {time_label} FleetClaw reconciled `STATUS.md` to `done` after "
        f"supervisor `{decision_name}` recorded in session history."
    )
    append_memory_note(agent_dir / "memory" / f"{today_name}.md", memory_note)
    changes.append(f"{agent_id}: reconciled ACCEPT_DONE into STATUS.md")

if changes:
    print("\n".join(changes))
PY
)"

if [[ -n "${OUTPUT}" && "${QUIET}" -ne 1 ]]; then
    printf '%s\n' "${OUTPUT}"
fi
