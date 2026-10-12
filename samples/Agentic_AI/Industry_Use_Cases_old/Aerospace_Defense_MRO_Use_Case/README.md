# Aerospace & Defense — MRO & AOG Operations Assistant

An **Agentic AI** demo for the **aerospace & defense / aircraft maintenance (MRO)** vertical, built on
TIBCO Flogo Enterprise. An **MRO controller** (maintenance operations coordinator) at a fictional
**Meridian Aerospace & Defense** chats with an AI assistant over WebSocket to **check fleet
airworthiness, review open work orders, look up maintenance history, check parts stock, find an
available certified technician, and triage AOG (Aircraft-on-Ground) events** — and, on confirmation,
to **schedule maintenance, order/expedite a part, dispatch a technician, and email operations a
confirmation**. The assistant looks the data up, performs the action against PostgreSQL, and notifies
ops by email.

> **Persona note:** this is an **operator-facing / back-office** assistant (like the Hospital
> reference use case), not a customer self-service one. The end user is a maintenance controller, so
> the tone is operational and the actions change fleet/maintenance state.

## What this demo does

- **Persona:** MRO Controller / Maintenance Operations Coordinator (back-office, self-service),
  working a fleet identified by **tail number** (commercial-derivative `N738MA`, defense `AD-0142`)
  and **work orders** (`WO-2026-00123`). Meridian operates a mixed fleet of commercial-derivative
  transports, business jets, and defense platforms out of a few bases (Edwards AFB, Palmdale,
  Meridian Field).
- **Problem automated:** the "is this tail airworthy, what's open on it, do we have the part and the
  lead time, who's certified and available to fix it, and can you resolve this AOG right now" load
  that normally means a controller juggling the maintenance system, the parts system, the tech
  roster, and email — resolved conversationally, grounded in live data.
- **Solution shape:** 3 Flogo apps — **1 MCP Server** (read-only lookup tools), **1 A2A Servers / Agents app**
  (action agents that write **directly to PostgreSQL** and send email), and **1 AI Orchestrator**
  (WebSocket chat, LLM routing). All state lives in **PostgreSQL**.
- **Locale / conventions:** USD for part prices (`NUMERIC(10,2)`); flight hours/cycles as integers;
  times are timezone-aware; the demo dataset is **`CURRENT_DATE`-relative** (due dates, AOG report
  times) so it always looks live.

---

## Architecture

```
Chatbot UI --WebSocket--> AI Orchestrator --MCP (HTTP streamable)--> MCP Server --\
                                 |                                                 +--> PostgreSQL
                                 \-A2A (HTTP)-----> A2A Servers / Agents ----------/   (+ Gmail SMTP for email)
```

```
                    ┌─────────────────────────┐
                    │     Chatbot UI          │
                    │  (WebSocket Client)     │
                    └───────┬─────────────────┘
                            │ WebSocket
                            │ ws://<host>:8085/mro
                            ▼
               ┌────────────────────────────────┐
               │  Aerospace MRO                 │
               │  AI Orchestrator               │
               │  (AerospaceMROAIOrchestrator)  │
               │  Port 8085 (WebSocket)         │
               │  LLM: OpenAI-compatible        │
               └───────┬───────────┬────────────┘
                       │           │
          MCP (HTTP)   │           │  A2A Servers / Agents
                       ▼           ▼
    ┌──────────────────────┐   ┌────────────────────────────────────┐
    │  Aerospace MRO       │   │  Aerospace MRO A2A Servers / Agents│
    │  MCP Server          │   │                                    │
    │  Port 9095           │   │  schedule_maintenance_agent  :8091 │
    │  /mromcpserver       │   │  order_part_agent            :8092 │
    │                      │   │  dispatch_technician_agent   :8093 │
    │  Tools (read-only):  │   │  send_confirmation_email     :8094 │
    │  - GetAircraft       │   │                                    │
    │  - GetWorkOrders     │   │  Writes to PostgreSQL              │
    │  - GetPartsInventory │   │  + Gmail SMTP for email            │
    │  - GetPartOrders     │   │                                    │
    │  - GetTechnicians    │   │                                    │
    │  - GetAOGIncidents   │   │                                    │
    └──────────┬───────────┘   └──────────────┬─────────────────────┘
               │                              │
               └──────────────┬───────────────┘
                              ▼
               ┌────────────────────────────┐
               │  PostgreSQL Database       │
               │  Database: aerospace_mro   │
               │  7 Tables                  │
               └────────────────────────────┘
```

- **MCP Server** — read-only lookups. Stateless, safe to retry; the LLM picks a tool from its
  description and filters the returned rows (by tail number, work-order number, part number, etc.).
- **A2A Servers / Agents** — action workflows. Each agent has its own trigger/port, guardrails, and system
  prompt. `schedule_maintenance_agent`, `order_part_agent`, and `dispatch_technician_agent` **write
  directly to PostgreSQL**; `send_confirmation_email_agent` sends via Gmail SMTP.
- **Orchestrator** — the AI brain. WebSocket chat endpoint; the LLM decides intent and either calls
  an MCP tool (data lookup) or hands off to an A2A agent (schedule, order part, dispatch, email).

---

## Apps / Components

| App | File | Trigger | Port (property) + path |
|-----|------|---------|------------------------|
| MCP Server | `AerospaceMROMCPServer.flogo` | `#mcpserver` | `MCP_SERVER_PORT` = **9095**, path `/mromcpserver` (Streamable HTTP) |
| A2A Servers / Agents | `AerospaceMROA2AServers.flogo` | `#agent` ×4 | see agent table below (**8091–8094**) |
| AI Orchestrator | `AerospaceMROAIOrchestrator.flogo` | `#wsserver` | **8085**, WebSocket path `/mro` |

---

## MCP tools (read-only)

All served by `AerospaceMROMCPServer.flogo`. Each tool runs a `SELECT * FROM public.<table>` and
returns the rows as a string; the LLM filters/joins by tail number, work-order number, part number,
technician id, etc.

| Tool | Table / source | What it answers |
|------|----------------|-----------------|
| `GetAircraft` | `aircraft` | Fleet master: tail number, model, platform type (Commercial/Defense), base, flight hours, cycles, airworthiness status (IN_SERVICE / IN_MAINTENANCE / AOG / GROUNDED), next check type + due date |
| `GetWorkOrders` | `work_orders` | Maintenance work orders: WO number, tail, type (Scheduled/Unscheduled/AOG/Inspection), description, priority (ROUTINE/URGENT/AOG), status (OPEN/IN_PROGRESS/AWAITING_PARTS/CLOSED), opened/due dates, assigned technician. Closed WOs double as maintenance history. |
| `GetPartsInventory` | `parts_inventory` | Spares stock: part number, description, applicable model, qty on hand, reorder level, warehouse/location, unit price, lead-time days, supplier |
| `GetPartOrders` | `part_orders` | Part order / expedite status: order id, part number, qty, tail, WO, priority (ROUTINE/EXPEDITE), status (ORDERED/IN_TRANSIT/RECEIVED), ordered date, expected delivery |
| `GetTechnicians` | `technicians` | Technician roster: tech id, name, base, certifications/skills (Hydraulics, Powerplant, Avionics, Structures…), shift, availability (AVAILABLE/ON_SHIFT/OFF), contact |
| `GetAOGIncidents` | `aog_incidents` | Aircraft-on-Ground events: AOG id, tail, location, reported time, reason, severity, status (OPEN/RESOLVING/RESOLVED), resolution notes |

> The `notification_log` table (email audit) is **write-only** — filled by the email agent — so it is
> not exposed as an MCP tool (matches the reference use cases' log-table convention).

---

## A2A action agents

All served by `AerospaceMROA2AServers.flogo`. Each agent has its own trigger, port, LLM, and system
prompt. Default action pattern is a **direct PostgreSQL write** (`noop → log → [query to validate] →
insert/update → log → actreturn`); the email agent uses `noop → sendmail → log → actreturn`.

| Agent | Port | Action type | What it does | Writes to |
|-------|------|-------------|--------------|-----------|
| `schedule_maintenance_agent` | 8091 | DB write (INSERT) | Opens a new work order (scheduled check / inspection / unscheduled task) for a tail. Validates the tail exists. | `work_orders` |
| `order_part_agent` | 8092 | DB write (INSERT) | Raises a part order, optionally **EXPEDITE**, against a WO/tail. Validates the part exists and flags when qty is at/below reorder level. | `part_orders` |
| `dispatch_technician_agent` | 8093 | DB write (UPDATE) | Assigns an available, suitably-certified technician to a work order (and moves the WO to IN_PROGRESS / the AOG to RESOLVING). Validates tech availability. | `work_orders`, `aog_incidents` |
| `send_confirmation_email_agent` | 8094 | Email (SMTP) | Emails operations/crew a confirmation of the action taken (AOG triage summary, dispatch, part ETA). | `notification_log` |

**toolParams (what the orchestrator passes each agent):**

- `schedule_maintenance_agent`: `tail_number`, `wo_type`, `description`, `priority`, `due_date`
- `order_part_agent`: `part_number`, `quantity`, `tail_number`, `wo_number`, `priority` (ROUTINE/EXPEDITE)
- `dispatch_technician_agent`: `wo_number`, `tech_id`
- `send_confirmation_email_agent`: `to_email` (defaults to the ops property), `subject`, `body`

---

## AI Orchestrator (routing brain)

`AerospaceMROAIOrchestrator.flogo` — WebSocket trigger (`#wsserver`, port **8085**, path `/mro`) →
AI Agent activity → write reply back over the socket. The AI Agent lists the MCP server under
`mcpServers` and all four A2A agents under `remoteAgents`, and its system prompt encodes the routing
rules:

- **Lookups** ("what's the status of AD-0142", "any open work orders", "do we have part PN-4471-A",
  "who's available", "what's AOG right now") → MCP tools.
- **Actions** (schedule a check, order/expedite a part, dispatch a tech, email ops) → the matching
  A2A agent, **only after confirming details with the controller**.
- **Multi-step AOG resolution** (the flagship) → chain lookups + several A2A agents in one thread.
- Decline politely and stay in scope for anything outside fleet maintenance.

---

## Database (`aerospace_mro`, PostgreSQL 14+)

| Table | Purpose | Seeded rows (approx) |
|-------|---------|----------------------|
| `aircraft` | Fleet master, keyed by `tail_number` (the natural id used in chat) | ~8 aircraft (commercial-derivative + defense; incl. 1–2 currently AOG) |
| `work_orders` | Maintenance work orders; write-target for `schedule_maintenance_agent`; closed rows act as history | ~10 (open / in-progress / awaiting-parts / closed) |
| `parts_inventory` | Spares stock with reorder levels + lead times | ~10 parts (incl. 1 at/below reorder, 1 out of stock/long lead) |
| `part_orders` | Part order/expedite records; write-target for `order_part_agent` (1–2 pre-seeded for status lookups) | ~2 pre-seeded, rest agent-written |
| `technicians` | Technician roster with certifications + availability | ~6 (mixed skills; some AVAILABLE, some busy) |
| `aog_incidents` | Aircraft-on-Ground events; status updated by `dispatch_technician_agent` | ~2 open + 1 resolved |
| `notification_log` | Email audit; write-only, filled by `send_confirmation_email_agent` | 0 (agent-filled) |

**Demo data is engineered per scenario** — each write agent has a clean/happy-path record and an
exception record (part out of stock, no available certified tech, unknown tail/part) so failures can
be demoed gracefully. `database.sql` loads schema + data; `reset_data.sql` truncates and reloads with
volatile dates relative to today.

---

## Demo scenarios (headline walkthroughs)

1. **Fleet & airworthiness lookup (MCP only)** — "What's the status of tail AD-0142?" · "Which
   aircraft are AOG right now?" · "When is N738MA's next check due?"
2. **Open work & history (MCP only)** — "Show me open work orders for AD-0198." · "What maintenance
   has been done on N738MA this year?"
3. **Parts & technicians (MCP only)** — "Do we have hydraulic pump PN-4471-A in stock?" · "Who's a
   hydraulics-certified tech available at Edwards?"
4. **Schedule maintenance (MCP + A2A write)** — "N738MA is coming up on its A-check — open a
   scheduled work order due next Friday." → `schedule_maintenance_agent` inserts a WO.
5. **Order / expedite a part (MCP + A2A write)** — "We're short on PN-4471-A for AD-0142 — order 2,
   expedite." → `order_part_agent` (flags stock below reorder, raises an EXPEDITE order).
6. **Dispatch a technician (MCP + A2A write)** — "Assign Marcus Reid to WO-2026-00123." →
   `dispatch_technician_agent` (validates availability, moves WO to IN_PROGRESS).
7. **⭐ Flagship — full AOG resolution (MCP + all A2A)** — "Tail AD-0142 is AOG at Edwards with a
   hydraulic pump failure — figure out what we need and resolve it." → the orchestrator checks the
   AOG record + aircraft (MCP), checks pump stock (MCP), **expedites the part** (A2A), **dispatches a
   certified tech** and moves the AOG to RESOLVING (A2A), then **emails ops a summary** (A2A).
8. **Exception / out-of-scope** — order an unknown part (`PN-9999-Z`), dispatch to a non-existent WO,
   AOG needing a part that's out of stock everywhere, or "book me a flight" (declined politely).

Full prompt list ships in [`prompts.md`](prompts.md).

---

## Prerequisites

- **TIBCO Flogo Enterprise** (VS Code extension 2.26.7 or later) to import/run the apps.
- **PostgreSQL 14+** reachable from the apps; ability to create the `aerospace_mro` database.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- **An LLM provider** — OpenAI (or OpenAI-compatible) API key, a real base URL
  (`https://api.openai.com/v1`), and a model your key can access.
- **Gmail App Password** (for the email agent) — SMTP `smtp.gmail.com:465`.
- A **WebSocket chat client / UI** to talk to `ws://<host>:8085/mro` (none is bundled).

---

## Setup & Run

1. **Database:** `createdb aerospace_mro` → `psql -d aerospace_mro -f database.sql` → verify row
   counts. Reset between demos with `psql -d aerospace_mro -f reset_data.sql`.
2. **Import** the three `.flogo` apps into Flogo Enterprise.
3. **Set app properties** per app (DB host/port/db/user/password; LLM provider/key/base-URL/model;
   ports; email username/app-password/recipient). See the manual-config section below.
4. **Start order: MCP → A2A → Orchestrator.** Each should log a clean start; the orchestrator log
   should show it discovered the MCP tool list and connected to all four A2A agent cards.
5. **Open the chatbot and connect** — the shared web client in `samples/Agentic_AI/Chatbot`:
   ```bash
   cd samples/Agentic_AI/Chatbot
   npm install    # first time only
   npm start
   ```

   Open **http://localhost:3000**, then:

   1. In the URL box at the top right, enter **`ws://localhost:8085/mro`**.
   2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
      and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
   3. Click **Connect**. The status turns green: **● Connected**.

   **Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
   last URL you applied, so a URL from another demo is a common cause.

   Then run the prompts in `prompts.md`.

---

## Ports

| App / agent | Port | Property | Notes |
|-------------|------|----------|-------|
| MCP Server | 9095 | `MCP_SERVER_PORT` (string) | path `/mromcpserver`, Streamable HTTP |
| schedule_maintenance_agent | 8091 | `SCHEDULE_MAINTENANCE_AGENT_PORT` (string) | A2A |
| order_part_agent | 8092 | `ORDER_PART_AGENT_PORT` (string) | A2A |
| dispatch_technician_agent | 8093 | `DISPATCH_TECHNICIAN_AGENT_PORT` (string) | A2A |
| send_confirmation_email_agent | 8094 | `SEND_CONFIRMATION_EMAIL_AGENT_PORT` (string) | A2A |
| AI Orchestrator | 8085 | `WebSocket_PORT` (number) | WebSocket path `/mro` |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| MCP server panics on start with `missing input schema` | A tool handler lacks its input/output schema | Rebuild the tool via `fda` (recipes attach both) |
| LLM call fails / posts to `/New_value/...` | `LLM_Base_URL` left blank | Set a real endpoint (`https://api.openai.com/v1`) |
| A2A connection dropdown empty / "Connection is required" | `input.Connection` isn't the literal `conn://<uuid>` | Patch to the connection's current id (don't regenerate the file) |
| SendMail: `Type of field 'Password' (password) differs …` | Email password is plaintext, not a secret | Re-enter it in App Properties so it's stored `SECRET:` (keep type `string`) |
| wsserver nil-panics / "not a WebSocket Connection" | handler output schema / `wsconnection` typing | Handled by the recipe (headers schema + `wsconnection`/`content` = `any`) |

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The three apps were generated with the Flogo Design CLI. Everything structural — the
`mcpServers` / `remoteAgents` `conn://` arrays, every tool/handler schema, the wsserver headers
schema, and the `wsconnection`/`content` = `any` typing — **is already wired**. The items below are
intentionally **not** set because they are environment-, secret-, or host-specific. Configure each
before an end-to-end run.

1. **LLM credentials & endpoint** (`AgenticAI.OpenAIConn.*` + `LLM_Model`, in the A2A app and the
   orchestrator).
   - `API_Key` — set your real provider key (kept out of the repo; inject at deploy).
   - `LLM_Base_URL` — must be a **real endpoint** (`https://api.openai.com/v1`). A blank value
     becomes the literal `New_value` and the LLM call fails with `unsupported protocol scheme`.
   - `LLM_Model` — confirm it's a model your key can access.

2. **PostgreSQL database & credentials** (`PostgreSQL.PostgresConn.Host/Port/Database_Name/User/Password`,
   in the MCP and A2A apps; `Database_Name` = `aerospace_mro`).
   - `createdb aerospace_mro` → `psql -d aerospace_mro -f database.sql`; reset with `reset_data.sql`.
   - Set the connection properties to your instance; keep `Password` a real secret, not committed.
   - Sanity-check: run each MCP tool's `SELECT` and each A2A write's SQL against the DB.

3. **Ports must be free & consistent.**
   - MCP **9095**, A2A **8091–8094**, orchestrator **8085** must be free on the host.
   - The orchestrator's MCP `serverUrl` (`http://localhost:9095/mromcpserver`) and the four A2A
     `serverUrl`s (`http://localhost:8091..8094`) must match those ports. If you change a port,
     change it in the property **and** in the matching orchestrator connection URL.

4. **Email / SMTP** (`Email_Username`, `Email_App_Password`, `To_Email` in the A2A app; Gmail
   `smtp.gmail.com:465`, SSL).
   - Set the username, the recipient (`To_Email`), and an **app-specific** password (not the
     account password). Confirm outbound SMTP is allowed from the host.
   - **Re-enter `Email_App_Password` in the designer's App Properties so it is stored as a `SECRET:`
     value — and leave its type as `string`.** FDA `cap` writes it as a plaintext `string`, but the
     `#sendmail` `Password` field only binds cleanly to a **secret-valued** property (otherwise:
     *"Type of field 'Password' (password) differs from bound app property (string)"*). Re-typing the
     value once in App Properties encrypts it to `SECRET:…` and clears the ✗. ⚠️ **There is no
     `password` app-property type** — setting one makes the designer silently drop the property on
     save (*"'Password' is bound to app property 'Email_App_Password' which does not exist"*). It
     builds/runs as a string either way; this only clears designer validation.

5. **Chatbot / WebSocket client.** The orchestrator exposes `ws://<host>:8085/mro`. Point your chat
   UI (or a WS test client) at it — no UI is bundled.

6. **Deploy-time secret injection** (if deploying to TIBCO Platform / Control Plane rather than
   running the local build). Provide `API_Key`, DB `Password`, and `Email_App_Password` as platform
   secrets / app properties at deploy; don't ship them inside the app.

7. **Flogo Design Assistant (FDA) manual steps** _(Tech-Preview limitations — the apps still
   build/run; these clear designer validation and cover what FDA cannot configure)._
   - **Sync every trigger.** FDA-built triggers are non-OpenAPI (`#mcpserver`, `#agent`, `#wsserver`),
     so some trigger/flow-input fields (the `toolParams` and input mappings) render with a red ✗
     until you open each trigger and click **Sync** once.
   - **Validate every connection.** FDA creates connections **without** validating them. Open each
     (PostgreSQL, LLM provider, the MCP connection, the four A2A connections) and click
     **Connect / Test** before running.
   - **Set the email password as a secret** — item 4 above.
   - **Certificates.** FDA can't add certificates. If your DB/TLS or SMTP needs a server certificate,
     add it manually.

**Quick pre-flight checklist**

- [ ] DB created, `database.sql` loaded, row counts sane (`reset_data.sql` resets between demos)
- [ ] LLM `API_Key`, `LLM_Base_URL` (real endpoint), `LLM_Model` set in A2A app **and** orchestrator
- [ ] All ports free; orchestrator MCP/A2A URLs match the MCP/A2A ports
- [ ] SMTP reachable; `Email_App_Password` stored as `SECRET:` (type left as `string`)
- [ ] Every trigger Synced; every connection Validated in the designer
- [ ] Start order: MCP → A2A → Orchestrator; each logs a clean start (orchestrator discovers the MCP
      tool list and connects to all four A2A agent cards)
- [ ] WebSocket client connects to `ws://<host>:8085/mro` and gets a reply
