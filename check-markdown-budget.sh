#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Estimate markdown instruction-file load against context window
# Shows startup/core read-set budget for each agent and supervisor
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

require_cmds python3

PROJECT_NAME=$(yq eval '.project.name' "$SCOPE_FILE")
PROJECT_REPO=$(yq eval '.project.repo' "$SCOPE_FILE")
OPENCLAW_PROFILE="$(resolve_openclaw_profile_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
WORKTREE_BASE="$(resolve_worktree_base_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
PROJECT_ROOT="$(resolve_project_root_path "${PROJECT_REPO}" "${SCRIPT_DIR}")"
SUPERVISOR_WS="${WORKTREE_BASE}/supervisor-workspace"
CONTEXT_LIMIT="$(resolve_context_limit_for_profile "${OPENCLAW_PROFILE}")"

python3 - "${SCOPE_FILE}" "${PROJECT_ROOT}" "${SUPERVISOR_WS}" "${CONTEXT_LIMIT}" <<'PY'
from __future__ import annotations

import math
import sys
from pathlib import Path

import yaml

scope_path = Path(sys.argv[1])
project_root = Path(sys.argv[2])
supervisor_ws = Path(sys.argv[3])
context_limit = int(sys.argv[4])

scope = yaml.safe_load(scope_path.read_text(encoding="utf-8")) or {}
shared_files = [str(value) for value in (scope.get("advanced", {}).get("shared_files") or [])]

estimator_label = "chars/4"
try:
    import tiktoken  # type: ignore

    encoder = tiktoken.get_encoding("cl100k_base")
    estimator_label = "cl100k_base"
except Exception:
    encoder = None


def unique_existing(paths: list[Path]) -> list[Path]:
    seen: set[str] = set()
    output: list[Path] = []
    for path in paths:
        key = str(path)
        if key in seen or not path.is_file():
            continue
        seen.add(key)
        output.append(path)
    return output


def estimate_tokens(paths: list[Path]) -> int:
    text = "".join(path.read_text(encoding="utf-8") + "\n\n" for path in paths)
    if encoder is not None:
        return len(encoder.encode(text))
    return round(len(text) / 4)


def percent(tokens: int, limit: int) -> float:
    if limit <= 0:
        return 0.0
    return (tokens / limit) * 100


rows: list[tuple[str, str, int, int, float]] = []

supervisor_core = unique_existing([
    supervisor_ws / "SOUL.md",
    supervisor_ws / "ROSTER.md",
])
supervisor_with_shared = unique_existing(
    supervisor_core
    + [supervisor_ws / "PROJECT.md"]
    + [supervisor_ws / shared_file for shared_file in shared_files if shared_file != "PROJECT.md"]
)

rows.append(("supervisor", "core_loop", len(supervisor_core), estimate_tokens(supervisor_core), percent(estimate_tokens(supervisor_core), context_limit)))
rows.append(("supervisor", "with_shared", len(supervisor_with_shared), estimate_tokens(supervisor_with_shared), percent(estimate_tokens(supervisor_with_shared), context_limit)))

for agent in scope.get("agents", []) or []:
    agent_id = str(agent.get("id", "unknown"))
    agent_dir = project_root / ".fleetclaw" / "agents" / agent_id

    startup_paths = unique_existing([
        agent_dir / "SOUL.md",
        agent_dir / "BRIEF.md",
        agent_dir / "STATUS.md",
    ])
    with_shared_paths = unique_existing(
        startup_paths
        + [agent_dir / "PROJECT.md"]
        + [agent_dir / shared_file for shared_file in shared_files if shared_file != "PROJECT.md"]
    )

    startup_tokens = estimate_tokens(startup_paths)
    with_shared_tokens = estimate_tokens(with_shared_paths)
    rows.append((agent_id, "startup", len(startup_paths), startup_tokens, percent(startup_tokens, context_limit)))
    rows.append((agent_id, "with_shared", len(with_shared_paths), with_shared_tokens, percent(with_shared_tokens, context_limit)))

print("")
print(f"Estimated Markdown Budget (context limit: {context_limit}, estimator: {estimator_label})")
print("==============================================================")
print(f"{'ROLE':<22} {'READ SET':<14} {'FILES':>5} {'TOKENS':>10} {'USAGE':>8}")
print("--------------------------------------------------------------")
for role, read_set, file_count, tokens, pct in rows:
    print(f"{role:<22} {read_set:<14} {file_count:>5} {tokens:>10} {pct:>7.2f}%")

print("")
print("Read sets:")
print("  startup/core_loop = files explicitly named in the read order")
print("  with_shared = adds PROJECT.md plus advanced.shared_files present in the workspace")
PY
