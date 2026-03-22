# FleetClaw Dashboard API

The dashboard runs on `http://<HOST>:<PORT>` (default `127.0.0.1:3333`).

All JSON endpoints return `{ "error": "..." }` with the appropriate status code on failure.

## Endpoints

### `GET /api/dashboard`

Full dashboard payload. This is the primary endpoint consumed by the UI.

**Response** — `200` with the complete project, agents, supervisor, metrics, feedback, and control-plane data.
Returns `404` if `project-scope.yaml` is missing.

The payload is cached for 3 seconds to avoid shell-out thrashing on rapid refreshes.

---

### `GET /api/project`

Project-level metadata only (a subset of `/api/dashboard`).

---

### `GET /api/agents`

Agent and supervisor metadata.

**Response shape:**
```json
{
  "agents": [ { "id": "...", "statusFields": {...}, ... } ],
  "supervisor": { "runtimeId": "...", "status": "...", ... }
}
```

---

### `GET /api/metrics`

Metrics payload (markdown budget, live context, operational analytics).

---

### `POST /api/runtime-settings`

Update runtime settings (models, supervisor check interval, gateway restart).

**Request body:**
```json
{
  "supervisor": {
    "model": "model-key",
    "checkIntervalMins": 5
  },
  "agents": [
    { "id": "frontend", "model": "model-key" }
  ],
  "restartGateway": false
}
```

**Response** — `200` with `{ "ok": true, "runtimeSettings": {...} }`.
Returns `400` on validation errors, `404` if scope file is missing.

Side effects: rewrites `project-scope.yaml`, re-runs `setup.sh`, reinstalls supervisor cron.

---

### `POST /api/feedback`

Send human feedback to a supervisor or agent session via the gateway.

**Request body:**
```json
{
  "target": "supervisor",
  "message": "The login page is broken",
  "severity": "issue",
  "surface": "http://localhost:4173/login",
  "blocksAcceptance": false
}
```

- `target` — `"supervisor"` or an agent id.
- `severity` — `"note"`, `"issue"`, or `"blocking"` (defaults to `"issue"`).
- `message` — required, max 6000 chars.

**Response** — `200` with `{ "ok": true, "entry": {...} }`.
Returns `400` for invalid target/message, `500` if gateway dispatch fails.

---

### `GET /api/agent/:id/file/:filename`

Read a specific agent file.

**Path params:**
- `id` — agent id (validated: `[a-zA-Z0-9._-]+`).
- `filename` — one of: `STATUS.md`, `BRIEF.md`, `PLAN.md`, `MEMORY.md`, `SOUL.md`, `PROJECT.md`, `BLOCKERS.md`.

**Response** — `200` with `text/plain` content.
Returns `400` for invalid id or disallowed filename, `404` if file not found.

---

### `GET /api/files`

List project files (max depth 3, excludes `node_modules` and `.git`).

**Response:**
```json
{ "files": ["./src/main.js", "./package.json", ...] }
```

---

### `GET /openclaw`

Redirects the browser to the OpenClaw gateway UI.

---

### `GET /openclaw/agent/:id`

Redirects to the OpenClaw gateway chat for a specific agent's main session.

---

### `GET /openclaw/supervisor`

Redirects to the OpenClaw gateway chat for the supervisor's main session.
