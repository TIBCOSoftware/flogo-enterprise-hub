# Retail Banking Assistant — Kestrel Bank

A chat assistant for a retail bank's customers (fictional **Kestrel Bank**). A customer verifies their
identity, checks balances, transactions, cards and loans, gets an unrecognised card charge decoded into the
real merchant, disputes it in two confirmed steps, blocks a lost or compromised card, and emails themselves
the confirmation. Fee refunds, hardship and deferral requests, credit-limit increases, complaints, account
changes and closures, bereavement and fraud reviews go to the right team — the assistant never decides them.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation and works out which
charge the customer means and who the merchant really is. PostgreSQL decides identity, dispute eligibility,
provisional credit, decision dates, card status and every change. People decide the exceptions.

> Kestrel Bank and all customers, accounts, cards and merchants in this sample are fictional.
> The app uses its own database (`banking_governed`); an earlier, simpler version of this demo is
> kept under [`Industry_Use_Cases_old/`](../../Industry_Use_Cases_old/Retail_Banking_Assistant_Use_Case/).

## Why an agent here?

| Part | Who owns it | Why |
|---|---|---|
| Decoding a cryptic statement descriptor (`QUICKPAY*XYZ 872-555`), matching the customer's words to one transaction, suggesting the dispute reason | **AI agent** (`dispute_triage_agent`) | "I don't recognise that QUICKPAY thing from last week" has to be matched against similar charges and a merchant directory. A fixed lookup can't tell "I cancelled it" from "I never signed up". |
| Understanding the request, explaining outcomes, chaining the steps | **AI agent** (orchestrator) | Conversation, ambiguity, multi-step planning across tools. |
| Who the customer is and which accounts, cards and transactions they can see | **Deterministic** (session token, scoped reads) | A model must not be able to talk its way into someone else's account. |
| Dispute eligibility, provisional credit, decision date, the write | **Deterministic, two-step** (`propose_dispute` → `pending_actions` → `disputes` + trigger) | The customer confirms an exact quote; the database files it, posts any provisional credit and re-checks the rules. |
| Blocking a card and ordering the replacement | **Deterministic, two-step** (`propose_card_block` → `card_blocks` + trigger) | The customer confirms the exact card; the database blocks it atomically. |
| Fee refunds, hardship, credit limits, complaints, account changes and closures, bereavement, fraud review | **Human** (`service_cases` → `service_teams`) | Discretion and accountability. Money and customer welfare are not an assistant's call. |

Without the AI, balances, card blocks and disputes still work through a form. What you would lose is
reading "I don't recognise a QUICKPAY charge" and knowing it is the $249.99 electronics order from XYZ
Gadgets Online, not the $18.75 one, and which dispute reason fits. That is the part the agent is for. The
agent is given only the customer's words and the candidate transactions (id, descriptor, amount, date) —
never the customer's name, customer ID, account number or session.

The demo is designed for retail and commercial banks and consumer-finance lenders: card disputes, lost
cards and hardship requests are their everyday service questions.

## Architecture

```
Chat UI ──WebSocket :9860 /retailbanking──► RetailBankingAIOrchestrator  (AI Agent)
                                              │
                  MCP :9862 ◄─────────────────┤──────────────► A2A :9863
                  RetailBankingMCPServer       │               RetailBankingAgents
                  13 governed tools            │               dispute_triage_agent
                          └────────────► PostgreSQL `banking_governed` ◄──┘
                                         rule functions · triggers · service teams · Gmail SMTP (email tool)
```

| App | Port / path | What it does |
|---|---|---|
| `RetailBankingAIOrchestrator.flogo` | WebSocket `9860` `/retailbanking` | The assistant the customer chats with. Each browser connection is its own conversation. |
| `RetailBankingMCPServer.flogo` | MCP `9862` `/retail-banking-mcp` | 13 governed tools: verify, accounts, transactions, cards, loans, branch finder, propose/confirm card block, propose/confirm dispute, open service case, list disputes and cases, email confirmation. |
| `RetailBankingAgents.flogo` | A2A `9863` | `dispute_triage_agent`: decodes the merchant behind a descriptor, picks the matching transaction and suggests a dispute reason. It never sees the customer's identity and never files anything. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (customer ID + passcode). Before building anything like it for real customers or data, review and
> follow your own organisation's security, privacy, and compliance policies and standards.

What the demo already enforces:

| Control | How |
|---|---|
| Identity + brute-force throttle | customer ID + 6-digit passcode → session token (30 min); 5 wrong passcodes lock the customer ID for 15 min (`verify_attempts`) |
| Rules in the database, not the prompt | guarded `INSERT…SELECT rule_fn`; the A2A agent is read-only and never receives identity |
| Per-user scoping | every read/write resolves the customer from the session token |
| Two-step confirm for state changes | `propose_dispute` / `propose_card_block` → explicit yes → `confirm_dispute` / `confirm_card_block` (proposals expire after 15 min; event row + trigger) |
| Human-in-the-loop for discretion | fee refund / hardship / credit limit / complaint / details change / closure / bereavement → routed `service_cases`; a fraud review opens automatically for unrecognised or fraud disputes and charges over $1,000 |
| Audit trail | every consequential change is written to `agent_audit` by triggers (query it by `customer_id` / `action`) |
| Resource limits | `rateLimit` + `tokenLimit` on the AI Agents |
| Transparency | the assistant says it is an AI when asked |
| Prompt-injection resistance | an injection cannot change state because the rules are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.6 or later.
- **PostgreSQL** 14 or later.
- An **OpenAI API key** (the apps ship set to model `gpt-5.5`; use a model your key can access — a capable
  model matches charges and merchants more reliably).
- A **Gmail App Password** for the confirmation email (or change the SMTP settings in the MCP app).
- **Node.js** 16 or later, for the shared [Chatbot](../../Chatbot/) web client.

## Steps to run

### 1. Create the database

```bash
createdb -U postgres banking_governed
psql -U postgres -d banking_governed -f database.sql
```

### 2. ⚠️ Configure the apps — these are NOT configured in the shipped files

Open each `.flogo` in VS Code and set these **App Properties**:

**`RetailBankingMCPServer.flogo`**

| Property | Set to |
|---|---|
| `PostgreSQL.PostgresConn.Host` / `Port` / `User` | your PostgreSQL server (default `localhost` / `5432` / `postgres`) |
| `PostgreSQL.PostgresConn.Password` | your PostgreSQL password |
| `PostgreSQL.PostgresConn.Database_Name` | `banking_governed` |
| `Email_Username` | the Gmail address that sends the confirmation |
| `Email_App_Password` | your Gmail **App Password** — re-enter it in App Properties so it stores as a `SECRET:` (keep the property type `string`) |
| `To_Email` | the operations inbox that receives confirmations |

**`RetailBankingAgents.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` | your LLM API key |
| `AgenticAI.OpenAIConn.LLM_Provider` / `LLM_Base_URL` | `OpenAI` / leave empty for OpenAI, or your provider's endpoint |
| `LLM_Model` | a model your key can use (ships as `gpt-5.5`) |
| `PostgreSQL.PostgresConn.*` | the same values as the MCP Server |

**`RetailBankingAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? Update the port property (`MCP_SERVER_PORT`, `dispute_triage_agent_PORT` together with
> `dispute_triage_agent_URL`, `WebSocket_PORT`) **and** the matching connection URL in the orchestrator:
> `http://localhost:9862/retail-banking-mcp` (MCP) and `http://localhost:9863` (A2A).

### 3. Start the apps in this order

**MCP Server (9862) → Agents (9863) → Orchestrator (9860).** Wait for each to log a clean start.

### 4. Open the chat client and connect

The chat client is the shared web app in [`samples/Agentic_AI/Chatbot`](../../Chatbot/). It needs Node.js 16+.

```bash
cd ../../Chatbot
npm install    # first time only
npm start
```

1. Open **http://localhost:3000**.
2. In the URL box at the top right, enter **`ws://localhost:9860/retailbanking`**.
3. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
4. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. Make sure the orchestrator
is running on port 9860. The chatbot remembers the last URL you applied, so a URL from another demo is a
common cause.

### 5. Run the demo

Sign in as one of the demo customers (in production the bank's app or online banking would already know
them; here they type their customer ID and the 6-digit passcode from the Kestrel app).

| Customer | Customer ID | Passcode | What they show |
|---|---|---|---|
| James Miller | `CUST-2026-00101` | `482913` | Unrecognised `QUICKPAY*XYZ 872-555` $249.99 → agent decodes **XYZ Gadgets Online** → dispute with provisional credit + fraud review → block debit card ••1123 → email (the flagship) |
| Olivia Davis | `CUST-2026-00102` | `730516` | `STRMPLS*MEMBERSHIP` $15.99 after cancelling → **cancelled subscription** dispute, no provisional credit; $35.00 overdraft fee → **fee refund** case for a person |
| William Garcia | `CUST-2026-00103` | `615204` | `LUXEJET TRAVEL` $1,850.00 → dispute with **no automatic provisional credit**, fraud review opened |
| Sophia Martinez | `CUST-2026-00104` | `559371` | Open dispute **DSP-2026-0001**; a single `CAFE LUMEN` charge is **not a duplicate**; `ACME HARDWARE #212` $64.10 charged twice → valid duplicate dispute |
| Benjamin Lee | `CUST-2026-00105` | `204867` | Debit card ••3390 **already blocked**; auto loan → **hardship** case for a person |
| Michael Brown | `CUST-2026-00107` | `377150` | Credit card ••8857 **expired** → nothing to block |

The flagship walkthrough, as James:

1. *"My customer ID is CUST-2026-00101 and my passcode is 482913."*
2. *"I don't recognise a $249.99 charge from QUICKPAY."* → the assistant explains it is **XYZ Gadgets
   Online**, an electronics web store billed through the QuickPay processor.
3. *"I never ordered anything from them, please dispute it."* → it reads back the amount, the **$249.99
   provisional credit**, the fraud review and the decision date, and asks you to confirm.
4. *"Yes, I confirm."* → dispute **DSP-…** is filed; the provisional credit is posted and the fraud team
   gets a case.
5. *"Please block my debit card ending 1123."* → it shows the card and the replacement delivery date and
   asks you to confirm → *"Yes, block it."* → the card is blocked and a replacement is ordered.
6. *"Email me the dispute confirmation."* → sent.
7. Open a new tab, sign in as Olivia (`CUST-2026-00102` / `730516`) and ask *"I'd like the $35 overdraft
   fee refunded."* → a case goes to Customer Care with a case ID and reply time; the assistant does not
   decide or promise the refund.

More prompts, including ones that show the rules holding, are in [prompts.md](prompts.md).

**Reset between demos** (run from this folder):

```bash
psql -U postgres -d banking_governed -f reset_data.sql
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The assistant never manages to verify the customer | Use the exact customer ID and passcode from the table. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it would mask the customer ID and passcode. |
| "I can't reach the tools" or no merchant explanation | Start the MCP Server and the Agents app **before** the orchestrator, and check the orchestrator's connection URLs match their ports. |
| Wrong charge picked or weak merchant explanations | Use a capable `LLM_Model` (ships as `gpt-5.5`); small models delegate to the dispute-triage agent unreliably. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For non-OpenAI providers, set `LLM_Base_URL`. |
| No confirmation email | Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, re-entered so it stores as `SECRET:`) and `To_Email`; confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed. |
| A new browser tab asks the customer to verify again | Expected: each connection is a separate conversation. |
| Transaction dates look wrong, or a dispute is refused as too old | Reload `reset_data.sql`. Demo dates are relative to today. |
| Verification keeps failing with "locked" | After 5 wrong passcodes a customer ID is locked for 15 minutes (brute-force throttle). Wait, or `TRUNCATE verify_attempts;` in dev. |
