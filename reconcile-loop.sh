#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL_SECS="${1:-30}"

if ! [[ "${INTERVAL_SECS}" =~ ^[0-9]+$ ]] || [[ "${INTERVAL_SECS}" -lt 1 ]]; then
    echo "Usage: $(basename "$0") [interval-secs>=1]" >&2
    exit 1
fi

while true; do
    bash "${SCRIPT_DIR}/reconcile-status.sh" --quiet || true
    sleep "${INTERVAL_SECS}"
done
