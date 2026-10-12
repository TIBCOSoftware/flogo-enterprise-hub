# Life & Pensions Member Assistant -- Manual Setup Steps

Step-by-step instructions to deploy and run the Life & Pensions Member Assistant demo end-to-end.

> All environment-specific values (PostgreSQL host/credentials, OpenAI API key, SMTP account) are app properties. Substitute your own values where noted below.

---

## Prerequisites

- TIBCO Flogo Enterprise v2.26.7+
- PostgreSQL 14+ (local or remote)
- OpenAI API key (or an on-premises OpenAI-compatible LLM endpoint) — model `gpt-5.5`
- Gmail account with an App Password (for the email agent; SMTP over SSL, port 465)
- Chatbot UI (from `samples/Agentic_AI/Chatbot/`)

---

## Step 1: Create the PostgreSQL Database

```bash
# Connect to PostgreSQL and create the database
psql -U postgres
CREATE DATABASE life_pensions;
\q

# Load the schema and demo data
psql -U postgres -d life_pensions -f database.sql
```

For live demos with today-relative contribution / claim / pending-policy dates, run the reset script instead (or afterwards):

```bash
psql -U postgres -d life_pensions -f reset_data.sql
```

Verify the data:
```bash
psql -U postgres -d life_pensions -c "SELECT member_id, first_name, last_name, marital_status FROM members ORDER BY member_id;"
psql -U postgres -d life_pensions -c "SELECT account_id, account_type, balance, contribution_rate, employer_match_rate FROM retirement_accounts ORDER BY account_id;"
```

---

## Step 2: Import Flogo Apps

Import all 3 `.flogo` files into TIBCO Flogo Enterprise:

1. **LifePensionsMCPServer.flogo**
2. **LifePensionsA2AServers.flogo**
3. **LifePensionsAIOrchestrator.flogo**

---

## Step 3: Configure App Properties

Values in the tables below are placeholders — substitute your own.

### LifePensionsMCPServer

| Property | Value |
|----------|-------|
| `PostgreSQL.PostgresConn.Host` | `localhost` (or your DB host) |
| `PostgreSQL.PostgresConn.Port` | `5432` |
| `PostgreSQL.PostgresConn.Database_Name` | `life_pensions` |
| `PostgreSQL.PostgresConn.User` | `postgres` |
| `PostgreSQL.PostgresConn.Password` | Your PostgreSQL password |
| `MCP_SERVER_PORT` | `9982` |

### LifePensionsA2AServers

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | Your OpenAI API key |
| `LLM_Model` | `gpt-5.5` (or your preferred / on-prem model) |
| `PostgreSQL.PostgresConn.Host` | `localhost` |
| `PostgreSQL.PostgresConn.Port` | `5432` |
| `PostgreSQL.PostgresConn.Database_Name` | `life_pensions` |
| `PostgreSQL.PostgresConn.User` | `postgres` |
| `PostgreSQL.PostgresConn.Password` | Your PostgreSQL password |
| `Email_Server` | `smtp.gmail.com` |
| `Email_Port` | `465` (SSL) |
| `Email_Username` | Gmail address for SMTP |
| `Email_App_Password` | Gmail App Password |
| `To_Email` | Recipient email for confirmations (e.g. the member's email on file) |
| `UpdateBeneficiary_A2AServer_PORT` | `9983` |
| `ChangeContribution_A2AServer_PORT` | `9984` |
| `FundSwitch_A2AServer_PORT` | `9985` |
| `SubmitClaim_A2AServer_PORT` | `9986` |
| `AdviserCallback_A2AServer_PORT` | `9987` |
| `SendEmail_A2AServer_PORT` | `9988` |

### LifePensionsAIOrchestrator

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | Your OpenAI API key |
| `LLM_Model` | `gpt-5.5` (or your preferred / on-prem model) |
| `Orchestrator_WS_PORT` | `9600` |
| WebSocket Path | `/lifepensions` |

---

## Step 4: Configure Connections (if needed)

The connection URLs default to `localhost`. If running on different hosts, update the MCP and A2A `serverUrl` overrides in Flogo Enterprise.

**Orchestrator app connections:**
- `LifePensionsMCPServer` → `http://<mcp-host>:9982/life-pensions`
- `UpdateBeneficiaryA2AServer` → `http://<a2a-host>:9983`
- `ChangeContributionA2AServer` → `http://<a2a-host>:9984`
- `FundSwitchA2AServer` → `http://<a2a-host>:9985`
- `SubmitClaimA2AServer` → `http://<a2a-host>:9986`
- `AdviserCallbackA2AServer` → `http://<a2a-host>:9987`
- `SendEmailA2AServer` → `http://<a2a-host>:9988`

**A2A Servers app connections:**
- `PostgresConn` → Update host/port/database if not localhost
- A2A Server URLs in properties → Update if not localhost

---

## Step 5: Start Apps (in order)

Start the apps in this exact order:

1. **LifePensionsMCPServer** (port 9982 must be ready first)
2. **LifePensionsA2AServers** (ports 9983–9988)
3. **LifePensionsAIOrchestrator** (port 9600 — needs MCP and A2A to be running)

---

## Step 6: Connect the Chatbot UI

```bash
cd samples/Agentic_AI/Chatbot
npm install
npm start
```

Open http://localhost:3000 in your browser. Enter the WebSocket URL and click **Connect**:

```
ws://localhost:9600/lifepensions
```

---

## Step 7: Run the Demo

Use the prompts from `prompts.md`. The recommended demo flow follows the flagship persona, James Carter (`MBR-100001`):

1. **Pension pot** -- "What's my 401(k) balance? MBR-100001." (MCP: GetRetirementAccounts — flags 3% vs 6% match)
2. **Investments** -- "How is my 401(k) invested? MBR-100001." (MCP: GetHoldings — flags HIGH-risk fund at 34.8%)
3. **Change contribution** -- "Raise my contribution to 6%." → change_contribution_agent (`CON-2026-XXXX`)
4. **Fund switch** -- "Move my Aggressive Growth holding into Target Retirement 2045." → fund_switch_agent (`SWT-2026-XXXX`)
5. **Update beneficiary** -- "My Term Life policy names my ex-wife — change it to my daughter Sarah Carter." → update_beneficiary_agent (`BEN-2026-XXXX`)
6. **Submit a claim** -- "File an income protection claim on POL-2026-1003." → submit_claim_agent (`CLM-2026-XXX`)
7. **Adviser callback** -- "Book a retirement-planning call for tomorrow afternoon." → adviser_callback_agent (`CBK-2026-XXXX`)
8. **Email confirmation** -- "Send me a confirmation email." → send_confirmation_email
9. **Edge cases** -- claim on Susan Miller's Lapsed policy (`MBR-100004`) or Patricia Wilson's Pending policy (`MBR-100010`) — the agent should decline. See `prompts.md` §13.

---

## Step 8: Reset Demo Data

After a demo run (especially after changing a contribution, switching funds, updating a beneficiary, filing a claim, or booking a callback), reset the data:

```bash
psql -U postgres -d life_pensions -f reset_data.sql
```

This restores all tables to the seeded state, clears agent-written rows from `adviser_callbacks` and `fund_switches` (and any new beneficiaries/claims/contributions added during the demo), and refreshes contribution / claim / pending-policy dates relative to today.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| MCP Server not connecting | Verify port 9982 is open and the MCP app is running |
| A2A agents not responding | Check ports 9983–9988 are open and the A2A app is running |
| PostgreSQL connection failed | Verify database `life_pensions` exists and credentials are correct |
| Email not sending | Verify the Gmail App Password is correct (not the regular password) and SMTP is set to `smtp.gmail.com:465` (SSL). Enable 2FA on the Google account first. |
| Agent gives stale/wrong data | Run `reset_data.sql` to restore demo data |
| WebSocket disconnects | Ensure the Orchestrator app is running on port 9600 |
| Agent can't find a member | Make sure the `member_id` matches one in the `members` table (format `MBR-1000NN`), or supply the member's name / email |
| Write action rejected | Confirm the target policy is `Active` — claims on `Lapsed` / `Pending` policies are intentionally declined |

---

## Gmail App Password Setup

To enable the email agent:

1. Go to https://myaccount.google.com/security
2. Enable 2-Step Verification
3. Go to https://myaccount.google.com/apppasswords
4. Generate an App Password for "Mail"
5. Use the 16-character password as `Email_App_Password` (SMTP host `smtp.gmail.com`, port `465`, SSL)
