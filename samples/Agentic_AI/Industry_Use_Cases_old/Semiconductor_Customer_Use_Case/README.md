# Semiconductor Customer & Order Assistant

An **Agentic AI** demo for the **semiconductor / electronic-components** vertical. A
**design engineer or procurement buyer** at a customer company (OEM, automotive tier-1,
distributor) chats with an AI assistant over WebSocket to **look up parts, stock, pricing,
orders, lifecycle status and cross-references**, and — on confirmation — **place or expedite
an order, open an RMA/quality case, request samples, and subscribe to stock/PCN alerts**. The
assistant looks the data up, performs the action against PostgreSQL, and emails a confirmation.

- **Persona:** Customer / design engineer / procurement buyer (self-service), identified by an
  account id in the form `CUST-100xx`.
- **Problem automated:** the "what's the price/stock/lead-time, where's my order, is this part
  going EOL, open me an RMA, send me samples" load that normally ties up a distributor FAE or a
  customer-service desk — resolved conversationally, grounded in live data.
- **Solution shape:** 3 Flogo apps — **1 MCP Server** (read-only tools), **1 A2A Servers / Agents app**
  (action agents that write **directly to PostgreSQL** + send email), and **1 AI Orchestrator**
  (WebSocket chat, LLM routing). All state lives in **PostgreSQL**. Currency is **USD** throughout.
- **Vendor-neutral:** part numbers are fictional-but-realistic MPNs plus genuinely multi-vendor
  JEDEC/Pro-Electron parts — nothing is tied to any brand, so the demo is reusable across
  semiconductor verticals.

---

## Architecture

```
Chatbot UI --WebSocket--> AI Orchestrator --MCP (HTTP streamable)--> MCP Server --\
                                 |                                                 +--> PostgreSQL
                                 \--A2A (HTTP)-----> A2A Servers / Agents ---------/   (+ SMTP for email)
```

- **MCP Server** — read-only lookups. Stateless, safe to retry; the LLM picks a tool from its
  description and filters the returned rows.
- **A2A Servers / Agents** — action workflows. Each agent has its own trigger/port, guardrails, and system
  prompt. Action agents **write directly to PostgreSQL**; one agent sends email via SMTP.
- **Orchestrator** — the AI brain. WebSocket chat endpoint; the LLM decides intent and either
  calls an MCP tool or hands off to an A2A agent.

---

## Apps

| App | File | Trigger | Port (property) |
|-----|------|---------|-----------------|
| MCP Server | `SemiconductorMCPServer.flogo` | `#mcpserver` | `MCP_SERVER_PORT` = **9098**, path `/semiconductor-parts` |
| A2A Servers / Agents | `SemiconductorA2AServers.flogo` | `#agent` ×6 | see agent table below (**8730–8735**) |
| AI Orchestrator | `SemiconductorAIOrchestrator.flogo` | `#wsserver` | **9310**, path `/semiconductor` |

---

## MCP tools (read-only)

All served by `SemiconductorMCPServer.flogo`. Each tool runs a `SELECT` and returns rows; the LLM
filters/joins by part number, account id, etc.

| Tool | Table / source | What it answers |
|------|----------------|-----------------|
| `GetCustomerProfile` | `customers` | Who the customer is: company, contact, region, industry, account tier, credit status |
| `GetProductDetails` | `products` | Part specs, package, RoHS, automotive/AEC qualification, lifecycle status, datasheet |
| `CheckStockAndLeadTime` | `inventory` | Qty available per warehouse, lead time, next restock date |
| `GetPricing` | `price_breaks` | Quantity price tiers (min qty → unit price, USD) |
| `GetOrders` | `orders` | Order headers: status, PO, order date, total amount |
| `GetOrderLines` | `order_lines` | Line detail: part, quantity, unit price, requested/promised dates |
| `GetLifecycleNotices` | `pcn_notices` | PCN / PDN / EOL notices, last-time-buy dates, replacement parts |
| `GetCrossReferences` | `cross_references` | Alternates: second-source / pin-compatible / upgrade / replacement |
| `GetRMAStatus` | `rma_cases` | RMA / quality-case status, defect type, resolution dates |
| `GetSampleStatus` | `sample_requests` | Sample request status, quantity, purpose, ship-to |
| `GetAlertSubscriptions` | `alert_subscriptions` | The customer's active stock/PCN alert subscriptions |

---

## A2A action agents

All served by `SemiconductorA2AServers.flogo`. Each agent **writes directly to PostgreSQL**
(validate with a `SELECT`, then INSERT/UPDATE); the email agent uses SMTP.

| Agent | Port (property) | Action | Writes to |
|-------|-----------------|--------|-----------|
| `place_order_agent` | `PlaceOrder_A2AServer_PORT` = **8730** | Place a new order (generates `SO-2026-NNNN`) | INSERT `orders` + INSERT `order_lines` |
| `expedite_order_agent` | `ExpediteOrder_A2AServer_PORT` = **8731** | Pull in the requested date on an existing order line | UPDATE `order_lines` |
| `open_rma_agent` | `OpenRMA_A2AServer_PORT` = **8732** | Open an RMA / quality case (generates `RMA-2026-NNNN`) | INSERT `rma_cases` |
| `request_sample_agent` | `RequestSample_A2AServer_PORT` = **8733** | Request free samples (generates `SMP-2026-NNNN`) | INSERT `sample_requests` |
| `subscribe_alert_agent` | `SubscribeAlert_A2AServer_PORT` = **8734** | Subscribe to STOCK/PCN alerts (derives email from the account) | INSERT `alert_subscriptions` |
| `send_confirmation_email` | `SendEmail_A2AServer_PORT` = **8735** | Email a confirmation to the customer | SMTP (`smtp.gmail.com:465`, SSL) |

> The place-order and expedite-order workflows are split into **two single-purpose agents** (a clean
> INSERT and a clean UPDATE) rather than one branching flow — it's more reliable and easier to demo.

---

## Database

PostgreSQL (14+). `database.sql` creates the schema and seeds demo data; `reset_data.sql` re-seeds
and empties/restores the agent-written tables between demos. Volatile dates are **`CURRENT_DATE`-relative**,
so stock, lead times, order dates and EOL/LTB dates always look current. All money is **USD**.

**Read tables (seeded):** `customers` (7), `products` (10), `inventory` (14), `price_breaks` (32),
`orders` (4), `order_lines` (7), `pcn_notices` (3), `cross_references` (5).
**Agent-written tables:** `rma_cases` (1 pre-seeded baseline), `sample_requests` (1 pre-seeded
baseline), `alert_subscriptions` (starts **empty**).

Flagship data hooks:
- **`CUST-10001` (Aurora Automotive Systems**, EMEA / Automotive / Direct-Gold) — the flagship
  customer, with active orders `SO-2026-0001` / `SO-2026-0002`.
- **`TMN4010Q`** — automotive AEC-Q101 MOSFET with a full price-break ladder → drives the
  place-order + pricing demos.
- **`SBD2010A`** — **EOL** part with a published EOL notice (`PCN-2026-0001`), a last-time-buy date,
  and a drop-in replacement `SBD2010B` in `cross_references` → drives the lifecycle → cross-ref →
  subscribe-to-alerts multi-step demo.
- **`GAN65R060` on `SO-2026-0003`** (CUST-10004) — has a pre-seeded RMA (`RMA-2026-0001`, Under
  Review) → drives RMA-status lookups and new RMA demos.
- **`PMN8033YS`** — carries an assembly/mold-compound PCN → drives PCN-alert demos.

---

## Demo scenarios

1. **Look up a part.** "Tell me about TMN4010Q — specs and qualification." → `GetProductDetails`.
2. **Stock & pricing.** "How many TMN4010Q in stock, and the price at 5,000?" → `CheckStockAndLeadTime` + `GetPricing`.
3. **Order status.** "What's on SO-2026-0002 and when is it promised?" → `GetOrders` + `GetOrderLines`.
4. **Lifecycle check.** "Is SBD2010A going EOL? What replaces it?" → `GetLifecycleNotices` + `GetCrossReferences`.
5. **Place an order.** "Order 5,000 TMN4010Q against PO AUR-PO-90001, I'm CUST-10001." → `place_order_agent`.
6. **Expedite.** "Pull in the PMN8033YS line on SO-2026-0002 to next week." → `expedite_order_agent`.
7. **Open an RMA.** "40 GAN65R060 from SO-2026-0003 failed in the field — open a case." → `open_rma_agent`.
8. **Request samples.** "Send 25 ESD1CANQ samples for a design-in eval, CUST-10005." → `request_sample_agent`.
9. **Subscribe to alerts.** "Notify me of any PCNs on PMN8033YS, CUST-10001." → `subscribe_alert_agent`.
10. **⭐ Flagship multi-step.** "Check if SBD2010A is EOL — if so, subscribe me to PCN alerts and email
    me the confirmation." → `GetLifecycleNotices` → `subscribe_alert_agent` → `send_confirmation_email`.

See `prompts.md` for the full, copy-pasteable prompt list.

---

## Prerequisites

- **PostgreSQL** running; a database created for this demo (assumed name **`semiconductor`**).
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- **TIBCO Flogo Enterprise** — VS Code extension 2.26.7 or later (import the `.flogo` apps into the designer) — or the `flogobuild` CLI
  if you prefer to build `.exe`s.
- An **LLM provider** key (OpenAI-compatible). Base URL must be a **real endpoint**, e.g.
  `https://api.openai.com/v1`.
- **SMTP** access for the email agent (Gmail: `smtp.gmail.com:465`, SSL, an app-specific password).

## Setup & Run

1. **Database**
   ```bash
   psql -h <host> -p <port> -U <user> -d semiconductor -f database.sql
   # between demos:
   psql -h <host> -p <port> -U <user> -d semiconductor -f reset_data.sql
   ```
2. **Import the three apps** into Flogo Enterprise (or build each to an `.exe` with `flogobuild`).
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

   1. In the URL box at the top right, enter **`ws://localhost:9310/semiconductor`**.
   2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
      and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
   3. Click **Connect**. The status turns green: **● Connected**.

   **Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
   last URL you applied, so a URL from another demo is a common cause.

## Ports

> **Note:** the orchestrator WebSocket port was moved from `8088` to **9310** because `8088` collided
> with the Retail Banking Assistant use case when both ran on the same host.

| Component | Property | Default |
|-----------|----------|---------|
| MCP Server | `MCP_SERVER_PORT` | 9098 (path `/semiconductor-parts`) |
| Place-order agent | `PlaceOrder_A2AServer_PORT` | 8730 |
| Expedite-order agent | `ExpediteOrder_A2AServer_PORT` | 8731 |
| Open-RMA agent | `OpenRMA_A2AServer_PORT` | 8732 |
| Request-sample agent | `RequestSample_A2AServer_PORT` | 8733 |
| Subscribe-alert agent | `SubscribeAlert_A2AServer_PORT` | 8734 |
| Email agent | `SendEmail_A2AServer_PORT` | 8735 |
| Orchestrator (WebSocket) | `#wsserver` | 9310 (path `/semiconductor`) |

## Troubleshooting

- **`unsupported protocol scheme` / posts to `/New_value/...`** — the LLM base URL is blank; set it to a real endpoint.
- **MCP runtime panics `missing input schema`** — a tool handler is missing its input/output schema.
- **A2A agent stalls asking for an id the user doesn't know** — the agent should derive FKs (e.g. the
  customer's email) in SQL, not ask; see the `subscribe_alert_agent` `INSERT … SELECT … COALESCE` pattern.
- **`missing substitution for: <name>`** on an A2A write — the runtime `input.mapping.parameters` is
  missing that param; patch it, then **Sync** the trigger to regenerate the design-time schemas.
- **`Configured connection is not a WebSocket Connection`** — the orchestrator's `wsconnection`/`content`
  were coerced to `object`; they must stay `any`.
- **Email field warns "type … differs from bound app property"** — re-enter `Email_App_Password` in App
  Properties so it's stored as a `SECRET:` (keep the property type `string`).
- **Orchestrator can't reach a tool/agent** — the MCP/A2A `serverUrl`s must match the ports above.

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The committed `.flogo` files carry placeholders / reference-app values for every secret; replace them
with your own before an end-to-end run. Never commit real secrets.

1. **LLM credentials & endpoint.**
   - `API_Key` — set your real provider key (inject as an app property / platform secret; keep it out of the repo).
   - `LLM_Base_URL` — a **real endpoint** (`https://api.openai.com/v1`). An empty value becomes the
     literal `New_value` and the LLM call fails with `unsupported protocol scheme`.
   - `LLM_Model` — confirm the model name is one your key can access.

2. **PostgreSQL database & credentials.**
   - Create the **`semiconductor`** database and load `database.sql`; run `reset_data.sql` to reset between demos.
   - Set the PostgreSQL connection `Host` / `Port` / `Database_Name` / `User` / `Password` to your
     instance. `Password` is a `SECRET:` app property — set the real secret in App Properties, not in plaintext.
   - Verify connectivity: run each MCP tool's `SELECT` and each A2A write's SQL against the DB.

3. **Ports must be free & consistent.**
   - MCP **9098**, place **8730**, expedite **8731**, RMA **8732**, sample **8733**, subscribe **8734**,
     email **8735**, and the orchestrator WebSocket **9310** must all be free on the host.
   - The orchestrator's MCP `serverUrl` and each A2A `serverUrl` must match those ports. If you change a
     port, change it in the app property **and** in the corresponding orchestrator connection URL.

4. **Email / SMTP** (the `send_confirmation_email` agent).
   - Set `Email_Username`, `Email_App_Password` (an app-specific password, **not** the account password),
     and the recipient `To_Email` property.
   - Confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed from the host/network.
   - **Re-enter `Email_App_Password` in App Properties so it is stored as a `SECRET:` value** (leave the
     property type as `string` — there is no `password` app-property type).

5. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://<host>:9310/semiconductor`. Point your chat UI (or a WS test client)
     at it — there is no bundled UI. See `prompts.md` for ready-to-paste demo prompts.

6. **Flogo designer manual steps** (clear design-time validation).
   - **Sync every trigger** (MCP, each A2A agent, the WS server) once, so `toolParams` and WS input
     mappings render without a red ✗.
   - **Validate every connection** (PostgreSQL, LLM provider, MCP server config, all six A2A server
     connections) — click **Connect / Test** before running.
   - **Set the email password as a secret** — see item 4.

**Quick pre-flight checklist**

- [ ] DB `semiconductor` created, `database.sql` loaded, row counts sane (customers 7, products 10, price_breaks 32, orders 4)
- [ ] LLM `API_Key`, `LLM_Base_URL` (real endpoint), `LLM_Model` set
- [ ] PostgreSQL `Password` set; MCP tool `SELECT`s and A2A write SQL run cleanly
- [ ] All 8 ports free; orchestrator MCP/A2A URLs match the MCP/A2A ports
- [ ] `Email_App_Password` re-entered as a `SECRET:` (type stays `string`); SMTP reachable
- [ ] Every trigger Synced; every connection validated in the designer
- [ ] Start order: MCP → A2A → Orchestrator; each logs a clean start
- [ ] WebSocket client connects to `ws://<host>:9310/semiconductor` and gets a reply
