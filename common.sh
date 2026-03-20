#!/usr/bin/env bash

if [[ -n "${FLEETCLAW_COMMON_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
FLEETCLAW_COMMON_SH_LOADED=1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FLEETCLAW_USING_YQ_FALLBACK=0
FLEETCLAW_USING_JQ_FALLBACK=0

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

require_cmds() {
    local missing=()
    local cmd

    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

python_yaml_available() {
    python3 - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("yaml") else 1)
PY
}

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

expand_path() {
    local raw_path="$1"
    if [[ "${raw_path}" == "~" || "${raw_path}" == ~/* ]]; then
        printf '%s\n' "${raw_path/#\~/$HOME}"
    else
        printf '%s\n' "${raw_path}"
    fi
}

resolve_scope_root() {
    local script_dir="$1"
    if [[ -f "${script_dir}/project-scope.example.yaml" ]]; then
        printf '%s\n' "${script_dir}"
    else
        printf '%s\n' "$(cd "${script_dir}/.." && pwd)"
    fi
}

resolve_openclaw_profile_from_scope() {
    local scope_file="$1"
    local project_name="${2:-$(yq eval '.project.name' "$scope_file")}"
    local project_slug
    local openclaw_profile

    project_slug="$(slugify "${project_name}")"
    openclaw_profile="$(yq eval ".advanced.openclaw_profile // \"${project_slug}\"" "$scope_file")"
    if [[ -z "${openclaw_profile}" || "${openclaw_profile}" == "null" ]]; then
        openclaw_profile="${project_slug}"
    fi
    printf '%s\n' "${openclaw_profile}"
}

resolve_worktree_base_from_scope() {
    local scope_file="$1"
    local project_name="${2:-$(yq eval '.project.name' "$scope_file")}"
    local worktree_base

    worktree_base="$(yq eval ".advanced.worktree_base // \"$HOME/.openclaw/projects/${project_name}\"" "$scope_file")"
    if [[ -z "${worktree_base}" || "${worktree_base}" == "null" ]]; then
        worktree_base="$HOME/.openclaw/projects/${project_name}"
    fi
    printf '%s\n' "${worktree_base}"
}

resolve_project_root_path() {
    local repo_source="$1"
    local script_dir="$2"

    if [[ -z "${repo_source}" || "${repo_source}" == "null" || "${repo_source}" == "." ]]; then
        repo_source="${script_dir}"
    fi

    repo_source="$(expand_path "${repo_source}")"
    if [[ "${repo_source}" != /* ]]; then
        repo_source="${script_dir}/${repo_source}"
    fi

    if [[ "${repo_source}" == "${script_dir}" ]]; then
        local parent_dir
        parent_dir="$(dirname "${script_dir}")"
        if [[ -d "${parent_dir}" ]]; then
            cd "${parent_dir}" && pwd
            return 0
        fi
    fi

    if [[ -d "${repo_source}" ]]; then
        cd "${repo_source}" && pwd
        return 0
    fi

    return 1
}

stable_project_slot() {
    python3 - "$1" <<'PY'
import hashlib
import sys

value = sys.argv[1].encode("utf-8")
digest = hashlib.sha1(value).hexdigest()
print(int(digest[:8], 16) % 400)
PY
}

resolve_dashboard_port_from_scope() {
    local scope_file="$1"
    local profile_name="${2:-$(resolve_openclaw_profile_from_scope "$scope_file")}"
    local gateway_port="${3:-}"
    local configured_port

    configured_port="$(yq eval '.advanced.dashboard_port // ""' "$scope_file")"
    if [[ -n "${configured_port}" && "${configured_port}" != "null" ]]; then
        printf '%s\n' "${configured_port}"
        return 0
    fi

    if [[ -n "${gateway_port}" && "${gateway_port}" != "null" ]]; then
        printf '%s\n' "$((gateway_port + 1))"
        return 0
    fi

    local slot
    slot="$(stable_project_slot "${profile_name}")"
    printf '%s\n' "$((19002 + slot * 20))"
}

resolve_context_limit_for_profile() {
    local profile_name="$1"
    local sessions_json
    local config_value
    local resolved_limit=""

    if command -v openclaw >/dev/null 2>&1; then
        sessions_json="$(openclaw --profile "${profile_name}" sessions --all-agents --json 2>/dev/null || true)"
        if [[ -n "${sessions_json}" ]]; then
            resolved_limit="$(python3 - "${sessions_json}" <<'PY'
import json
import sys

payload_raw = sys.argv[1]
if not payload_raw:
    raise SystemExit(0)

try:
    payload = json.loads(payload_raw)
except json.JSONDecodeError:
    raise SystemExit(0)

sessions = payload.get("sessions") if isinstance(payload, dict) else []
if not isinstance(sessions, list):
    raise SystemExit(0)

limits = []
for session in sessions:
    if not isinstance(session, dict):
        continue
    value = session.get("contextTokens")
    if isinstance(value, int) and value > 0:
        limits.append(value)

if limits:
    print(max(limits))
PY
)"
        fi

        if [[ -z "${resolved_limit}" ]]; then
            config_value="$(openclaw --profile "${profile_name}" config get agents.defaults.contextTokens --json 2>/dev/null || true)"
            if [[ -n "${config_value}" ]]; then
                resolved_limit="$(python3 - "${config_value}" <<'PY'
import json
import sys

raw = sys.argv[1]
if not raw:
    raise SystemExit(0)

try:
    value = json.loads(raw)
except json.JSONDecodeError:
    raise SystemExit(0)

if isinstance(value, int) and value > 0:
    print(value)
PY
)"
            fi
        fi
    fi

    if [[ -z "${resolved_limit}" ]]; then
        resolved_limit="200000"
    fi

    printf '%s\n' "${resolved_limit}"
}

detect_platform() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        FLEETCLAW_PLATFORM="macos"
        FLEETCLAW_DASHBOARD_HOST="127.0.0.1"
        FLEETCLAW_GATEWAY_BIND="loopback"
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        FLEETCLAW_PLATFORM="wsl"
        FLEETCLAW_DASHBOARD_HOST="localhost"
        FLEETCLAW_GATEWAY_BIND="loopback"
    elif [[ "$(uname -s)" == "Linux" ]]; then
        FLEETCLAW_PLATFORM="linux"
        FLEETCLAW_DASHBOARD_HOST="127.0.0.1"
        FLEETCLAW_GATEWAY_BIND="loopback"
    elif [[ "$(uname -s)" =~ MINGW|MSYS|CYGWIN ]]; then
        FLEETCLAW_PLATFORM="windows"
        FLEETCLAW_DASHBOARD_HOST="127.0.0.1"
        FLEETCLAW_GATEWAY_BIND="loopback"
    else
        FLEETCLAW_PLATFORM="unknown"
        FLEETCLAW_DASHBOARD_HOST="127.0.0.1"
        FLEETCLAW_GATEWAY_BIND="loopback"
    fi
}

enable_yq_fallback() {
    if command -v yq >/dev/null 2>&1; then
        return 0
    fi

    FLEETCLAW_USING_YQ_FALLBACK=1
    yq() {
        python3 - "$@" <<'PY'
import json
import re
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"PyYAML is required for the fallback yq implementation: {exc}")

args = sys.argv[1:]
if not args or args[0] != "eval":
    raise SystemExit("fallback yq only supports: yq eval [ -o=json ] <expr> <file>")

json_output = False
cursor = 1
if cursor < len(args) and args[cursor] == "-o=json":
    json_output = True
    cursor += 1

if len(args) - cursor != 2:
    raise SystemExit("fallback yq expects: yq eval [ -o=json ] <expr> <file>")

expr = args[cursor]
path = args[cursor + 1]
with open(path, "r", encoding="utf-8") as handle:
    data = yaml.safe_load(handle) or {}


def split_unquoted(text: str, sep: str) -> list[str]:
    parts = []
    current = []
    in_quote = False
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == '"':
            in_quote = not in_quote
            current.append(ch)
            i += 1
            continue
        if not in_quote and text.startswith(sep, i):
            parts.append("".join(current).strip())
            current = []
            i += len(sep)
            continue
        current.append(ch)
        i += 1
    parts.append("".join(current).strip())
    return parts


def lookup(node, token):
    if token == ".":
        return node
    if not token.startswith("."):
        raise KeyError(token)
    token = token[1:]
    if token == "":
        return node
    current = node
    for part in token.split("."):
        match = re.fullmatch(r"([^\[\]]+)(?:\[(\d+)\])?", part)
        if not match:
            raise KeyError(token)
        key = match.group(1)
        index = match.group(2)
        if not isinstance(current, dict) or key not in current:
            raise KeyError(token)
        current = current[key]
        if index is not None:
            idx = int(index)
            if not isinstance(current, list) or idx >= len(current):
                raise KeyError(token)
            current = current[idx]
    return current


def eval_term(node, term):
    term = term.strip()
    if term == "[]":
        return []
    if term == "empty":
        return None
    if term.startswith('"') and term.endswith('"'):
        return bytes(term[1:-1], "utf-8").decode("unicode_escape")
    return lookup(node, term)


def eval_base(node, base_expr):
    for term in split_unquoted(base_expr, "//"):
        try:
            value = eval_term(node, term)
        except KeyError:
            continue
        if value is not None:
            return value
    return None


parts = split_unquoted(expr, "|")
value = eval_base(data, parts[0])
emit_each = False
for part in parts[1:]:
    part = part.strip()
    if part == "length":
        value = len(value) if value is not None else 0
    elif part == ".[]":
        emit_each = True
    else:
        join_match = re.fullmatch(r'join\("(.+)"\)', part)
        if join_match:
            separator = bytes(join_match.group(1), "utf-8").decode("unicode_escape")
            value = separator.join(str(item) for item in (value or []))
        else:
            raise SystemExit(f"fallback yq does not support expression: {expr}")

if emit_each:
    for item in value or []:
        if isinstance(item, (dict, list)):
            print(json.dumps(item))
        elif isinstance(item, bool):
            print(str(item).lower())
        else:
            print(item)
    raise SystemExit(0)

if json_output:
    print(json.dumps(value))
elif isinstance(value, bool):
    print(str(value).lower())
elif value is None:
    print("null")
elif isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
    }
}

enable_jq_fallback() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi

    FLEETCLAW_USING_JQ_FALLBACK=1
    jq() {
        local stdin_payload
        stdin_payload="$(cat)"
        FLEETCLAW_JQ_STDIN="${stdin_payload}" python3 - "$@" <<'PY'
import json
import os
import sys

args = sys.argv[1:]
raw = False
if args and args[0] == "-r":
    raw = True
    args = args[1:]

if len(args) != 1:
    raise SystemExit("fallback jq only supports: jq [-r] '<filter>'")

filter_expr = args[0].strip()
payload = os.environ.get("FLEETCLAW_JQ_STDIN", "")
data = json.loads(payload) if payload else None

if filter_expr == '.every // empty':
    value = data.get("every") if isinstance(data, dict) else None
    if value not in (None, ""):
        print(value)
elif filter_expr == '.target // "none"':
    value = data.get("target") if isinstance(data, dict) else None
    print("none" if value in (None, "") else value)
elif filter_expr == 'keys[]?':
    if isinstance(data, dict):
        for key in data.keys():
            print(key)
elif filter_expr == 'if type == "string" then\n            .\n        elif type == "object" then\n            [.primary, (.fallbacks[]?)] | .[]\n        else\n            empty\n        end':
    if isinstance(data, str):
        print(data)
    elif isinstance(data, dict):
        primary = data.get("primary")
        fallbacks = data.get("fallbacks") or []
        for value in [primary, *fallbacks]:
            if value:
                print(value)
elif filter_expr == '.[] | [.agentId // "main", (.totalTokens // 0 | tostring), (.contextTokens // 200000 | tostring), .key] | @tsv':
    if isinstance(data, list):
        for item in data:
            if not isinstance(item, dict):
                continue
            row = [
                item.get("agentId") or "main",
                str(item.get("totalTokens") or 0),
                str(item.get("contextTokens") or 200000),
                "" if item.get("key") is None else str(item.get("key")),
            ]
            print("\t".join(row))
else:
    raise SystemExit(f"fallback jq does not support filter: {filter_expr}")
PY
    }
}
