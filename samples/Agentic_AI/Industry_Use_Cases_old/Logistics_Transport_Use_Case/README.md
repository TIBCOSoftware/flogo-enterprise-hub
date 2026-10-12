# Logistics / Transport — Shipper Self-Service AI Assistant

An **Agentic AI** demo for the Logistics / Transport vertical, built entirely with the
**TIBCO Flogo Design CLI (`flogodesign-cli` / `fda`)**. A **shipper (customer)** chats with an
AI assistant over WebSocket to **track shipments, understand service levels, reschedule or
redirect a delivery, book a pickup, and file a claim** — the assistant looks data up and, on
confirmation, performs the action and emails a confirmation.

- **Persona:** Shipper / Customer (self-service). The customer talks to the assistant; the
  assistant reads shipment data and performs actions on their behalf.
- **Problem automated:** the "where is my package / change my delivery / file a claim" support
  load that normally hits a call center — resolved conversationally, grounded in live data.
- **Solution shape:** 3 Flogo apps — **1 MCP Server** (read-only tools), **1 A2A Servers / Agents app**
  (action agents that write **directly to PostgreSQL** + send email), and **1 AI Orchestrator**
  (WebSocket chat, LLM routing). All state lives in **PostgreSQL**.

---

## Architecture

```
Chatbot UI --WebSocket--> AI Orchestrator --MCP (HTTP streamable)--> MCP Server --\
                                 |                                                 +--> PostgreSQL
                                 \--A2A (HTTP)-----> A2A Servers / Agents ---------/   (+ SMTP for email)
```

- **MCP Server** — read-only lookups. Stateless, safe to retry; the LLM picks a tool from its
  description.
- **A2A Servers / Agents** — action workflows. Each agent has its own trigger/port, guardrails, and
  system prompt. Action agents **write directly to PostgreSQL**; one agent sends email via SMTP.
- **Orchestrator** — the AI brain. WebSocket chat endpoint; the LLM decides intent and either
  calls an MCP tool or hands off to an A2A agent.

---

## Apps

| App | File | Trigger | Port (property) |
|-----|------|---------|-----------------|
| MCP Server | `LogisticsMCPServer.flogo` | `tr_mcpserver` | `MCP_SERVER_PORT` = **9790** |
| A2A Servers / Agents | `LogisticsA2AServers.flogo` | `tr_agent` ×4 | see agent table below |
| AI Orchestrator | `LogisticsAIOrchestrator.flogo` | `tr_wsserver` | `WS_SERVER_PORT` = **9690**, path `/logistics` |

---

## MCP tools (read-only)

All served by `LogisticsMCPServer.flogo`. Each tool runs a `SELECT` and returns rows; the LLM
filters/joins by tracking number, customer, etc.

| Tool | Table / source | What it answers |
|------|----------------|-----------------|
| `GetCustomerProfile` | `customers` | Who the customer is, account type, loyalty tier, contact |
| `GetShipments` | `shipments` | All shipments + status, service, ETA, value, carrier |
| `TrackShipment` | `tracking_events` | Scan-by-scan movement history for a tracking number |
| `GetServiceLevels` | `service_levels` | Rate card: Same-Day / Express / Standard / Eco, transit days, price |
| `GetDeliveryChanges` | `delivery_changes` | Reschedule/redirect requests already on file |
| `GetClaims` | `claims` | Claims already filed and their status |

---

## A2A action agents

All served by `LogisticsA2AServers.flogo`. Each agent **writes directly to PostgreSQL**
(validate with a `SELECT`, then INSERT/UPDATE); the email agent uses SMTP.

| Agent | Port (property) | Action | Writes to |
|-------|-----------------|--------|-----------|
| `reschedule_delivery_agent` | `RESCHEDULE_AGENT_PORT` = **9791** | Reschedule **or redirect** a delivery (new date / new address) | INSERT `delivery_changes` + UPDATE `shipments.estimated_delivery` / `destination_address` |
| `book_pickup_agent` | `PICKUP_AGENT_PORT` = **9792** | Schedule a carrier pickup | INSERT `pickup_requests` |
| `file_claim_agent` | `CLAIM_AGENT_PORT` = **9793** | File a Lost/Damaged claim (validates the shipment first) | INSERT `claims` |
| `send_confirmation_email` | `EMAIL_AGENT_PORT` = **9794** | Email a confirmation to the customer | SMTP (`smtp.gmail.com:465`, SSL) |

---

## Database

PostgreSQL. `database.sql` creates the schema and seeds demo data; `reset_data.sql` re-seeds and
empties the agent-written tables between demos. Dates are **`CURRENT_DATE`-relative**, so delays
and ETAs stay realistic whenever you run it.

**Read tables (seeded):** `customers` (5), `addresses` (6), `service_levels` (4),
`shipments` (10), `tracking_events` (20).
**Agent-written tables (start empty):** `delivery_changes`, `pickup_requests`, `claims`.

Flagship data hooks:
- `TRK-2026-0007` — **Delayed** (SF → Dallas, weather-held in Phoenix) → drives the
  "track → redirect → email" multi-step demo.
- `TRK-2026-0001` / `TRK-2026-0005` / `TRK-2026-0008` — **Delivered** → drive claim demos.
- `TRK-2026-0003` — **Out for Delivery** → drives a reschedule demo.
- `TRK-2026-0004` — **Exception** (address issue) → drives a redirect demo.
- `CUST-LOG-1001` (**Acme Retail Ltd**, Gold) is the flagship customer with SF Warehouse +
  Austin Office addresses.

---

## Demo scenarios

1. **Track a shipment.** "Where is TRK-2026-0002?" → `TrackShipment` returns the scan history.
2. **Compare service levels.** "What's the fastest way to ship 5 kg to Denver?" → `GetServiceLevels`.
3. **Reschedule a delivery.** "Reschedule TRK-2026-0003 to next Monday." → `reschedule_delivery_agent`.
4. **Redirect an exception.** "TRK-2026-0004 is stuck — send it to my London home instead." → `reschedule_delivery_agent`.
5. **Book a pickup.** "Book a pickup at my SF warehouse tomorrow afternoon, 3 boxes." → `book_pickup_agent`.
6. **File a claim.** "TRK-2026-0001 arrived damaged, claim $850." → `file_claim_agent`.
7. **⭐ Flagship multi-step.** "Track TRK-2026-0007 — if it's delayed, redirect it to my Austin
   office and email me the confirmation." → `TrackShipment` → `reschedule_delivery_agent` →
   `send_confirmation_email`.

See `prompts.md` for the full, copy-pasteable prompt list.

---

## Prerequisites

- **PostgreSQL** running; a database created for this demo.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- **TIBCO Flogo Enterprise** — VS Code extension 2.26.7 or later (import the `.flogo` apps into the designer) — or the **`flogobuild`** CLI if you prefer to build `.exe`s.
- An **LLM provider** key (OpenAI-compatible). Base URL must be a **real endpoint**, e.g. `https://api.openai.com/v1`.
- **SMTP** access for the email agent (Gmail: `smtp.gmail.com:465`, SSL, an app-specific password).

## Setup & Run

1. **Database**
   ```bash
   psql -h <host> -p <port> -U <user> -d <db> -f database.sql
   # between demos:
   psql -h <host> -p <port> -U <user> -d <db> -f reset_data.sql
   ```
2. **Import the apps** into Flogo Enterprise, or build each from its `.flogo` source with `flogobuild`:
   ```bash
   flogobuild build-exe -f LogisticsMCPServer.flogo   -c <context>
   flogobuild build-exe -f LogisticsA2AServers.flogo  -c <context>
   flogobuild build-exe -f LogisticsAIOrchestrator.flogo -c <context>
   ```
3. **Set app properties** (DB creds, LLM key/base URL/model, SMTP creds, ports, recipient email) —
   see the manual-config section below.
4. **Start order:** MCP Server → A2A Servers / Agents → Orchestrator.
5. **Open the chatbot and connect** — the shared web client in `samples/Agentic_AI/Chatbot`:
   ```bash
   cd samples/Agentic_AI/Chatbot
   npm install    # first time only
   npm start
   ```

   Open **http://localhost:3000**, then:

   1. In the URL box at the top right, enter **`ws://localhost:9690/logistics`**.
   2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
      and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
   3. Click **Connect**. The status turns green: **● Connected**.

   **Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
   last URL you applied, so a URL from another demo is a common cause.

## Ports

| Component | Property | Default |
|-----------|----------|---------|
| MCP Server | `MCP_SERVER_PORT` | 9790 |
| Reschedule agent | `RESCHEDULE_AGENT_PORT` | 9791 |
| Pickup agent | `PICKUP_AGENT_PORT` | 9792 |
| Claim agent | `CLAIM_AGENT_PORT` | 9793 |
| Email agent | `EMAIL_AGENT_PORT` | 9794 |
| Orchestrator (WebSocket) | `WS_SERVER_PORT` | 9690 (path `/logistics`) |

## Troubleshooting

- **`unsupported protocol scheme` / posts to `/New_value/...`** — the LLM base URL is blank; set it to a real endpoint.
- **MCP runtime panics `missing input schema`** — a tool handler is missing its input/output schema (the FDA recipe attaches both).
- **`Configured connection is not a WebSocket Connection`** — the orchestrator's `wsconnection`/`content` were coerced to `object`; they must stay `any`.
- **Email field warns "type … differs from bound app property"** — re-enter `Email_App_Password` in App Properties so it's stored as a `SECRET:` (keep type `string`).
- **Orchestrator can't reach a tool/agent** — the MCP/A2A `serverUrl`s must match the MCP/A2A ports above.

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The three apps were generated with the Flogo Design CLI and build cleanly to `.exe`, but the
following are intentionally **not** set (they are environment-, secret-, or backend-specific and
must never be committed). The committed `.flogo` files carry **placeholders** for every secret /
PII / model value — replace them with your own before an end-to-end run:

1. **LLM credentials & endpoint.**
   - `API_Key` — replace the placeholder `SET_YOUR_LLM_API_KEY` with your real provider key
     (keep it out of the repo; inject as an app property / platform secret at deploy).
   - `LLM_Base_URL` — already set to a **real endpoint** (`https://api.openai.com/v1`). It is
     deliberately not blank: an empty value becomes the literal `New_value` and the LLM call fails
     with `unsupported protocol scheme`. Change it only if you use a different OpenAI-compatible host.
   - `LLM_Model` — confirm the model name (`gpt-5.5` placeholder) is one your key can access.

2. **PostgreSQL database & credentials.**
   - Create a database (the build assumes **`logistics`**) and load `database.sql`; run
     `reset_data.sql` to reset between demos.
   - Set the PostgreSQL connection `Host` / `Port` / `Database_Name` / `User` / `Password`
     to your instance. `Password` is a placeholder (`SET_YOUR_DB_PASSWORD`) — set the real secret
     in App Properties, not in plaintext in the repo.
   - Verify connectivity: run each MCP tool's `SELECT` and each A2A write's SQL against the DB.

3. **Ports must be free & consistent.**
   - MCP **9790**, reschedule **9791**, pickup **9792**, claim **9793**, email **9794**, and the
     orchestrator WebSocket **9690** must all be free on the host.
   - The orchestrator's MCP `serverUrl` and each A2A `serverUrl` must match those ports. If you
     change a port, change it in the app property **and** in the corresponding orchestrator
     connection URL.

4. **Email / SMTP** (the `send_confirmation_email` agent).
   - Set `Email_Username`, `Email_App_Password` (an app-specific password, **not** the account
     password), and the recipient `To_Email` property. Placeholders: `sender@example.com`,
     `SET_YOUR_EMAIL_APP_PASSWORD`, `recipient@example.com`.
   - Confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed from the host/network.
   - **Re-enter `Email_App_Password` in the designer's App Properties panel so it is stored as a
     `SECRET:` value.** FDA writes the password as a plaintext `string`, but the sendmail
     `Password` field only binds cleanly to a **secret-valued** property; a plaintext one shows
     *"Type of field 'Password' (password) differs from bound app property (string)"*. Re-type the
     value once in App Properties and the designer encrypts it to `SECRET:…`, clearing the ✗.
     ⚠️ **Leave the property's type as `string`** — there is no `password` app-property type;
     setting one makes the designer silently drop the property on save. It builds/runs as a string
     either way; this only clears designer validation.

5. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://<host>:9690/logistics`. Point your chat UI (or a WS test
     client) at it — there is no bundled UI. See `prompts.md` for ready-to-paste demo prompts.

6. **Deploy-time secret injection** (if deploying to TIBCO Platform / Control Plane rather than
   running the local `.exe`).
   - Provide `API_Key`, the DB `Password`, and `Email_App_Password` as platform secrets / app
     properties at deploy time; do not ship them inside the app.
   - Ensure the build context / runtime version matches your target environment.

7. **Flogo Design Assistant (FDA) manual steps** (Tech-Preview limitations — the apps still
   build/run as `.exe`; these clear designer validation and cover things FDA cannot configure).
   - **Sync every trigger.** FDA-built triggers are non-OpenAPI (`tr_mcpserver`, `tr_agent`,
     `tr_wsserver`), so some trigger/flow-input fields (e.g. `toolParams`, the WS input mappings)
     don't render and show a red ✗ until you click **"Sync"** once on each trigger.
   - **Validate every connection.** FDA creates connections **without** validating them. Open each
     (PostgreSQL, LLM provider, MCP server config, and all four A2A server connections) and click
     **Connect / Test** to establish and verify it before running.
   - **Set the email password as a secret** — see item 4. Never set the property type to `password`.
   - **Certificates (if any).** FDA cannot add certificates. If secure DB/TLS or the SMTP server
     certificate is required in your environment, add it manually.

**Quick pre-flight checklist**

- [ ] DB `logistics` created, `database.sql` loaded, row counts sane (customers 5, shipments 10, tracking_events 20)
- [ ] LLM `API_Key`, `LLM_Base_URL` (real endpoint), `LLM_Model` set
- [ ] PostgreSQL `Password` set; MCP tool `SELECT`s and A2A write SQL run cleanly
- [ ] All 6 ports free; orchestrator MCP/A2A URLs match the MCP/A2A ports
- [ ] `Email_App_Password` re-entered as a `SECRET:` (type stays `string`); SMTP reachable
- [ ] Every trigger Synced; every connection validated in the designer
- [ ] Start order: MCP → A2A → Orchestrator; each logs a clean start
- [ ] WebSocket client connects to `ws://<host>:9690/logistics` and gets a reply
