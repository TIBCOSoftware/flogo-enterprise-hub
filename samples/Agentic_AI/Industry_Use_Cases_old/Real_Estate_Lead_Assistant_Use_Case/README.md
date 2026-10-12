# Real Estate Lead Engagement Assistant — Agentic AI Use Case

An agentic AI system built on **TIBCO Flogo Enterprise** that lets a **home buyer/seller lead**
self-serve in natural language over a chat window. A prospect who came in from a website or ad can
**ask about their profile and saved criteria**, **browse and get details on active listings**,
**see local market insights**, **book a property showing**, **get curated home recommendations by
email**, and **request an agent follow-up** — with no human in the loop until they want one. An
orchestrator agent classifies intent and routes each request to read-only **MCP tools** or to
write-workflow **A2A agents**, all backed by PostgreSQL. As the prospect takes real steps (books a
tour), the assistant automatically **advances their funnel stage** so the pipeline stays current.

> Built with the `agentic-ai-use-case` skill (Flogo Design CLI method). Demo data is fictional.

---

## Architecture

```
                       ┌──────────────────────────┐
                       │   Agentic Chatbot UI      │
                       │  (samples/Agentic_AI/Chatbot)│
                       └────────────┬──────────────┘
                                    │ WebSocket  ws://localhost:9590/realestate
                                    ▼
                    ┌───────────────────────────────┐
                    │   RealEstateAIOrchestrator      │
                    │   (#wsserver + AI Agent)        │
                    │   Port 9590                      │
                    └───┬───────────────────────┬─────┘
             MCP (HTTP) │                        │ A2A
                        ▼                        ▼
      ┌──────────────────────────┐   ┌──────────────────────────────────────────┐
      │  RealEstateMCPServer      │   │  RealEstateA2AServers                      │
      │  6 read-only tools        │   │  book_property_showing        :9593        │
      │  Port 9592                │   │  update_lead_stage            :9594        │
      │  /realestate-mls          │   │  send_property_recommendations:9595        │
      └────────────┬─────────────┘   │  log_followup_task            :9596        │
                   │                  │  send_confirmation_email      :9597        │
                   │                  └──────────────────┬─────────────────────────┘
                   │                                     │  (+ SMTP for email)
                   └──────────────────┬──────────────────┘
                                      ▼
                           ┌──────────────────────┐
                           │  PostgreSQL (realestate)│
                           └──────────────────────┘
```

- **MCP Server** = read-only lookups. Stateless, safe to retry; the LLM picks a tool by intent and filters rows.
- **A2A Servers / Agents** = write workflows (book a showing = INSERT, advance the funnel = UPDATE + activity log, send recommendations = INSERT activity, log a follow-up = INSERT, send email = SMTP).
- **Orchestrator** = the AI brain. WebSocket chat; decides intent, calls MCP tools or hands off to A2A agents, and confirms before any write.

---

## Flogo Apps

### 1. `RealEstateMCPServer.flogo` — MCP Server (port 9592, path `/realestate-mls`)

| Tool | Returns | Table |
|------|---------|-------|
| **GetLeadProfile** | name, email, phone, lead type, funnel stage, budget, preferred area/beds/baths, timeline, source, assigned agent id | `leads` |
| **GetLeadActivity** | engagement history — searches, listing views, saved homes, emails opened, recommendations sent, stage changes | `lead_activity` |
| **SearchListings** | active listings — address, city, price, beds/baths, sqft, type, status, days on market, MLS id, description (LLM filters by city/price/beds) | `listings` |
| **GetAssignedAgent** | the lead's assigned agent — name, email, phone, brokerage, service area | `agents` |
| **GetLeadAppointments** | the lead's showings — listing, date/time, status | `appointments` |
| **GetAreaMarketInsights** | market stats by city/zip — median price, avg days on market, active inventory, $/sqft, YoY change | `area_market_stats` |

Each tool is a flow `#query (SELECT * FROM <table>) → #actreturn`. All read-only.

### 2. `RealEstateA2AServers.flogo` — A2A Servers / Agents (write workflows)

| Agent | Port | Tool | Workflow |
|-------|------|------|----------|
| **book_property_showing** | 9593 | `book_property_showing` | validate lead + listing (`#query`) → **INSERT** into `appointments` (status `Requested`); derives `agent_id` from the lead's assigned agent via `INSERT…SELECT` |
| **update_lead_stage** | 9594 | `update_lead_stage` | **UPDATE** `leads.stage` → **INSERT** a `Stage Change` row into `lead_activity` |
| **send_property_recommendations** | 9595 | `send_property_recommendations` | **INSERT** a `Recommendation Sent` row into `lead_activity` (records the curated listing ids) |
| **log_followup_task** | 9596 | `log_followup_task` | **INSERT** into `follow_up_tasks` (status `Open`); derives `agent_id` from the lead |
| **send_confirmation_email** | 9597 | `send_confirmation_email` | `#sendmail` (Gmail SSL:465) → sends one confirmation/recommendation email |

> All write agents write **directly to PostgreSQL** (or send email) — no separate REST backend, matching the reference customer-facing use cases.

### 3. `RealEstateAIOrchestrator.flogo` — Orchestrator (WebSocket port 9590, path `/realestate`)

`#wsserver → #agentactivity → #wswritedata`. The AI Agent lists the MCP server under `mcpServers`
and all five A2A agents under `remoteAgents`, with a system prompt that:
- identifies the lead by `lead_id` (LEAD-2026-NNNNN), email, or phone;
- routes read questions to the right MCP tool and filters results to the lead's criteria;
- requires **confirmation before any write** (booking, stage change, email, follow-up);
- after a prospect books a showing, **advances the funnel stage** (e.g. `Nurturing → Active`) via `update_lead_stage`;
- sends the confirmation/recommendation email **once, last, only when asked or after a booking**;
- **declines out-of-scope** requests (making price/offer commitments, legal/mortgage advice, editing MLS data, contacting other people's leads).

---

## Database (`realestate`, 7 tables)

| Table | Purpose | Rows (seed) |
|-------|---------|:-----------:|
| `agents` | real estate agents a lead is assigned to | 4 |
| `leads` | master CRM record keyed by `lead_id` (LEAD-2026-NNNNN) — the prospect | 8 |
| `listings` | the property catalog (MLS) — search + detail | 12 |
| `lead_activity` | engagement history; **write target** (recommendations, stage changes) — a few pre-seeded | 10 |
| `appointments` | showings; **write target** (INSERT) — 1 pre-seeded upcoming | 1 |
| `follow_up_tasks` | agent tasks; **write target** (INSERT) — starts empty | 0 |
| `area_market_stats` | market reference by city/zip | 4 |

**Key demo personas (leads)**

| Lead | Name | Highlights |
|------|------|-----------|
| LEAD-2026-00001 | Ava Thompson | Buyer, `Nurturing`, 3bd/2ba < $750k in the flagship city → **full flow: search → book showing → advance to Active → email** |
| LEAD-2026-00002 | Marcus Reed | Buyer, `Active`, **1 pre-seeded upcoming showing** → appointment lookup |
| LEAD-2026-00003 | Priya Nair | Buyer, `New`, came from a Google ad → recommendations + email |
| LEAD-2026-00004 | Daniel Cho | Seller, `Active` → market-insights + agent follow-up |
| LEAD-2026-00005 | Sofia Ramirez | Buyer, `Under Contract` (edge — no new booking) |
| LEAD-2026-00006 | Liam O'Brien | Buyer, `Lost` (edge — re-engagement declined/limited) |
| LEAD-2026-00007 | Grace Kim | Buyer/seller, high budget, luxury criteria |
| LEAD-2026-00008 | Noah Bennett | Buyer, `Nurturing`, **pre-seeded recommendation activity** → activity lookup |

```sql
-- create the database, then load schema + data
psql -U postgres -d realestate -f database.sql
-- reset to a clean, current-dated baseline before each demo run
psql -U postgres -d realestate -f reset_data.sql
```

---

## Prerequisites

- **TIBCO Flogo Enterprise** v2.26.7+ (to import/build the three `.flogo` apps).
- **PostgreSQL** 14+ with a database named `realestate`.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- An **OpenAI API key** (the apps ship configured for `gpt-5.5`; the key is an app property).
- A **Gmail App Password** for the confirmation-email agent (SMTP `smtp.gmail.com:465` SSL).
- The **chatbot UI** in `samples/Agentic_AI/Chatbot`.

---

## Setup & Run

### 1. Database
```sql
CREATE DATABASE realestate;
psql -U postgres -d realestate -f database.sql
psql -U postgres -d realestate -f reset_data.sql
```

### 2. Import & configure the three apps
Import each `.flogo` into Flogo Enterprise and set its app properties:

**RealEstateMCPServer** (start first)
| Property | Value |
|---|---|
| `PostgreSQL.PostgresConn.Host/Port/User/Password` | your PostgreSQL connection |
| `PostgreSQL.PostgresConn.Database_Name` | `realestate` |
| `MCP_SERVER_PORT` | `9592` |

**RealEstateA2AServers** (start second)
| Property | Value |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` | your OpenAI API key |
| `LLM_Model` | `gpt-5.5` (or any model your key can access) |
| `PostgreSQL.PostgresConn.*` | your PostgreSQL connection, DB `realestate` |
| `Email_Username` / `Email_App_Password` / `To_Email` | Gmail sender / app password / recipient mailbox |
| `book_property_showing_PORT` … `send_confirmation_email_PORT` | `9593` … `9597` (one `_PORT` + `_URL` per agent) |

**RealEstateAIOrchestrator** (start last)
| Property | Value |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` | your OpenAI API key |
| `LLM_Model` | `gpt-5.5` (or any model your key can access) |
| `WebSocket_PORT` | `9590` |

> The orchestrator's connections point at `http://localhost:9592/realestate-mls` (MCP) and
> `http://localhost:9593..9597` (A2A). If you change any port, update the matching connection URL.

### 3. Start order
**MCP (9592) → A2A (9593–9597) → Orchestrator (9590).**

### 4. Chatbot UI
```bash
cd samples/Agentic_AI/Chatbot
npm install    # first time only
npm start
```

Open **http://localhost:3000**, then:

1. In the URL box at the top right, enter **`ws://localhost:9590/realestate`**.
2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
3. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
last URL you applied, so a URL from another demo is a common cause.

### 5. Run the demo
Use the prompts in [prompts.md](prompts.md). Reset between runs with `reset_data.sql`.

---

## Demo scenarios (headline walkthroughs)

1. **Profile & criteria:** *"I'm LEAD-2026-00001, what do you have on file for me?"* → GetLeadProfile.
2. **Search listings:** *"Show me 3-bed homes under $750k in <city>."* → SearchListings, filtered.
3. **Market insight:** *"How's the market in <city> right now?"* → GetAreaMarketInsights.
4. **Book a showing (full flow):** *"I'd like to tour <address> this Saturday at 2pm."* → assistant finds the listing, confirms, **books the showing**, then **advances the lead to Active**, and offers a confirmation email.
5. **Recommendations by email:** *"Email me a few homes that match what I want."* → send_property_recommendations (logged) → send_confirmation_email.
6. **Agent follow-up:** *"Have my agent call me tomorrow afternoon."* → GetAssignedAgent → log_followup_task → optional email.
7. **Appointment status:** *"Do I have any showings scheduled?"* (LEAD-2026-00002) → GetLeadAppointments.
8. **Out of scope:** *"Lower the price / give me legal advice / show me another buyer's file."* → politely declined.

---

## Ports

| App | Port(s) | Path |
|-----|---------|------|
| RealEstateMCPServer | 9592 | `/realestate-mls` |
| RealEstateA2AServers | 9593 (book), 9594 (stage), 9595 (recommend), 9596 (follow-up), 9597 (email) | — |
| RealEstateAIOrchestrator | 9590 | `/realestate` |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Orchestrator can't reach tools/agents | Start MCP (9592) and A2A (9593–9597) **before** the orchestrator; confirm the connection `serverUrl`s match the ports. |
| MCP tool returns nothing | Verify the `realestate` DB is loaded and `PostgreSQL.PostgresConn.Database_Name = realestate`. |
| Booking/stage change "fails" | Check the A2A app's PostgreSQL connection; confirm the `lead_id` / `listing_id` exists (run `reset_data.sql`). |
| No email received | Verify `Email_Username` + `Email_App_Password` (Gmail App Password) and `To_Email`; port 465 SSL. |
| Appointment/market dates look stale | Re-run `reset_data.sql` (volatile dates are relative to today). |

---

## Notes & production considerations

- Demo data is fictional (USD / US personas). No real PII.
- For production: put TLS on all endpoints, add bearer-token auth and rate limiting, use an on-prem/data-residency LLM, and replace direct PostgreSQL access with the real CRM/MLS APIs. Add offer/transaction agents only behind compliance review (intentionally out of scope here).

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The three `.flogo` apps were generated with the Flogo Design CLI (all mappings validate clean via
`check-mappings`), but the following are intentionally **not** finalized because they are
environment-, secret-, or host-specific. Configure each before an end-to-end run:

1. **LLM credentials & endpoint.**
   - `AgenticAI.OpenAIConn.API_Key` — set to your real provider key (keep it out of the repo; inject as an app property / secret at deploy).
   - `AgenticAI.OpenAIConn.LLM_Base_URL` — must be a **real endpoint** (`https://api.openai.com/v1`). It is not blank on purpose: an empty value becomes the literal `New_value` and the LLM call fails with `unsupported protocol scheme`.
   - `LLM_Model` — confirm the model name is one your key can access.

2. **PostgreSQL database & credentials.**
   - Create the DB and load `database.sql`, then `reset_data.sql` between demos.
   - Set `PostgreSQL.PostgresConn.Host/Port/Database_Name/User/Password` (DB `realestate`) on **both** the MCP and A2A apps. The `Password` should be a real secret, not committed in plaintext.

3. **Ports must be free & consistent.**
   - MCP `9592`, A2A `9593–9597`, orchestrator WS `9590` must be free on the host.
   - The orchestrator's MCP `serverUrl` (`http://localhost:9592/realestate-mls`) and each A2A `serverUrl` (`http://localhost:9593..9597`) must match the MCP/A2A ports. Change a port → change it in the property **and** the matching orchestrator connection URL.

4. **Email / SMTP** (the `send_confirmation_email` agent).
   - Set `Email_Username`, `Email_App_Password` (an app-specific password, not the account password), and `To_Email`.
   - Confirm outbound SMTP (Gmail `smtp.gmail.com:465`, SSL) is allowed from the host.
   - **Re-enter `Email_App_Password` in the designer's App Properties panel so it is stored as a `SECRET:` value — leave the property type as `string`.** FDA `cap` writes it as plaintext `string`; the `#sendmail` `Password` field binds cleanly only to a secret-valued property (otherwise: *"Type of field 'Password' differs from bound app property (string)"*). Re-typing the value once in App Properties encrypts it to `SECRET:…` and clears the ✗. ⚠️ There is **no** `password` app-property type — setting one makes the designer silently drop the property on save (*"'Password' is bound to app property … which does not exist"*). It builds/runs as a string either way; this only clears designer validation.

5. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://localhost:9590/realestate`. Use the shared chat UI in `samples/Agentic_AI/Chatbot`: enter the URL, **click the ↻ icon next to the URL box**, then **Connect**.

6. **Deploy-time secret injection** (if deploying to TIBCO Platform rather than running the local `.exe`).
   - Provide `API_Key`, DB `Password`, and `Email_App_Password` as platform secrets / app properties at deploy time; do not ship them inside the app.

7. **Flogo Design Assistant (FDA) manual steps** *(Tech-Preview limitations — the apps still build/run; these clear designer validation and cover things FDA cannot configure).*
   - **Sync every trigger.** FDA-built triggers are non-OpenAPI (`tr_mcpserver`, `tr_agent`, `tr_wsserver`); some trigger/flow-input fields (e.g. `toolParams`) don't render and show a red ✗ until you click **"Sync"** once on each trigger.
   - **Validate every connection.** FDA creates connections without validating them. Open each (PostgreSQL, LLM provider, MCP, and the five A2A) and click **Connect / Test** before running.
   - **Set the email password as a secret** (see item 4).

**Quick pre-flight checklist**

- [ ] `realestate` DB created, `database.sql` loaded, row counts sane
- [ ] LLM `API_Key`, `LLM_Base_URL` (real endpoint), `LLM_Model` set on A2A + orchestrator
- [ ] PostgreSQL creds set on MCP + A2A
- [ ] All ports free; orchestrator MCP/A2A URLs match the MCP/A2A ports
- [ ] `Email_App_Password` re-saved as `SECRET:`; SMTP reachable
- [ ] Every trigger **Synced**; every connection **Tested**
- [ ] Start order: MCP (9592) → A2A (9593–9597) → Orchestrator (9590); each logs a clean start
- [ ] WS client connects to `ws://localhost:9590/realestate` and gets a reply
