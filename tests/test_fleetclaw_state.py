#!/usr/bin/env python3
"""Tests for bin/fleetclaw-state.py — state normalization logic."""
from __future__ import annotations

import importlib.util
import json
import textwrap
from pathlib import Path

import pytest

# Load the module from its non-standard location.
_LIB_PATH = Path(__file__).resolve().parents[1] / "bin" / "fleetclaw-state.py"
_spec = importlib.util.spec_from_file_location("fleetclaw_state", _LIB_PATH)
assert _spec and _spec.loader
state_lib = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(state_lib)


# --- normalize_key -----------------------------------------------------------

@pytest.mark.parametrize("label,expected", [
    ("State", "state"),
    ("Last updated", "last_updated"),
    ("  Files touched  ", "files_touched"),
    ("Needs supervisor decision", "needs_supervisor_decision"),
    ("UPPER-CASE_mixed", "upper_case_mixed"),
    ("", ""),
])
def test_normalize_key(label, expected):
    assert state_lib.normalize_key(label) == expected


# --- display_label ------------------------------------------------------------

def test_display_label_override():
    assert state_lib.display_label("last_updated") == "Last updated"
    assert state_lib.display_label("needs_supervisor_decision") == "Needs supervisor decision"

def test_display_label_fallback():
    assert state_lib.display_label("custom_field") == "Custom Field"
    assert state_lib.display_label("a") == "A"


# --- stringify_value ----------------------------------------------------------

@pytest.mark.parametrize("value,expected", [
    (None, ""),
    (True, "yes"),
    (False, "no"),
    (["a", "b"], "a, b"),
    ({"x": 1}, '{"x": 1}'),
    (42, "42"),
    ("hello", "hello"),
])
def test_stringify_value(value, expected):
    assert state_lib.stringify_value(value) == expected


# --- parse_markdown_state -----------------------------------------------------

def test_parse_markdown_state(tmp_path):
    md = tmp_path / "STATUS.md"
    md.write_text(textwrap.dedent("""\
        # STATUS.md
        State: working
        Summary: did stuff
        Last updated: 2026-03-22T10:00:00Z
    """))
    result = state_lib.parse_markdown_state(md)
    assert result["state"] == "working"
    assert result["summary"] == "did stuff"
    assert result["last_updated"] == "2026-03-22T10:00:00Z"

def test_parse_markdown_state_missing(tmp_path):
    result = state_lib.parse_markdown_state(tmp_path / "nope.md")
    assert result == {}


# --- load_json_state ----------------------------------------------------------

def test_load_json_state(tmp_path):
    jf = tmp_path / "state.json"
    jf.write_text(json.dumps({"state": "blocked", "blocker": "waiting on API"}))
    result = state_lib.load_json_state(jf)
    assert result["state"] == "blocked"
    assert result["blocker"] == "waiting on API"

def test_load_json_state_invalid(tmp_path):
    jf = tmp_path / "state.json"
    jf.write_text("{bad json")
    assert state_lib.load_json_state(jf) == {}

def test_load_json_state_missing(tmp_path):
    assert state_lib.load_json_state(tmp_path / "nope.json") == {}


# --- choose_state -------------------------------------------------------------

def test_choose_state_prefers_newer_markdown(tmp_path):
    import time
    jf = tmp_path / "state.json"
    jf.write_text(json.dumps({"state": "working", "summary": "from json"}))
    time.sleep(0.05)
    md = tmp_path / "STATUS.md"
    md.write_text("State: done\nSummary: from md\n")

    result = state_lib.choose_state(md, jf)
    # Markdown is newer, so its values win via merge
    assert result["state"] == "done"
    assert result["summary"] == "from md"

def test_choose_state_prefers_json_when_newer(tmp_path):
    import time
    md = tmp_path / "STATUS.md"
    md.write_text("State: working\n")
    time.sleep(0.05)
    jf = tmp_path / "state.json"
    jf.write_text(json.dumps({"state": "blocked"}))

    result = state_lib.choose_state(md, jf)
    assert result["state"] == "blocked"


# --- render_markdown ----------------------------------------------------------

def test_render_markdown_respects_order():
    state = {"summary": "s", "state": "working", "blocker": "none"}
    result = state_lib.render_markdown("# STATUS.md", state, ["state", "summary", "blocker"])
    lines = result.strip().split("\n")
    assert lines[0] == "# STATUS.md"
    assert lines[1].startswith("State:")
    assert lines[2].startswith("Summary:")
    assert lines[3].startswith("Blocker:")

def test_render_markdown_skips_empty():
    state = {"state": "done", "summary": ""}
    result = state_lib.render_markdown("# STATUS.md", state, ["state", "summary"])
    assert "Summary" not in result


# --- write_json_state ---------------------------------------------------------

def test_write_json_state(tmp_path):
    jf = tmp_path / "sub" / "state.json"
    state_lib.write_json_state(jf, {"b": "2", "a": "1", "c": ""})
    loaded = json.loads(jf.read_text())
    # Empty values are excluded, keys are sorted
    assert loaded == {"a": "1", "b": "2"}
    assert list(loaded.keys()) == ["a", "b"]


# --- sync_markdown_and_json (round-trip) --------------------------------------

def test_sync_creates_both_files(tmp_path):
    md = tmp_path / "STATUS.md"
    jf = tmp_path / "state.json"
    result = state_lib.sync_markdown_and_json(
        md, jf, "# STATUS.md", state_lib.AGENT_PREFERRED_ORDER,
        updates={"state": "working", "summary": "hello"},
    )
    assert result["state"] == "working"
    assert md.exists()
    assert jf.exists()
    assert "State: working" in md.read_text()
    loaded_json = json.loads(jf.read_text())
    assert loaded_json["state"] == "working"

def test_sync_applies_updates(tmp_path):
    md = tmp_path / "STATUS.md"
    jf = tmp_path / "state.json"
    md.write_text("State: working\nSummary: old\n")
    jf.write_text(json.dumps({"state": "working", "summary": "old"}))

    result = state_lib.sync_markdown_and_json(
        md, jf, "# STATUS.md", state_lib.AGENT_PREFERRED_ORDER,
        updates={"summary": "new", "blocker": "stuck"},
    )
    assert result["summary"] == "new"
    assert result["blocker"] == "stuck"
    assert "Summary: new" in md.read_text()

def test_sync_removes_empty_updates(tmp_path):
    md = tmp_path / "STATUS.md"
    jf = tmp_path / "state.json"
    md.write_text("State: working\nSummary: old\n")
    jf.write_text(json.dumps({"state": "working", "summary": "old"}))

    result = state_lib.sync_markdown_and_json(
        md, jf, "# STATUS.md", state_lib.AGENT_PREFERRED_ORDER,
        updates={"summary": ""},
    )
    assert "summary" not in result
