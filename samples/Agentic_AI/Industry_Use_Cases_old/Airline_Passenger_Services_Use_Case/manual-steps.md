# Airline Passenger Services -- Manual Setup Steps

Step-by-step instructions to deploy and run the Passenger Services AI Agent demo end-to-end.

---

## Prerequisites

- TIBCO Flogo Enterprise v2.26.7+
- PostgreSQL 14+ (local or remote)
- OpenAI API key (GPT-4o or later)
- Gmail account with App Password (for email agent)
- Chatbot UI (from `samples/Agentic_AI/Chatbot/`)

---

## Step 1: Create the PostgreSQL Database

```bash
# Connect to PostgreSQL and create the database
psql -U postgres
CREATE DATABASE airline;
\q

# Load the schema and demo data
psql -U postgres -d airline -f database.sql
```

For live demos with today-relative flight times, run the reset script instead:

```bash
psql -U postgres -d airline -f reset_data.sql
```

Verify the data:
```bash
psql -U postgres -d airline -c "SELECT flight_number, origin, destination, status, delay_minutes FROM flights ORDER BY flight_number;"
```

---

## Step 2: Import Flogo Apps

Import all 3 `.flogo` files into TIBCO Flogo Enterprise:

1. **PassengerServicesMCPServer.flogo**
2. **PassengerServicesA2AServers.flogo**
3. **PassengerServicesAIOrchestrator.flogo**

---

## Step 3: Configure App Properties

### PassengerServicesMCPServer

| Property | Value |
|----------|-------|
| `PostgreSQL.PostgresConn.Host` | `localhost` (or your DB host) |
| `PostgreSQL.PostgresConn.Port` | `5432` |
| `PostgreSQL.PostgresConn.Database_Name` | `airline` |
| `PostgreSQL.PostgresConn.User` | `postgres` |
| `PostgreSQL.PostgresConn.Password` | Your PostgreSQL password |
| `MCP_SERVER_PORT` | `9093` |

### PassengerServicesA2AServers

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | Your OpenAI API key |
| `LLM_Model` | `gpt-5.5` (or preferred model) |
| `PostgreSQL.PostgresConn.Host` | `localhost` |
| `PostgreSQL.PostgresConn.Database_Name` | `airline` |
| `PostgreSQL.PostgresConn.User` | `postgres` |
| `PostgreSQL.PostgresConn.Password` | Your PostgreSQL password |
| `To_Email` | Recipient email for confirmations |
| `Email_Username` | Gmail address for SMTP |
| `Email_App_Password` | Gmail App Password |
| `Connection_Risk_A2AServer_PORT` | `8074` |
| `Rebook_Passenger_A2AServer_PORT` | `8075` |
| `SendEmail_A2AServer_PORT` | `8076` |

### PassengerServicesAIOrchestrator

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | Your OpenAI API key |
| `LLM_Model` | `gpt-5.5` (or preferred model) |

---

## Step 4: Configure Connections (if needed)

The connection URLs default to `localhost`. If running on different hosts, update these connections in Flogo Enterprise:

**Orchestrator app connections:**
- `AirlineMCPServer` → `http://<mcp-host>:9093/airlinemcpserver`
- `ConnectionRiskA2AServer` → `http://<a2a-host>:8074`
- `RebookPassengerA2AServer` → `http://<a2a-host>:8075`
- `SendEmailA2AServer` → `http://<a2a-host>:8076`

**A2A Servers app connections:**
- `PostgresConn` → Update host/port/database if not localhost
- A2A Server URLs in properties → Update if not localhost

---

## Step 5: Start Apps (in order)

Start the apps in this exact order:

1. **PassengerServicesMCPServer** (port 9093 must be ready first)
2. **PassengerServicesA2AServers** (ports 8074, 8075, 8076)
3. **PassengerServicesAIOrchestrator** (port 8083 -- needs MCP and A2A to be running)

---

## Step 6: Connect the Chatbot UI

```bash
cd samples/Agentic_AI/Chatbot
npm install
npm start
```

Open http://localhost:3000 in your browser. Enter the WebSocket URL and click **Connect**:

```
ws://localhost:8083/ws/chat
```

---

## Step 7: Run the Demo

Use the prompts from `prompts.md`. The recommended demo flow:

1. **Flight status check** -- "What's the status of flight FL801?"
2. **Booking lookup** -- "My booking is ABCDE1. Will I make my connection?"
3. **Connection risk** -- Agent invokes connection_risk_agent, identifies MISSED connection
4. **Rebooking** -- "Yes, please rebook me on FL447" -- Agent invokes rebook_passenger_agent
5. **Email confirmation** -- "Send me a confirmation email" -- Agent invokes send_confirmation_email

---

## Step 8: Reset Demo Data

After a demo run (especially after rebooking), reset the data:

```bash
psql -U postgres -d airline -f reset_data.sql
```

This resets all tables with today-relative flight times and clears the `rebooking_log`.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| MCP Server not connecting | Verify port 9093 is open and MCP app is running |
| A2A agents not responding | Check ports 8074-8076 are open and A2A app is running |
| PostgreSQL connection failed | Verify database `airline` exists and credentials are correct |
| Email not sending | Verify Gmail App Password is correct (not regular password). Enable 2FA on Google account first. |
| Agent gives wrong data | Run `reset_data.sql` to restore demo data |
| WebSocket disconnects | Ensure Orchestrator app is running on port 8083 |

---

## Gmail App Password Setup

To enable the email agent:

1. Go to https://myaccount.google.com/security
2. Enable 2-Step Verification
3. Go to https://myaccount.google.com/apppasswords
4. Generate an App Password for "Mail"
5. Use the 16-character password as `Email_App_Password`
