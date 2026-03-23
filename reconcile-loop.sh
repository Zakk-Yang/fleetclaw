#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL_SECS="${1:-30}"

if ! [[ "${INTERVAL_SECS}" =~ ^[0-9]+$ ]] || [[ "${INTERVAL_SECS}" -lt 1 ]]; then
    echo "Usage: $(basename "$0") [interval-secs>=1]" >&2
    exit 1
fi

SCOPE_FILE="${SCRIPT_DIR}/project-scope.yaml"
LAST_SIGNATURES_FILE="${SCRIPT_DIR}/generated/.reconcile-signatures"

# Capture current agent state signatures for change detection
capture_signatures() {
    local project_root
    project_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local fleetclaw_dir="${project_root}/.fleetclaw/agents"
    [[ -d "${fleetclaw_dir}" ]] || return
    for status_file in "${fleetclaw_dir}"/*/STATUS.md; do
        [[ -f "${status_file}" ]] || continue
        local agent_id
        agent_id="$(basename "$(dirname "${status_file}")")"
        local sig
        sig="$(grep -E '^(State|Needs supervisor decision|Blocker):' "${status_file}" 2>/dev/null | tr '\n' '|')"
        echo "${agent_id}=${sig}"
    done | sort
}

# Trigger supervisor when agent states change
trigger_supervisor_if_changed() {
    local current_sigs
    current_sigs="$(capture_signatures)"
    local previous_sigs=""
    [[ -f "${LAST_SIGNATURES_FILE}" ]] && previous_sigs="$(cat "${LAST_SIGNATURES_FILE}")"

    echo "${current_sigs}" > "${LAST_SIGNATURES_FILE}"

    # Skip on first run (no previous signatures)
    [[ -z "${previous_sigs}" ]] && return

    # Compare
    if [[ "${current_sigs}" != "${previous_sigs}" ]]; then
        # State changed — wake supervisor
        if [[ -f "${SCOPE_FILE}" ]]; then
            local project_name
            project_name="$(python3 -c "import yaml; print(yaml.safe_load(open('${SCOPE_FILE}')).get('project',{}).get('name',''))" 2>/dev/null || true)"
            if [[ -n "${project_name}" ]]; then
                local profile
                profile="$(echo "${project_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/^-\+\|-\+$//g; s/-\+/-/g')"
                local supervisor_id="${profile}-supervisor"
                openclaw --profile "${profile}" agent \
                    --agent "${supervisor_id}" \
                    --message "Agent state change detected. Run progress check now. Check all agent STATUS.md files and send decisions." \
                    >/dev/null 2>&1 &
            fi
        fi
    fi
}

while true; do
    bash "${SCRIPT_DIR}/reconcile-status.sh" --quiet || true
    bash "${SCRIPT_DIR}/sync-supervisor-cron.sh" --quiet || true
    bash "${SCRIPT_DIR}/project-status.sh" --quiet || true
    trigger_supervisor_if_changed || true
    sleep "${INTERVAL_SECS}"
done
