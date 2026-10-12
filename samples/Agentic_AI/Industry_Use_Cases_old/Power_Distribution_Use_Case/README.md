# Electric Power Distribution — Residential Self-Service Use Case

An AI-powered self-service assistant for a residential electric power distribution utility, built on
TIBCO Flogo Enterprise. Residents chat in natural language ("Why is my bill so high?", "Is there an
outage in my area?", "My power is out — send a crew", "I paid my balance, please reconnect me") over a
WebSocket streaming chat. The system uses a 3-tier agentic architecture — an AI Orchestrator, an MCP
Server for read-only grid/BSS lookups, and A2A Servers / Agents for write workflows (outage tickets, service
appointments, service requests, and email) — all communicating via standard protocols (MCP, A2A,
WebSocket).

> **Demo dataset:** a residential electric transmission & distribution (T&D) utility — currency
> **USD**, **Taxes & Regulatory Fees ~7%**, residents identified by account number
> (`ACCT-XXXXXXXX`), phone on file (`+1-XXX-555-01XX`), or service address. 18 accounts span four
> residential rate plans (Standard, Time-of-Use, EV, Solar Net-Metering) with pre-seeded outages,
> outage tickets, service appointments, and reconnect requests for status demos.

---

## Architecture

```
                    ┌─────────────────────────┐
                    │     Chatbot UI          │
                    │  (WebSocket Client)     │
                    └───────┬─────────────────┘
                            │ WebSocket
                            │ ws://localhost:9680/grid
                            ▼
               ┌────────────────────────────────┐
               │  Power Distribution            │
               │  AI Orchestrator               │
               │  (PowerDistributionAIOrch.)    │
               │  Port 9680 (WebSocket)         │
               │  LLM: OpenAI GPT               │
               └───────┬───────────┬────────────┘
                       │           │
          MCP (HTTP)   │           │  A2A Protocol
                       ▼           ▼
    ┌──────────────────────┐   ┌──────────────────────────────────────┐
    │  Power Distribution  │   │  Power Distribution                  │
    │  MCP Server          │   │  A2A Servers / Agents                │
    │  Port 9682           │   │                                      │
    │  /grid-bss           │   │  outage_dispatch_agent        :9683  │
    │                      │   │  service_appointment_agent    :9684  │
    │  Tools (read-only):  │   │  service_change_agent         :9685  │
    │  - GetCustomerAccounts│  │  send_confirmation_email      :9686  │
    │  - GetInvoiceDetails │   │                                      │
    │  - GetUsageRecords   │   │  Writes to PostgreSQL                │
    │  - GetPaymentHistory │   │  (tickets / appointments /           │
    │  - GetRatePlans      │   │   service requests)                  │
    │  - GetOutages        │   │  + Gmail SMTP for email              │
    │  - GetOutageTickets  │   │                                      │
    │  - GetServiceAppts   │   │                                      │
    │  - GetServiceRequests│   │                                      │
    └──────────┬───────────┘   └──────────────┬───────────────────────┘
               │                              │
               └──────────────┬───────────────┘
                              ▼
               ┌────────────────────────────┐
               │  PostgreSQL Database       │
               │  Database: power_distribution│
               │  10 Tables                 │
               └────────────────────────────┘
```

**How it works:** the **AI Orchestrator** is the brain — a WebSocket endpoint whose AI Agent activity
classifies each message and routes it. Read questions (account, bill, usage, payments, rate plans,
outages, ticket/appointment/request status) go to the **MCP Server**, which exposes 9 read-only
PostgreSQL lookup tools. Actions that change state (report an outage, schedule an appointment, submit
a reconnect, send an email) go to the **A2A Servers / Agents**, one write agent per port.

---

## Flogo Apps

### 1. `PowerDistributionMCPServer.flogo` — MCP Server (Port 9682)

Exposes 9 read-only lookup tools via the Model Context Protocol over Streamable HTTP (endpoint
`/grid-bss`). Each tool queries the PostgreSQL `power_distribution` database and returns the result set
as a string; the LLM filters by account number / phone / zip.

| Tool | Description | Table / Query |
|------|-------------|---------------|
| **GetCustomerAccounts** | Account master: account #, phone, name, address, segment, meter, connection status, rate plan | `SELECT * FROM customers` |
| **GetInvoiceDetails** | Monthly bill header + itemized line items (BASE_CHARGE, DELIVERY, TOU, RIDER, credits, TAXES_FEES) | `invoices JOIN bill_line_items` |
| **GetUsageRecords** | Metered kWh usage: total, on/off-peak, solar export, avg daily, prior-year comparison | `SELECT * FROM usage_records` |
| **GetPaymentHistory** | Recent payments with method, status, reference | `SELECT * FROM payments` |
| **GetRatePlans** | Residential rate catalog (Standard, TOU, EV, Solar) | `SELECT * FROM rate_plans` |
| **GetOutages** | Area-level active outages by feeder / zip / area, cause, status, ETA | `SELECT * FROM outages` |
| **GetOutageTickets** | Customer-reported outage tickets + crew dispatch status | `SELECT * FROM outage_tickets` |
| **GetServiceAppointments** | Scheduled field appointments (inspection, upgrade, survey) | `SELECT * FROM service_appointments` |
| **GetServiceRequests** | Reconnect / disconnect / transfer requests and status | `SELECT * FROM service_requests` |

### 2. `PowerDistributionA2AServers.flogo` — A2A Servers / Agents (Ports 9683–9686)

Four A2A agents that handle write workflows. Each agent has its own LLM, system prompt, and tool
handler, and writes to PostgreSQL (the email agent sends via SMTP).

| Agent | Port | Tool | Write Workflow |
|-------|------|------|----------------|
| **outage_dispatch_agent** | 9683 | `report_outage` | Checks current area outages, then inserts a new outage ticket (status OPEN → CREW_DISPATCHED) with a crew ID and ETA into `outage_tickets`. |
| **service_appointment_agent** | 9684 | `schedule_appointment` | Books a field appointment (meter inspection, meter upgrade, new service, tree trim, site survey) with a date + time window into `service_appointments` (status SCHEDULED). |
| **service_change_agent** | 9685 | `submit_service_request` | Submits a reconnect / disconnect / transfer into `service_requests`. **Guardrail:** a reconnect is only submitted once the past-due balance is cleared. |
| **send_confirmation_email** | 9686 | `send_confirmation_email` | Sends a confirmation email (outage ticket / appointment / reconnect) via Gmail SMTP. Invoked only once, after the action, when the resident requests it. |

### 3. `PowerDistributionAIOrchestrator.flogo` — AI Orchestrator (Port 9680)

The main orchestration app. Exposes a WebSocket endpoint for natural-language chat. An AI Agent
activity classifies intent and routes to either MCP tools (data lookups) or A2A agents (write
workflows).

| Setting | Value |
|---------|-------|
| WebSocket Port | `9680` |
| WebSocket Path | `/grid` |
| Connect URL | `ws://localhost:9680/grid` |
| LLM | OpenAI GPT |
| MCP Server | `http://localhost:9682/grid-bss` |
| A2A Servers / Agents | outage_dispatch (9683), service_appointment (9684), service_change (9685), email (9686) |

---

## Database

10 tables in the PostgreSQL `power_distribution` database:

| Table | Purpose | Records |
|-------|---------|---------|
| `rate_plans` | Residential delivery rate catalog (Standard, TOU, EV, Solar) | 4 plans |
| `customers` | Account master — one residential account = one service point / meter | 18 accounts |
| `invoices` | Monthly electric bill headers (June 2026) | 18 invoices |
| `bill_line_items` | Itemized charges per invoice (delivery, riders, credits, taxes) | 70+ line items |
| `usage_records` | Metered kWh usage vs prior year | 18 (one per account) |
| `payments` | Payment history (2 per account; Henry has an extra cleared payment) | 37 payments |
| `outages` | Area-level active outages by feeder / zip | 3 outages |
| `outage_tickets` | Customer-reported outages + crew dispatch (**written by** outage_dispatch_agent) | 1 pre-seeded |
| `service_appointments` | Scheduled field appointments (**written by** service_appointment_agent) | 1 pre-seeded |
| `service_requests` | Reconnect / disconnect / transfer requests (**written by** service_change_agent) | 1 pre-seeded |

```bash
# Initialize schema and demo data (operational tables are already today-relative)
psql -U postgres -d power_distribution -f database.sql

# Reset to a clean demo state (today-relative dates; clears agent-written rows)
psql -U postgres -d power_distribution -f reset_data.sql
```

---

## Demo Personas

| Account ID | Name | Phone | Area (Zip) | Rate Plan | Demo role |
|------------|------|-------|------------|-----------|-----------|
| ACCT-50010001 | Laura Bennett | +1-469-555-0142 | Cedar Springs (75001) | Standard | "Why is my bill high" — summer AC spike ($125.19); report a new outage; schedule inspection |
| ACCT-50010002 | Marcus Reed | +1-214-555-0178 | Maple Grove (75002) | EV TOU | EV overnight charging (cheap off-peak) |
| ACCT-50010003 | Priya Nair | +1-972-555-0163 | Riverton (75003) | Solar | Solar net-metering export credit (-$27.90) |
| ACCT-50010004 | Diane Foster | +1-682-555-0119 | Oakdale (75004) | Standard | Medical baseline credit; in storm-outage zip 75004 |
| ACCT-50010005 | Tom Alvarez | +1-940-555-0187 | Highland (75005) | TOU | Heavy on-peak TOU (highest bill $143.86) |
| ACCT-50010006 | Grace Kim | +1-817-555-0134 | Fair Meadows (75006) | Standard | Analog meter, ESTIMATED read; smart-meter upgrade |
| ACCT-50010007 | Henry Wu | +1-469-555-0155 | Cedar Springs (75007) | Standard | DISCONNECTED; recent $142.50 payment cleared past-due → reconnect eligible |
| ACCT-50010008 | Olivia Brooks | +1-214-555-0198 | Maple Grove (75008) | Standard | Clean bill / general |
| ACCT-50010009 | Samuel Ortiz | +1-972-555-0172 | Riverton (75009) | Standard | Clean bill / general |
| ACCT-50010010 | Rebecca Lynn | +1-682-555-0110 | Oakdale (75010) | Standard | In planned-outage zip 75010 |
| ACCT-50010011 | David Chen | +1-940-555-0145 | Lakeside (75011) | Standard | Clean bill / general |
| ACCT-50010012 | Angela Price | +1-817-555-0166 | Oakdale (75004) | Standard | In storm-outage zip 75004 |
| ACCT-50010013 | Nathan Cole | +1-469-555-0129 | Fair Meadows (75013) | Standard | Budget billing levelization (-$12.50) |
| ACCT-50010014 | Sophia Turner | +1-214-555-0181 | Highland (75014) | Standard | Pre-seeded appointment APPT-2026-0001 (METER_INSPECTION, SCHEDULED) |
| ACCT-50010015 | Ethan Mills | +1-972-555-0193 | Lakeside (75015) | Standard | Pre-seeded outage ticket OTKT-2026-0001 (CREW_DISPATCHED, CREW-07) |
| ACCT-50010016 | Maria Gonzalez | +1-682-555-0157 | Riverton (75016) | Standard | PENDING connection; reconnect SRV-2026-0001 (IN_PROGRESS) |
| ACCT-50010017 | William Scott | +1-817-555-0102 | Highland (75017) | Standard | In equipment-outage zip 75017 (INVESTIGATING) |
| ACCT-50010018 | Chloe Adams | +1-940-555-0113 | Maple Grove (75018) | EV TOU | EV owner / general |

### Flagship Bill — Laura Bennett (INV-2026-06-0001)

| Line item | Category | Amount (USD) |
|-----------|----------|--------------|
| Basic Service Charge | BASE_CHARGE | 9.50 |
| Energy Delivery Charge (1,850 kWh @ $0.045) | DELIVERY | 83.25 |
| Grid Access & Transmission Cost Recovery | RIDER | 24.25 |
| Taxes & Regulatory Fees | TAXES_FEES | 8.19 |
| **Total** | | **125.19** |

Usage: 1,850 kWh this period vs 1,210 kWh a year ago (a ~53% summer AC spike) · 61.67 kWh/day avg ·
peak demand 6.8 kW · ACTUAL read.

### Pre-seeded operational rows (for status demos)

| Record | Account | State |
|--------|---------|-------|
| Area outages OUT-2026-0001/0002/0003 | zips 75004 / 75010 / 75017 | STORM (RESTORING) / PLANNED (CREW_ASSIGNED) / EQUIPMENT (INVESTIGATING) |
| Outage ticket OTKT-2026-0001 | Ethan Mills (ACCT-50010015) | CREW_DISPATCHED, CREW-07 |
| Appointment APPT-2026-0001 | Sophia Turner (ACCT-50010014) | METER_INSPECTION, SCHEDULED (+3 days) |
| Service request SRV-2026-0001 | Maria Gonzalez (ACCT-50010016) | RECONNECT, IN_PROGRESS |

---

## Demo Scenarios

### Scenario 1: "Why is my bill so high?" (MCP only)
Laura Bennett (ACCT-50010001) has a June bill of **USD 125.19**. The agent looks up her account,
invoice line items, and usage and explains that her 1,850 kWh is up ~53% from 1,210 kWh a year ago —
a valid summer AC spike, not a billing error — itemizing the base charge, delivery, grid-access rider,
and taxes.

### Scenario 2: "How does my rate plan / credit work?" (MCP only)
Tom Alvarez (Time-of-Use, heavy on-peak — highest bill), Priya Nair (solar export credit), Diane
Foster (medical baseline credit), Grace Kim (estimated read on an analog meter), and Nathan Cole
(budget billing) each showcase a distinct residential billing construct the agent can explain from
`GetInvoiceDetails` + `GetRatePlans`.

### Scenario 3: "Is there an outage near me?" (MCP only)
Diane Foster / Angela Price (zip 75004) sit under an active STORM outage (OUT-2026-0001, RESTORING,
1,240 affected, ETA ~2 hours). The agent reports the cause, status, and estimated restoration. Rebecca
Lynn (75010, planned) and William Scott (75017, equipment/investigating) show the other outage types.

### Scenario 4: "What's the status of my outage report?" (MCP only)
Ethan Mills (ACCT-50010015) has a pre-seeded ticket OTKT-2026-0001. The agent looks it up via
`GetOutageTickets` and reports CREW_DISPATCHED, crew CREW-07, ETA ~90 minutes.

### Scenario 5: "My power is out — report it" (MCP + A2A report_outage)
Laura Bennett (ACCT-50010001, zip 75001) has no active area outage. The agent confirms there's no
known outage, then on confirmation files a new ticket via `outage_dispatch_agent`, returning a ticket
ID and crew ETA. Optionally emails the confirmation.

### Scenario 6: "Schedule a service appointment" (MCP + A2A schedule_appointment)
Sophia Turner (ACCT-50010014) checks her pre-seeded meter inspection (APPT-2026-0001) via
`GetServiceAppointments`. Grace Kim (ACCT-50010006, analog meter) requests a smart-meter upgrade; the
agent books it via `service_appointment_agent` with a date and time window.

### Scenario 7: "Turn my power back on" (MCP + A2A submit_service_request + guardrail)
Maria Gonzalez (ACCT-50010016) checks her IN_PROGRESS reconnect (SRV-2026-0001). Henry Wu
(ACCT-50010007) is DISCONNECTED; his recent **$142.50** payment cleared the past-due balance, so the
agent submits a RECONNECT via `service_change_agent`. **Guardrail:** if the past-due balance were still
outstanding, the agent refuses the reconnect and asks the resident to pay first.

### Scenario 8: Email confirmation (A2A send_confirmation_email)
After any write action (outage ticket, appointment, reconnect), the resident can ask "email me a
confirmation" and `send_confirmation_email` sends the details to the address on file via SMTP.

See `prompts.md` for copy-paste-ready prompts grouped by scenario.

---

## Prerequisites

- TIBCO Flogo Enterprise v2.26.7+
- PostgreSQL 14+ (local or remote)
- PostgreSQL ODBC driver (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md))
- OpenAI API key (or an on-premises OpenAI-compatible LLM endpoint)
- Gmail account with an App Password (for the email agent)
- Chatbot UI (from `samples/Agentic_AI/Chatbot/`)

> Environment values (PostgreSQL host/port/user/password, OpenAI API key & model, SMTP host/port/user/
> app-password) are app properties. Do **not** commit secrets to this repo — set the app properties
> listed below with your own values at import time.

---

## Setup & Run

### Step 1 — Create the PostgreSQL database

```bash
psql -U postgres -c "CREATE DATABASE power_distribution;"
psql -U postgres -d power_distribution -f database.sql
```

For live demos with today-relative outage / appointment / due dates, run (or re-run) the reset script:

```bash
psql -U postgres -d power_distribution -f reset_data.sql
```

Verify the data:
```bash
psql -U postgres -d power_distribution -c "SELECT account_id, first_name, last_name, connection_status, rate_plan_id FROM customers ORDER BY account_id;"
psql -U postgres -d power_distribution -c "SELECT invoice_id, total_amount, status FROM invoices ORDER BY invoice_id;"
```

### Step 2 — Import the Flogo apps

Import all 3 `.flogo` files into TIBCO Flogo Enterprise:

1. **PowerDistributionMCPServer.flogo**
2. **PowerDistributionA2AServers.flogo**
3. **PowerDistributionAIOrchestrator.flogo**

### Step 3 — Configure app properties

Set your own values (do not hard-code secrets).

**PowerDistributionMCPServer**

| Property | Value |
|----------|-------|
| `PostgreSQL.PostgresConn.Host` | `localhost` (or your DB host) |
| `PostgreSQL.PostgresConn.Port` | `5432` |
| `PostgreSQL.PostgresConn.Database_Name` | `power_distribution` |
| `PostgreSQL.PostgresConn.User` | `postgres` |
| `PostgreSQL.PostgresConn.Password` | Your PostgreSQL password |
| `MCP_SERVER_PORT` | `9682` |

**PowerDistributionA2AServers**

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | Your OpenAI API key |
| `LLM_Model` | `gpt-5.5` (or any model your key can access) |
| `PostgreSQL.PostgresConn.Host` | `localhost` |
| `PostgreSQL.PostgresConn.Database_Name` | `power_distribution` |
| `PostgreSQL.PostgresConn.User` | `postgres` |
| `PostgreSQL.PostgresConn.Password` | Your PostgreSQL password |
| `Email_Host` | `smtp.gmail.com` |
| `Email_Port` | `465` |
| `Email_Username` | Gmail address for SMTP |
| `Email_App_Password` | Gmail App Password |
| `To_Email` | Recipient email for confirmations |
| `OutageDispatch_A2AServer_PORT` | `9683` |
| `ServiceAppointment_A2AServer_PORT` | `9684` |
| `ServiceChange_A2AServer_PORT` | `9685` |
| `SendEmail_A2AServer_PORT` | `9686` |

**PowerDistributionAIOrchestrator**

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | Your OpenAI API key |
| `LLM_Model` | `gpt-5.5` (or any model your key can access) |

If apps run on different hosts, update the orchestrator's connection URLs
(`http://<mcp-host>:9682/grid-bss` and the A2A server URLs on 9683–9686).

### Step 4 — Start the apps (in this order)

1. **PowerDistributionMCPServer** (port 9682 must be ready first)
2. **PowerDistributionA2AServers** (ports 9683, 9684, 9685, 9686)
3. **PowerDistributionAIOrchestrator** (port 9680 — needs MCP and A2A running)

### Step 5 — Connect the chatbot UI

```bash
cd samples/Agentic_AI/Chatbot
npm install    # first time only
npm start
```

Open **http://localhost:3000**, then:

1. In the URL box at the top right, enter **`ws://localhost:9680/grid`**.
2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
3. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
last URL you applied, so a URL from another demo is a common cause.

### Step 6 — Run the demo & reset

Use the prompts from `prompts.md`. Recommended flow: bill explanation (Laura) → outage lookup (zip
75004) → outage ticket status (Ethan) → report a new outage (Laura) → appointment status (Sophia) →
schedule a meter upgrade (Grace) → reconnect status (Maria) → reconnect after payment (Henry) → email
confirmation. After a run, restore clean data:

```bash
psql -U postgres -d power_distribution -f reset_data.sql
```

---

## Ports

| App | Port | Protocol |
|-----|------|----------|
| PowerDistributionAIOrchestrator | 9680 | WebSocket, `/grid` |
| PowerDistributionMCPServer | 9682 | HTTP (MCP), `/grid-bss` |
| PowerDistributionA2AServers — outage_dispatch_agent | 9683 | HTTP (A2A), `report_outage` |
| PowerDistributionA2AServers — service_appointment_agent | 9684 | HTTP (A2A), `schedule_appointment` |
| PowerDistributionA2AServers — service_change_agent | 9685 | HTTP (A2A), `submit_service_request` |
| PowerDistributionA2AServers — send_confirmation_email | 9686 | HTTP (A2A), `send_confirmation_email` |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| MCP Server not connecting | Verify port 9682 is open and the MCP app is running before the orchestrator |
| A2A agents not responding | Check ports 9683–9686 are open and the A2A app is running |
| PostgreSQL connection failed | Verify database `power_distribution` exists and credentials match the app properties |
| Agent can't find an account | Match the account number (`ACCT-500100XX`), phone (`+1-XXX-555-01XX`), or address to `customers` |
| Outages / tickets look stale or wrong dates | Re-run `reset_data.sql` — operational rows use today-relative timestamps |
| Reconnect refused | Expected guardrail: the account still shows a past-due balance. Henry (ACCT-50010007) is reconnect-eligible only because his recent payment cleared the balance |
| Email not sending | Verify the Gmail **App Password** (not the account password) and that SMTP host/port (`smtp.gmail.com:465`) are set; enable 2FA on the Google account first |
| Agent gives stale data after writes | Run `reset_data.sql` to clear agent-written tickets/appointments/requests |
| WebSocket disconnects | Ensure the Orchestrator is running on port 9680 and the client uses `ws://localhost:9680/grid` (enter it, click ↻ next to the URL box, then **Connect**) |

---

## Supporting Files

| File | Description |
|------|-------------|
| `database.sql` | PostgreSQL schema (10 tables) + demo data (today-relative operational rows) |
| `reset_data.sql` | Reset script (today-relative dates; clears agent-written rows) |
| `prompts.md` | Demo prompts organized by scenario |
| `PowerDistributionMCPServer.flogo` | MCP Server app (9 read-only tools) |
| `PowerDistributionA2AServers.flogo` | A2A Servers / Agents app (4 write agents) |
| `PowerDistributionAIOrchestrator.flogo` | AI Orchestrator app (WebSocket brain) |

---

## Security & Production Notes

This is a working demo. For production the design calls for: TLS on all endpoints (WebSocket + MCP +
A2A), Bearer-token auth on the MCP Server, API-gateway rate limiting, an on-premises LLM for data
residency, and swapping the PostgreSQL-backed tools for real utility backend integrations (CIS/Billing,
CRM, Outage Management System, Meter Data Management, Work/Field Service Management).

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The committed `.flogo` files carry placeholders / reference-app values for every secret; replace them
with your own before an end-to-end run. Never commit real secrets — set the app properties listed
above with your own values at import time.

1. **LLM credentials & endpoint** (A2A Servers / Agents + Orchestrator).
   - `AgenticAI.OpenAIConn.API_Key` — your real provider key (kept as a `SECRET:` app property).
   - `AgenticAI.OpenAIConn.LLM_Base_URL` — set to your provider's endpoint; for OpenAI use
     `https://api.openai.com/v1`. Leaving it blank can make the LLM call fail with
     `unsupported protocol scheme`.
   - `LLM_Model` — confirm the model name is one your key can access.

2. **PostgreSQL database & credentials** (MCP + A2A).
   - Create the **`power_distribution`** database and load `database.sql`; run `reset_data.sql` to
     reset between demos.
   - Set `PostgreSQL.PostgresConn.Host` / `Port` / `Database_Name` / `User` / `Password` on **both** the
     MCP Server and A2A Servers / Agents apps. `Password` is a `SECRET:` app property — set the real secret in
     App Properties, not in plaintext.

3. **Email / SMTP** (the `send_confirmation_email` agent).
   - Set `Email_Host` (`smtp.gmail.com`), `Email_Port` (`465`), `Email_Username`, `Email_App_Password`
     (a Gmail **App Password**, not the account password), and the recipient `To_Email`.
   - Confirm outbound SMTP (SSL:465) is allowed from the host/network.

4. **Ports free & consistent.**
   - MCP **9682**, A2A **9683–9686**, and the orchestrator WebSocket **9680** must all be free on the host.
   - The orchestrator's MCP `serverUrl` (`http://localhost:9682/grid-bss`) and the four A2A
     `serverUrl`s (9683–9686) must match those ports. If you change a port, change it in the app
     property **and** in the orchestrator connection URL.

5. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://<host>:9680/grid`. Point the shared Chatbot UI
     (`samples/Agentic_AI/Chatbot/`) at it — see `prompts.md` for ready-to-paste demo prompts.

6. **Flogo designer manual steps.**
   - **Sync every trigger** (MCP, each A2A agent, the WS server) once so `toolParams` and WS input
     mappings render without a red ✗.
   - **Validate every connection** (PostgreSQL, LLM provider, MCP server config, all four A2A server
     connections) — click **Connect / Test** before running.

**Quick pre-flight checklist**

- [ ] DB `power_distribution` created, `database.sql` loaded, `reset_data.sql` run; row counts sane (customers 18, invoices 18, rate_plans 4)
- [ ] LLM `AgenticAI.OpenAIConn.API_Key` and `LLM_Model` set on A2A + Orchestrator; `LLM_Base_URL` correct for your provider
- [ ] PostgreSQL `Password` set on MCP + A2A; MCP tool `SELECT`s and A2A write SQL run cleanly
- [ ] All ports free (9680, 9682, 9683–9686); orchestrator MCP/A2A URLs match the MCP/A2A ports
- [ ] `Email_App_Password` set as a Gmail App Password; `To_Email` set; SMTP `smtp.gmail.com:465` reachable
- [ ] Every trigger Synced; every connection validated in the designer
- [ ] Start order: MCP (9682) → A2A (9683–9686) → Orchestrator (9680); each logs a clean start
- [ ] Chatbot UI connects to `ws://localhost:9680/grid` and gets a reply
