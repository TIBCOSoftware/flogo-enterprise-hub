# Telecom Invoice Chatbot -- Manual Setup Steps

Step-by-step instructions to deploy and run the Telecom Invoice Chatbot demo end-to-end.

---

## Prerequisites

- TIBCO Flogo Enterprise v2.26.5+
- PostgreSQL 14+ (local or remote)
- OpenAI API key (or an on-premises OpenAI-compatible LLM endpoint)
- Gmail account with App Password (for the email agent)
- Chatbot UI (from `demos/Agentic_AI/Chatbot/`)

---

## Step 1: Create the PostgreSQL Database

```bash
# Connect to PostgreSQL and create the database
psql -U postgres
CREATE DATABASE telecom;
\q

# Load the schema and demo data
psql -U postgres -d telecom -f database.sql
```

For live demos with today-relative due/payment/dispute dates, run the reset script instead (or afterwards):

```bash
psql -U postgres -d telecom -f reset_data.sql
```

Verify the data:
```bash
psql -U postgres -d telecom -c "SELECT customer_id, mobile_number, first_name, segment FROM customers ORDER BY customer_id;"
psql -U postgres -d telecom -c "SELECT invoice_id, total_amount, status FROM invoices ORDER BY invoice_id;"
```

---

## Step 2: Import Flogo Apps

Import all 3 `.flogo` files into TIBCO Flogo Enterprise:

1. **TelecomInvoiceMCPServer.flogo**
2. **TelecomInvoiceA2AServers.flogo**
3. **TelecomInvoiceAIOrchestrator.flogo**

---

## Step 3: Configure App Properties

### TelecomInvoiceMCPServer

| Property | Value |
|----------|-------|
| `PostgreSQL.PostgresConn.Host` | `localhost` (or your DB host) |
| `PostgreSQL.PostgresConn.Port` | `5432` |
| `PostgreSQL.PostgresConn.Database_Name` | `telecom` |
| `PostgreSQL.PostgresConn.User` | `postgres` |
| `PostgreSQL.PostgresConn.Password` | Your PostgreSQL password |
| `MCP_SERVER_PORT` | `9882` |

### TelecomInvoiceA2AServers

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | Your OpenAI API key |
| `LLM_Model` | `gpt-4o` (or your preferred / on-prem model) |
| `PostgreSQL.PostgresConn.Host` | `localhost` |
| `PostgreSQL.PostgresConn.Database_Name` | `telecom` |
| `PostgreSQL.PostgresConn.User` | `postgres` |
| `PostgreSQL.PostgresConn.Password` | Your PostgreSQL password |
| `To_Email` | Recipient email for confirmations |
| `Email_Username` | Gmail address for SMTP |
| `Email_App_Password` | Gmail App Password |
| `BillingDispute_A2AServer_PORT` | `9883` |
| `Recharge_A2AServer_PORT` | `9884` |
| `SendEmail_A2AServer_PORT` | `9885` |

### TelecomInvoiceAIOrchestrator

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | Your OpenAI API key |
| `LLM_Model` | `gpt-4o` (or your preferred / on-prem model) |

---

## Step 4: Configure Connections (if needed)

The connection URLs default to `localhost`. If running on different hosts, update these connections in Flogo Enterprise:

**Orchestrator app connections:**
- `TelecomBSSMCPServer` → `http://<mcp-host>:9882/telecom-bss`
- `BillingDisputeA2AServer` → `http://<a2a-host>:9883`
- `RechargeA2AServer` → `http://<a2a-host>:9884`
- `SendEmailA2AServer` → `http://<a2a-host>:9885`

**A2A Servers app connections:**
- `PostgresConn` → Update host/port/database if not localhost
- A2A Server URLs in properties → Update if not localhost

---

## Step 5: Start Apps (in order)

Start the apps in this exact order:

1. **TelecomInvoiceMCPServer** (port 9882 must be ready first)
2. **TelecomInvoiceA2AServers** (ports 9883, 9884, 9885)
3. **TelecomInvoiceAIOrchestrator** (port 9500 -- needs MCP and A2A to be running)

---

## Step 6: Connect the Chatbot UI

```bash
cd demos/Agentic_AI/Chatbot
npm install
npm start
```

Open http://localhost:3000 in your browser. Enter the WebSocket URL and click **Connect**:

```
ws://localhost:9500/telecom
```

---

## Step 7: Run the Demo

Use the prompts from `prompts.md`. The recommended demo flow:

1. **Bill explanation** -- "Why is my bill so high? My number is +971-50-123-4567." (MCP: profile → invoice → usage)
2. **Payment history** -- "Show me my last 3 payments. My number is +971-52-567-8901." (MCP)
3. **Dispute** -- "I was charged for roaming but I didn't travel. +971-50-234-5678" → agent detects 0 roaming days → files dispute via billing_dispute_agent
4. **Recharge** -- "I need more data. +971-55-345-6789" → shows offers → applies pack via recharge_agent
5. **Email confirmation** -- "Send me a confirmation email" → send_confirmation_email
6. **Dispute status** -- "What's the status of my dispute? +971-50-678-9012" (MCP: GetDisputes)

---

## Step 8: Reset Demo Data

After a demo run (especially after filing disputes or applying recharges), reset the data:

```bash
psql -U postgres -d telecom -f reset_data.sql
```

This restores all tables, clears agent-written rows from `disputes` (new ones) and `recharges`, and refreshes due/payment/dispute dates relative to today.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| MCP Server not connecting | Verify port 9882 is open and the MCP app is running |
| A2A agents not responding | Check ports 9883-9885 are open and the A2A app is running |
| PostgreSQL connection failed | Verify database `telecom` exists and credentials are correct |
| Email not sending | Verify the Gmail App Password is correct (not the regular password). Enable 2FA on the Google account first. |
| Agent gives stale/wrong data | Run `reset_data.sql` to restore demo data |
| WebSocket disconnects | Ensure the Orchestrator app is running on port 9500 |
| Agent can't find a subscriber | Make sure the mobile number matches one in the `customers` table (format `+971-5X-XXX-XXXX`) |

---

## Gmail App Password Setup

To enable the email agent:

1. Go to https://myaccount.google.com/security
2. Enable 2-Step Verification
3. Go to https://myaccount.google.com/apppasswords
4. Generate an App Password for "Mail"
5. Use the 16-character password as `Email_App_Password`
