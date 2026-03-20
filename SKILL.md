---
name: progress-check
version: 1.0.0
description: >
  Skill for supervisor agents to check coding agent progress via git diff analysis.
  Use when: (1) running a periodic progress check on coding agents,
  (2) detecting stalled agents, (3) deciding whether to intervene.
---

# Progress Check Skill

## When to Use
- Called by the supervisor agent during cron-triggered progress checks
- When evaluating whether a coding agent has made meaningful progress
- When deciding whether to send corrective instructions

## How to Check an Agent's Progress

### Step 1: Git Diff Analysis
For each agent workspace, run:
```bash
# Files changed since last check (uncommitted)
git -C <workspace_path> diff --stat

# Files changed in last N commits
git -C <workspace_path> log --oneline --stat -3

# Time since last commit
git -C <workspace_path> log -1 --format="%cr"
```

### Step 2: Evaluate Meaningful Progress
A diff is **meaningful** if:
- New functions, classes, or modules were added
- Tests were written or updated
- Config/infrastructure files were modified appropriately
- The changes align with the agent's assigned task and focus_dirs

A diff is **NOT meaningful** if:
- Only whitespace or formatting changes
- Same file modified back and forth (revert loop)
- Changes are outside the agent's focus_dirs
- Only comments or TODOs added with no implementation

### Step 3: Detect Stall Patterns
An agent is likely **stalled** if:
- No git diff AND no new commits for > stall_timeout
- Same error pattern appears in multiple recent commits
- Agent is repeatedly modifying the same file without progress
- Large number of deleted lines with few additions (thrashing)

### Step 4: Check Context Health
```
Use session_status for the agent's session to get token usage.
Calculate: usage_pct = totalTokens / contextTokens * 100
```

Thresholds:
- **< 50%**: Healthy, no action needed
- **50-70%**: Monitor, note in status log
- **> 70%**: Send `/compact` to the agent's session
- **> 85%**: Urgent — compact immediately, may need session reset

### Step 5: Decide Action

| Condition | Action |
|-----------|--------|
| Good progress, healthy context | Log status, move on |
| Good progress, high context | Send `/compact`, log |
| Stalled, healthy context | Diagnose cause, send instructions |
| Stalled, high context | Compact first, then send instructions |
| Stalled after 2+ interventions | Escalate to human via notification |

## How to Send Corrective Instructions

When sending instructions to a stalled agent via `sessions_send`:
1. Be specific — include file paths, function names, concrete next steps
2. Include context — what you observed in the diff
3. Suggest an approach — don't just say "fix it"
4. Set a checkpoint — "After implementing X, commit and move to Y"

Example:
```
sessions_send to coder-backend:
"You appear stuck on the auth endpoint. The JWT validation in src/api/auth.py
is missing the refresh token flow. Focus on:
1. Add refresh_token endpoint to src/api/auth.py
2. Add token rotation logic in src/lib/jwt_utils.py
3. Write a test in tests/api/test_auth.py
Commit after each step with prefix [coder-backend]."
```

## Status Log Format

Write to memory/YYYY-MM-DD.md after each check:
```markdown
## Check: 2026-03-19T14:30:00Z

| Agent | Last Commit | Files Changed | Context % | Status |
|-------|------------|---------------|-----------|--------|
| coder-backend | 3m ago | +42/-8 (3 files) | 45% | ✅ OK |
| coder-frontend | 22m ago | +0/-0 | 68% | ⚠️ STALLED |

### Actions Taken
- Sent corrective instructions to coder-frontend (stuck on login page layout)
- Triggered /compact on coder-frontend (context at 68%)
```
