# Telecom — Mobile Billing & Spend Control Assistant

**Nova** is a chat assistant for the customers of a US mobile operator (fictional **Tidewell Mobile**).
A customer verifies with their mobile number and a one-time code, then asks why their bill jumped. Nova
explains it from the system's own bill-to-bill comparison, which is usually pay-per-use roaming on a trip
abroad or a premium content subscription they don't remember signing up for. The customer can then stop the
cause and keep it from happening again: cancel the subscription, add TravelPass, set a roaming limit or
change plan. Each change takes two confirmed steps and is followed by an emailed confirmation. Nova also
recommends plans from the customer's real usage and travel. Refunds and disputed charges, service
cancellations, number transfers (port-out) and suspected fraud go to the right team. The assistant never
decides them.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation, explains why a bill
changed, classifies a charge the customer doesn't recognize and recommends a plan. PostgreSQL decides
identity, amounts, bill-to-bill deltas, eligibility, prices and every change. People decide the exceptions.

> Tidewell Mobile and all customers, phone numbers, plans, bills and charges in this sample are fictional.
> Amounts are in US dollars ($). Plan prices are before taxes & fees, which appear as a separate bill line.

## Why an agent here?

| Part | Owner | Why |
|---|---|---|
| Explaining *why* a bill jumped (`BillExplainer`) | **AI agent** | Turns the system's category deltas and line items into a plain-English story ("most of the increase is pay-per-use roaming in Mexico, plus a $9.99 games subscription"). It narrates the numbers it is given and never computes them. |
| Working out what a disputed or unknown charge is (`ChargeClassifier`) | **AI agent** | Reads the customer's own words ("I never signed up for this", "I wasn't in Canada") against the line items, the days abroad on record and the last SIM swap date, then picks a category and next step: cancel, roaming options, dispute or fraud. |
| Recommending a plan from free-text needs (`PlanRecommender`) | **AI agent** | Weighs "I go to Mexico every few months and keep running low on data" against three cycles of usage, days abroad and only the plans the system says are allowed, including roaming-included plans vs. TravelPass. |
| The conversation, chaining several requests in one message | **AI agent** (orchestrator) | Understanding the request, asking for a yes before each change, handling the steps in order. |
| Identity, bills, usage, roaming days, bill-to-bill deltas, eligible plans | **Deterministic (SQL)** | Every read is scoped to the verified customer, and the deltas are computed in SQL. A model must not be able to talk its way into another customer's bill or invent a number. |
| TravelPass, roaming limit, canceling a subscription, plan changes | **Deterministic, two-step (SQL)** | Past-due balances, device installment lock-in, one plan change per cycle and account holds are rule functions. The customer confirms an exact proposal; the database re-checks the rules and applies it. |
| Refunds & billing disputes, service cancellation & port-out, suspected fraud | **Human** (Billing Disputes · Retention · Fraud Team) | Money given back, service ended and fraud decisions need a person who is accountable. The assistant opens a routed case and never promises an outcome. |

If you removed the LLM, the bills, usage, TravelPass, roaming limit, subscription cancellation and plan
changes would still work through a form. What you would lose is someone reading "why is my bill so high?"
or "I wasn't even in Canada" and turning the numbers into an explanation and the right next step, and
matching "I travel to Mexico a lot" to a plan. That is the part the agents are for. The agents are given
only the numbers and line items they need, never the customer's name, phone number, SSN, email or session.

## Architecture

```
Chat UI ──WebSocket :9900 /mobilebilling──► MobileBillingAIOrchestrator  (AI Agent "Nova")
                                              │
     MCP :9902 /mobilebillingmcpserver ◄──────┤──────► A2A  MobileBillingAgents
     MobileBillingMCPServer                   │          :9903  PlanRecommender
     13 governed tools                        │          :9904  ChargeClassifier
            │                                 │          :9905  BillExplainer
            ▼                                            (read-only, identity-free)
     PostgreSQL `mobile_billing`
     rule functions · triggers · case routing · SMTP (email tool)
```

| App | Port / path | What it does |
|---|---|---|
| `MobileBillingAIOrchestrator.flogo` | WebSocket `9900` `/mobilebilling` | Nova, the assistant the customer chats with. Each browser connection is its own conversation. |
| `MobileBillingMCPServer.flogo` | MCP `9902` `/mobilebillingmcpserver` | 13 governed tools: verify the customer, account, bills, bill detail, bill-to-bill comparison, usage & roaming, subscriptions & TravelPass, payments, eligible plans, propose a change, confirm a change, open a case for a person, email a confirmation. |
| `MobileBillingAgents.flogo` | A2A `9903` / `9904` / `9905` | Three read-only reasoning agents: `PlanRecommender` ranks up to two allowed plans, `ChargeClassifier` classifies a charge and suggests the next step, `BillExplainer` narrates what changed on the bill. None of them sees the customer's identity, and none can change anything. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (mobile number + fixed one-time code). Before building anything like it for real customers or
> data, review and follow your own organization's security, privacy, and compliance policies and standards.

| Control | How |
|---|---|
| Identity | mobile number + one-time code → a session token valid for 30 minutes; a wrong code gives no hint which part was wrong |
| Rules in the database, not the prompt | guarded `INSERT … SELECT rule_fn`; eligibility, prices, effective dates and deltas all come from SQL |
| Per-customer scoping | every read and write resolves the customer from the session token; another customer's bill is "not found" |
| Data minimization | internal fraud flags, risk scores, notes, SSNs and email addresses are never returned by any tool; the A2A agents get no identity |
| Two-step confirm for every change | `propose_action` → explicit yes → `confirm_action` (re-checks every rule; proposals expire after 15 minutes) |
| Human-in-the-loop for discretion | refunds/disputes, service cancellation, port-out and suspected fraud → routed `service_cases` with the team and reply time from a routing table |
| Guarded email | a confirmation is only sent for a completed change on the caller's own account |
| Resource limits | `rateLimit` + `tokenLimit` on every AI agent |
| Transparency | Nova says it is an AI assistant when asked |
| Prompt-injection resistance | claiming to be staff changes nothing, because the rules are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.7 or later.
- **PostgreSQL** 14 or later.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- An **OpenAI API key** (or another supported provider). The apps ship set to model `gpt-5.5`. Use a capable
  tool-calling model: nano-class models drop tool calls and delegate to the agents unreliably.
- A **Gmail App Password** for the confirmation email (or change the SMTP settings in the MCP app).
- **Node.js** 16 or later, for the shared [Chatbot](../../../../Chatbot/) web client.

## Steps to run

### 1. Create the database

From this folder:

```bash
createdb -U postgres mobile_billing
psql -U postgres -d mobile_billing -f database.sql
```

`database.sql` creates the schema and rule functions and then loads the demo data from `seed_data.sql`
(keep both files in the same folder).

### 2. ⚠️ Configure the apps — these are NOT configured in the shipped files

Open each `.flogo` in VS Code and set these **App Properties**:

**`MobileBillingMCPServer.flogo`**

| Property | Set to |
|---|---|
| `PostgreSQL.PostgresConn.Host` / `Port` / `User` | your PostgreSQL server (default `localhost` / `5432` / `postgres`) |
| `PostgreSQL.PostgresConn.Password` | your PostgreSQL password |
| `PostgreSQL.PostgresConn.Database_Name` | `mobile_billing` |
| `Email_Username` | the Gmail address that sends the confirmation |
| `Email_App_Password` | your Gmail **App Password**: re-enter it in App Properties so it is stored as a `SECRET:` (keep the property type `string`) |
| `EMAIL_TO` | the demo inbox that receives every confirmation email (the customer's own address is never used) |
| `MCP_SERVER_PORT` | `9902` (change only if the port is taken) |

**`MobileBillingAgents.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` | your LLM API key |
| `AgenticAI.OpenAIConn.LLM_Provider` / `LLM_Base_URL` | `OpenAI` / leave empty for OpenAI, or your provider's endpoint |
| `LLM_Model` | a capable tool-calling model your key can use (ships as `gpt-5.5`) |
| `PlanRecommender_PORT` / `PlanRecommender_URL` | `9903` / `http://localhost:9903` |
| `ChargeClassifier_PORT` / `ChargeClassifier_URL` | `9904` / `http://localhost:9904` |
| `BillExplainer_PORT` / `BillExplainer_URL` | `9905` / `http://localhost:9905` |

**`MobileBillingAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |
| `WebSocket_PORT` | `9900` |
| `MobileBillingMCPServer_URL` | `http://localhost:9902/mobilebillingmcpserver` |
| `PlanRecommender_URL` / `ChargeClassifier_URL` / `BillExplainer_URL` | `http://localhost:9903` / `http://localhost:9904` / `http://localhost:9905` |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? Change it in **both** places: the port property of the app that listens
> (`MCP_SERVER_PORT`, `<Agent>_PORT` and `<Agent>_URL`, `WebSocket_PORT`) **and** the matching URL property
> in the orchestrator (`MobileBillingMCPServer_URL`, `<Agent>_URL`).

### 3. Start the apps in this order

**MCP Server (9902) → Agents (9903–9905) → Orchestrator (9900).** Wait for each to log a clean start.

### 4. Open the chat client and connect

The chat client is the shared web app in [`samples/Agentic_AI/Chatbot`](../../../../Chatbot/). It needs Node.js 16+.

```bash
cd ../../../../Chatbot
npm install    # first time only
npm start
```

1. Open **http://localhost:3000**.
2. In the URL box at the top right, enter **`ws://localhost:9900/mobilebilling`**.
3. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
4. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect** (↻ is refused while connected), check the URL, click **↻** again,
then **Connect**. Make sure the orchestrator is running on port 9900. The chatbot remembers the last URL you
applied, so a URL from another demo is a common cause.

### 5. Run the demo

Sign in as one of the demo customers. In production the Tidewell app would already know who they are; here
they type their mobile number and the one-time code "sent by text message" (fixed for the demo).

| Customer | Mobile number | One-time code | What they show |
|---|---|---|---|
| Maria Lopez | `(212) 555-0101` | `4821` | Bill jumped from **$52.00** to **$270.00**: **$206.47** pay-per-use roaming on a 4-day Mexico trip + a **StarPlay Games** subscription ($9.99/month) → explain, cancel, TravelPass / roaming limit, plan advice, email, refund → Billing Disputes |
| James Carter | `(212) 555-0102` | `7305` | **$186.40** past due → TravelPass, upgrades and raising his limit are **blocked**; prompt injection and another customer's bill are refused; lowering his limit to $0 is allowed |
| Priya Shah | `(212) 555-0103` | `9164` | Device installment → plan changes **locked in**; a $96.32 Canada roaming charge with no days abroad, right after a SIM swap → **Fraud Team**; port-out → **Retention** |

The flagship walkthrough, as Maria:

1. *"Hi, my number is (212) 555-0101 and my code is 4821."*
2. *"Why is my bill so high this month? Stop whatever is causing it and make sure it doesn't happen again."*
   → the bill went from $52.00 to $270.00. Nova explains the Mexico roaming charges and the StarPlay Games
   subscription, then proposes canceling the subscription.
3. *"Yes, cancel it."* → canceled with a reference. Nova then offers TravelPass and/or a roaming limit.
4. *"Yes, add TravelPass."* → enrolled ($10 a day, only on days she uses her phone abroad).
5. *"I go to Mexico every few months and I'm always close to my data limit. Is there a better plan for me?"*
   → plan picks from her real usage and travel, from the plans she is allowed to move to. Nothing changes
   until she confirms.
6. *"Please email me the confirmation."* → sent.
7. *"Can you refund the StarPlay charge? I never signed up for it."* → a case goes to **Billing Disputes**
   (reply within 5 business days); Nova does not decide it.
8. *"Am I talking to a real person?"* → it says it is an AI assistant.

More prompts, including James's and Priya's stories and two optional rule-test logins, are in
[prompts.md](prompts.md).

**Reset between demos** (from this folder):

```bash
psql -U postgres -d mobile_billing -f reset_data.sql
```

Then reconnect the chatbot (**Disconnect** → **Connect**) so the next demo starts a fresh conversation.

## Troubleshooting

| Symptom | Fix |
|---|---|
| LLM error about `temperature` (unsupported value) | Keep the AI agents' **Temperature** at `0`. In this connector `0` means "not sent", so the provider default is used. gpt-5.x models reject any other value. |
| The assistant never manages to verify the customer | Use the exact mobile number and code from the table. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it would mask the number and the code. |
| No reply, or replies stop mid-conversation | Click **Disconnect**, then **Connect**, and verify again. Each connection is its own conversation. |
| Answers get slow or mix in an earlier demo | Reconnect between demos. A long conversation keeps its history in memory and sends it with every message, which costs tokens. A fresh connection starts clean. |
| "I can't reach that right now" or no bill explanation / plan picks | Start the MCP Server and the Agents app **before** the orchestrator. Check that ports 9902, 9903, 9904 and 9905 are listening (for example `netstat -an \| findstr "9902 9903 9904 9905"` on Windows, `lsof -i :9903` on macOS/Linux) and that the orchestrator's URL properties match. |
| Changes are proposed but tool calls are skipped, or agents are never used | Use a capable tool-calling `LLM_Model` (ships as `gpt-5.5`); nano-class models drop tool calls. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For non-OpenAI providers, set `LLM_Base_URL`. |
| No confirmation email | Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, re-entered so it stores as `SECRET:`) and `EMAIL_TO`; confirm outbound SMTP to Gmail is allowed. |
| Bills, usage or dates look wrong, or a change is "already done" | Reload `reset_data.sql`. Demo dates are relative to today. |

## Rebuild from code

To regenerate these apps from code or run the automated checks, see [`_rebuild/README.md`](_rebuild/README.md).
