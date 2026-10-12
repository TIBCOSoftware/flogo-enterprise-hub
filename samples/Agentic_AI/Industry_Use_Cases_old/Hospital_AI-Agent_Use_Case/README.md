# Hospital Post-Discharge AI Assistant

An **Agentic AI** demo for the **hospital / patient-care** vertical. A **ward nurse,
discharge coordinator, or care-desk operator** chats with an AI assistant over WebSocket to
**look up a patient's discharge summary, medications, appointments, pharmacy orders, bed status,
and specialties**, and — on request — **book a follow-up appointment, create pharmacy orders,
initiate bed turnover/cleaning, and email a discharge confirmation** to the patient. The
assistant reads the data, runs the action, and returns a consolidated, healthcare-appropriate
summary.

- **Persona:** Discharge coordinator / ward nurse (self-service), working with patients
  identified as `P-2024-00XXX`.
- **Problem automated:** the manual, multi-system post-discharge choreography — pull the
  discharge summary, book the right specialty follow-up, order every prescribed medication, flag
  the vacated bed for housekeeping, and notify the patient — resolved conversationally, grounded
  in live data.
- **Solution shape:** 3 Flogo apps — **1 MCP Server** (read-only tools), **1 A2A Servers / Agents app**
  (action agents), and **1 AI Orchestrator** (WebSocket chat, LLM intent routing). All state
  lives in **PostgreSQL**.

---

## Architecture

```
                                        /-- MCP (HTTP streamable) --> MCP Server --------------\
Chatbot UI --WebSocket--> AI Orchestrator                                                       +--> PostgreSQL
                                        \-- A2A (HTTP) --> A2A Agents --REST--> endevour-api ---/   (+ SMTP for email)
```

- **MCP Server** (`Hospital_MCP_Server.flogo`) — read-only lookups. Stateless, safe to retry;
  the LLM picks a tool from its description and filters the returned rows.
- **A2A Servers / Agents** (`HospitalA2AServers.flogo`) — action workflows. Each agent has its own
  trigger/port, guardrails, and system prompt. In this original version the write agents **call
  the `endevour-api` REST layer** (which persists to PostgreSQL) rather than writing SQL directly;
  the `SendEmail` agent sends email via SMTP.
- **AI Orchestrator** (`HospitalAIOrchestrator.flogo`) — the AI brain. WebSocket chat endpoint;
  the LLM decides intent and either calls an MCP tool (read) or hands off to an A2A Agent (action).

**Extra apps also present in this folder** (used by the core set):
- `endevour-api.flogo` — the PostgreSQL-backed REST backend the A2A Agents call. **Required** for
  the write agents to work.
- `eai-api.flogo` — a lightweight supplementary REST API.

---

## Apps / Components

**Core 3-app agentic set:**

| App | File | Trigger | Port (property) + path |
|-----|------|---------|------------------------|
| MCP Server | `Hospital_MCP_Server.flogo` | `#mcpserver` | `MCP_SERVER_PORT` = **9092**, path `/hospitalmcpserver` |
| A2A Servers / Agents | `HospitalA2AServers.flogo` | `#agent` ×4 | see agent table below (**8070–8073**) |
| AI Orchestrator | `HospitalAIOrchestrator.flogo` | `#wsserver` | `WebSocket_PORT` = **8652**, path `/hospital` |

**Extra / supporting apps:**

| App | File | Trigger | Port (property) + path | Role |
|-----|------|---------|------------------------|------|
| REST backend | `endevour-api.flogo` | `#rest` | `API_PORT` = **9095**, base `/api/v1` | PostgreSQL-backed REST API called by the A2A write agents (discharge-summary, appointments, pharmacy orders, beds). Start it **before** the A2A app. |
| Supplementary API | `eai-api.flogo` | `#rest` | **9999** (fixed), `GET /appointments` | Lightweight standalone appointments endpoint; optional. |

---

## MCP tools (read-only)

All served by `Hospital_MCP_Server.flogo` (path `/hospitalmcpserver`). Each tool runs a `SELECT`
and returns rows; the LLM filters/joins by patient id, bed id, discharge id, etc.

| Tool | Table / source | What it answers |
|------|----------------|-----------------|
| `GetPatients` | `patients` | Patient roster: name, phone, email |
| `GetBeds` | `beds` | Every bed's ward, occupant, status, and estimated-ready time |
| `GetAppointments` | `appointments` | Which patient booked which specialty appointment, on what date/time |
| `GetPatientDischarges` | `patient_discharges` | Discharge records: date, ward/bed, follow-up flag, specialty |
| `GetDischarge_medications` | `discharge_medications` | Medications prescribed at discharge (by discharge_id / medication_code) |
| `GetMedicationName` | `medication_catalog` | Drug name + how many hours until ready, by medication code |
| `GetPharmacyOrders` | `pharmacy_orders` | Pharmacy orders: which drug for which patient, pickup location, availability |
| `GetSpeciality` | `specialties` | Specialty name by specialty code |

---

## A2A action agents

All served by `HospitalA2AServers.flogo`. Each write agent calls the `endevour-api` REST layer
(port **9095**), which persists to PostgreSQL; the `SendEmail` agent uses SMTP.

| Agent | Port (property) | Action | Writes to (via endevour-api) |
|-------|-----------------|--------|------------------------------|
| `post_discharge_coordinator` | `Post_Discharge_A2AServer_PORT` = **8070** | Retrieve discharge summary and book the follow-up appointment (specialty from summary, ~7 days out) | `appointments` (`POST /api/v1/appointments`) |
| `pharmacy_fulfillment_agent` | `Pharmacy_Fullfillment_A2AServer_PORT` = **8071** | Create a pharmacy order per prescribed medication | `pharmacy_orders` (`POST /api/v1/pharmacy/orders`) |
| `bed_turnover_agent` | `Bed_Turnover_A2AServer_PORT` = **8072** | Flag the vacated bed for cleaning and clear its occupant | `beds` (`POST /api/v1/beds/actions`) |
| `SendEmail` | `SendEmail_A2AServer_PORT` = **8073** | Email the patient a discharge/appointment confirmation | SMTP (`smtp.gmail.com`, app password) |

> The orchestrator's LLM only invokes `SendEmail` when the user **explicitly** asks for an email,
> and never more than once per conversation (enforced in its system prompt).

---

## Database

PostgreSQL (14+). `database.sql` creates the 8-table schema and seeds a small baseline;
`reset_data.sql` truncates and re-seeds a fuller demo baseline (dates anchored to **2026-07-28**)
and clears the agent-written tables for the test patients between runs.

**Tables (row counts after `reset_data.sql`):** `specialties` (5), `medication_catalog` (10),
`patients` (10), `patient_discharges` (10), `discharge_medications` (10), `appointments` (5),
`pharmacy_orders` (4), `beds` (10).

- **Read tables (MCP tools):** `patients`, `patient_discharges`, `discharge_medications`,
  `medication_catalog`, `specialties`, plus the agent-written ones below (for lookups).
- **Agent-written tables:** `appointments`, `pharmacy_orders`, `beds` — for the four "test"
  patients (P-2024-00122/00123/00125/00126) these are left **clean** so the agents' writes are
  visible; the other patients carry historical rows.

Flagship data hooks:
- **`P-2024-00123` (John Tan)** — discharging today, `CARDIOLOGY` follow-up, **3 medications**
  (Aspirin, Metoprolol, Atorvastatin), bed `BED-4A-010` / `WARD-4A` → the flagship
  **full-workflow** demo (summary → appointment → 3 orders → bed cleanup → email).
- **`P-2024-00122` (Bob Tan)** — discharging today, `ORTHOPEDICS` follow-up, **1 medication**
  (Paracetamol), bed `BED-3B-001` → the simple full-workflow demo.
- **`P-2024-00125` (David Wong)** — discharging today, **no follow-up**, 1 medication (Amoxicillin)
  → edge case: agent should book no appointment.
- **`P-2024-00128` (Emily Goh)** — follow-up required, **no medications** → edge case: no orders.
- **`P-2024-00121` (Alice Ng)** — a **past** discharge, no follow-up, no meds → read-only lookup.

```bash
# load schema + baseline:
psql -h <host> -p <port> -U <user> -d <database> -f database.sql
# reset to the fuller demo baseline between runs:
psql -h <host> -p <port> -U <user> -d <database> -f reset_data.sql
```

---

## Demo scenarios

1. **Discharge summary only.** "Get the discharge summary for patient P-2024-00125." →
   `post_discharge_coordinator` (read) / `GetPatientDischarges`.
2. **Summary + appointment.** "Get the discharge summary for P-2024-00123 and book a follow-up." →
   `post_discharge_coordinator`.
3. **Medication order only.** "Order Paracetamol 500mg (MED006) for P-2024-00122, 7-day supply." →
   `pharmacy_fulfillment_agent`.
4. **Bed cleanup only.** "Patient left BED-2A-002 in WARD-2A — start bed cleaning." →
   `bed_turnover_agent`.
5. **Discharge + all meds.** "Process discharge for P-2024-00126 and order all prescribed
   medications." → `post_discharge_coordinator` + `pharmacy_fulfillment_agent`.
6. **Discharge + bed.** "Get the summary for P-2024-00128 and clean their bed." →
   `post_discharge_coordinator` + `bed_turnover_agent`.
7. **Full (no email).** "Complete the discharge for P-2024-00122 — appointment, meds, and bed
   cleanup." → coordinator → pharmacy → bed.
8. **⭐ Flagship full workflow + email.** "Complete the full discharge for P-2024-00123 including
   follow-up appointment, all medication orders, bed cleanup, and send the confirmation email." →
   `post_discharge_coordinator` → `pharmacy_fulfillment_agent` → `bed_turnover_agent` → `SendEmail`.
9. **Edge — no follow-up, has meds.** "Full discharge for P-2024-00125." → no appointment booked,
   1 pharmacy order, bed cleanup.
10. **Scope boundary.** "What's the recommended dosage of Aspirin?" / "How much does P-2024-00123
    owe?" → the agent politely declines (out of scope).

See [prompts.md](prompts.md) for the full, copy-pasteable list of 19 test scenarios and expected
results, and [agents.md](agents.md) for each agent's system prompt and handover schema.

---

## Prerequisites

- **PostgreSQL** running; a database created for this demo, loaded from `database.sql`.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- **TIBCO Flogo Enterprise** — VS Code extension 2.26.7 or later (import the `.flogo` apps into the designer) — or the `flogobuild`
  CLI if you prefer to build `.exe`s; set the app properties listed below before you run.
- An **LLM provider** key (OpenAI-compatible; the apps default to model `gpt-5.5`). The base URL
  must be a **real endpoint**, e.g. `https://api.openai.com/v1` — it ships **blank** and must be set.
- **SMTP** access for the `SendEmail` agent (Gmail: `smtp.gmail.com`, an app-specific password).
- A **chatbot / WebSocket client** — the shared UI under `samples/Agentic_AI/Chatbot` works
  (there is no UI bundled in this folder).

---

## Setup & Run

1. **Database**
   ```bash
   psql -h <host> -p <port> -U <user> -d <database> -f database.sql
   # between demos:
   psql -h <host> -p <port> -U <user> -d <database> -f reset_data.sql
   ```
2. **Import / build the apps** into Flogo Enterprise (or build each with `flogobuild`): the three
   core apps plus `endevour-api.flogo` (and optionally `eai-api.flogo`).
3. **Set app properties** — PostgreSQL creds, LLM key/base URL/model, SMTP creds, the
   `endevour-api` URLs (`Appointments_URL`, `Discharge_Summary_URL`, `Pharmacy_Orders_URL`,
   `Beds_URL`), the ports, and the recipient email — see the manual-config section below.
4. **Start order:** `endevour-api` (REST backend) → **MCP Server** → **A2A Servers / Agents** →
   **AI Orchestrator**. (`eai-api` is optional.)
5. **Open the chatbot and connect** — the shared web client in `samples/Agentic_AI/Chatbot`:
   ```bash
   cd samples/Agentic_AI/Chatbot
   npm install    # first time only
   npm start
   ```

   Open **http://localhost:3000**, then:

   1. In the URL box at the top right, enter **`ws://localhost:8652/hospital`**.
   2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
      and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
   3. Click **Connect**. The status turns green: **● Connected**.

   **Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
   last URL you applied, so a URL from another demo is a common cause.

---

## Ports

| Component | Property | Default | Path |
|-----------|----------|---------|------|
| MCP Server | `MCP_SERVER_PORT` | 9092 | `/hospitalmcpserver` |
| post_discharge_coordinator | `Post_Discharge_A2AServer_PORT` | 8070 | — |
| pharmacy_fulfillment_agent | `Pharmacy_Fullfillment_A2AServer_PORT` | 8071 | — |
| bed_turnover_agent | `Bed_Turnover_A2AServer_PORT` | 8072 | — |
| SendEmail | `SendEmail_A2AServer_PORT` | 8073 | — |
| AI Orchestrator (WebSocket) | `WebSocket_PORT` | 8652 | `/hospital` |
| endevour-api (REST backend) | `API_PORT` | 9095 | `/api/v1/...` |
| eai-api (supplementary) | — | 9999 | `GET /appointments` |

---

## Troubleshooting

- **`unsupported protocol scheme` / posts to `/New_value/...`** — the LLM base URL is blank
  (it ships empty in these apps); set `LLM_Base_URL` to a real endpoint.
- **MCP runtime panics `missing input schema`** — a tool handler is missing its input/output
  schema; open the MCP trigger and **Sync** it.
- **`missing substitution for: <name>`** on an A2A agent — the runtime `input.mapping.parameters`
  is missing that param; patch it, then **Sync** the agent flow to regenerate the design-time schemas.
- **A2A write agents fail / connection refused on `:9095`** — the `endevour-api` backend isn't
  running or the `*_URL` properties don't match its `API_PORT`; start `endevour-api` **first**.
- **`Configured connection is not a WebSocket Connection`** — the orchestrator's `wsconnection` /
  `content` were coerced to `object`; they must stay type `any`.
- **Email field warns "type … differs from bound app property"** — re-enter `Email_App_Password`
  in App Properties so it is stored as a `SECRET:` (keep the property type `string`).
- **Orchestrator can't reach a tool/agent** — the MCP `serverUrl`
  (`http://localhost:9092/hospitalmcpserver`) and each A2A `serverUrl` (8070–8073) must match the
  ports above.

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The committed `.flogo` files carry placeholders / reference-app values for every secret; replace
them with your own before an end-to-end run. **Never commit real secrets.**

1. **LLM credentials & endpoint.**
   - `API_Key` — set your real provider key (inject as an app property / platform secret; keep it
     out of the repo).
   - `LLM_Base_URL` — a **real endpoint** (`https://api.openai.com/v1`). It ships **blank**; an
     empty value becomes the literal `New_value` and the LLM call fails with
     `unsupported protocol scheme`.
   - `LLM_Model` — confirm the model name (default `gpt-5.5`) is one your key can access.

2. **PostgreSQL database & credentials.**
   - Create the database and load `database.sql`; run `reset_data.sql` to reset between demos.
   - Set the PostgreSQL connection `Host` / `Port` / `Database_Name` / `User` / `Password` to your
     instance. `Password` is a `SECRET:` app property — set the real secret in App Properties, not
     in plaintext. Set it in **both** the MCP Server and `endevour-api` apps.

3. **endevour-api URLs & ports.**
   - The A2A Agents call `endevour-api` via `Appointments_URL`, `Discharge_Summary_URL`,
     `Pharmacy_Orders_URL`, and `Beds_URL` (default `http://localhost:9095/...`). Point these at
     the host/port where `endevour-api` actually runs.

4. **Ports must be free & consistent.**
   - MCP **9092**, A2A **8070–8073**, orchestrator WebSocket **8652**, and `endevour-api`
     **9095** must all be free on the host.
   - The orchestrator's MCP `serverUrl` and each A2A `serverUrl` must match those ports. If you
     change a port, change it in the app property **and** in the corresponding orchestrator
     connection URL.

5. **Email / SMTP** (the `SendEmail` agent).
   - Set `Email_Username`, `Email_App_Password` (an app-specific password, **not** the account
     password), and the recipient `To_Email` property.
   - Confirm outbound SMTP (`smtp.gmail.com`) is allowed from the host/network.
   - **Re-enter `Email_App_Password` in App Properties so it is stored as a `SECRET:` value**
     (leave the property type as `string` — there is no `password` app-property type).

6. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://<host>:8652/hospital`. Point your chat UI (or the sample UI in
     `samples/Agentic_AI/Chatbot`) at it — there is no UI bundled in this folder. See `prompts.md`
     for ready-to-paste demo prompts.

7. **Flogo designer manual steps** (clear design-time validation).
   - **Sync every trigger** (MCP, each A2A agent, the WS server) once, so `toolParams` and WS
     input mappings render without a red ✗.
   - **Validate every connection** (PostgreSQL, LLM provider, MCP server config, all four A2A
     server connections) — click **Connect / Test** before running.
   - **Set the email password as a secret** — see item 5.

**Quick pre-flight checklist**

- [ ] DB created, `database.sql` loaded, `reset_data.sql` run; row counts sane (patients 10, beds 10, discharges 10)
- [ ] LLM `API_Key`, `LLM_Base_URL` (real endpoint, not blank), `LLM_Model` set
- [ ] PostgreSQL `Password` set in **both** the MCP Server and `endevour-api`; queries run cleanly
- [ ] `endevour-api` running on `API_PORT` 9095; the four `*_URL` properties point to it
- [ ] All ports free (9092, 8070–8073, 8652, 9095); orchestrator MCP/A2A URLs match the app ports
- [ ] `Email_App_Password` re-entered as a `SECRET:` (type stays `string`); SMTP reachable
- [ ] Every trigger Synced; every connection validated in the designer
- [ ] Start order: endevour-api → MCP → A2A → Orchestrator; each logs a clean start
- [ ] WebSocket client connects to `ws://<host>:8652/hospital` and gets a reply

---

## Supporting files

| File | Description |
|------|-------------|
| `agents.md` | Agent definitions, system prompts, and handover-context schemas |
| `prompts.md` | 19 test prompts (single-agent, multi-agent, full-workflow, edge cases) |
| `hospital.spec.md` | Use-case spec |
| `hospital-poc.md` | Full POC document (architecture, scenarios, demo script) |
| `swagger.json` | OpenAPI 3.0 spec for the Hospital Management REST API |
| `api-endpoints.txt` | Quick reference for the REST endpoints with request/response examples |
| `database.sql` | PostgreSQL DDL + initial seed data |
| `reset_data.sql` | Truncate + re-seed to the demo baseline (anchored to 2026-07-28) |
