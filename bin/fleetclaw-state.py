#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any


AGENT_PREFERRED_ORDER = [
    "state",
    "needs_supervisor_decision",
    "requested_decision",
    "summary",
    "files_touched",
    "validation_state",
    "tests",
    "next_step",
    "blocker",
    "executor_ready_scope",
    "last_event_id",
    "last_updated",
    "supervisor_notified",
    "supervisor_notified_signature",
    "last_observed_signature",
]

PROJECT_PREFERRED_ORDER = [
    "state",
    "supervisor_progress_cron",
    "supervisor_progress_reason",
    "lanes_done",
    "lanes_active",
    "lanes_blocked",
    "lanes_pending_review",
    "summary",
    "completed_work",
    "where_to_review",
    "review_command",
    "next_action",
    "last_updated",
]

LABEL_OVERRIDES = {
    "needs_supervisor_decision": "Needs supervisor decision",
    "requested_decision": "Requested decision",
    "files_touched": "Files touched",
    "validation_state": "Validation state",
    "next_step": "Next step",
    "last_event_id": "Last event id",
    "last_updated": "Last updated",
    "supervisor_notified": "Supervisor notified",
    "supervisor_notified_signature": "Supervisor notified signature",
    "last_observed_signature": "Last observed signature",
    "executor_ready_scope": "Executor-ready scope",
    "supervisor_progress_cron": "Supervisor progress cron",
    "supervisor_progress_reason": "Supervisor progress reason",
    "lanes_done": "Lanes done",
    "lanes_active": "Lanes active",
    "lanes_blocked": "Lanes blocked",
    "lanes_pending_review": "Lanes pending review",
    "completed_work": "Completed work",
    "where_to_review": "Where to review",
    "review_command": "Review command",
    "next_action": "Next action",
}


def normalize_key(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", str(label).strip().lower()).strip("_")


def display_label(key: str) -> str:
    if key in LABEL_OVERRIDES:
        return LABEL_OVERRIDES[key]
    words = [segment for segment in key.split("_") if segment]
    return " ".join(word.capitalize() for word in words)


def stringify_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, (list, tuple)):
        return ", ".join(str(item) for item in value)
    if isinstance(value, dict):
        return json.dumps(value, sort_keys=True)
    return str(value)


def parse_markdown_state(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    fields: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if ": " not in line:
            continue
        key, value = line.split(": ", 1)
        fields[normalize_key(key)] = value.strip()
    return fields


def load_json_state(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    if not isinstance(payload, dict):
        return {}
    normalized: dict[str, str] = {}
    for key, value in payload.items():
        normalized[normalize_key(str(key))] = stringify_value(value).strip()
    return normalized


def choose_state(markdown_path: Path, json_path: Path) -> dict[str, str]:
    json_state = load_json_state(json_path)
    markdown_state = parse_markdown_state(markdown_path)

    if not json_state and not markdown_state:
        return {}
    if not json_state:
        return markdown_state
    if not markdown_state:
        return json_state

    markdown_mtime = markdown_path.stat().st_mtime
    json_mtime = json_path.stat().st_mtime
    if markdown_mtime > json_mtime:
        merged = dict(json_state)
        merged.update(markdown_state)
        return merged
    return json_state


def render_markdown(header: str, state: dict[str, str], preferred_order: list[str]) -> str:
    ordered_keys: list[str] = []
    for key in preferred_order:
        if key in state and state[key] != "":
            ordered_keys.append(key)
    for key in sorted(state):
        if key not in ordered_keys and state[key] != "":
            ordered_keys.append(key)

    lines = [header]
    for key in ordered_keys:
        lines.append(f"{display_label(key)}: {state[key]}")
    return "\n".join(lines) + "\n"


def write_json_state(path: Path, state: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ordered = {key: state[key] for key in sorted(state) if state[key] != ""}
    path.write_text(json.dumps(ordered, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sync_markdown_and_json(
    markdown_path: Path,
    json_path: Path,
    header: str,
    preferred_order: list[str],
    updates: dict[str, Any] | None = None,
) -> dict[str, str]:
    state = choose_state(markdown_path, json_path)
    if updates:
        for key, value in updates.items():
            normalized_key = normalize_key(key)
            normalized_value = stringify_value(value).strip()
            if normalized_value == "":
                state.pop(normalized_key, None)
            else:
                state[normalized_key] = normalized_value
    write_json_state(json_path, state)
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.write_text(render_markdown(header, state, preferred_order), encoding="utf-8")
    return state
