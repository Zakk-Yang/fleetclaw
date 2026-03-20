#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# FleetClaw — Setup Script
# Reads project-scope.yaml and bootstraps:
#   - OpenClaw agents (supervisor + N coders)
#   - Per-agent config in .fleetclaw/agents/<id>/
#   - Supervisor cron jobs
#   - Workspace files (SOUL.md, PROJECT.md, MEMORY.md)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

python_yaml_available() {
    python3 - <<'PY' >/dev/null 2>&1
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("yaml") else 1)
PY
}

if ! command -v yq &>/dev/null; then
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
fi

if ! command -v jq &>/dev/null; then
    jq() {
        python3 - "$@" <<'PY'
import json
import sys

args = sys.argv[1:]
raw = False
if args and args[0] == "-r":
    raw = True
    args = args[1:]

if len(args) != 1:
    raise SystemExit("fallback jq only supports: jq [-r] '<filter>'")

filter_expr = args[0].strip()
data = json.load(sys.stdin)

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
else:
    raise SystemExit(f"fallback jq does not support filter: {filter_expr}")
PY
    }
fi

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

# --- Prerequisites ---
check_deps() {
    local missing=()
    command -v openclaw &>/dev/null || missing+=("openclaw")
    command -v git      &>/dev/null || missing+=("git")
    command -v python3  &>/dev/null || missing+=("python3")
    python_yaml_available || missing+=("python3 yaml module (PyYAML)")

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing dependencies: ${missing[*]}"
        echo "Install them and re-run this script."
        exit 1
    fi
    if ! command -v yq &>/dev/null; then
        warn "yq not found; using built-in Python fallback"
    fi
    if ! command -v jq &>/dev/null; then
        warn "jq not found; using built-in Python fallback"
    fi
    log "All dependencies found"
}

# --- Read scope file ---
read_scope() {
    if [[ ! -f "$SCOPE_FILE" ]]; then
        err "project-scope.yaml not found."
        echo "Run: cp project-scope.example.yaml project-scope.yaml"
        echo "Then edit project-scope.yaml with your project details."
        exit 1
    fi
    log "Reading project-scope.yaml"
}

# --- Helper: read yaml values ---
yval() { yq eval "$1" "$SCOPE_FILE"; }
yval_default() { yq eval "$1 // \"$2\"" "$SCOPE_FILE"; }

expand_path() {
    local raw_path="$1"
    if [[ "${raw_path}" == "~" || "${raw_path}" == ~/* ]]; then
        printf '%s\n' "${raw_path/#\~/$HOME}"
    else
        printf '%s\n' "${raw_path}"
    fi
}

resolve_local_repo_path() {
    local repo_source="$1"
    local expanded_path

    if [[ -z "${repo_source}" || "${repo_source}" == "null" || "${repo_source}" == "." ]]; then
        repo_source="${SCRIPT_DIR}"
    fi

    repo_source="$(expand_path "${repo_source}")"
    if [[ "${repo_source}" != /* ]]; then
        repo_source="${SCRIPT_DIR}/${repo_source}"
    fi

    # If the resolved path IS the fleetclaw directory (a subdirectory of the
    # actual project), prefer the parent directory as the project repo.
    # This way agent worktrees are checkouts of the project, and focus_dirs
    # like "sentiment-dashboard/" resolve relative to the project root.
    if [[ "${repo_source}" == "${SCRIPT_DIR}" ]]; then
        local parent_dir
        parent_dir="$(dirname "${SCRIPT_DIR}")"

        if git -C "${parent_dir}" rev-parse --show-toplevel >/dev/null 2>&1; then
            # Parent is already a git repo — use it
            git -C "${parent_dir}" rev-parse --show-toplevel
            return 0
        elif [[ -d "${parent_dir}" ]]; then
            # Parent exists but is not a git repo — initialize one so
            # worktrees, diffs, and commits work for the project root
            echo -e "${BLUE}[i]${NC} Initializing git repo in project root: ${parent_dir}" >&2
            git -C "${parent_dir}" init -q
            git -C "${parent_dir}" add -A 2>/dev/null || true
            git -C "${parent_dir}" commit -q -m "FleetClaw: initialize project repo" 2>/dev/null || true
            printf '%s\n' "${parent_dir}"
            return 0
        fi
    fi

    if git -C "${repo_source}" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "${repo_source}" rev-parse --show-toplevel
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

derive_gateway_port() {
    local profile_name="$1"
    local configured_port="$2"

    if [[ -n "${configured_port}" && "${configured_port}" != "null" ]]; then
        printf '%s\n' "${configured_port}"
        return 0
    fi

    local slot
    slot="$(stable_project_slot "${profile_name}")"
    printf '%s\n' "$((19001 + slot * 20))"
}

generate_gateway_token() {
    python3 - <<'PY'
import secrets

print(secrets.token_hex(24))
PY
}

resolve_main_auth_profiles_json() {
    local auth_profiles_json
    auth_profiles_json="$(openclaw config get auth.profiles --json 2>/dev/null || true)"

    if [[ -n "${auth_profiles_json}" && "${auth_profiles_json}" != "null" && "${auth_profiles_json}" != "{}" ]]; then
        printf '%s\n' "${auth_profiles_json}"
    else
        printf 'null\n'
    fi
}

resolve_model_json() {
    local expr="$1"
    yq eval -o=json "${expr}" "$SCOPE_FILE"
}

resolve_model_label() {
    local expr="$1"
    yq eval "${expr}" "$SCOPE_FILE"
}

resolve_thinking_level() {
    local expr="$1"
    local default_value="${2:-}"
    yq eval "${expr} // \"${default_value}\"" "$SCOPE_FILE"
}

model_refs_from_json() {
    local model_json="$1"
    python3 - "${model_json}" <<'PY'
import json
import sys

model = json.loads(sys.argv[1])
if isinstance(model, str):
    print(model)
elif isinstance(model, dict):
    primary = model.get("primary")
    fallbacks = model.get("fallbacks") or []
    for value in [primary, *fallbacks]:
        if value:
            print(value)
PY
}

collect_required_models() {
    local agent_model_json
    local i

    model_refs_from_json "${SUPERVISOR_MODEL_JSON}"

    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        agent_model_json=$(resolve_model_json ".agents[$i].model // .advanced.default_agent_model // \"openai-codex/gpt-5.4\"")
        model_refs_from_json "${agent_model_json}"
    done | awk 'NF' | sort -u
}

warn_for_openclaw_inheritance() {
    local heartbeat_json existing_models_json heartbeat_every heartbeat_target
    local required_models existing_model_keys missing_models

    heartbeat_json="$(openclaw config get agents.defaults.heartbeat --json 2>/dev/null || true)"
    if [[ -n "${heartbeat_json}" && "${heartbeat_json}" != "null" ]]; then
        heartbeat_every="$(python3 - "${heartbeat_json}" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
value = data.get("every") if isinstance(data, dict) else None
if value not in (None, ""):
    print(value)
PY
)"
        heartbeat_target="$(python3 - "${heartbeat_json}" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
value = data.get("target") if isinstance(data, dict) else None
print("none" if value in (None, "") else value)
PY
)"

        if [[ -n "${heartbeat_every}" && "${heartbeat_every}" != "0" && "${heartbeat_every}" != "0m" ]]; then
            warn "OpenClaw global heartbeat is enabled (${heartbeat_every}, target=${heartbeat_target}). FleetClaw agents inherit agents.defaults.heartbeat unless you override it in your main OpenClaw config."
        fi
    fi

    existing_models_json="$(openclaw config get agents.defaults.models --json 2>/dev/null || true)"
    if [[ -n "${existing_models_json}" && "${existing_models_json}" != "null" && "${existing_models_json}" != "{}" ]]; then
        required_models="$(collect_required_models)"
        existing_model_keys="$(python3 - "${existing_models_json}" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
if isinstance(data, dict):
    for key in data.keys():
        print(key)
PY
)"
        missing_models="$(comm -23 <(printf '%s\n' "${required_models}" | awk 'NF' | sort -u) <(printf '%s\n' "${existing_model_keys}" | awk 'NF' | sort -u))"

        if [[ -n "${missing_models}" ]]; then
            warn "OpenClaw uses agents.defaults.models as a model allowlist/catalog. Add these FleetClaw models before merging:"
            while IFS= read -r model_ref; do
                [[ -n "${model_ref}" ]] && warn "  - ${model_ref}"
            done <<< "${missing_models}"
        fi
    fi
}

warn_for_unsupported_scope() {
    local unsupported=()

    if [[ "$(yq eval '.advanced.extra_skills // [] | length' "$SCOPE_FILE")" != "0" ]]; then
        unsupported+=("advanced.extra_skills")
    fi

    if [[ "$(yq eval '.advanced.max_budget_per_agent_usd // ""' "$SCOPE_FILE")" != "" ]]; then
        unsupported+=("advanced.max_budget_per_agent_usd")
    fi

    if [[ "$(yq eval '.advanced.supervisor_model_for_heartbeat // ""' "$SCOPE_FILE")" != "" ]]; then
        unsupported+=("advanced.supervisor_model_for_heartbeat")
    fi

    if [[ ${#unsupported[@]} -gt 0 ]]; then
        warn "Unsupported scope keys will be ignored: ${unsupported[*]}"
    fi
}

copy_shared_files() {
    local workspace_path="$1"
    local shared_file source_path target_path

    mkdir -p "${workspace_path}/memory"
    cp "${PROJECT_MD}" "${workspace_path}/PROJECT.md"
    if [[ -n "${MEMORY_MD:-}" && -f "${MEMORY_MD}" && ! -f "${workspace_path}/MEMORY.md" ]]; then
        cp "${MEMORY_MD}" "${workspace_path}/MEMORY.md"
    fi

    while IFS= read -r shared_file; do
        [[ -z "${shared_file}" || "${shared_file}" == "PROJECT.md" ]] && continue

        source_path=""
        if [[ -f "${SCRIPT_DIR}/${shared_file}" ]]; then
            source_path="${SCRIPT_DIR}/${shared_file}"
        elif [[ -f "${SCRIPT_DIR}/generated/${shared_file}" ]]; then
            source_path="${SCRIPT_DIR}/generated/${shared_file}"
        fi

        if [[ -z "${source_path}" ]]; then
            warn "Shared file ${shared_file} not found relative to ${SCRIPT_DIR}, skipping"
            continue
        fi

        target_path="${workspace_path}/${shared_file}"
        mkdir -p "$(dirname "${target_path}")"
        cp "${source_path}" "${target_path}"
    done < <(yq eval '.advanced.shared_files // [] | .[]' "$SCOPE_FILE")
}

agent_runtime_id() {
    local agent_id="$1"
    printf '%s-%s\n' "${PROJECT_SLUG}" "${agent_id}"
}

seed_profile_agent_state() {
    local runtime_agent_id="$1"
    local target_agent_dir="${PROFILE_ROOT}/agents/${runtime_agent_id}/agent"
    local file target_path candidate

    mkdir -p "${target_agent_dir}"

    for file in auth-profiles.json models.json; do
        target_path="${target_agent_dir}/${file}"
        [[ -f "${target_path}" ]] && continue

        for candidate in \
            "${HOME}/.openclaw/agents/${runtime_agent_id}/agent/${file}" \
            "${HOME}/.openclaw/agents/main/agent/${file}"; do
            if [[ -f "${candidate}" ]]; then
                cp "${candidate}" "${target_path}"
                log "Seeded ${runtime_agent_id} ${file}"
                break
            fi
        done
    done
}

# --- Main setup ---
main() {
    echo ""
    echo "=========================================="
    echo "  🦞 FleetClaw — Setup"
    echo "=========================================="
    echo ""

    check_deps
    read_scope
    warn_for_unsupported_scope

    # --- Parse project config ---
    PROJECT_NAME=$(yval '.project.name')
    PROJECT_REPO=$(yval '.project.repo')
    PROJECT_BRANCH=$(yval_default '.project.branch' 'main')
    PROJECT_DESC=$(yval '.project.description')

    SUPERVISOR_MODEL_JSON=$(resolve_model_json '.supervisor.model // "anthropic/claude-sonnet-4-6"')
    SUPERVISOR_MODEL_LABEL=$(resolve_model_label '.supervisor.model.primary // .supervisor.model // "anthropic/claude-sonnet-4-6"')
    SUPERVISOR_THINKING=$(resolve_thinking_level '.supervisor.thinking' '')
    CHECK_INTERVAL=$(yval_default '.supervisor.check_interval_mins' '10')
    COMPACT_THRESHOLD=$(yval_default '.supervisor.context_compact_threshold' '70')
    STALL_TIMEOUT=$(yval_default '.supervisor.stall_timeout_mins' '20')
    REVIEW_CHECKPOINT_MINS=$(yval_default '.supervisor.review_checkpoint_mins' '20')
    MAX_COMMITS_WITHOUT_DECISION=$(yval_default '.supervisor.max_commits_without_decision' '3')
    NOTIFY_CHANNEL=$(yval_default '.supervisor.notify_channel' '')
    NOTIFY_TARGET=$(yval_default '.supervisor.notify_target' '')
    REPORT_HOUR=$(yval_default '.supervisor.morning_report_hour' '8')
    REPORT_TZ=$(yval_default '.supervisor.morning_report_tz' 'Europe/London')

    AGENT_COUNT=$(yq eval '.agents | length' "$SCOPE_FILE")
    WORKTREE_BASE=$(yval_default '.advanced.worktree_base' "$HOME/.openclaw/projects/${PROJECT_NAME}")
    if [[ -z "${WORKTREE_BASE}" || "${WORKTREE_BASE}" == "null" ]]; then
        WORKTREE_BASE="$HOME/.openclaw/projects/${PROJECT_NAME}"
    fi
    PROJECT_SLUG=$(slugify "${PROJECT_NAME}")
    PROJECT_PROFILE_RAW=$(yval_default '.advanced.openclaw_profile' '')
    if [[ -z "${PROJECT_PROFILE_RAW}" || "${PROJECT_PROFILE_RAW}" == "null" ]]; then
        PROJECT_PROFILE="${PROJECT_SLUG}"
    else
        PROJECT_PROFILE="$(slugify "${PROJECT_PROFILE_RAW}")"
    fi
    if [[ -z "${PROJECT_PROFILE}" ]]; then
        PROJECT_PROFILE="${PROJECT_SLUG}"
    fi
    PROFILE_ROOT="${HOME}/.openclaw-${PROJECT_PROFILE}"
    PROFILE_CONFIG_PATH="${PROFILE_ROOT}/openclaw.json"
    PROFILE_GATEWAY_PORT="$(derive_gateway_port "${PROJECT_PROFILE}" "$(yval_default '.advanced.gateway_port' '')")"
    PROFILE_GATEWAY_TOKEN="$(generate_gateway_token)"
    PROFILE_AUTH_PROFILES_JSON="$(resolve_main_auth_profiles_json)"
    PROGRESS_CRON_NAME="${PROJECT_SLUG}-supervisor-progress-check"
    MORNING_CRON_NAME="${PROJECT_SLUG}-supervisor-morning-report"
    CONFIG_THINKING_DEFAULT=""
    THINKING_VALUES=""

    if [[ -n "${SUPERVISOR_THINKING}" && "${SUPERVISOR_THINKING}" != "null" ]]; then
        THINKING_VALUES+=$'\n'"${SUPERVISOR_THINKING}"
    fi
    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_THINKING_VALUE=$(resolve_thinking_level ".agents[$i].thinking // .advanced.default_agent_thinking" '')
        if [[ -n "${AGENT_THINKING_VALUE}" && "${AGENT_THINKING_VALUE}" != "null" ]]; then
            THINKING_VALUES+=$'\n'"${AGENT_THINKING_VALUE}"
        fi
    done

    UNIQUE_THINKING_VALUES="$(printf '%s\n' "${THINKING_VALUES}" | awk 'NF' | sort -u)"
    UNIQUE_THINKING_COUNT="$(printf '%s\n' "${UNIQUE_THINKING_VALUES}" | awk 'NF' | wc -l | tr -d ' ')"
    if [[ "${UNIQUE_THINKING_COUNT}" == "1" ]]; then
        CONFIG_THINKING_DEFAULT="$(printf '%s\n' "${UNIQUE_THINKING_VALUES}" | awk 'NF { print; exit }')"
    elif [[ "${UNIQUE_THINKING_COUNT}" -gt 1 ]]; then
        warn "OpenClaw config only supports a shared agents.defaults.thinkingDefault. FleetClaw will keep per-run thinking in generated cron and kickoff commands instead of writing conflicting per-agent defaults."
    fi

    if [[ "${PROFILE_AUTH_PROFILES_JSON}" == "null" ]]; then
        warn "No auth.profiles block was found in the default OpenClaw config. The dedicated FleetClaw profile will be generated without provider auth mappings."
    fi

    info "Project: ${PROJECT_NAME} (${AGENT_COUNT} coding agents)"
    info "OpenClaw profile: ${PROJECT_PROFILE}"
    info "Supervisor: ${SUPERVISOR_MODEL_LABEL} checking every ${CHECK_INTERVAL}m"
    info "Compact threshold: ${COMPACT_THRESHOLD}%"
    info "Review checkpoints: ${REVIEW_CHECKPOINT_MINS}m or ${MAX_COMMITS_WITHOUT_DECISION} commits"
    info "Worktree base: ${WORKTREE_BASE}"
    info "Profile state dir: ${PROFILE_ROOT}"
    info "Profile gateway port: ${PROFILE_GATEWAY_PORT}"
    echo ""

    # --- Resolve project repo source ---
    mkdir -p "${WORKTREE_BASE}"
    if REPO_DIR="$(resolve_local_repo_path "${PROJECT_REPO}")"; then
        log "Using local repo at ${REPO_DIR}"
        cd "${REPO_DIR}"
    else
        REPO_DIR="${WORKTREE_BASE}/repo"
        if [[ ! -d "${REPO_DIR}/.git" ]]; then
            log "Cloning ${PROJECT_REPO} → ${REPO_DIR}"
            git clone "${PROJECT_REPO}" "${REPO_DIR}"
            cd "${REPO_DIR}"
        else
            log "Repo already cloned at ${REPO_DIR}"
            cd "${REPO_DIR}"
            git fetch origin
        fi
    fi

    if git rev-parse --verify "${PROJECT_BRANCH}" >/dev/null 2>&1; then
        :
    elif git rev-parse --verify "origin/${PROJECT_BRANCH}" >/dev/null 2>&1; then
        log "Creating local branch ${PROJECT_BRANCH} from origin/${PROJECT_BRANCH}"
        git branch "${PROJECT_BRANCH}" "origin/${PROJECT_BRANCH}" >/dev/null 2>&1 || true
    elif git rev-parse --verify "refs/remotes/origin/${PROJECT_BRANCH}" >/dev/null 2>&1; then
        log "Creating local branch ${PROJECT_BRANCH} from origin/${PROJECT_BRANCH}"
        git branch "${PROJECT_BRANCH}" "origin/${PROJECT_BRANCH}" >/dev/null 2>&1 || true
    else
        err "Base branch '${PROJECT_BRANCH}' was not found in ${REPO_DIR}"
        exit 1
    fi

    # --- Create per-agent directories in project root ---
    FLEETCLAW_AGENTS_DIR="${REPO_DIR}/.fleetclaw/agents"
    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
        AGENT_DIR="${FLEETCLAW_AGENTS_DIR}/${AGENT_ID}"
        mkdir -p "${AGENT_DIR}/memory"
        log "Created agent directory: .fleetclaw/agents/${AGENT_ID}"
    done

    # --- Generate PROJECT.md (shared context for all agents) ---
    PROJECT_MD="${SCRIPT_DIR}/generated/PROJECT.md"
    mkdir -p "${SCRIPT_DIR}/generated"

    cat > "${PROJECT_MD}" << PROJECTEOF
# Project: ${PROJECT_NAME}

## Description
${PROJECT_DESC}

## Repository
- Repo: ${PROJECT_REPO}
- Base branch: ${PROJECT_BRANCH}

## Team Overview
PROJECTEOF

    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
        AGENT_TASK=$(yq eval ".agents[$i].task" "$SCOPE_FILE")
        FOCUS=$(yq eval ".agents[$i].focus_dirs | join(\", \")" "$SCOPE_FILE")
        AGENT_TASK_SUMMARY="$(printf '%s\n' "${AGENT_TASK}" | awk 'NF { print; exit }')"
        cat >> "${PROJECT_MD}" << AGENTEOF

### ${AGENT_ID}
- **Focus directories:** ${FOCUS}
- **Goal:** ${AGENT_TASK_SUMMARY}
AGENTEOF
    done

    log "Generated PROJECT.md"

    # --- Generate shared MEMORY.md template ---
    MEMORY_MD="${SCRIPT_DIR}/generated/MEMORY.md"
    cat > "${MEMORY_MD}" << MEMORYEOF
# MEMORY.md

Durable project memory for ${PROJECT_NAME}.

Use this file for facts worth keeping across sessions and days.
Do not use it as a running log.

## Durable Decisions
- None yet.

## Conventions And Preferences
- None yet.

## Known Risks And Watchouts
- None yet.

## Reusable Lessons
- None yet.
MEMORYEOF

    log "Generated MEMORY.md"

    # --- Generate shared ROSTER.md for supervisor lookups ---
    ROSTER_MD="${SCRIPT_DIR}/generated/ROSTER.md"
    AGENT_ID_LIST=""
    cat > "${ROSTER_MD}" << ROSTEREOF
# ROSTER.md

Fleet map for ${PROJECT_NAME}.

Use this file when you need to look up an agent's workspace, focus dirs, or task summary.
Do not treat it as a file to reread on every turn.
ROSTEREOF

    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
        AGENT_TASK=$(yq eval ".agents[$i].task" "$SCOPE_FILE")
        AGENT_TASK_SUMMARY="$(printf '%s\n' "${AGENT_TASK}" | awk 'NF { print; exit }')"
        FOCUS=$(yq eval ".agents[$i].focus_dirs | join(\", \")" "$SCOPE_FILE")
        RUNTIME_AGENT_ID="$(agent_runtime_id "${AGENT_ID}")"
        PRIMARY_SESSION_KEY="agent:${RUNTIME_AGENT_ID}:main"

        if [[ -n "${AGENT_ID_LIST}" ]]; then
            AGENT_ID_LIST+=", "
        fi
        AGENT_ID_LIST+="${AGENT_ID}"

        cat >> "${ROSTER_MD}" << ROSTERAGENTEOF

## ${AGENT_ID}
- Runtime agent id: ${RUNTIME_AGENT_ID}
- Primary session key: \`${PRIMARY_SESSION_KEY}\`
- Workspace: ${REPO_DIR}
- Agent config dir: .fleetclaw/agents/${AGENT_ID}
- Focus: ${FOCUS}
- Task summary: ${AGENT_TASK_SUMMARY}
- Status file: \`.fleetclaw/agents/${AGENT_ID}/STATUS.md\`
- Git diff: \`git diff --stat\`
- Recent commits: \`git log --oneline -5\`
ROSTERAGENTEOF
    done

    log "Generated ROSTER.md"

    # --- Generate Supervisor SOUL.md ---
    SUPERVISOR_SOUL="${SCRIPT_DIR}/generated/supervisor-SOUL.md"
    cat > "${SUPERVISOR_SOUL}" << SOULEOF
# Supervisor Agent — ${PROJECT_NAME}

You are a development supervisor managing ${AGENT_COUNT} coding agents working on "${PROJECT_NAME}".

## Fleet Layout
- Project root: ${REPO_DIR}
- Agent ids: ${AGENT_ID_LIST}
- Agent config path pattern: .fleetclaw/agents/<agent-id>/
- All agents work directly in the project root directory
- Read \`ROSTER.md\` only when you need focus directories, task summaries, runtime agent ids, or session keys.

## Core Loop (runs every ${CHECK_INTERVAL} minutes)

For EACH coding agent in the fleet:

1. **Read STATUS.md first** — treat it as the agent's checkpoint and request-for-decision file
2. **Use git diff and recent commits** — inspect only the changed surface first
3. **Check the coding agent main session first** — copy the exact \`Primary session key:\` value from \`ROSTER.md\` and use that exact string with \`session_status\`; do not shorten it or infer it from the short agent id
4. **Use memory_search / memory_get only if historical notes are needed** — do not reread full daily logs by default
5. **Read ROSTER.md or PROJECT.md only if the current checkpoint is ambiguous or you need runtime session metadata**
6. **Evaluate progress** — is the agent making meaningful progress on its task?
7. **Take action if needed:**
   - No changes for ${STALL_TIMEOUT}+ minutes → agent is STALLED. Diagnose: read recent files, check for error patterns, then send corrective instructions via sessions_send
   - Context usage > ${COMPACT_THRESHOLD}% → send \`/compact\` to the agent's session
   - Agent working on wrong files (outside focus_dirs) → redirect with specific instructions
   - Agent in a loop (same diff repeated) → send clear redirect with alternative approach
   - STATUS.md says \`Needs supervisor decision: yes\` → send a decision before the agent continues
   - Agent has worked for roughly ${REVIEW_CHECKPOINT_MINS}+ minutes or ${MAX_COMMITS_WITHOUT_DECISION}+ commits without a fresh decision request → require a fresh checkpoint update

## Decision Protocol

When an agent requests a decision, reply via sessions_send with exactly one leading decision token:

- \`SUPERVISOR_DECISION: CONTINUE\`
- \`SUPERVISOR_DECISION: REDIRECT\`
- \`SUPERVISOR_DECISION: STOP\`
- \`SUPERVISOR_DECISION: ACCEPT_DONE\`
- \`SUPERVISOR_DECISION: ESCALATE\`

Then include 1-3 concise bullets with the reasoning and next action.

Use the decisions like this:

- \`CONTINUE\` → current direction is acceptable, keep going
- \`REDIRECT\` → change scope, ordering, or approach
- \`STOP\` → pause implementation now
- \`ACCEPT_DONE\` → work is accepted as complete for now
- \`ESCALATE\` → human decision is required

If STATUS.md says \`State: done\`, verify the diff/tests before sending \`ACCEPT_DONE\`.

## Agent Status Format

Each coding agent maintains a \`STATUS.md\` file with this shape:

\`\`\`markdown
# STATUS.md
State: working | blocked | ready-for-review | done
Needs supervisor decision: no | yes
Requested decision: none | continue | redirect | stop | accept_done
Summary: ...
Files touched: ...
Tests: not run | passing | failing
Next step: ...
Blocker: none | ...
Last updated: YYYY-MM-DD HH:MM
\`\`\`

## Memory Policy

- \`STATUS.md\` is the latest live checkpoint only. Expect it to be overwritten.
- \`memory/YYYY-MM-DD.md\` is the historical day log. Search it with \`memory_search\`, then inspect the relevant note with \`memory_get\`.
- \`MEMORY.md\` is for durable facts, conventions, risks, and accepted decisions that should survive beyond the current day.
- Do not reread full daily logs unless a search result points you there.
- When you intervene or make a durable supervision decision, append a short dated note to \`memory/YYYY-MM-DD.md\`.
- Promote only lasting guidance or reusable lessons into \`MEMORY.md\`.

## Rules
- Do NOT write code yourself. You are a supervisor, not a coder.
- Be specific when sending instructions to agents. Include file paths, function names, and concrete next steps.
- Copy the coding agent's \`Primary session key:\` value from \`ROSTER.md\` verbatim for \`session_status\` and \`sessions_send\`.
- Never derive a session key from the short agent id or task summary; \`ROSTER.md\` is authoritative.
- If \`sessions_list\` does not show the coding agent, do not assume the agent is unreachable — use the explicit primary session key from \`ROSTER.md\`.
- Use \`openclaw sessions --all-agents --json\` via \`exec\` only as a fallback when you need raw cross-agent session metadata.
- If an agent is stuck on the same problem after 2 interventions, escalate: write a detailed blocker note and notify the human.
- Keep your own context lean — you should rarely need compaction.
SOULEOF

    log "Generated supervisor SOUL.md"

    # --- Generate per-agent SOUL.md ---
    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
        AGENT_TASK=$(yq eval ".agents[$i].task" "$SCOPE_FILE")
        FOCUS=$(yq eval ".agents[$i].focus_dirs | join(\", \")" "$SCOPE_FILE")

        AGENT_BRIEF="${SCRIPT_DIR}/generated/${AGENT_ID}-BRIEF.md"
        cat > "${AGENT_BRIEF}" << BRIEFEOF
# BRIEF.md

Agent: ${AGENT_ID}
Project: ${PROJECT_NAME}

## Your Task
${AGENT_TASK}

## Focus Directories
${FOCUS}

## Read Order
1. Read \`.fleetclaw/agents/${AGENT_ID}/SOUL.md\` on session start or after compaction.
2. Read \`.fleetclaw/agents/${AGENT_ID}/BRIEF.md\` for your exact assignment and scope.
3. Read \`.fleetclaw/agents/${AGENT_ID}/STATUS.md\` for the latest checkpoint.
4. Read \`.fleetclaw/agents/${AGENT_ID}/PROJECT.md\` only when you need shared project context or another agent's lane.
5. Use \`memory_search\` / \`memory_get\` for older notes instead of rereading full daily logs.
BRIEFEOF

        log "Generated ${AGENT_ID} BRIEF.md"

        AGENT_SOUL="${SCRIPT_DIR}/generated/${AGENT_ID}-SOUL.md"
        cat > "${AGENT_SOUL}" << CODERSOULEOF
# Agent: ${AGENT_ID}
# Project: ${PROJECT_NAME}

You are a coding agent working on "${PROJECT_NAME}".

## Your Task
${AGENT_TASK}

## Constraints
- Only modify files in your focus directories: ${FOCUS}
- Do NOT modify files outside your scope — other agents own those
- Commit frequently with descriptive messages prefixed with [${AGENT_ID}]
- If you encounter a dependency on another agent's work, write a note to BLOCKERS.md and continue with a stub/mock
- Read BRIEF.md for your exact scope; read PROJECT.md only when you need wider project context
- Keep \`.fleetclaw/agents/${AGENT_ID}/STATUS.md\` current; the supervisor uses it to accept, redirect, or stop your work

## Your Config Directory
Your agent-specific files are in: \`.fleetclaw/agents/${AGENT_ID}/\`
- STATUS.md, BRIEF.md, MEMORY.md, memory/ are all there
- You work directly in the project root, creating files in your focus directories

## Workflow
1. Read \`.fleetclaw/agents/${AGENT_ID}/BRIEF.md\`, then \`.fleetclaw/agents/${AGENT_ID}/STATUS.md\`; skim MEMORY.md only if durable past decisions matter
2. Plan your approach — write it to \`.fleetclaw/agents/${AGENT_ID}/PLAN.md\`
3. Implement incrementally in your focus directories (${FOCUS}), committing after each logical unit
4. After each logical unit, refresh \`.fleetclaw/agents/${AGENT_ID}/STATUS.md\` with the latest short factual checkpoint only
5. Run tests after each significant change
6. Use memory_search / memory_get to retrieve old notes instead of rereading full memory/YYYY-MM-DD.md files
7. If a stop rule triggers, update STATUS.md, request a decision, and stop active implementation until the supervisor responds

## Memory Policy
- \`.fleetclaw/agents/${AGENT_ID}/STATUS.md\` is current-state only. Keep only the latest checkpoint there.
- \`.fleetclaw/agents/${AGENT_ID}/memory/YYYY-MM-DD.md\` is a historical log for dated notes, dead ends, and short summaries of important work.
- \`.fleetclaw/agents/${AGENT_ID}/MEMORY.md\` is for durable facts, conventions, accepted decisions, and reusable lessons.
- Do not reread full daily logs by default. Search old notes with \`memory_search\`, then inspect the relevant note with \`memory_get\`.
- When you finish a meaningful chunk, add a brief dated memory note if future-you or the supervisor will need the history.
- When you discover something that should survive beyond the day, update \`MEMORY.md\`.

## Communication
- The supervisor checks your progress every ${CHECK_INTERVAL} minutes via git diff
- If the supervisor sends you instructions, prioritize them
- Write blockers to BLOCKERS.md so the supervisor can help
- Supervisor decisions arrive with one of these leading tokens:
  - \`SUPERVISOR_DECISION: CONTINUE\`
  - \`SUPERVISOR_DECISION: REDIRECT\`
  - \`SUPERVISOR_DECISION: STOP\`
  - \`SUPERVISOR_DECISION: ACCEPT_DONE\`
  - \`SUPERVISOR_DECISION: ESCALATE\`

## STATUS.md Format
\`\`\`markdown
# STATUS.md
State: working | blocked | ready-for-review | done
Needs supervisor decision: no | yes
Requested decision: none | continue | redirect | stop | accept_done
Summary: ...
Files touched: ...
Tests: not run | passing | failing
Next step: ...
Blocker: none | ...
Last updated: YYYY-MM-DD HH:MM
\`\`\`

## Stop Rules
Stop and request a supervisor decision when ANY of these happen:

1. You believe the current task is complete or ready for acceptance
2. You have made about ${MAX_COMMITS_WITHOUT_DECISION} commits or worked about ${REVIEW_CHECKPOINT_MINS} minutes since the last supervisor decision
3. You need to go outside your focus directories or make a risky architecture change
4. You are blocked by failing tests, unclear requirements, or repeated rework

When a stop rule triggers:

1. Update STATUS.md
2. Set \`Needs supervisor decision: yes\`
3. Set \`Requested decision:\` to the closest match
4. Stop active implementation and wait for the supervisor
CODERSOULEOF

        log "Generated ${AGENT_ID} SOUL.md"

        AGENT_STATUS="${SCRIPT_DIR}/generated/${AGENT_ID}-STATUS.md"
        cat > "${AGENT_STATUS}" << STATUSEOF
# STATUS.md
State: working
Needs supervisor decision: no
Requested decision: none
Summary: Not started yet.
Files touched: none
Tests: not run
Next step: Read PROJECT.md, write PLAN.md, and start the first logical unit.
Blocker: none
Last updated: $(date '+%Y-%m-%d %H:%M')
STATUSEOF

        log "Generated ${AGENT_ID} STATUS.md"
    done

    # --- Generate openclaw.json patch ---
    CONFIG_PATCH="${SCRIPT_DIR}/generated/openclaw-config.json5"
    CRON_INSTALL_SH="${SCRIPT_DIR}/generated/openclaw-cron.sh"

    # Build agents list JSON
    AGENTS_JSON="["
    FLEET_AGENT_RUNTIME_IDS_JSON="[\"$(agent_runtime_id "supervisor")\""
    # Supervisor
    AGENTS_JSON+="{
      \"id\": \"$(agent_runtime_id "supervisor")\",
      \"name\": \"${PROJECT_NAME} Supervisor\",
      \"workspace\": \"${WORKTREE_BASE}/supervisor-workspace\",
      \"agentDir\": \"${PROFILE_ROOT}/agents/$(agent_runtime_id "supervisor")/agent\",
      \"model\": ${SUPERVISOR_MODEL_JSON},
      \"tools\": {
        \"allow\": [\"read\", \"write\", \"edit\", \"exec\", \"sessions_list\", \"sessions_history\", \"sessions_send\", \"session_status\", \"memory_search\", \"memory_get\"],
        \"deny\": [\"apply_patch\", \"browser\", \"canvas\"]
      }
    }"

    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
        AGENT_MODEL_JSON=$(resolve_model_json ".agents[$i].model // .advanced.default_agent_model // \"openai-codex/gpt-5.4\"")
        RUNTIME_AGENT_ID="$(agent_runtime_id "${AGENT_ID}")"
        FLEET_AGENT_RUNTIME_IDS_JSON+=", \"${RUNTIME_AGENT_ID}\""

        AGENTS_JSON+=",{
      \"id\": \"${RUNTIME_AGENT_ID}\",
      \"name\": \"${PROJECT_NAME} ${AGENT_ID}\",
      \"workspace\": \"${REPO_DIR}\",
      \"agentDir\": \"${PROFILE_ROOT}/agents/${RUNTIME_AGENT_ID}/agent\",
      \"model\": ${AGENT_MODEL_JSON},
      \"tools\": {
        \"allow\": [\"read\", \"write\", \"edit\", \"exec\", \"memory_search\", \"memory_get\"]
      }
    }"
    done
    AGENTS_JSON+="]"
    FLEET_AGENT_RUNTIME_IDS_JSON+="]"

    CONFIG_THINKING_JSON=""
    if [[ -n "${CONFIG_THINKING_DEFAULT}" && "${CONFIG_THINKING_DEFAULT}" != "null" ]]; then
        CONFIG_THINKING_JSON=",
      thinkingDefault: \"${CONFIG_THINKING_DEFAULT}\""
    fi

    AUTH_CONFIG_BLOCK=""
    if [[ -n "${PROFILE_AUTH_PROFILES_JSON}" && "${PROFILE_AUTH_PROFILES_JSON}" != "null" && "${PROFILE_AUTH_PROFILES_JSON}" != "{}" ]]; then
        AUTH_CONFIG_BLOCK="  auth: {
    profiles: ${PROFILE_AUTH_PROFILES_JSON}
  },
"
    fi

    # WSL2 auto-forwards localhost from Windows, so loopback works.
    # No special bind needed — Windows browser reaches WSL via localhost.
    GATEWAY_BIND="loopback"
    WSL_ORIGIN_ENTRY=""

    # Write config
    cat > "${CONFIG_PATCH}" << CONFIGEOF
// ============================================================
// Standalone OpenClaw config for: ${PROJECT_NAME}
// Generated by fleetclaw/setup.sh
//
// This config is written to the dedicated profile:
//   ${PROFILE_CONFIG_PATH}
// Source of truth:
//   ${SCOPE_FILE}
// ============================================================
{
${AUTH_CONFIG_BLOCK}  gateway: {
    mode: "local",
    port: ${PROFILE_GATEWAY_PORT},
    bind: "${GATEWAY_BIND}",
    controlUi: {
      allowedOrigins: [
        "http://localhost:${PROFILE_GATEWAY_PORT}",
        "http://127.0.0.1:${PROFILE_GATEWAY_PORT}"${WSL_ORIGIN_ENTRY}
      ]
    },
    auth: {
      mode: "token",
      token: "${PROFILE_GATEWAY_TOKEN}"
    }
  },
  tools: {
    profile: "coding",
    sessions: {
      visibility: "all"
    },
    agentToAgent: {
      enabled: true,
      allow: ${FLEET_AGENT_RUNTIME_IDS_JSON}
    }
  },
  agents: {
    defaults: {
      model: ${SUPERVISOR_MODEL_JSON},
      workspace: "${PROFILE_ROOT}/workspace",
      heartbeat: {
        every: "2m"
      },
      compaction: {
        mode: "safeguard",
        memoryFlush: {
          enabled: true,
          softThresholdTokens: 8000,
          systemPrompt: "Session nearing compaction. Store all important context NOW.",
          prompt: "Write dated historical notes to memory/\$(date +%Y-%m-%d).md. Keep STATUS.md as the latest checkpoint only. If you learned a durable fact, preference, convention, or accepted decision, update MEMORY.md too. Reply NO_REPLY if nothing to store."
        }
      }${CONFIG_THINKING_JSON}
    },
    list: ${AGENTS_JSON}
  }
}
CONFIGEOF

    log "Generated openclaw config at generated/openclaw-config.json5"

    mkdir -p "${PROFILE_ROOT}"
    cp "${CONFIG_PATCH}" "${PROFILE_CONFIG_PATH}"
    log "Wrote dedicated profile config at ${PROFILE_CONFIG_PATH}"
    openclaw --profile "${PROJECT_PROFILE}" config validate >/dev/null
    log "Validated dedicated profile config"

    PROGRESS_THINKING_ARGS=()
    if [[ -n "${SUPERVISOR_THINKING}" && "${SUPERVISOR_THINKING}" != "null" ]]; then
        PROGRESS_THINKING_ARGS+=("--thinking" "${SUPERVISOR_THINKING}")
    fi

    cat > "${CRON_INSTALL_SH}" << CRONEOF
#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_CMD=(openclaw --profile "${PROJECT_PROFILE}")

find_job_id() {
    local job_name="\$1"
    local payload
    payload="\$("\${OPENCLAW_CMD[@]}" cron list --json)"
    OPENCLAW_JSON_PAYLOAD="\${payload}" python3 - "\${job_name}" <<'PY'
import json
import os
import sys

job_name = sys.argv[1]
payload = json.loads(os.environ["OPENCLAW_JSON_PAYLOAD"])
for job in payload.get("jobs", []):
    if job.get("name") == job_name:
        print(job.get("id", ""))
        break
PY
}

upsert_cron_job() {
    local job_name="\$1"
    shift
    local existing_id
    existing_id="\$(find_job_id "\${job_name}")"
    if [[ -n "\${existing_id}" ]]; then
        "\${OPENCLAW_CMD[@]}" cron edit "\${existing_id}" "\$@"
    else
        "\${OPENCLAW_CMD[@]}" cron add --name "\${job_name}" "\$@"
    fi
}

upsert_cron_job "${PROGRESS_CRON_NAME}" \\
  --agent "$(agent_runtime_id "supervisor")" \\
  --every "${CHECK_INTERVAL}m" \\
  --session isolated \\
  --message "Run progress check cycle. Check all ${AGENT_COUNT} coding agents. Follow your SOUL.md instructions." \\
  --no-deliver$(if [[ ${#PROGRESS_THINKING_ARGS[@]} -gt 0 ]]; then printf ' \\\n  --thinking "%s"' "${PROGRESS_THINKING_ARGS[1]}"; fi)
CRONEOF

    if [[ -n "${REPORT_HOUR}" && "${REPORT_HOUR}" != "null" && "${REPORT_HOUR}" != "" ]]; then
        {
            echo ""
            echo "upsert_cron_job \"${MORNING_CRON_NAME}\" \\"
            echo "  --agent \"$(agent_runtime_id "supervisor")\" \\"
            echo "  --cron \"0 ${REPORT_HOUR} * * *\" \\"
            echo "  --tz \"${REPORT_TZ}\" \\"
            echo "  --session isolated \\"
            echo "  --message \"Generate morning status report for ${PROJECT_NAME}. Summarize: each agent's progress, blockers, context health, total costs. Be concise.\" \\"
            if [[ -n "${SUPERVISOR_THINKING}" && "${SUPERVISOR_THINKING}" != "null" ]]; then
                echo "  --thinking \"${SUPERVISOR_THINKING}\" \\"
            fi
            if [[ -n "${NOTIFY_CHANNEL}" && "${NOTIFY_CHANNEL}" != "null" && -n "${NOTIFY_TARGET}" && "${NOTIFY_TARGET}" != "null" ]]; then
                echo "  --announce \\"
                echo "  --channel \"${NOTIFY_CHANNEL}\" \\"
                echo "  --to \"${NOTIFY_TARGET}\""
            else
                echo "  --no-deliver"
            fi
        } >> "${CRON_INSTALL_SH}"
    fi

    chmod +x "${CRON_INSTALL_SH}"
    log "Generated cron installer at generated/openclaw-cron.sh"

    # --- Set up supervisor workspace ---
    SUPERVISOR_WS="${WORKTREE_BASE}/supervisor-workspace"
    mkdir -p "${SUPERVISOR_WS}"
    cp "${SUPERVISOR_SOUL}" "${SUPERVISOR_WS}/SOUL.md"
    cp "${ROSTER_MD}" "${SUPERVISOR_WS}/ROSTER.md"
    copy_shared_files "${SUPERVISOR_WS}"
    seed_profile_agent_state "$(agent_runtime_id "supervisor")"
    log "Set up supervisor workspace"

    # --- Copy SOUL.md + BRIEF.md + STATUS.md to each agent's config dir ---
    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID=$(yq eval ".agents[$i].id" "$SCOPE_FILE")
        AGENT_CONFIG_DIR="${FLEETCLAW_AGENTS_DIR}/${AGENT_ID}"
        AGENT_SOUL="${SCRIPT_DIR}/generated/${AGENT_ID}-SOUL.md"
        AGENT_BRIEF="${SCRIPT_DIR}/generated/${AGENT_ID}-BRIEF.md"
        AGENT_STATUS="${SCRIPT_DIR}/generated/${AGENT_ID}-STATUS.md"

        mkdir -p "${AGENT_CONFIG_DIR}/memory"
        cp "${AGENT_SOUL}" "${AGENT_CONFIG_DIR}/SOUL.md"
        cp "${AGENT_BRIEF}" "${AGENT_CONFIG_DIR}/BRIEF.md"
        if [[ ! -f "${AGENT_CONFIG_DIR}/STATUS.md" ]]; then
            cp "${AGENT_STATUS}" "${AGENT_CONFIG_DIR}/STATUS.md"
        fi
        copy_shared_files "${AGENT_CONFIG_DIR}"
        seed_profile_agent_state "$(agent_runtime_id "${AGENT_ID}")"
        log "Set up ${AGENT_ID} workspace"
    done

    # --- Summary ---
    echo ""
    echo "=========================================="
    echo "  ✅ Setup Complete"
    echo "=========================================="
    echo ""
    info "Generated files are in: ${SCRIPT_DIR}/generated/"
    echo ""
    echo "Next step:"
    echo ""
    echo "  ./launch.sh"
    echo ""
    echo "This will install the gateway, cron jobs, bootstrap git, and kick off all agents."
    echo ""
}

main "$@"
