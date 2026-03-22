#!/usr/bin/env bash
# Lightweight tests for bin/fleetclaw-protocol-lib.sh
# Run: bash tests/test_protocol_lib.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1"; }

echo "=== Protocol lib tests ==="

# --- Test: fleetclaw_rotate_log does not crash on missing file ----------------
echo ""
echo "-- fleetclaw_rotate_log --"

source "${ROOT_DIR}/bin/fleetclaw-protocol-lib.sh"

# Override env vars so the library loads
export FLEETCLAW_LOG_MAX_BYTES=100
export FLEETCLAW_LOG_ROTATE_KEEP=2

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# Test 1: Missing file — should not error
if fleetclaw_rotate_log "${TMPDIR_TEST}/nope.jsonl" 2>/dev/null; then
    pass "rotate missing file does not error"
else
    fail "rotate missing file errored"
fi

# Test 2: Small file — should not rotate
echo '{"small": true}' > "${TMPDIR_TEST}/small.jsonl"
fleetclaw_rotate_log "${TMPDIR_TEST}/small.jsonl"
if [[ -f "${TMPDIR_TEST}/small.jsonl" && ! -f "${TMPDIR_TEST}/small.jsonl.1" ]]; then
    pass "small file not rotated"
else
    fail "small file was unexpectedly rotated"
fi

# Test 3: Large file — should rotate
python3 -c "print('x' * 200)" > "${TMPDIR_TEST}/big.jsonl"
fleetclaw_rotate_log "${TMPDIR_TEST}/big.jsonl"
if [[ -f "${TMPDIR_TEST}/big.jsonl.1" && ! -f "${TMPDIR_TEST}/big.jsonl" ]]; then
    pass "large file rotated to .1"
else
    fail "large file rotation failed"
fi

# Test 4: Multiple rotations respect keep limit
echo "second" > "${TMPDIR_TEST}/big2.jsonl"
python3 -c "print('x' * 200)" > "${TMPDIR_TEST}/big2.jsonl"
fleetclaw_rotate_log "${TMPDIR_TEST}/big2.jsonl"
# Simulate another rotation
echo "third large" > "${TMPDIR_TEST}/big2.jsonl"
python3 -c "print('x' * 200)" > "${TMPDIR_TEST}/big2.jsonl"
fleetclaw_rotate_log "${TMPDIR_TEST}/big2.jsonl"
if [[ -f "${TMPDIR_TEST}/big2.jsonl.2" ]]; then
    pass "multiple rotations produce .2"
else
    fail "multiple rotations did not produce .2"
fi

# --- Test: fleetclaw_generate_event_id format ---------------------------------
echo ""
echo "-- fleetclaw_generate_event_id --"

EVENT_ID="$(fleetclaw_generate_event_id "test-agent")"
if [[ "${EVENT_ID}" =~ ^test-agent-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$ ]]; then
    pass "event id format correct: ${EVENT_ID}"
else
    fail "event id format unexpected: ${EVENT_ID}"
fi

# --- Summary ------------------------------------------------------------------
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if (( FAIL > 0 )); then
    exit 1
fi
