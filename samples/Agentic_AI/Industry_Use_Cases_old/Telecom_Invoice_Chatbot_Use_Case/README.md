# Telecom Invoice Chatbot Use Case

An **Agentic AI** demo for the **telecom / BSS billing** vertical, built on TIBCO Flogo
Enterprise. A **postpaid/prepaid subscriber** chats with an AI assistant over a streaming
WebSocket to **understand a bill, check usage, plans, payments and dispute status** — and, on
confirmation, to **file a billing dispute, apply a recharge pack, and email a confirmation**.
The assistant looks the data up, performs the action against PostgreSQL, and (optionally) emails
a confirmation.

## What this demo does

- **Persona:** a telecom subscriber (self-service), identified by their `+1` **mobile number**.
  The agent resolves the mobile number to a customer id and uses it for every other lookup.
- **Problem automated:** the "why is my bill so high, was this roaming charge real, I need more
  data, what's my dispute status, file this dispute for me" load that normally ties up a call
  centre / BSS agent — resolved conversationally, grounded in live billing data.
- **Solution shape:** 3 Flogo apps — **1 MCP Server** (read-only BSS lookup tools), **1 A2A
  Agents app** (action agents that write **directly to PostgreSQL** + send email), and **1 AI
  Orchestrator** (WebSocket chat, LLM intent routing). All state lives in **PostgreSQL**.
- **Locale / currency:** a **US telecom provider** — currency **USD** (US Dollar), **Taxes &
  Regulatory Fees ~10%**, subscribers with `+1` mobile numbers, and international / roaming
  destinations (Mexico, Canada, Japan, China, India, UK, Germany). Six accounts carry
  intentionally incorrect charges for billing-dispute demos.

---

## Architecture

```
                    ┌─────────────────────────┐
                    │     Chatbot UI          │
                    │  (WebSocket Client)     │
                    └───────┬─────────────────┘
                            │ WebSocket
                            │ ws://localhost:9500/telecom
                            ▼
               ┌────────────────────────────────┐
               │  Telecom Invoice               │
               │  AI Orchestrator               │
               │  (TelecomInvoiceAIOrch.)       │
               │  Port 9500 (WebSocket)         │
               │  LLM: OpenAI GPT               │
               └───────┬───────────┬────────────┘
                       │           │
          MCP (HTTP)   │           │  A2A Protocol
                       ▼           ▼
    ┌──────────────────────┐   ┌──────────────────────────────────┐
    │  Telecom Invoice     │   │  Telecom Invoice                 │
    │  MCP Server          │   │  A2A Servers / Agents            │
    │  Port 9882           │   │                                  │
    │  /telecom-bss        │   │  billing_dispute_agent    :9883  │
    │                      │   │  recharge_agent           :9884  │
    │  Tools (read-only):  │   │  send_confirmation_email  :9885  │
    │  - GetCustomerProfile│   │                                  │
    │  - GetInvoiceDetails │   │  Uses PostgreSQL for             │
    │  - GetUsageBreakdown │   │  data validation & writes        │
    │  - GetActivePlans    │   │  + Gmail SMTP for email          │
    │  - GetPaymentHistory │   │                                  │
    │  - CheckRechargeOffers│  │                                  │
    │  - GetDisputes       │   │                                  │
    └──────────┬───────────┘   └──────────────┬───────────────────┘
               │                              │
               └──────────────┬───────────────┘
                              ▼
               ┌────────────────────────────┐
               │  PostgreSQL Database       │
               │  Database: telecom         │
               │  9 Tables                  │
               └────────────────────────────┘
```

- **MCP Server** — read-only BSS lookups. Stateless, safe to retry; the LLM picks a tool from its
  description and filters the returned rows by mobile number / customer id.
- **A2A Servers / Agents** — action workflows. Each agent has its own trigger/port, LLM, system prompt and
  tool handler. Action agents **write directly to PostgreSQL**; one agent sends email via SMTP.
- **AI Orchestrator** — the AI brain. WebSocket chat endpoint; the LLM decides intent and either
  calls an MCP tool (data lookup) or hands off to an A2A agent (write workflow).

---

## Apps / Components

| App | File | Trigger | Port (property) + path |
|-----|------|---------|------------------------|
| MCP Server | `TelecomInvoiceMCPServer.flogo` | `#mcpserver` | `MCP_SERVER_PORT` = **9882**, path `/telecom-bss` |
| A2A Servers / Agents | `TelecomInvoiceA2AServers.flogo` | `#agent` ×3 | see agent table below (**9883–9885**) |
| AI Orchestrator | `TelecomInvoiceAIOrchestrator.flogo` | `#wsserver` | **9500** (WebSocket trigger setting), path `/telecom` |

> The orchestrator's WebSocket port (**9500**) is a trigger setting, not an app property; the MCP
> and A2A ports are app properties (see [Ports](#ports)).

### 1. `TelecomInvoiceMCPServer.flogo` — MCP Server (Port 9882)

Exposes 7 read-only BSS lookup tools via the Model Context Protocol over Streamable HTTP (endpoint `/telecom-bss`). Each tool queries the PostgreSQL `telecom` database and returns the full result set as a string; the LLM filters by mobile number / customer ID.

| Tool | Description | SQL |
|------|-------------|-----|
| **GetCustomerProfile** | CRM profile: mobile, name, segment, account type, active since | `SELECT * FROM customers` |
| **GetInvoiceDetails** | Invoice header + line items (PLAN/IDD/ADDON/ROAMING/OTHER/TAX) | `invoices JOIN invoice_line_items` |
| **GetUsageBreakdown** | Data/voice/SMS/roaming usage vs limits | `SELECT * FROM usage_records` |
| **GetActivePlans** | Current base plan + add-ons with expiry | `SELECT * FROM plans` |
| **GetPaymentHistory** | Recent payments with method and status | `SELECT * FROM payments` |
| **CheckRechargeOffers** | Catalog of data/IDD/roaming/combo packs | `SELECT * FROM recharge_offers` |
| **GetDisputes** | Dispute tickets with status and resolution | `SELECT * FROM disputes` |

### 2. `TelecomInvoiceA2AServers.flogo` — A2A Servers / Agents (Ports 9883–9885)

Three A2A agents that handle write workflows. Each agent has its own LLM, system prompt, and tool handler, and (except the email agent) **writes directly to PostgreSQL** after validating with a `SELECT`.

### 3. `TelecomInvoiceAIOrchestrator.flogo` — AI Orchestrator (Port 9500)

The main orchestration app. Exposes a WebSocket endpoint for natural-language chat. An AI Agent activity classifies intent and routes to either MCP tools (data lookups) or A2A agents (write workflows).

| Setting | Value |
|---------|-------|
| WebSocket Path | `/telecom` (port 9500) |
| LLM | OpenAI GPT (`AgenticAI.OpenAIConn.*` + `LLM_Model`) |
| MCP Server | `http://localhost:9882/telecom-bss` |
| A2A Servers / Agents | billing_dispute (9883), recharge (9884), email (9885) |

---

## MCP tools (read-only)

All served by `TelecomInvoiceMCPServer.flogo`. Each tool runs a `SELECT` and returns rows; the LLM
filters/joins by mobile number, customer id, invoice id, etc. See the tool table in
[App 1 above](#1-telecominvoicemcpserverflogo--mcp-server-port-9882).

---

## A2A action agents

All served by `TelecomInvoiceA2AServers.flogo`. Each write agent validates with a `SELECT`, then
INSERTs; the email agent uses SMTP. The email agent is invoked **only once, after** the billing
action, when the user requests it.

| Agent | Port (property) | Action | Writes to |
|-------|-----------------|--------|-----------|
| `billing_dispute_agent` | `BillingDispute_A2AServer_PORT` = **9883** | Validate a disputed invoice line item against usage records, then file a dispute (tool `file_billing_dispute`; status `OPEN`, 5-day estimated resolution) | INSERT `disputes` |
| `recharge_agent` | `Recharge_A2AServer_PORT` = **9884** | Apply a chosen recharge pack (tool `apply_recharge_pack`; status `ACTIVE`, 30-day validity) | INSERT `recharges` |
| `send_confirmation_email` | `SendEmail_A2AServer_PORT` = **9885** | Email a confirmation (dispute filed / recharge applied) (tool `send_confirmation_email`) | SMTP (`smtp.gmail.com:465`, SSL) |

---

## Database

PostgreSQL (14+). `database.sql` creates the schema and seeds demo data; `reset_data.sql` restores
a clean demo state (undoes agent writes) with **today-relative** due/payment/dispute dates. All
money is **USD**.

9 tables in the PostgreSQL `telecom` database:

| Table | Purpose | Records |
|-------|---------|---------|
| `customers` | CRM master records (mobile = subscriber id) | 22 subscribers |
| `invoices` | Monthly invoice headers | 18 (June 2026, postpaid) |
| `invoice_line_items` | Charges per invoice (incl. Taxes & Fees) | 59 line items |
| `usage_records` | Metered usage vs limits | 22 (one per subscriber) |
| `plans` | Base plans + add-ons | 27 |
| `payments` | Payment / top-up history | 50 |
| `recharge_offers` | Global recharge catalog | 8 offers |
| `disputes` | Dispute tickets (pre-seeded + written by agent) | 3 seeded |
| `recharges` | Recharge activation log (written by agent) | starts empty |

```bash
# Initialize schema and demo data
psql -h <host> -p <port> -U <user> -d telecom -f database.sql

# Reset with today-relative due/payment/dispute dates (for live demos, between runs)
psql -h <host> -p <port> -U <user> -d telecom -f reset_data.sql
```

**Flagship data hooks:**
- **James Anderson** (`CUST-10042871`, +1-415-555-0142, Premium, San Francisco) — flagship
  "why is my bill high" invoice `INV-2026-06-871` (USD 139.70, roaming Mexico **valid**).
- **Emily Carter** (`CUST-10042872`, +1-212-555-0178) — roaming Mexico charged (USD 45.00) but
  **0 roaming days** → drives the file-a-dispute demo.
- **Michael Rodriguez** (`CUST-10042873`, +1-312-555-0163) — **19.6 / 20 GB** used → drives the
  recharge demo; also carries OPEN dispute `DSP-2026-0003`.
- **Jessica Williams** (`CUST-10042876`, +1-305-555-0134, VIP) — pre-seeded dispute
  `DSP-2026-0001` (`UNDER_REVIEW`) → drives dispute-status lookups.
- **Six wrong-charge accounts** (`CUST-10042887 … CUST-10042892`) — each carries one intentionally
  incorrect June charge contradicted by its usage record → drive additional dispute demos.

---

## Demo Scenarios

Each scenario maps to the MCP tool / A2A agent it exercises. See `prompts.md` for the full,
copy-pasteable prompt list (organized by scenario, incl. §10 wrong-charge accounts).

### Scenario 1: "Why is my bill so high?" (MCP only)

James Anderson (+1-415-555-0142, Premium, San Francisco) has a June 2026 bill of **USD 139.70**. The agent looks up his profile, invoice, and usage and explains each line item — Plan USD 70.00, IDD Mexico USD 12.00, Data Add-on 10GB USD 15.00, Roaming Mexico USD 30.00, Taxes & Regulatory Fees USD 12.70 — confirming the roaming is valid (3 roaming days recorded). → `GetCustomerProfile` + `GetInvoiceDetails` + `GetUsageBreakdown`.

```
You:   Why is my bill so high this month? My number is +1-415-555-0142.
Agent: Your June bill is USD 139.70, made up of: Premium Unlimited (USD 70.00),
       International Calls to Mexico (USD 12.00), a 10GB Data Add-on (USD 15.00),
       Roaming Mexico for 3 days (USD 30.00), and Taxes & Regulatory Fees (USD 12.70).
       Your usage shows 3 roaming days in Mexico, so the roaming charge is valid.
```

### Scenario 2: "I was charged for roaming but I didn't travel" (MCP + A2A dispute)

Emily Carter (+1-212-555-0178) is billed **USD 45.00 Roaming Mexico**, but her usage shows **0 roaming days**. The agent detects the discrepancy and, on confirmation, files a dispute via `billing_dispute_agent`.

```
You:   I was charged for roaming in Mexico but I never left the country.
       My number is +1-212-555-0178.
Agent: I checked invoice INV-2026-06-872: it has a Roaming Mexico charge of
       USD 45.00, but your usage shows 0 roaming days. That's a clear discrepancy.
       Would you like me to file a dispute?
You:   Yes please.
Agent: Done. Dispute DSP-2026-XXXX is now OPEN, estimated resolution within
       5 business days.
```

### Scenario 3: "I need more data" (MCP + A2A recharge)

Michael Rodriguez (+1-312-555-0163) has used 19.6 of 20 GB. The agent shows recharge offers and, on confirmation, applies one via `recharge_agent`.

```
You:   I'm almost out of data. My number is +1-312-555-0163.
Agent: You've used 19.6 of your 20 GB. Here are recharge packs: Data Booster 5GB
       (USD 10.00), Data Booster 10GB (USD 15.00), Data Max 25GB (USD 30.00).
You:   Give me the 10GB one.
Agent: Applied! Recharge RCG-2026-XXXX — Data Booster 10GB (USD 15.00), 10 GB added,
       active for 30 days.
```

### Scenario 4: "Show my last 3 payments" (MCP only)

David Martinez (+1-617-555-0187, Business, Boston) — the agent returns his most recent Auto-Pay payments via `GetPaymentHistory`.

### Scenario 5: "What plan am I on?" (MCP only)

Any subscriber — the agent summarizes the base plan and any active add-ons with expiry dates via `GetActivePlans`.

### Scenario 6: "What's the status of my dispute?" (MCP only)

Jessica Williams (+1-305-555-0134, VIP, Miami) has a pre-seeded dispute (DSP-2026-0001, UNDER_REVIEW). The agent looks it up via `GetDisputes`.

### Scenario 7: Wrong-charge disputes (MCP + A2A dispute)

Six dedicated accounts (CUST-10042887 … CUST-10042892) each carry one intentionally incorrect charge on their June invoice, contradicted by their usage record — a roaming charge with 0 roaming days, an international-call charge with 0 intl minutes, a duplicated monthly plan fee, an unauthorized premium-content subscription, a data-overage fee while under the limit, and a late-payment fee despite paying on time. Each lets the agent confirm the discrepancy and file a dispute via `billing_dispute_agent`. See `prompts.md` §10 for the exact prompts.

### Scenario 8: Full workflow with email (all agents)

File a dispute (or apply a recharge), then ask the agent to email a confirmation → the billing action runs first, then `send_confirmation_email` is invoked once. See `prompts.md` §8.

---

## Sample Data Summary

### Subscribers

| Customer ID | Name | Mobile | City | Segment | Type | Demo role |
|-------------|------|--------|------|---------|------|-----------|
| CUST-10042871 | James Anderson | +1-415-555-0142 | San Francisco | Premium | Postpaid | "Why is my bill high" (roaming Mexico valid) |
| CUST-10042872 | Emily Carter | +1-212-555-0178 | New York | Consumer | Postpaid | Dispute (roaming Mexico charged, 0 roaming days) |
| CUST-10042873 | Michael Rodriguez | +1-312-555-0163 | Chicago | Consumer | Postpaid | Recharge (19.6/20 GB) + OPEN dispute DSP-2026-0003 |
| CUST-10042874 | Sarah Thompson | +1-206-555-0119 | Seattle | Consumer | Prepaid | Plan lookup |
| CUST-10042875 | David Martinez | +1-617-555-0187 | Boston | Business | Postpaid | Payment history |
| CUST-10042876 | Jessica Williams | +1-305-555-0134 | Miami | VIP | Postpaid | Dispute status (DSP-2026-0001, UNDER_REVIEW) |
| CUST-10042877 | Christopher Lee | +1-702-555-0155 | Las Vegas | Consumer | Prepaid | Prepaid / general |
| CUST-10042878 | Amanda Davis | +1-512-555-0198 | Austin | Premium | Postpaid | Clean bill |
| CUST-10042879 | Robert Johnson | +1-404-555-0172 | Atlanta | Consumer | Postpaid | Dispute (IDD China charged, 0 intl minutes) |
| CUST-10042880 | Ashley Brown | +1-646-555-0110 | New York | Premium | Postpaid | High roaming (Canada, valid) |
| CUST-10042881 | Daniel Wilson | +1-773-555-0145 | Chicago | Business | Postpaid | Recharge (96.5/100 GB) |
| CUST-10042882 | Michelle Garcia | +1-480-555-0166 | Phoenix | Consumer | Prepaid | Prepaid top-ups |
| CUST-10042883 | Matthew Miller | +1-215-555-0129 | Philadelphia | Consumer | Postpaid | Resolved dispute (DSP-2026-0002) |
| CUST-10042884 | Stephanie Moore | +1-503-555-0181 | Portland | Premium | Postpaid | Roaming Mexico (valid) |
| CUST-10042885 | Kevin Taylor | +1-725-555-0193 | Las Vegas | VIP | Postpaid | Roaming Japan (valid), highest bill |
| CUST-10042886 | Nicole Jackson | +1-919-555-0157 | Raleigh | Consumer | Prepaid | Clean prepaid |
| CUST-10042887 | Brian Hall | +1-408-555-0102 | San Jose | Consumer | Postpaid | Wrong charge: roaming Mexico, 0 roaming days |
| CUST-10042888 | Laura Adams | +1-619-555-0113 | San Diego | Premium | Postpaid | Wrong charge: IDD India, 0 intl minutes |
| CUST-10042889 | Kevin Nguyen | +1-716-555-0124 | Buffalo | Consumer | Postpaid | Wrong charge: monthly plan billed twice |
| CUST-10042890 | Rachel Scott | +1-813-555-0135 | Tampa | Consumer | Postpaid | Wrong charge: unauthorized premium content |
| CUST-10042891 | Justin King | +1-901-555-0146 | Memphis | Premium | Postpaid | Wrong charge: data overage while under limit |
| CUST-10042892 | Megan Wright | +1-303-555-0157 | Denver | Consumer | Postpaid | Wrong charge: late fee despite paying on time |

### Flagship Invoice — James Anderson (INV-2026-06-871)

| Line item | Category | Amount (USD) |
|-----------|----------|--------------|
| Premium Unlimited (monthly) | PLAN | 70.00 |
| International Calls (Mexico) | IDD | 12.00 |
| Data Add-on 10GB | ADDON | 15.00 |
| Roaming Mexico (3 days) | ROAMING | 30.00 |
| Taxes & Regulatory Fees | TAX | 12.70 |
| **Total** | | **139.70** |

Usage: Data 38.7 / 50 GB · Local 342 min · International 47 min · SMS 12 · Roaming 3 days (Mexico)

---

## Prerequisites

- **PostgreSQL 14+** running (local or remote); a database named **`telecom`** created for this demo.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- **TIBCO Flogo Enterprise** (v2.26.7+) to import the `.flogo` apps into the designer — or the
  `flogobuild` CLI if you prefer to build `.exe`s.
- An **LLM provider** key (OpenAI-compatible). The base URL must be a **real endpoint**, e.g.
  `https://api.openai.com/v1` (or an on-premises OpenAI-compatible endpoint).
- **SMTP** access for the `send_confirmation_email` agent (Gmail: `smtp.gmail.com:465`, SSL, an
  **app-specific password** — see [Gmail App Password setup](#gmail-app-password-setup)).
- A **Chatbot UI / WebSocket client** — the bundled UI lives at `samples/Agentic_AI/Chatbot`.

---

## Setup & Run

> Folded in from `manual-steps.md` — the end-to-end deployment flow.

### Step 1 — Create the PostgreSQL database

```bash
# Connect to PostgreSQL and create the database
psql -h <host> -p <port> -U <user>
CREATE DATABASE telecom;
\q

# Load the schema and demo data
psql -h <host> -p <port> -U <user> -d telecom -f database.sql

# For live demos with today-relative due/payment/dispute dates, run the reset script:
psql -h <host> -p <port> -U <user> -d telecom -f reset_data.sql
```

Verify the data:

```bash
psql -h <host> -p <port> -U <user> -d telecom -c "SELECT customer_id, mobile_number, first_name, segment FROM customers ORDER BY customer_id;"
psql -h <host> -p <port> -U <user> -d telecom -c "SELECT invoice_id, total_amount, status FROM invoices ORDER BY invoice_id;"
```

### Step 2 — Import the three Flogo apps

Import all 3 `.flogo` files into TIBCO Flogo Enterprise (or build each to an `.exe` with `flogobuild`):

1. `TelecomInvoiceMCPServer.flogo`
2. `TelecomInvoiceA2AServers.flogo`
3. `TelecomInvoiceAIOrchestrator.flogo`

### Step 3 — Configure app properties

Use placeholders below; **never commit real secrets**. `Password` / `API_Key` / `Email_App_Password`
are stored as `SECRET:` app properties (type stays `string`).

**TelecomInvoiceMCPServer**

| Property | Value |
|----------|-------|
| `PostgreSQL.PostgresConn.Host` | `<db-host>` |
| `PostgreSQL.PostgresConn.Port` | `<db-port>` (default 5432) |
| `PostgreSQL.PostgresConn.Database_Name` | `telecom` |
| `PostgreSQL.PostgresConn.User` | `<db-user>` |
| `PostgreSQL.PostgresConn.Password` | `<db-password>` (SECRET) |
| `MCP_SERVER_PORT` | `9882` |

**TelecomInvoiceA2AServers**

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | `<your-llm-key>` (SECRET) |
| `AgenticAI.OpenAIConn.LLM_Base_URL` | `<real-llm-endpoint>` (e.g. `https://api.openai.com/v1`) |
| `LLM_Model` | `<model-name>` (e.g. `gpt-5.5`, or your preferred / on-prem model) |
| `PostgreSQL.PostgresConn.Host` | `<db-host>` |
| `PostgreSQL.PostgresConn.Database_Name` | `telecom` |
| `PostgreSQL.PostgresConn.User` | `<db-user>` |
| `PostgreSQL.PostgresConn.Password` | `<db-password>` (SECRET) |
| `To_Email` | `<recipient-email>` |
| `Email_Username` | `<gmail-address>` |
| `Email_App_Password` | `<gmail-app-password>` (SECRET) |
| `BillingDispute_A2AServer_PORT` | `9883` |
| `Recharge_A2AServer_PORT` | `9884` |
| `SendEmail_A2AServer_PORT` | `9885` |

**TelecomInvoiceAIOrchestrator**

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | `<your-llm-key>` (SECRET) |
| `AgenticAI.OpenAIConn.LLM_Base_URL` | `<real-llm-endpoint>` |
| `LLM_Model` | `<model-name>` |

### Step 4 — Configure connections (if not localhost)

Connection URLs default to `localhost`. If running on different hosts, update these in Flogo Enterprise:

**Orchestrator app connections:**
- `TelecomBSSMCPServer` → `http://<mcp-host>:9882/telecom-bss`
- `BillingDisputeA2AServer` → `http://<a2a-host>:9883`
- `RechargeA2AServer` → `http://<a2a-host>:9884`
- `SendEmailA2AServer` → `http://<a2a-host>:9885`

**A2A / MCP app connections:**
- `PostgresConn` → update host/port/database if not localhost

> The orchestrator's MCP/A2A `serverUrl`s **must match** the MCP/A2A ports above. If you change a
> port, change it in the app property **and** in the corresponding orchestrator connection URL.

### Step 5 — Start the apps (in order)

1. `TelecomInvoiceMCPServer` (port 9882 must be ready first)
2. `TelecomInvoiceA2AServers` (ports 9883, 9884, 9885)
3. `TelecomInvoiceAIOrchestrator` (port 9500 — needs MCP and A2A running)

### Step 6 — Connect the Chatbot UI

```bash
cd samples/Agentic_AI/Chatbot
npm install    # first time only
npm start
```

Open **http://localhost:3000**, then:

1. In the URL box at the top right, enter **`ws://localhost:9500/telecom`**.
2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
3. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
last URL you applied, so a URL from another demo is a common cause.

### Step 7 — Run the demo

Use the prompts from `prompts.md`. Recommended flow: bill explanation → payment history → dispute →
recharge → email confirmation → dispute status → more wrong-charge disputes (see
[Demo Scenarios](#demo-scenarios)).

### Step 8 — Reset demo data

After a run (especially after filing disputes or applying recharges), reset:

```bash
psql -h <host> -p <port> -U <user> -d telecom -f reset_data.sql
```

This restores all tables, clears agent-written rows from `disputes` (new ones) and `recharges`, and
refreshes due/payment/dispute dates relative to today.

---

## Ports

| App | Property | Port | Protocol |
|-----|----------|------|----------|
| TelecomInvoiceMCPServer | `MCP_SERVER_PORT` | 9882 | HTTP (MCP), `/telecom-bss` |
| TelecomInvoiceA2AServers — billing_dispute | `BillingDispute_A2AServer_PORT` | 9883 | HTTP (A2A) |
| TelecomInvoiceA2AServers — recharge | `Recharge_A2AServer_PORT` | 9884 | HTTP (A2A) |
| TelecomInvoiceA2AServers — send_email | `SendEmail_A2AServer_PORT` | 9885 | HTTP (A2A) |
| TelecomInvoiceAIOrchestrator | `#wsserver` (trigger setting) | 9500 | WebSocket, `/telecom` |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| **`unsupported protocol scheme` / posts to `/New_value/...`** | The LLM base URL is blank; set `AgenticAI.OpenAIConn.LLM_Base_URL` to a real endpoint. |
| **MCP runtime panics `missing input schema`** | A tool handler is missing its input/output schema — **Sync** the MCP trigger. |
| **A2A write fails with `missing substitution for: <name>`** | The runtime `input.mapping.parameters` is missing that param; patch it, then **Sync** the agent flow to regenerate design-time schemas. |
| **`Configured connection is not a WebSocket Connection`** | The orchestrator's `wsconnection` / `content` were coerced to `object`; they must stay type **`any`**. |
| **Email field warns "type … differs from bound app property"** | Re-enter `Email_App_Password` in App Properties so it's stored as a `SECRET:` (keep the property type `string` — there is no `password` app-property type). |
| **Orchestrator can't reach a tool/agent** | The MCP/A2A `serverUrl`s must match the ports in [Ports](#ports). |
| **MCP Server not connecting** | Verify port 9882 is open and the MCP app is running. |
| **A2A agents not responding** | Check ports 9883–9885 are open and the A2A app is running. |
| **PostgreSQL connection failed** | Verify database `telecom` exists and credentials are correct. |
| **Email not sending** | Verify the Gmail **App Password** (not the account password); enable 2FA on the Google account first. |
| **Agent gives stale/wrong data** | Run `reset_data.sql` to restore demo data. |
| **WebSocket disconnects** | Ensure the Orchestrator app is running on port 9500. |
| **Agent can't find a subscriber** | The mobile number must match one in `customers` (format `+1-XXX-555-01XX`). |

### Gmail App Password setup

To enable the email agent:

1. Go to `https://myaccount.google.com/security`
2. Enable **2-Step Verification**
3. Go to `https://myaccount.google.com/apppasswords`
4. Generate an App Password for "Mail"
5. Use the 16-character password as `Email_App_Password`

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The committed `.flogo` files carry placeholders / reference-app values for every secret; replace them
with your own before an end-to-end run. **Never commit real secrets.**

1. **LLM credentials & endpoint.**
   - `AgenticAI.OpenAIConn.API_Key` — set your real provider key (inject as an app property /
     platform secret; keep it out of the repo).
   - `AgenticAI.OpenAIConn.LLM_Base_URL` — a **real endpoint** (`https://api.openai.com/v1`). An
     empty value becomes the literal `New_value` and the LLM call fails with `unsupported protocol scheme`.
   - `LLM_Model` — confirm the model name is one your key can access.

2. **PostgreSQL database & credentials.**
   - Create the **`telecom`** database and load `database.sql`; run `reset_data.sql` to reset between demos.
   - Set the PostgreSQL connection `Host` / `Port` / `Database_Name` / `User` / `Password` to your
     instance. `Password` is a `SECRET:` app property — set the real secret in App Properties, not in plaintext.
   - Verify connectivity: run each MCP tool's `SELECT` and each A2A write's SQL against the DB.

3. **Ports must be free & consistent.**
   - MCP **9882**, billing-dispute **9883**, recharge **9884**, email **9885**, and the orchestrator
     WebSocket **9500** must all be free on the host.
   - The orchestrator's MCP `serverUrl` and each A2A `serverUrl` must match those ports.

4. **Email / SMTP** (the `send_confirmation_email` agent).
   - Set `Email_Username`, `Email_App_Password` (an app-specific password, **not** the account
     password), and the recipient `To_Email` property.
   - Confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed from the host/network.
   - **Re-enter `Email_App_Password` in App Properties so it is stored as a `SECRET:` value** (leave
     the property type as `string`).

5. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://<host>:9500/telecom`. Point the bundled UI
     (`samples/Agentic_AI/Chatbot`) or a WS test client at it. See `prompts.md` for ready-to-paste prompts.

6. **Flogo designer manual steps** (clear design-time validation).
   - **Sync every trigger** (MCP, each A2A agent, the WS server) once, so `toolParams` and WS input
     mappings render without a red ✗.
   - **Validate every connection** (PostgreSQL, LLM provider, MCP server config, all three A2A server
     connections) — click **Connect / Test** before running.
   - **Set the email password as a secret** — see item 4.

**Quick pre-flight checklist**

- [ ] DB `telecom` created, `database.sql` loaded, row counts sane (customers 22, invoices 18, line_items 59, payments 50)
- [ ] LLM `API_Key`, `LLM_Base_URL` (real endpoint), `LLM_Model` set
- [ ] PostgreSQL `Password` set; MCP tool `SELECT`s and A2A write SQL run cleanly
- [ ] All 5 ports free (9882, 9883, 9884, 9885, 9500); orchestrator MCP/A2A URLs match the MCP/A2A ports
- [ ] `Email_App_Password` re-entered as a `SECRET:` (type stays `string`); SMTP reachable
- [ ] Every trigger Synced; every connection validated in the designer
- [ ] Start order: MCP → A2A → Orchestrator; each logs a clean start
- [ ] WebSocket client connects to `ws://<host>:9500/telecom` and gets a reply

---

## Supporting Files

| File | Description |
|------|-------------|
| `database.sql` | PostgreSQL schema with 9 tables and demo data |
| `reset_data.sql` | Data reset script (today-relative dates; clears agent-written rows) |
| `prompts.md` | Demo prompts organized by scenario |
| `manual-steps.md` | Step-by-step setup and deployment instructions (folded into [Setup & Run](#setup--run) above) |

---

## Security & Production Notes (from the design)

This is the Phase-1 working demo. For production the design calls for: TLS on all endpoints (WebSocket + MCP + A2A), Bearer-token auth on the MCP Server, API-gateway rate limiting, an on-premises LLM for data residency, and swapping the PostgreSQL-backed tools for real BSS API calls (Billing, CRM, Product Catalog, Payment Gateway).
