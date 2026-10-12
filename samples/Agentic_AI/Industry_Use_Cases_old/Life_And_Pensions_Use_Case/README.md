# Life & Pensions Member Assistant Use Case

An AI-powered member self-service assistant for a mutual life, pensions & investments provider, built on TIBCO Flogo Enterprise. Members ask natural-language questions ("What's my 401(k) balance?", "How am I invested?", "Update my beneficiary", "File a claim") over a WebSocket streaming chat. The system uses a 3-tier agentic architecture — an AI Orchestrator, an MCP Server for read-only book-of-record lookups, and A2A Servers / Agents for write workflows — all communicating via standard protocols (MCP, A2A, WebSocket).

> **Demo dataset:** a US mutual life, pensions & investments provider — currency **USD** (US Dollar). Members hold protection policies (Life / Critical Illness / Income Protection / Investment), 401(k) and IRA retirement accounts, fund holdings, contribution history, nominated beneficiaries and claims. The flagship persona (James Carter) is engineered so every write workflow has a clear, real reason to fire: an outdated beneficiary, an under-matched 401(k) contribution, an over-weight high-risk fund holding, and a claimable policy with no existing claim.

---

## Architecture

```
                    ┌─────────────────────────┐
                    │     Chatbot UI          │
                    │  (WebSocket Client)     │
                    └───────┬─────────────────┘
                            │ WebSocket
                            │ ws://localhost:9600/lifepensions
                            ▼
               ┌────────────────────────────────┐
               │  Life & Pensions               │
               │  AI Orchestrator               │
               │  (LifePensionsAIOrchestrator)  │
               │  Port 9600 (WebSocket)         │
               │  LLM: OpenAI gpt-5.5           │
               └───────┬───────────┬────────────┘
                       │           │
          MCP (HTTP)   │           │  A2A Protocol
                       ▼           ▼
    ┌──────────────────────┐   ┌──────────────────────────────────────┐
    │  Life & Pensions     │   │  Life & Pensions                     │
    │  MCP Server          │   │  A2A Servers / Agents                │
    │  Port 9982           │   │                                      │
    │  /life-pensions      │   │  update_beneficiary_agent     :9983  │
    │                      │   │  change_contribution_agent    :9984  │
    │  Tools (read-only):  │   │  fund_switch_agent            :9985  │
    │  - GetMemberProfile  │   │  submit_claim_agent           :9986  │
    │  - GetPolicies       │   │  adviser_callback_agent       :9987  │
    │  - GetRetirementAccts│   │  send_confirmation_email      :9988  │
    │  - GetFunds          │   │                                      │
    │  - GetHoldings       │   │  Uses PostgreSQL for                 │
    │  - GetContributions  │   │  data validation & writes            │
    │  - GetBeneficiaries  │   │  + Gmail SMTP for email              │
    │  - GetClaims         │   │                                      │
    └──────────┬───────────┘   └──────────────┬───────────────────────┘
               │                              │
               └──────────────┬───────────────┘
                              ▼
               ┌────────────────────────────┐
               │  PostgreSQL Database       │
               │  Database: life_pensions   │
               │  10 Tables                 │
               └────────────────────────────┘
```

- **MCP Server** — read-only lookups. Stateless and safe to retry; the LLM picks a tool
  from its description and filters the returned rows by `member_id` / name / email.
- **A2A Servers / Agents** — action workflows. Each agent has its own trigger, port, guardrails and
  system prompt. Five agents **write directly to PostgreSQL**; the sixth sends email via SMTP.
- **AI Orchestrator** — the AI brain. Exposes the WebSocket chat endpoint; the LLM classifies
  intent and either calls an MCP tool (lookup) or hands off to an A2A Agent (write).

---

## Flogo Apps

| App | File | Trigger | Port (property) + path |
|-----|------|---------|------------------------|
| MCP Server | `LifePensionsMCPServer.flogo` | `#mcpserver` | `MCP_SERVER_PORT` = **9982**, path `/life-pensions` |
| A2A Servers / Agents | `LifePensionsA2AServers.flogo` | `#agent` ×6 | see agent table below (**9983–9988**) |
| AI Orchestrator | `LifePensionsAIOrchestrator.flogo` | `#wsserver` | **9600** (set on the trigger), path `/lifepensions` |

### 1. `LifePensionsMCPServer.flogo` — MCP Server (Port 9982)

Exposes 8 read-only lookup tools via the Model Context Protocol over Streamable HTTP (endpoint `/life-pensions`). Each tool queries the PostgreSQL `life_pensions` database and returns the full result set as a string; the LLM filters by `member_id` / name / email.

| Tool | Description | SQL |
|------|-------------|-----|
| **GetMemberProfile** | Member profile: name, email, phone, DOB, address, marital status, member since | `SELECT * FROM members` |
| **GetPolicies** | Protection & investment policies: product type, sum assured, premium, status, renewal | `SELECT * FROM policies` |
| **GetRetirementAccounts** | 401(k) / IRA balances, contribution rate, employer match, YTD & limit, vested balance | `SELECT * FROM retirement_accounts` |
| **GetFunds** | Fund catalog: category, risk level, returns (YTD / 1yr / 3yr), expense ratio, NAV | `SELECT * FROM funds` |
| **GetHoldings** | Per-account fund allocation with fund details (units, value, allocation %) | `holdings JOIN funds` |
| **GetContributions** | Contribution & premium payment history (Employee / Employer / Premium / Rollover) | `SELECT * FROM contributions` |
| **GetBeneficiaries** | Nominated beneficiaries per policy with policy context | `beneficiaries JOIN policies` |
| **GetClaims** | Protection claims with type, amount, status and last update | `SELECT * FROM claims` |

### 2. `LifePensionsA2AServers.flogo` — A2A Servers / Agents (Ports 9983–9988)

Six A2A Agents that handle write workflows. Each agent has its own LLM, system prompt, and tool handler. The first five **write directly to PostgreSQL** (validate with a `SELECT`, then INSERT); the sixth sends a confirmation email via SMTP.

| Agent | Port (property) | Action | Writes to | Generated ID |
|-------|-----------------|--------|-----------|--------------|
| **update_beneficiary_agent** | `UpdateBeneficiary_A2AServer_PORT` = **9983** | Replaces the nominated beneficiary on a policy (e.g. swaps out an ex-spouse). | INSERT `beneficiaries` | `BEN-2026-XXXX` |
| **change_contribution_agent** | `ChangeContribution_A2AServer_PORT` = **9984** | Changes a 401(k) contribution rate (e.g. raising it to capture the full employer match) and logs the change. | INSERT `contributions` | `CON-2026-XXXX` |
| **fund_switch_agent** | `FundSwitch_A2AServer_PORT` = **9985** | Moves value out of one fund into another within a retirement account. | INSERT `fund_switches` | `SWT-2026-XXXX` |
| **submit_claim_agent** | `SubmitClaim_A2AServer_PORT` = **9986** | Files a protection claim against an eligible active policy (status Submitted). | INSERT `claims` | `CLM-2026-XXX` |
| **adviser_callback_agent** | `AdviserCallback_A2AServer_PORT` = **9987** | Books a callback with a financial adviser on a chosen topic and preferred time. | INSERT `adviser_callbacks` | `CBK-2026-XXXX` |
| **send_confirmation_email** | `SendEmail_A2AServer_PORT` = **9988** | Sends a confirmation email (contribution change / fund switch / claim filed / callback booked). Invoked once, after a write action, when the user requests it. | SMTP (`smtp.gmail.com:465`, SSL) | — |

### 3. `LifePensionsAIOrchestrator.flogo` — AI Orchestrator (Port 9600)

The main orchestration app. Exposes a WebSocket endpoint for natural-language chat. An AI Agent activity classifies intent and routes to either MCP tools (data lookups) or A2A agents (write workflows).

| Setting | Value |
|---------|-------|
| WebSocket Path | `/lifepensions` |
| LLM | OpenAI gpt-5.5 |
| MCP Server | `http://localhost:9982/life-pensions` |
| A2A Servers / Agents | update_beneficiary (9983), change_contribution (9984), fund_switch (9985), submit_claim (9986), adviser_callback (9987), email (9988) |

---

## Database

10 tables in the PostgreSQL `life_pensions` database:

| Table | Purpose | Records |
|-------|---------|---------|
| `members` | Member master records (member_id = subscriber id) | 10 members |
| `policies` | Protection & investment products per member | 17 policies |
| `retirement_accounts` | 401(k) / IRA balances (writeable: contribution rate) | 8 accounts |
| `funds` | Shared fund catalog | 10 funds |
| `holdings` | Per-account fund allocation (writeable: fund switch) | 15 holdings |
| `contributions` | Contribution / premium history (writeable: change) | 16 records |
| `beneficiaries` | Nominated beneficiaries per policy (writeable: update) | 10 records |
| `claims` | Protection claims (writeable: submit) | 4 seeded |
| `adviser_callbacks` | Adviser callback requests (written by agent) | starts empty |
| `fund_switches` | Fund switch requests (written by agent) | starts empty |

```bash
# Initialize schema and demo data
psql -h <host> -p <port> -U <user> -d life_pensions -f database.sql

# Reset with today-relative contribution/claim/pending-policy dates (between demo runs)
psql -h <host> -p <port> -U <user> -d life_pensions -f reset_data.sql
```

All volatile dates (contributions, claims, the pending policy) are stored **`CURRENT_DATE`-relative**
in `reset_data.sql`, so the demo always looks current. All money is **USD**.

---

## Prerequisites

- **PostgreSQL 14+** (local or remote); a database named **`life_pensions`** created for this demo.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- **TIBCO Flogo Enterprise** (v2.26.7+) to import the three `.flogo` apps into the designer — or the
  `flogobuild` CLI if you prefer to build `.exe`s.
- An **LLM provider** key (OpenAI-compatible). `LLM_Base_URL` must be a **real endpoint**, e.g.
  `https://api.openai.com/v1`; default `LLM_Model` is `gpt-5.5` (use any model your key can access,
  including an on-prem OpenAI-compatible endpoint).
- **SMTP access** for the `send_confirmation_email` agent (Gmail: `smtp.gmail.com:465`, SSL, with a
  Gmail **App Password** — not the account password; see the manual-config section).
- A **chatbot / WebSocket client** — the reference UI is under `samples/Agentic_AI/Chatbot`.

> Environment-specific values (PostgreSQL host/credentials, OpenAI API key, SMTP account) are app
> properties — set the app properties listed below with your own values; never commit real secrets.

---

## Setup & Run

### 1. Load the database

```bash
# create the database, then load schema + demo data
psql -h <host> -p <port> -U <user> -c "CREATE DATABASE life_pensions;"
psql -h <host> -p <port> -U <user> -d life_pensions -f database.sql

# between demo runs (today-relative dates; clears agent-written rows):
psql -h <host> -p <port> -U <user> -d life_pensions -f reset_data.sql
```

Verify:
```bash
psql -h <host> -p <port> -U <user> -d life_pensions -c "SELECT member_id, first_name, last_name, marital_status FROM members ORDER BY member_id;"
```

### 2. Import (or build) the three apps

Import all three `.flogo` files into TIBCO Flogo Enterprise (or build each to an `.exe` with
`flogobuild`):

1. `LifePensionsMCPServer.flogo`
2. `LifePensionsA2AServers.flogo`
3. `LifePensionsAIOrchestrator.flogo`

### 3. Set app properties

Substitute your own values (placeholders shown).

**LifePensionsMCPServer**

| Property | Value |
|----------|-------|
| `PostgreSQL.PostgresConn.Host` | `<host>` (e.g. `localhost`) |
| `PostgreSQL.PostgresConn.Port` | `5432` |
| `PostgreSQL.PostgresConn.Database_Name` | `life_pensions` |
| `PostgreSQL.PostgresConn.User` | `<user>` |
| `PostgreSQL.PostgresConn.Password` | `<db-password>` (`SECRET:` app property) |
| `MCP_SERVER_PORT` | `9982` |

**LifePensionsA2AServers**

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | `<your OpenAI key>` (`SECRET:`) |
| `AgenticAI.OpenAIConn.LLM_Base_URL` | a **real endpoint** (e.g. `https://api.openai.com/v1`) |
| `LLM_Model` | `gpt-5.5` (or your preferred / on-prem model) |
| `PostgreSQL.PostgresConn.*` | Host / Port / Database_Name / User / Password (as above) |
| `Email_Server` | `smtp.gmail.com` |
| `Email_Port` | `465` (SSL) |
| `Email_Username` | Gmail address for SMTP |
| `Email_App_Password` | Gmail **App Password** (`SECRET:`) |
| `To_Email` | Recipient for confirmations (e.g. the member's email on file) |
| `UpdateBeneficiary_A2AServer_PORT` | `9983` |
| `ChangeContribution_A2AServer_PORT` | `9984` |
| `FundSwitch_A2AServer_PORT` | `9985` |
| `SubmitClaim_A2AServer_PORT` | `9986` |
| `AdviserCallback_A2AServer_PORT` | `9987` |
| `SendEmail_A2AServer_PORT` | `9988` |

**LifePensionsAIOrchestrator**

| Property / setting | Value |
|--------------------|-------|
| `AgenticAI.OpenAIConn.API_Key` | `<your OpenAI key>` (`SECRET:`) |
| `AgenticAI.OpenAIConn.LLM_Base_URL` | a **real endpoint** (e.g. `https://api.openai.com/v1`) |
| `LLM_Model` | `gpt-5.5` |
| WebSocket port | `9600` (set directly on the `#wsserver` trigger — there is no `_PORT` property) |
| WebSocket path | `/lifepensions` |

The orchestrator reaches the other apps via connection `serverUrl`s (defaults shown). If you run on
other hosts/ports, update them so they match the MCP/A2A ports:

- MCP → `http://<mcp-host>:9982/life-pensions`
- A2A → `http://<a2a-host>:9983` … `:9988` (one per agent)

### 4. Start the apps (in order)

1. **LifePensionsMCPServer** (port 9982 must be ready first)
2. **LifePensionsA2AServers** (ports 9983–9988)
3. **LifePensionsAIOrchestrator** (port 9600 — needs MCP and A2A running)

### 5. Connect the chatbot UI

```bash
cd samples/Agentic_AI/Chatbot
npm install    # first time only
npm start
```

Open **http://localhost:3000**, then:

1. In the URL box at the top right, enter **`ws://localhost:9600/lifepensions`**.
2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
3. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
last URL you applied, so a URL from another demo is a common cause.

Then drive the demo from `prompts.md`. After a run that changed data, re-run `reset_data.sql`.

---

## Demo Scenarios

The demo is built around a flagship persona — **James Carter (member_id `MBR-100001`, james.carter@example.com, San Francisco CA, Divorced)** — whose data is engineered so each of the six capabilities has a real trigger. See **`prompts.md`** for the full, copy-pasteable prompt list (organized by scenario).

### Scenario 1: "What's my pension pot?" (MCP only)

James Carter asks about his retirement savings. The agent looks up his accounts via `GetRetirementAccounts` and reports his **401(k) (RET-5001) balance of USD 181,685** and **Roth IRA (RET-5002) of USD 45,300** — and flags that he is contributing only **3%** while his employer matches up to **6%**, so he is leaving free money on the table.

```
You:   What's my 401(k) balance? My member ID is MBR-100001.
Agent: Your 401(k) (RET-5001) balance is USD 181,685 and your Roth IRA (RET-5002)
       is USD 45,300. Note: you're contributing 3%, but your employer matches up
       to 6% — raising your rate to 6% would capture the full match.
```

### Scenario 2: "How am I invested?" (MCP only)

James reviews his 401(k) allocation. The agent uses `GetHoldings` and highlights that **34.8% sits in the Aggressive Growth Equity Fund (FND-001, HIGH risk)**, which is aggressive for someone approaching retirement.

```
You:   How is my 401(k) invested? MBR-100001.
Agent: Your RET-5001 holdings are: Aggressive Growth Equity Fund (HIGH risk) 34.8%,
       S&P 500 Index Fund 38.9%, Total Bond Market Fund 26.3%. A third of your pot
       is in a HIGH-risk fund — worth reviewing as you near retirement.
```

### Scenario 3: Increase contribution to capture full match (MCP + A2A change_contribution)

James raises his 401(k) contribution from **3% to 6%** to capture the full employer match. The agent confirms, then fires `change_contribution_agent` (→ `CON-2026-XXXX`) and can email a confirmation.

```
You:   Increase my 401(k) contribution to 6% so I get the full employer match. MBR-100001.
Agent: Done — your contribution rate on RET-5001 is now 6% (CON-2026-XXXX), which
       captures your full 6% employer match. Would you like an email confirmation?
```

### Scenario 4: Switch out of the high-risk fund (MCP + A2A fund_switch)

James de-risks by moving out of the HIGH-risk **Aggressive Growth Equity Fund (FND-001)** into **Target Retirement 2045 (FND-005)** (or Total Bond, FND-003). The agent fires `fund_switch_agent` (→ `SWT-2026-XXXX`).

```
You:   Move my Aggressive Growth holding into the Target Retirement 2045 fund. MBR-100001.
Agent: Switch requested: FND-001 (Aggressive Growth) → FND-005 (Target Retirement 2045)
       in RET-5001 (SWT-2026-XXXX), status Requested.
```

### Scenario 5: Update an outdated beneficiary (MCP + A2A update_beneficiary)

James is divorced but his Term Life (POL-2026-1001) and Critical Illness (POL-2026-1002) policies still name his ex-spouse **Emily Carter**. The agent detects this via `GetBeneficiaries` and, on confirmation, replaces her via `update_beneficiary_agent` (→ `BEN-2026-XXXX`).

```
You:   My Term Life policy still lists my ex-wife. Change the beneficiary to my daughter, Sarah Carter. MBR-100001.
Agent: Your Term Life policy (POL-2026-1001) currently names Emily Carter (Spouse, 100%).
       I've replaced her with Sarah Carter (Child, 100%) — new record BEN-2026-XXXX.
```

### Scenario 6: File an Income Protection claim (MCP + A2A submit_claim)

James has an active Income Shield Plan (POL-2026-1003, IncomeProtection, USD 4,000/mo) and **no existing claim**, so he can file one. The agent files it via `submit_claim_agent` (→ `CLM-2026-XXX`) and can email a confirmation.

```
You:   I've been signed off work and need to claim on my income protection policy. MBR-100001.
Agent: I've submitted an Income Protection claim on POL-2026-1003 (CLM-2026-XXX),
       monthly benefit USD 4,000, status Submitted. Shall I email you the confirmation?
```

### Scenario 7: Book an adviser callback (A2A adviser_callback)

James requests a retirement-planning call. The agent books it via `adviser_callback_agent` (→ `CBK-2026-XXXX`).

```
You:   Can a financial adviser call me about my retirement plan? Tomorrow afternoon works. MBR-100001.
Agent: Booked — a retirement-planning callback is scheduled for tomorrow afternoon
       (CBK-2026-XXXX). An adviser will call you on +1-415-555-0101.
```

### Scenario 8: Other personas (read + edge cases)

- **Robert Johnson** (`MBR-100005`) — near retirement, large **401(k) (RET-5005) of USD 512,300**; good "big pot" read demo.
- **David Chen** (`MBR-100003`) — has an Income Protection claim **UnderReview** (`CLM-2026-001`); claim-status lookup.
- **Susan Miller** (`MBR-100004`) — her only policy (POL-2026-1008) is **Lapsed**; the agent should decline a claim on it (edge case).
- **Patricia Wilson** (`MBR-100010`) — her Critical Illness policy (POL-2026-1017) is **Pending** underwriting (edge case).

---

## Sample Data Summary

### Members

| Member ID | Name | Email | City, State | Marital | Demo role |
|-----------|------|-------|-------------|---------|-----------|
| MBR-100001 | James Carter | james.carter@example.com | San Francisco, CA | Divorced | **Flagship** — all six workflows |
| MBR-100002 | Maria Gonzalez | maria.gonzalez@example.com | Chicago, IL | Married | Fully matched 401(k) (6%) |
| MBR-100003 | David Chen | david.chen@example.com | Seattle, WA | Married | Income Protection claim UnderReview |
| MBR-100004 | Susan Miller | susan.miller@example.com | Boston, MA | Single | Lapsed policy (edge case) |
| MBR-100005 | Robert Johnson | robert.johnson@example.com | Denver, CO | Married | Near retirement, USD 512k 401(k) |
| MBR-100006 | Linda Williams | linda.williams@example.com | Austin, TX | Widowed | Denied claim; Trust beneficiary |
| MBR-100007 | Michael Brown | michael.brown@example.com | Atlanta, GA | Single | Roth IRA, 100% in high-risk fund |
| MBR-100008 | Jennifer Davis | jennifer.davis@example.com | Miami, FL | Married | Paid claim; Investment plan |
| MBR-100009 | William Martinez | william.martinez@example.com | Phoenix, AZ | Married | Whole Life; split beneficiaries |
| MBR-100010 | Patricia Wilson | patricia.wilson@example.com | Portland, OR | Single | Pending policy (edge case) |

### Flagship Profile — James Carter (MBR-100001)

**Policies (all Active, no existing claim):**

| Policy | Product | Type | Sum assured / benefit | Premium |
|--------|---------|------|-----------------------|---------|
| POL-2026-1001 | 20-Year Term Life | Life | USD 500,000 | USD 45.00/mo |
| POL-2026-1002 | Critical Illness Protect | CriticalIllness | USD 100,000 | USD 28.50/mo |
| POL-2026-1003 | Income Shield Plan | IncomeProtection | USD 4,000/mo benefit | USD 32.00/mo |

**Retirement accounts:**

| Account | Type | Balance | Contribution | Employer match | Note |
|---------|------|---------|--------------|----------------|------|
| RET-5001 | 401(k) | USD 181,685 | 3% | up to 6% | **Under-matched** — capture the extra 3% |
| RET-5002 | Roth IRA | USD 45,300 | — | — | — |

**RET-5001 holdings:**

| Fund | Risk | Value (USD) | Allocation |
|------|------|-------------|------------|
| FND-001 Aggressive Growth Equity Fund | HIGH | 63,225 | 34.80% |
| FND-002 S&P 500 Index Fund | Medium | 70,720 | 38.92% |
| FND-003 Total Bond Market Fund | Low | 47,740 | 26.28% |

**Beneficiaries (outdated — names ex-spouse):**

| Policy | Beneficiary | Relationship | Share |
|--------|-------------|--------------|-------|
| POL-2026-1001 | Emily Carter *(ex-spouse)* | Spouse | 100% |
| POL-2026-1002 | Emily Carter *(ex-spouse)* | Spouse | 100% |

---

## Ports

| Component | Property | Port | Protocol / path |
|-----------|----------|------|-----------------|
| LifePensionsMCPServer | `MCP_SERVER_PORT` | 9982 | HTTP (MCP), `/life-pensions` |
| A2A — update_beneficiary | `UpdateBeneficiary_A2AServer_PORT` | 9983 | HTTP (A2A) |
| A2A — change_contribution | `ChangeContribution_A2AServer_PORT` | 9984 | HTTP (A2A) |
| A2A — fund_switch | `FundSwitch_A2AServer_PORT` | 9985 | HTTP (A2A) |
| A2A — submit_claim | `SubmitClaim_A2AServer_PORT` | 9986 | HTTP (A2A) |
| A2A — adviser_callback | `AdviserCallback_A2AServer_PORT` | 9987 | HTTP (A2A) |
| A2A — send_confirmation_email | `SendEmail_A2AServer_PORT` | 9988 | HTTP (A2A) |
| LifePensionsAIOrchestrator | (set on `#wsserver` trigger) | 9600 | WebSocket, `/lifepensions` |

**Start order:** MCP Server → A2A Servers / Agents → Orchestrator, then connect the chatbot UI.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| LLM call fails with `unsupported protocol scheme` / posts to `/New_value/...` | `LLM_Base_URL` is blank — set it to a **real endpoint** (e.g. `https://api.openai.com/v1`). An empty value becomes the literal `New_value`. |
| MCP runtime panics `missing input schema` (or a tool returns nothing) | A tool handler is missing its input/output schema — **Sync** the `#mcpserver` trigger once to regenerate the design-time schemas. |
| A2A write fails with `missing substitution for: <name>` | The runtime `input.mapping.parameters` for that agent is missing the param — patch it, then **Sync** the agent's trigger so the design-time `toolParams` schema regenerates. |
| Orchestrator error `Configured connection is not a WebSocket Connection` | The orchestrator's `wsconnection` / `content` fields were coerced to `object`; they must stay type **`any`**. |
| Email field warns "type … differs from bound app property" / email won't send | Re-enter `Email_App_Password` in App Properties so it is stored as a `SECRET:` (keep the property type `string`). Use a Gmail **App Password**, not the account password, with `smtp.gmail.com:465` (SSL); enable 2FA first. |
| Orchestrator can't reach a tool/agent | The MCP/A2A `serverUrl`s must match the MCP/A2A ports (9982 and 9983–9988). If you change a port, change it in the app property **and** the orchestrator connection URL. |
| MCP Server / A2A agents not responding | Verify ports 9982 and 9983–9988 are free and the apps are running, in order. |
| PostgreSQL connection failed | Verify the `life_pensions` database exists and Host/Port/User/Password are correct. |
| Agent gives stale / wrong data | Run `reset_data.sql` to restore the seeded demo state. |
| Agent can't find a member | Supply a `member_id` that exists (`MBR-1000NN`), or the member's name / email. |
| Write action rejected | Confirm the target policy is `Active` — claims on `Lapsed` / `Pending` policies are intentionally declined. |

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The committed `.flogo` files carry placeholders / reference-app values for every secret; replace them
with your own before an end-to-end run. **Never commit real secrets.**

1. **LLM credentials & endpoint.**
   - `AgenticAI.OpenAIConn.API_Key` — set your real provider key (a `SECRET:` app property; keep it out of the repo).
   - `AgenticAI.OpenAIConn.LLM_Base_URL` — a **real endpoint** (`https://api.openai.com/v1`). An empty
     value becomes the literal `New_value` and the LLM call fails with `unsupported protocol scheme`.
   - `LLM_Model` — confirm the model name (default `gpt-5.5`) is one your key can access.

2. **PostgreSQL database & credentials.**
   - Create the **`life_pensions`** database and load `database.sql`; run `reset_data.sql` to reset between demos.
   - Set the PostgreSQL connection `Host` / `Port` / `Database_Name` / `User` / `Password` to your
     instance. `Password` is a `SECRET:` app property — set the real secret in App Properties, not in plaintext.

3. **Ports must be free & consistent.**
   - MCP **9982**, update-beneficiary **9983**, change-contribution **9984**, fund-switch **9985**,
     submit-claim **9986**, adviser-callback **9987**, email **9988**, and the orchestrator WebSocket **9600**
     must all be free on the host.
   - The orchestrator's MCP `serverUrl` and each A2A `serverUrl` must match those ports.

4. **Email / SMTP** (the `send_confirmation_email` agent).
   - Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, not the account password),
     and the recipient `To_Email` property.
   - Confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed from the host/network.
   - **Re-enter `Email_App_Password` in App Properties so it is stored as a `SECRET:` value** (leave the
     property type `string` — there is no `password` app-property type).
   - Gmail App Password: enable 2-Step Verification at `myaccount.google.com/security`, then generate a
     "Mail" app password at `myaccount.google.com/apppasswords`.

5. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://<host>:9600/lifepensions`. Point your chat UI (or a WS test client)
     at it — the reference UI is under `samples/Agentic_AI/Chatbot`. See `prompts.md` for ready-to-paste prompts.

6. **Flogo designer manual steps** (clear design-time validation).
   - **Sync every trigger** (MCP, each A2A agent, the WS server) once, so `toolParams` and WS input
     mappings render without a red ✗.
   - **Validate every connection** (PostgreSQL, LLM provider, MCP server config, all six A2A server
     connections) — click **Connect / Test** before running.
   - **Set the email password as a secret** — see item 4.

**Quick pre-flight checklist**

- [ ] DB `life_pensions` created, `database.sql` loaded, row counts sane (members 10, policies 17, retirement_accounts 8, funds 10, holdings 15, contributions 16, beneficiaries 10, claims 4)
- [ ] LLM `API_Key`, `LLM_Base_URL` (real endpoint), `LLM_Model` set
- [ ] PostgreSQL `Password` set; MCP tool `SELECT`s and A2A write SQL run cleanly
- [ ] All 8 ports free (9982, 9983–9988, 9600); orchestrator MCP/A2A URLs match the MCP/A2A ports
- [ ] `Email_App_Password` re-entered as a `SECRET:` (type stays `string`); SMTP reachable
- [ ] Every trigger Synced; every connection validated in the designer
- [ ] Start order: MCP → A2A → Orchestrator; each logs a clean start
- [ ] WebSocket client connects to `ws://<host>:9600/lifepensions` and gets a reply

---

## Supporting Files

| File | Description |
|------|-------------|
| `database.sql` | PostgreSQL schema with 10 tables and demo data |
| `reset_data.sql` | Data reset script (today-relative dates; clears agent-written rows) |
| `prompts.md` | Demo prompts organized by scenario |
| `manual-steps.md` | Step-by-step setup instructions (now folded into the **Setup & Run** and **Manual configuration** sections of this README; kept for reference) |

---

## Security & Production Notes

This is the Phase-1 working demo. For production the design calls for: TLS on all endpoints (WebSocket + MCP + A2A), Bearer-token auth on the MCP Server, strong member authentication before any write action, API-gateway rate limiting, an on-premises LLM for data residency, and swapping the PostgreSQL-backed tools for real policy administration, pensions/investment platform and claims APIs.
