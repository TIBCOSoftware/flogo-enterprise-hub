# Predictive Maintenance & Asset Monitoring — Agentic AI Demo

An **Agentic AI** demo for the **oilfield operations / industrial asset monitoring** vertical. A
**control-room operator** chats with an AI assistant over WebSocket to **analyze live sensor
readings from pumps, compressors and wellhead valves, classify asset health, and query prediction /
work-order / alert history** — and, on request, **store an AI health prediction, raise a maintenance
work order, and log an alert**. The assistant reads the data, the LLM performs the threshold analysis
itself, and the write actions are persisted to PostgreSQL through a REST API service.

- **Persona:** Oilfield operations control-room operator (self-service), working with assets
  identified as `PUMP-W47-TX`, `COMP-W12-OK`, `VALVE-W03-NM`, etc. across three well sites.
- **Problem automated:** the "what do the sensors say, is this asset healthy, how long until it
  fails, open me a work order, send an alert" load that normally ties up a reliability engineer —
  resolved conversationally, grounded in live time-series data.
- **Solution shape:** 3 Flogo apps — **1 MCP Server** (read-only lookup tools), **1 REST API
  Service** (write operations + sensor-data read), and **1 Agent app** that hosts **both** the
  **WebSocket AI Orchestrator** and **4 A2A Agents** in a single deployable. All state lives in
  **PostgreSQL**.

> ### ⚠️ How this demo diverges from the standard 3-app WebSocket pattern
> This use case is **not** the textbook "MCP Server + separate A2A Servers / Agents app + separate
> Orchestrator" trio (as in the Semiconductor / Telecom demos). The differences are deliberate —
> document and demo them as they actually are:
> 1. **The A2A Agents are embedded in the Orchestrator app**, not a separate "A2A Servers / Agents" app.
>    `predictive-maintenance-agent.flogo` contains the `#wsserver` orchestrator **and** all four
>    `#agent` triggers.
> 2. **All four A2A Agents share a single agent port (`8080`)** rather than one port per agent.
> 3. **The A2A Agents do not write to PostgreSQL directly.** Each agent calls the **REST API
>    Service** (`predictive-maintenance-api.flogo`, port `9095`), which owns every DB write. The
>    flow is 3-tier: *Orchestrator → A2A Agent → REST API → PostgreSQL*.
> 4. **There is no email/SMTP agent** — `alert_notification_agent` logs to the `alert_history`
>    table via REST; it does not send email.
> 5. **The health analysis is done by the Orchestrator LLM itself** (using sensor thresholds in its
>    system prompt), not by a dedicated analysis agent — `sensor_analysis_agent` only fetches raw
>    readings.

---

## Architecture

```
                                       (read-only MCP tools)
                          ┌───────── MCP (HTTP streamable) ──────────┐
                          │        :9093 /predmaintmcpserver          ▼
Chatbot UI --WebSocket--> AI Orchestrator (#wsserver :8083 /ws/chat)  MCP Server ──┐
   ws://host:8083/ws/chat        │  (Orchestrator-Agent flow)                       │
                                 │  agentHandoffs ↓ (4 A2A Agents, in-app :8080)    ├─> PostgreSQL
                                 │                                                  │  predictive_
                    ┌────────────┼─────────────┬──────────────┐                    │  maintenance
                    ▼            ▼             ▼              ▼                     │
             sensor_analysis  prediction   work_order   alert_notification         │
                 _agent         _agent       _agent          _agent                │
                    │            │             │              │                     │
                    └──── REST (HTTP) → REST API Service (#rest :9095) ─────────────┘
                          GET /sensor-data · POST /predictions · /work-orders · /alerts
```

**Component roles**

- **MCP Server** (`predictive-maintenance-mcp-server.flogo`) — read-only lookups. Six stateless
  `SELECT` tools; the Orchestrator LLM picks one from its description and filters the returned rows.
- **REST API Service** (`predictive-maintenance-api.flogo`) — the write tier. Four REST endpoints
  that run the sensor-data read (`GET`) and the three writes (`POST`) against PostgreSQL. This is the
  only app that mutates the database.
- **Agent app** (`predictive-maintenance-agent.flogo`) — hosts the **AI Orchestrator** (WebSocket
  chat, LLM routing, sensor-threshold reasoning) **and** the **4 A2A Agents** it hands off to. Each
  A2A Agent is a thin flow that calls one REST endpoint and returns the result to the Orchestrator.

---

## Apps / Components

| App | File | Trigger | Port (property) + path |
|-----|------|---------|------------------------|
| MCP Server | `predictive-maintenance-mcp-server.flogo` | `#mcpserver` | `MCP_SERVER_PORT` = **9093**, path `/predmaintmcpserver` |
| REST API Service | `predictive-maintenance-api.flogo` | `#rest` | `API_PORT` = **9095**, paths under `/api/v1/...` |
| Agent app (Orchestrator + 4 A2A Agents) | `predictive-maintenance-agent.flogo` | `#wsserver` + 4 × `#agent` | WS **8083** (`/ws/chat`); A2A Agents share `agentPort` **8080** |

---

## MCP tools (read-only)

All served by `predictive-maintenance-mcp-server.flogo` (connection `PostgresConn` → `predictive_maintenance`).
Each tool runs a `SELECT` and returns rows; the LLM filters by asset id, status, etc.

| Tool | Table / source | What it answers |
|------|----------------|-----------------|
| `GetAssets` | `assets` | All pumps/compressors/valves with type, well-site assignment, operational status |
| `GetSensorReadings` | `sensor_readings` | Historical sensor readings (vibration, temp, pressure, flow, power) with timestamps |
| `GetPredictions` | `predictions` | AI health predictions: status, confidence, days-to-failure, failure mode, recommended action |
| `GetWorkOrders` | `work_orders` | Maintenance work orders: priority, assigned tech, schedule, completion status |
| `GetAlertHistory` | `alert_history` | Alert notifications: severity, message, acknowledgment status |
| `GetWellSites` | `well_sites` | Well-site locations: site name, physical location, operating region |

---

## A2A Agents

All four A2A Agents live inside `predictive-maintenance-agent.flogo` and **share the single
`agentPort` `8080`**. None of them touches PostgreSQL directly — each calls a REST endpoint on the
REST API Service (`predictive-maintenance-api.flogo`, port `9095`), which performs the DB operation.

| Agent | Port (property) | Action | REST endpoint called → writes to |
|-------|-----------------|--------|----------------------------------|
| `sensor_analysis_agent` | `agentPort` **8080** (shared) | Fetch latest sensor readings + asset details (no write) | `GET /api/v1/assets/{asset_id}/sensor-data` → reads `assets` + `sensor_readings` |
| `prediction_agent` | `agentPort` **8080** (shared) | Store an AI health prediction | `POST /api/v1/predictions` → INSERT `predictions` |
| `work_order_agent` | `agentPort` **8080** (shared) | Create a maintenance work order | `POST /api/v1/work-orders` → INSERT `work_orders` |
| `alert_notification_agent` | `agentPort` **8080** (shared) | Log a WARNING/CRITICAL alert (no email) | `POST /api/v1/alerts` → INSERT `alert_history` |

> The **Orchestrator** (agent name `Orchestrator-Agent`) is the AI brain: it exposes the six MCP
> tools for read-only queries and hands off to the four A2A Agents for actions. When it receives raw
> sensor readings from `sensor_analysis_agent`, **the LLM classifies health itself** (NORMAL /
> WARNING / CRITICAL) using the thresholds in its system prompt, then stores the result via
> `prediction_agent`. See **Reference: Orchestrator behavior** below.

The REST API URLs the agents call are app properties on the agent app:
`Sensor_Data_URL`, `Predictions_URL`, `WorkOrders_URL`, `Alerts_URL` — all default to
`http://localhost:9095/api/v1/...`.

---

## Database

PostgreSQL (14+), database **`predictive_maintenance`**. `database.sql` creates the schema (6 tables);
`reset_data.sql` truncates and re-seeds everything to a baseline (baseline date **2026-04-17**). Load /
reset with placeholders:

```bash
# create the schema
psql -h <host> -p <port> -U <user> -d predictive_maintenance -f database.sql
# seed / reset to baseline between demos
psql -h <host> -p <port> -U <user> -d predictive_maintenance -f reset_data.sql
```

**Seeded tables (row counts):** `well_sites` (**3**), `assets` (**8**), `sensor_readings` (**48** =
8 assets × 6 readings over the past 24h), `predictions` (**4** historical), `work_orders` (**2**
historical), `alert_history` (**2** historical).

Flagship data hooks:
- **`PUMP-W47-TX`** (Permian) — latest reading trends to **WARNING** (vibration 4.8g, temp 98.5°C) →
  the go-to asset for the analyze-and-predict demo. Left clean (no prediction) for a fresh run.
- **`COMP-W12-OK`** (Permian) — latest reading is **CRITICAL** (all sensors elevated: 6.5g / 112°C /
  1480 PSI) → drives the full-health-check demo that fires all four agents.
- **`PUMP-E14-TX`** (Eagle Ford) — a second **CRITICAL** pump (7.1g / 108°C / 580 PSI / 55 bbl/hr).
- **`VALVE-W03-NM`** (Bakken) — stable **NORMAL** asset → proves the LLM correctly skips work orders
  and alerts.
- **`PUMP-B21-ND`** (Bakken, status `MAINTENANCE`) — the only pre-seeded asset with history: 2
  predictions, 2 work orders, 2 alerts → drives read-only history queries.

---

## Demo scenarios

1. **List assets (MCP only).** "List all assets and their current status." → `GetAssets`.
2. **Sensor retrieval.** "Show the latest sensor readings for pump PUMP-W47-TX." → `sensor_analysis_agent`.
3. **Analyze + predict.** "Analyze the sensor readings for PUMP-W47-TX and generate a health prediction." → `sensor_analysis_agent` → LLM classifies (WARNING) → `prediction_agent`.
4. **Create a work order.** "Create a HIGH priority work order for COMP-W12-OK — compressor overheating, assign to Field Tech Team B, schedule for 2026-04-19." → `work_order_agent`.
5. **Send an alert.** "Send a CRITICAL alert for PUMP-E14-TX — multiple sensor failures, immediate shutdown recommended." → `alert_notification_agent`.
6. **⭐ Full health check (CRITICAL).** "Run a full health check on COMP-W12-OK — analyze sensors, store prediction, create work order if critical, and send alert." → `sensor_analysis_agent` → `prediction_agent` → `work_order_agent` → `alert_notification_agent`.
7. **Full health check (NORMAL).** "Run a full health check on VALVE-W03-NM." → `sensor_analysis_agent` → `prediction_agent` (NORMAL) → **no** work order, **no** alert.
8. **History queries (MCP only).** "Show all predictions stored so far" / "What work orders are open?" / "Show the alert history." → `GetPredictions` / `GetWorkOrders` / `GetAlertHistory`.
9. **Edge — unknown asset.** "Analyze sensor readings for PUMP-X99-UNKNOWN." → graceful not-found.
10. **Edge — out of scope.** "What is the current oil price per barrel?" → politely declines.

See `prompts.md` for the full, copy-pasteable prompt list and a suggested demo flow.

---

## Prerequisites

- **PostgreSQL** running; a database named **`predictive_maintenance`** created for this demo.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- **TIBCO Flogo Enterprise** — VS Code extension 2.26.7 or later (import the `.flogo` apps into the designer) — or the `flogobuild` CLI
  if you prefer to build `.exe`s; set the app properties listed below before you run.
- An **LLM provider** key (OpenAI-compatible). The base URL must be a **real endpoint**, e.g.
  `https://api.openai.com/v1`. The committed agent app ships with the base URL **blank** (see
  Troubleshooting).
- **Chatbot UI** — this demo uses a WebSocket orchestrator, so the bundled chat client at
  `samples/Agentic_AI/Chatbot` works out of the box (or point any WS test client at `ws://<host>:8083/ws/chat`).

---

## Setup & Run

1. **Database** — create `predictive_maintenance`, then load and seed:
   ```bash
   psql -h <host> -p <port> -U <user> -d predictive_maintenance -f database.sql
   psql -h <host> -p <port> -U <user> -d predictive_maintenance -f reset_data.sql
   ```
2. **Import the three apps** into Flogo Enterprise (or build each to an `.exe` with `flogobuild`).
3. **Set app properties** (DB creds, LLM key / base URL / model, ports, and the four `*_URL`
   properties on the agent app) — see the manual-config section below.
4. **Start order:** MCP Server (**9093**) → REST API Service (**9095**) → Agent app (**8083**).
5. **Invoke it** — start the chatbot UI and connect to the orchestrator:
   ```bash
   cd samples/Agentic_AI/Chatbot
   npm install    # first time only
   npm start
   ```

   Open **http://localhost:3000**, then:

   1. In the URL box at the top right, enter **`ws://localhost:8083/ws/chat`**.
   2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
      and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
   3. Click **Connect**. The status turns green: **● Connected**.

   **Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
   last URL you applied, so a URL from another demo is a common cause.

---

## Ports

| Component | Property | Default | Path |
|-----------|----------|---------|------|
| MCP Server | `MCP_SERVER_PORT` | **9093** | `/predmaintmcpserver` |
| REST API Service | `API_PORT` | **9095** | `/api/v1/...` |
| A2A Agents (all 4, shared) | `agentPort` (trigger setting) | **8080** | — |
| Orchestrator (WebSocket) | `#wsserver` trigger port | **8083** | `/ws/chat` |

---

## Troubleshooting

- **`unsupported protocol scheme` / posts to `/New_value/...`** — the LLM base URL is blank (it is,
  by default: `AgenticAI.OpenAIConn.LLM_Base_URL` = `""`). Set it to a real endpoint.
- **MCP runtime panics `missing input schema`** — an MCP tool handler is missing its input/output
  schema; **Sync** the MCP trigger in the designer.
- **A2A agent handoff fails with `missing substitution for: <name>`** — the agent flow's
  `input.mapping.parameters` (or the flow-input `toolParams` schema) is missing that param; patch it,
  then **Sync** the agent trigger to regenerate the design-time schemas.
- **Orchestrator can't reach a tool/agent** — the MCP connection `serverUrl`
  (`http://localhost:9093/predmaintmcpserver`) and the four REST `*_URL` app properties
  (`http://localhost:9095/api/v1/...`) must match the MCP and API ports. **If you change
  `MCP_SERVER_PORT` or `API_PORT`, update the agent app's connection URL and `*_URL` properties too.**
- **REST API 500 / no rows written** — the API app's `PredMaintConn` PostgreSQL connection must point
  at the same `predictive_maintenance` DB the MCP app reads; verify `Host`/`Port`/`Database_Name`/
  `User`/`Password` and that `reset_data.sql` ran cleanly.
- **`Configured connection is not a WebSocket Connection`** — the orchestrator's `wsconnection` /
  `content` fields were coerced to `object`; they must stay `any`.
- **Agent runs read-only actions via MCP by mistake** — remind the LLM (system prompt) to use MCP
  tools only for reads and to hand off to the A2A Agents for predictions / work orders / alerts.

---

## Reference: Orchestrator behavior

**Intent routing** (from the orchestrator system prompt):

| User request | What runs |
|--------------|-----------|
| "Show sensor readings for X" | `sensor_analysis_agent` only |
| "What's the status of X?" / "List assets / predictions / work orders / alerts" | MCP tools only (read-only) |
| "Analyze and predict health of X" | `sensor_analysis_agent` → LLM analyzes → `prediction_agent` |
| "Create work order for X" | `work_order_agent` only |
| "Send alert for X" | `alert_notification_agent` only |
| "Full health check for X" | `sensor_analysis_agent` → analyze → `prediction_agent` → (if WARNING/CRITICAL) `work_order_agent` → `alert_notification_agent` |

**Sensor thresholds** (the LLM applies these to the raw readings; worst single sensor sets overall status):

| Sensor | Normal | Warning | Critical |
|---|---|---|---|
| Vibration RMS (g) | < 3.5 | 3.5 – 6.0 | > 6.0 |
| Temperature (°C) | < 85 | 85 – 105 | > 105 |
| Pressure (PSI) | 800 – 1200 | 600–800 or 1200–1500 | < 600 or > 1500 |
| Flow Rate (bbl/hr) | 80 – 120 | 60–80 or 120–140 | < 60 or > 140 |

Confidence scales with the number of anomalous sensors (1→0.75, 2→0.85, 3→0.92, 4→0.97);
days-to-failure: CRITICAL 3–7, WARNING 10–21, NORMAL 90+. Failure modes: `bearing_wear`,
`overheating`, `seal_leak`, `pressure_anomaly`, `flow_blockage`, `electrical_fault`. Rules: never open
a work order or send an alert for a NORMAL asset; alert at most once per conversation; always store a
prediction after analyzing sensors.

---

## Reference: REST API specification

Served by `predictive-maintenance-api.flogo` (port `API_PORT` = 9095, connection `PredMaintConn`).

| # | Method + Path | Purpose | SQL |
|---|---------------|---------|-----|
| 1 | `GET /api/v1/assets/{asset_id}/sensor-data` | Asset details + latest reading | `SELECT ... FROM assets a LEFT JOIN sensor_readings sr ON a.asset_id = sr.asset_id WHERE a.asset_id = '{asset_id}' ORDER BY sr.id DESC LIMIT 1` |
| 2 | `POST /api/v1/predictions` | Store an AI prediction | `INSERT INTO predictions (...) VALUES (...) RETURNING prediction_id, ...` |
| 3 | `POST /api/v1/work-orders` | Create a work order | `INSERT INTO work_orders (...) VALUES (...) RETURNING work_order_id, ...` |
| 4 | `POST /api/v1/alerts` | Log an alert | `INSERT INTO alert_history (...) VALUES (...) RETURNING alert_id, ...` |

Full request/response shapes are in `api-spec.json` (OpenAPI 3.0). The `POST` bodies use string-typed
fields (`confidence`, `days_to_failure` are sent as strings and cast in SQL).

---

## Reference: Database schema

Database **`predictive_maintenance`** (DDL in `database.sql`):

| Table | Key columns |
|-------|-------------|
| `well_sites` | `well_site_id` PK, `site_name`, `location`, `region` |
| `assets` | `asset_id` PK, `asset_type` (PUMP/COMPRESSOR/VALVE), `well_site_id`, `description`, `install_date`, `status` (OPERATIONAL/MAINTENANCE/OFFLINE) |
| `sensor_readings` | `id` PK, `asset_id`, `reading_timestamp`, `vibration_rms`, `temperature_c`, `pressure_psi`, `flow_rate`, `power_consumption` |
| `predictions` | `prediction_id` PK, `asset_id`, `predicted_at`, `status`, `confidence`, `days_to_failure`, `failure_mode`, `recommended_action`, `sensor_anomalies` |
| `work_orders` | `work_order_id` PK, `asset_id`, `prediction_id`, `priority`, `description`, `assigned_to`, `scheduled_date`, `status`, `created_at` |
| `alert_history` | `alert_id` PK, `asset_id`, `prediction_id`, `severity`, `message`, `sent_at`, `status` |

Seeded assets (8) span three well sites — Permian Basin (`WS-PERMIAN-001`), Bakken (`WS-BAKKEN-002`),
Eagle Ford (`WS-EAGLE-003`). Each asset has 6 sensor readings (every 4h over the past 24h) whose
latest row encodes the intended health state (see flagship data above).

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The committed `.flogo` files carry placeholders / reference-app values for every secret; replace them
with your own before an end-to-end run. **Never commit real secrets.**

1. **LLM credentials & endpoint** (agent app).
   - `AgenticAI.OpenAIConn.API_Key` — set your real provider key (a `SECRET:` app property / platform
     secret; keep it out of the repo). The committed value is a placeholder secret — replace it.
   - `AgenticAI.OpenAIConn.LLM_Base_URL` — **currently blank**; set a real endpoint
     (`https://api.openai.com/v1`). An empty value becomes the literal `New_value` and the call fails
     with `unsupported protocol scheme`.
   - `LLM_Model` — the committed value is `gpt-5.5`; confirm it is a model your key can access.

2. **PostgreSQL database & credentials** (MCP app `PostgresConn`, API app `PredMaintConn`).
   - Create the **`predictive_maintenance`** database; load `database.sql`; run `reset_data.sql` to
     reset between demos.
   - Set `Host` / `Port` / `Database_Name` / `User` / `Password` on **both** connections to your
     instance. `Password` is a `SECRET:` app property — set the real secret in App Properties, not in
     plaintext. Both apps must point at the same DB.

3. **Ports must be free & consistent.**
   - MCP **9093**, REST API **9095**, A2A Agents **8080**, orchestrator WebSocket **8083** must all be
     free on the host.
   - The agent app's MCP connection `serverUrl` (`:9093/predmaintmcpserver`) and its four `*_URL`
     properties (`:9095/api/v1/...`) must match the MCP and API ports. Change a port → change it in
     the owning app **and** in these references.

4. **REST API URLs** (agent app properties `Sensor_Data_URL`, `Predictions_URL`, `WorkOrders_URL`,
   `Alerts_URL`).
   - All default to `http://localhost:9095/...`; update the host/port if the REST API Service runs
     elsewhere.

5. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://<host>:8083/ws/chat`. Use the bundled UI at
     `samples/Agentic_AI/Chatbot` (or any WS client). See `prompts.md` for ready-to-paste prompts.

6. **Flogo designer manual steps** (clear design-time validation).
   - **Sync every trigger** — the MCP trigger, each of the four `#agent` triggers, and the `#wsserver`
     trigger — once, so `toolParams` and WS input mappings render without a red ✗.
   - **Validate every connection** — PostgreSQL (`PostgresConn`, `PredMaintConn`), the LLM provider
     (`OpenAIConn`), and the MCP server config (`PredMaintMCPServer`) — click **Connect / Test** before running.

**Quick pre-flight checklist**

- [ ] DB `predictive_maintenance` created, `database.sql` + `reset_data.sql` loaded; row counts sane (well_sites 3, assets 8, sensor_readings 48, predictions 4, work_orders 2, alert_history 2)
- [ ] LLM `API_Key`, `LLM_Base_URL` (real endpoint — **not blank**), `LLM_Model` set
- [ ] PostgreSQL `Password` set on both `PostgresConn` and `PredMaintConn`; both point at the same DB
- [ ] All 4 ports free (9093 / 9095 / 8080 / 8083); agent app's MCP `serverUrl` + four `*_URL` props match the MCP/API ports
- [ ] Every trigger Synced; every connection validated in the designer
- [ ] Start order: MCP Server → REST API Service → Agent app; each logs a clean start
- [ ] Chatbot UI (or WS client) connects to `ws://localhost:8083/ws/chat` and gets a reply
