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
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

enable_yq_fallback
enable_jq_fallback
detect_platform

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
    if [[ "${FLEETCLAW_USING_YQ_FALLBACK}" == "1" ]]; then
        warn "yq not found; using built-in Python fallback"
    fi
    if [[ "${FLEETCLAW_USING_JQ_FALLBACK}" == "1" ]]; then
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

resolve_scope_path() {
    local raw_path="$1"

    if [[ -z "${raw_path}" || "${raw_path}" == "null" ]]; then
        return 1
    fi

    raw_path="$(expand_path "${raw_path}")"
    if [[ "${raw_path}" != /* ]]; then
        raw_path="${SCRIPT_DIR}/${raw_path}"
    fi

    printf '%s\n' "${raw_path}"
}

read_scope_text_file() {
    local raw_path="$1"
    local label="$2"
    local resolved_path

    resolved_path="$(resolve_scope_path "${raw_path}")" || {
        err "${label} file path is empty"
        exit 1
    }

    if [[ ! -f "${resolved_path}" ]]; then
        err "${label} file not found: ${resolved_path}"
        exit 1
    fi

    cat "${resolved_path}"
}

resolve_scope_text() {
    local inline_expr="$1"
    local file_expr="$2"
    local default_value="${3:-}"
    local label="${4:-scope text}"
    local inline_value
    local file_value

    inline_value="$(yval_default "${inline_expr}" "")"
    file_value="$(yval_default "${file_expr}" "")"

    if [[ -n "${file_value}" && "${file_value}" != "null" ]]; then
        if [[ -n "${inline_value}" && "${inline_value}" != "null" ]]; then
            warn "${label} is defined inline and via ${file_expr}; using the file-backed value"
        fi
        read_scope_text_file "${file_value}" "${label}"
        return 0
    fi

    if [[ -n "${inline_value}" && "${inline_value}" != "null" ]]; then
        printf '%s\n' "${inline_value}"
        return 0
    fi

    printf '%s\n' "${default_value}"
}

bootstrap_local_repo() {
    local repo_dir="$1"
    local branch_name="$2"

    mkdir -p "${repo_dir}"
    echo -e "${BLUE}[i]${NC} Initializing git repo in local project path: ${repo_dir}" >&2
    git -C "${repo_dir}" init -q -b "${branch_name}"
    git -C "${repo_dir}" add -A 2>/dev/null || true
    git -C "${repo_dir}" \
        -c user.name="FleetClaw" \
        -c user.email="fleetclaw@local" \
        commit --allow-empty -q -m "FleetClaw: initialize project repo" 2>/dev/null || true
}

resolve_template_dir() {
    local configured_dir

    configured_dir="$(yval_default '.advanced.template_dir' '')"
    if [[ -z "${configured_dir}" || "${configured_dir}" == "null" ]]; then
        configured_dir="${SCRIPT_DIR}/templates"
    else
        configured_dir="$(resolve_scope_path "${configured_dir}")"
    fi

    if [[ ! -d "${configured_dir}" ]]; then
        err "Template directory not found: ${configured_dir}"
        exit 1
    fi

    printf '%s\n' "${configured_dir}"
}

template_path() {
    local template_dir="$1"
    local template_name="$2"
    local resolved_template="${template_dir}/${template_name}"

    if [[ ! -f "${resolved_template}" ]]; then
        err "Template not found: ${resolved_template}"
        exit 1
    fi

    printf '%s\n' "${resolved_template}"
}

render_template() {
    local template_file="$1"
    local output_file="$2"
    shift 2
    local env_args=()
    local key

    for key in "$@"; do
        env_args+=("${key}=${!key-}")
    done

    env "${env_args[@]}" python3 - "${template_file}" "${output_file}" <<'PY'
import os
import pathlib
import re
import sys

template_text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
missing = []

def replace(match: re.Match[str]) -> str:
    key = match.group(1)
    if key not in os.environ:
        missing.append(key)
        return ""
    return os.environ[key]

rendered = re.sub(r"\{\{([A-Z0-9_]+)\}\}", replace, template_text)
if missing:
    raise SystemExit(
        f"Missing template values for {sys.argv[1]}: {', '.join(sorted(set(missing)))}"
    )

pathlib.Path(sys.argv[2]).write_text(rendered, encoding="utf-8")
PY
}

build_optional_section() {
    local title="$1"
    local body="$2"

    if [[ -z "${body}" || "${body}" == "null" ]]; then
        return 0
    fi

    printf '\n## %s\n%s\n' "${title}" "${body}"
}

resolve_local_repo_path() {
    local repo_source="$1"

    if [[ -z "${repo_source}" || "${repo_source}" == "null" || "${repo_source}" == "." ]]; then
        repo_source="${SCRIPT_DIR}"
    fi

    repo_source="$(expand_path "${repo_source}")"
    if [[ "${repo_source}" != /* ]]; then
        repo_source="${SCRIPT_DIR}/${repo_source}"
    fi

    # If the resolved path IS the fleetclaw directory (a subdirectory of the
    # actual project), prefer the parent directory as the project repo.
    # This way the shared agent workspace is the project root and focus_dirs
    # resolve relative to the actual project.
    if [[ "${repo_source}" == "${SCRIPT_DIR}" ]]; then
        local parent_dir
        parent_dir="$(dirname "${SCRIPT_DIR}")"

        if git -C "${parent_dir}" rev-parse --show-toplevel >/dev/null 2>&1; then
            # Parent is already a git repo — use it
            git -C "${parent_dir}" rev-parse --show-toplevel
            return 0
        elif [[ -d "${parent_dir}" ]]; then
            # Parent exists but is not a git repo — initialize one so
            # diffs and commits work for the shared project root
            bootstrap_local_repo "${parent_dir}" "${PROJECT_BRANCH:-main}"
            git -C "${parent_dir}" rev-parse --show-toplevel
            return 0
        fi
    fi

    if git -C "${repo_source}" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "${repo_source}" rev-parse --show-toplevel
        return 0
    fi

    if [[ -d "${repo_source}" ]]; then
        bootstrap_local_repo "${repo_source}" "${PROJECT_BRANCH:-main}"
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

resolve_cli_backend_config_json() {
    local required_models codex_bin
    required_models="$(collect_required_models)"

    if printf '%s\n' "${required_models}" | grep -q '^codex-cli/'; then
        codex_bin="$(command -v codex || true)"
        if [[ -z "${codex_bin}" ]]; then
            err "A codex-cli model is configured but the 'codex' binary was not found in PATH."
            exit 1
        fi

        cat <<EOF
      cliBackends: {
        "codex-cli": {
          command: "${codex_bin}"
        }
      },
EOF
    fi
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
    PROJECT_DESC=$(resolve_scope_text '.project.description' '.project.description_file' '' 'project.description')

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
    SUPERVISOR_OBJECTIVE=$(resolve_scope_text '.supervisor.objective' '.supervisor.objective_file' '' 'supervisor objective')
    SUPERVISOR_HANDOFF_RULES=$(resolve_scope_text '.supervisor.handoff_rules' '.supervisor.handoff_rules_file' '' 'supervisor handoff rules')
    SUPERVISOR_OBJECTIVE_BLOCK=""
    SUPERVISOR_HANDOFF_RULES_BLOCK=""
    TEMPLATE_DIR="$(resolve_template_dir)"
    PROJECT_TEMPLATE="$(template_path "${TEMPLATE_DIR}" "PROJECT.md.tpl")"
    MEMORY_TEMPLATE="$(template_path "${TEMPLATE_DIR}" "MEMORY.md.tpl")"
    ROSTER_TEMPLATE="$(template_path "${TEMPLATE_DIR}" "ROSTER.md.tpl")"
    SUPERVISOR_SOUL_TEMPLATE="$(template_path "${TEMPLATE_DIR}" "supervisor-SOUL.md.tpl")"
    AGENT_BRIEF_TEMPLATE="$(template_path "${TEMPLATE_DIR}" "agent-BRIEF.md.tpl")"
    AGENT_SOUL_TEMPLATE="$(template_path "${TEMPLATE_DIR}" "agent-SOUL.md.tpl")"
    AGENT_STATUS_TEMPLATE="$(template_path "${TEMPLATE_DIR}" "agent-STATUS.md.tpl")"

    AGENT_COUNT=$(yq eval '.agents | length' "$SCOPE_FILE")
    WORKTREE_BASE="$(resolve_worktree_base_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
    PROJECT_SLUG="$(slugify "${PROJECT_NAME}")"
    PROJECT_PROFILE="$(resolve_openclaw_profile_from_scope "$SCOPE_FILE" "$PROJECT_NAME")"
    OPENCLAW_BIN="$(command -v openclaw)"
    PROFILE_ROOT="${HOME}/.openclaw-${PROJECT_PROFILE}"
    PROFILE_CONFIG_PATH="${PROFILE_ROOT}/openclaw.json"
    PROFILE_GATEWAY_PORT="$(derive_gateway_port "${PROJECT_PROFILE}" "$(yval_default '.advanced.gateway_port' '')")"
    PROFILE_GATEWAY_TOKEN="$(generate_gateway_token)"
    PROFILE_AUTH_PROFILES_JSON="$(resolve_main_auth_profiles_json)"
    PROGRESS_CRON_NAME="${PROJECT_SLUG}-supervisor-progress-check"
    MORNING_CRON_NAME="${PROJECT_SLUG}-supervisor-morning-report"
    CONFIG_THINKING_DEFAULT=""
    THINKING_VALUES=""
    declare -a AGENT_IDS AGENT_TASKS AGENT_FOCUS_DIRS AGENT_TASK_SUMMARIES AGENT_RUNTIME_IDS AGENT_MODEL_JSONS

    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_IDS[i]="$(yq eval ".agents[$i].id" "$SCOPE_FILE")"
        AGENT_TASKS[i]="$(resolve_scope_text ".agents[$i].task" ".agents[$i].task_file" "" "agents[$i].task")"
        AGENT_FOCUS_DIRS[i]="$(yq eval ".agents[$i].focus_dirs | join(\", \")" "$SCOPE_FILE")"
        AGENT_TASK_SUMMARIES[i]="$(printf '%s\n' "${AGENT_TASKS[i]}" | awk 'NF { print; exit }')"
        AGENT_RUNTIME_IDS[i]="$(agent_runtime_id "${AGENT_IDS[i]}")"
        AGENT_MODEL_JSONS[i]="$(resolve_model_json ".agents[$i].model // .advanced.default_agent_model // \"openai-codex/gpt-5.4\"")"
    done

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

    SUPERVISOR_OBJECTIVE_BLOCK="$(build_optional_section "Project-Specific Objective" "${SUPERVISOR_OBJECTIVE}")"
    SUPERVISOR_HANDOFF_RULES_BLOCK="$(build_optional_section "Project-Specific Coordination Rules" "${SUPERVISOR_HANDOFF_RULES}")"

    info "Project: ${PROJECT_NAME} (${AGENT_COUNT} coding agents)"
    info "OpenClaw profile: ${PROJECT_PROFILE}"
    info "Supervisor: ${SUPERVISOR_MODEL_LABEL} checking every ${CHECK_INTERVAL}m"
    info "Compact threshold: ${COMPACT_THRESHOLD}%"
    info "Review checkpoints: ${REVIEW_CHECKPOINT_MINS}m or ${MAX_COMMITS_WITHOUT_DECISION} commits"
    info "Worktree base: ${WORKTREE_BASE}"
    info "Template dir: ${TEMPLATE_DIR}"
    info "Profile state dir: ${PROFILE_ROOT}"
    info "Profile gateway port: ${PROFILE_GATEWAY_PORT}"
    info "Platform: ${FLEETCLAW_PLATFORM}"
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

    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        log "Repository has no commits yet; creating initial commit on ${PROJECT_BRANCH}"
        git symbolic-ref HEAD "refs/heads/${PROJECT_BRANCH}" >/dev/null 2>&1 || true
        git add -A 2>/dev/null || true
        git \
            -c user.name="FleetClaw" \
            -c user.email="fleetclaw@local" \
            commit --allow-empty -q -m "FleetClaw: initialize project repo" 2>/dev/null || true
    fi

    # --- Create per-agent directories in project root ---
    FLEETCLAW_AGENTS_DIR="${REPO_DIR}/.fleetclaw/agents"
    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID="${AGENT_IDS[i]}"
        AGENT_DIR="${FLEETCLAW_AGENTS_DIR}/${AGENT_ID}"
        mkdir -p "${AGENT_DIR}/memory"
        log "Created agent directory: .fleetclaw/agents/${AGENT_ID}"
    done

    # --- Generate PROJECT.md (shared context for all agents) ---
    PROJECT_MD="${SCRIPT_DIR}/generated/PROJECT.md"
    mkdir -p "${SCRIPT_DIR}/generated"
    TEAM_OVERVIEW_BLOCK=""

    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID="${AGENT_IDS[i]}"
        FOCUS="${AGENT_FOCUS_DIRS[i]}"
        AGENT_TASK_SUMMARY="${AGENT_TASK_SUMMARIES[i]}"

        if [[ -n "${TEAM_OVERVIEW_BLOCK}" ]]; then
            TEAM_OVERVIEW_BLOCK+=$'\n\n'
        fi
        TEAM_OVERVIEW_BLOCK+="### ${AGENT_ID}"$'\n'
        TEAM_OVERVIEW_BLOCK+="- **Focus directories:** ${FOCUS}"$'\n'
        TEAM_OVERVIEW_BLOCK+="- **Goal:** ${AGENT_TASK_SUMMARY}"
    done

    render_template "${PROJECT_TEMPLATE}" "${PROJECT_MD}" \
        PROJECT_NAME PROJECT_DESC PROJECT_REPO PROJECT_BRANCH TEAM_OVERVIEW_BLOCK

    log "Generated PROJECT.md"

    # --- Generate shared MEMORY.md template ---
    MEMORY_MD="${SCRIPT_DIR}/generated/MEMORY.md"
    render_template "${MEMORY_TEMPLATE}" "${MEMORY_MD}" PROJECT_NAME

    log "Generated MEMORY.md"

    # --- Generate shared ROSTER.md for supervisor lookups ---
    ROSTER_MD="${SCRIPT_DIR}/generated/ROSTER.md"
    AGENT_ID_LIST=""
    ROSTER_ENTRIES_BLOCK=""

    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID="${AGENT_IDS[i]}"
        AGENT_TASK_SUMMARY="${AGENT_TASK_SUMMARIES[i]}"
        FOCUS="${AGENT_FOCUS_DIRS[i]}"
        RUNTIME_AGENT_ID="${AGENT_RUNTIME_IDS[i]}"
        PRIMARY_SESSION_KEY="agent:${RUNTIME_AGENT_ID}:main"

        if [[ -n "${AGENT_ID_LIST}" ]]; then
            AGENT_ID_LIST+=", "
        fi
        AGENT_ID_LIST+="${AGENT_ID}"

        if [[ -n "${ROSTER_ENTRIES_BLOCK}" ]]; then
            ROSTER_ENTRIES_BLOCK+=$'\n\n'
        fi
        ROSTER_ENTRIES_BLOCK+="## ${AGENT_ID}"$'\n'
        ROSTER_ENTRIES_BLOCK+="- Runtime agent id: ${RUNTIME_AGENT_ID}"$'\n'
        ROSTER_ENTRIES_BLOCK+="- Primary session key: \`${PRIMARY_SESSION_KEY}\`"$'\n'
        ROSTER_ENTRIES_BLOCK+="- Workspace: ${REPO_DIR}"$'\n'
        ROSTER_ENTRIES_BLOCK+="- Agent config dir: .fleetclaw/agents/${AGENT_ID}"$'\n'
        ROSTER_ENTRIES_BLOCK+="- Focus: ${FOCUS}"$'\n'
        ROSTER_ENTRIES_BLOCK+="- Task summary: ${AGENT_TASK_SUMMARY}"$'\n'
        ROSTER_ENTRIES_BLOCK+="- Status file: \`.fleetclaw/agents/${AGENT_ID}/STATUS.md\`"$'\n'
        ROSTER_ENTRIES_BLOCK+="- Git diff: \`git diff --stat\`"$'\n'
        ROSTER_ENTRIES_BLOCK+="- Recent commits: \`git log --oneline -5\`"
    done

    render_template "${ROSTER_TEMPLATE}" "${ROSTER_MD}" PROJECT_NAME ROSTER_ENTRIES_BLOCK

    log "Generated ROSTER.md"

    # --- Generate Supervisor SOUL.md ---
    SUPERVISOR_SOUL="${SCRIPT_DIR}/generated/supervisor-SOUL.md"
    render_template "${SUPERVISOR_SOUL_TEMPLATE}" "${SUPERVISOR_SOUL}" \
        PROJECT_NAME AGENT_COUNT REPO_DIR AGENT_ID_LIST \
        SUPERVISOR_OBJECTIVE_BLOCK SUPERVISOR_HANDOFF_RULES_BLOCK \
        CHECK_INTERVAL STALL_TIMEOUT COMPACT_THRESHOLD \
        REVIEW_CHECKPOINT_MINS MAX_COMMITS_WITHOUT_DECISION

    log "Generated supervisor SOUL.md"

    # --- Generate per-agent SOUL.md ---
    for i in $(seq 0 $((AGENT_COUNT - 1))); do
        AGENT_ID="${AGENT_IDS[i]}"
        AGENT_TASK="${AGENT_TASKS[i]}"
        FOCUS="${AGENT_FOCUS_DIRS[i]}"

        AGENT_BRIEF="${SCRIPT_DIR}/generated/${AGENT_ID}-BRIEF.md"
        render_template "${AGENT_BRIEF_TEMPLATE}" "${AGENT_BRIEF}" \
            AGENT_ID PROJECT_NAME AGENT_TASK FOCUS

        log "Generated ${AGENT_ID} BRIEF.md"

        AGENT_SOUL="${SCRIPT_DIR}/generated/${AGENT_ID}-SOUL.md"
        render_template "${AGENT_SOUL_TEMPLATE}" "${AGENT_SOUL}" \
            AGENT_ID PROJECT_NAME AGENT_TASK FOCUS CHECK_INTERVAL \
            MAX_COMMITS_WITHOUT_DECISION REVIEW_CHECKPOINT_MINS

        log "Generated ${AGENT_ID} SOUL.md"

        AGENT_STATUS="${SCRIPT_DIR}/generated/${AGENT_ID}-STATUS.md"
        GENERATED_STATUS_TIMESTAMP="$(date '+%Y-%m-%d %H:%M')"
        render_template "${AGENT_STATUS_TEMPLATE}" "${AGENT_STATUS}" GENERATED_STATUS_TIMESTAMP

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
        AGENT_ID="${AGENT_IDS[i]}"
        AGENT_MODEL_JSON="${AGENT_MODEL_JSONS[i]}"
        RUNTIME_AGENT_ID="${AGENT_RUNTIME_IDS[i]}"
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

    CLI_BACKENDS_CONFIG_JSON="$(resolve_cli_backend_config_json)"

    GATEWAY_BIND="${FLEETCLAW_GATEWAY_BIND}"
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
${CLI_BACKENDS_CONFIG_JSON}      heartbeat: {
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

OPENCLAW_CMD=("${OPENCLAW_BIN}" --profile "${PROJECT_PROFILE}")

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
        AGENT_ID="${AGENT_IDS[i]}"
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
    bash "${SCRIPT_DIR}/check-markdown-budget.sh"
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
