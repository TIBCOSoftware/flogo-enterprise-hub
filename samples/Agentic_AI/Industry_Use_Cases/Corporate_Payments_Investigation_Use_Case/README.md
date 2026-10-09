# Corporate Payment Investigation & Status — Aurelia Global Bank

A chat assistant for a bank's corporate clients (fictional **Aurelia Global Bank**). An authorised treasury or
accounts-payable user verifies their identity, checks a payment's status, rail, FX and fees, gets a cryptic
return/reason code decoded into plain language, raises a trace on a delayed payment in two confirmed steps,
requests a recall on a wrong or erroneous payment, and emails themselves the confirmation. Recalls (money
reversals), fee waivers, compensation, suspected fraud, sanctions queries and payment repairs go to the right
team — the assistant never decides them.

This pattern applies to retail, commercial and transaction-banking institutions alike: "where is my payment,
why was it returned or held, trace it, recall it" is the universal payments-servicing question.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation, decodes cryptic
return-reason codes, works out which payment the client means and recommends a trace or a recall. PostgreSQL
decides identity, scope, status, delivery estimates, eligibility and every state change. People decide the money
reversals and compliance.

> Aurelia Global Bank and all clients, accounts, beneficiaries and payments in this sample are fictional.
> The app uses its own database (`payments_governed`).

## Why an agent here?

| Part | Who owns it | Why |
|---|---|---|
| Decoding a cryptic return/reason code (`AC04`, `BE01`), matching the client's words to one payment, recommending trace vs recall | **AI agent** (`payment_triage_agent`) | "Our €48,500 payment to the supplier came back" has to be matched against the client's recent payments and a reason-code directory. A fixed lookup can't tell "trace a delayed payment" from "recall one sent to the wrong company". |
| Understanding the request, explaining outcomes, chaining the steps | **AI agent** (orchestrator) | Conversation, ambiguity, multi-step planning across tools. |
| Who the client is and which payments and cases they can see | **Deterministic** (session token, scoped reads) | A model must not be able to talk its way into another company's payments. |
| Payment status, rail, FX, fees, delivery estimate, trace eligibility, the write | **Deterministic, two-step** (`propose_trace` → `pending_actions` → `investigations` + trigger) | The client confirms an exact quote; the database files it, opens the investigation and re-checks the rules. Settlement dates come from `cutoff_rules` arithmetic, never guessed. |
| Requesting a recall of a payment (money reversal) | **Human, two-step** (`propose_recall` → `confirm_recall` → Payment Operations review case) | The client confirms the exact payment; a person decides the recall and funds are never reversed automatically. |
| Fee waivers, compensation, fraud, sanctions queries, payment repair | **Human** (`review_cases` → `service_teams`) | Discretion and accountability. Money and compliance are not an assistant's call. |

Without the AI, payment status, traces and recalls still work through a form. What you would lose is reading "our
€48,500 payment to the supplier came back" and knowing it is the one to Lyon Textiles SARL, that **AC04** means
the beneficiary's account is closed, and that the right next step is to confirm the account and re-send. That is
the part the agent is for. The agent is given only the client's words and the candidate payments (reference,
direction, rail, amount, currency, beneficiary, status, return code, dates) — never the client's legal name,
client ID, account number or session.

The demo is designed for retail, commercial and transaction-banking institutions: high-value and cross-border
payment status, returns, traces and recalls are their everyday servicing questions.

## Architecture

```
Chat UI ──WebSocket :9870 /corporatepayments──► CorporatePaymentsAIOrchestrator  (AI Agent)
                                                  │
                  MCP :9872 ◄─────────────────────┤──────────────► A2A :9873
                  CorporatePaymentsMCPServer       │               CorporatePaymentsAgents
                  12 governed tools                │               payment_triage_agent
                          └────────────────► PostgreSQL `payments_governed` ◄──┘
                                             rule functions · triggers · service teams · Gmail SMTP (email tool)
```

| App | Port / path | What it does |
|---|---|---|
| `CorporatePaymentsAIOrchestrator.flogo` | WebSocket `9870` `/corporatepayments` | The assistant the client chats with. Each browser connection is its own conversation. |
| `CorporatePaymentsMCPServer.flogo` | MCP `9872` `/corporate-payments-mcp` | 12 governed tools: verify, list payments, payment status, timeline, delivery estimate, propose/confirm trace, propose/confirm recall, open review case, list cases, email confirmation. |
| `CorporatePaymentsAgents.flogo` | A2A `9873` | `payment_triage_agent`: decodes the return/reason code, matches the client's words to one payment and recommends a trace, a recall or a human review. It never sees the client's identity and never files anything. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (client ID + passcode). Before building anything like it for real customers or data, review and
> follow your own organisation's security, privacy, and compliance policies and standards.

What the demo already enforces:

| Control | How |
|---|---|
| Identity + brute-force throttle | client ID + 6-digit passcode → session token (30 min); 5 wrong passcodes lock the client ID for 15 min (`verify_attempts`) |
| Rules in the database, not the prompt | guarded `INSERT…SELECT rule_fn`; the A2A agent is read-only and never receives identity |
| Per-client scoping | every read and write resolves the client from the session token; one client can never see or act on another's payment |
| Two-step confirm for state changes | `propose_trace` / `propose_recall` → explicit yes → `confirm_trace` / `confirm_recall` (proposals expire after 15 min; event row + trigger) |
| Human-in-the-loop for money & compliance | a recall opens a Payment Operations review case for a person to decide — funds are never auto-reversed; fee waiver / compensation / fraud / sanctions query / payment repair → routed `review_cases` |
| Deterministic delivery estimates | settlement dates come from `cutoff_rules` arithmetic (rail + currency, business-day aware), never guessed by the model |
| Audit trail | every consequential change is written to `agent_audit` by triggers (query it by `client_id` / `action`) |
| Resource limits | `rateLimit` + `tokenLimit` on the AI Agents |
| Transparency | the assistant says it is an AI when asked |
| Prompt-injection resistance | an injection cannot change state because the rules are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.6 or later.
- **PostgreSQL** 14 or later.
- An **OpenAI API key** (the apps ship set to model `gpt-5.5`; use a model your key can access — a capable
  model decodes reason codes and matches payments more reliably).
- A **Gmail App Password** for the confirmation email (or change the SMTP settings in the MCP app).
- **Node.js** 16 or later, for the shared [Chatbot](../../Chatbot/) web client.

## Steps to run

### 1. Create the database

```bash
createdb -U postgres payments_governed
psql -U postgres -d payments_governed -f database.sql
```

### 2. ⚠️ Configure the apps — these are NOT configured in the shipped files

Open each `.flogo` in VS Code and set these **App Properties**:

**`CorporatePaymentsMCPServer.flogo`**

| Property | Set to |
|---|---|
| `PostgreSQL.PostgresConn.Host` / `Port` / `User` | your PostgreSQL server (default `localhost` / `5432` / `postgres`) |
| `PostgreSQL.PostgresConn.Password` | your PostgreSQL password |
| `PostgreSQL.PostgresConn.Database_Name` | `payments_governed` |
| `Email_Username` | the Gmail address that sends the confirmation |
| `Email_App_Password` | your Gmail **App Password** — re-enter it in App Properties so it stores as a `SECRET:` (keep the property type `string`) |
| `To_Email` | the operations inbox that receives confirmations |

**`CorporatePaymentsAgents.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` | your LLM API key |
| `AgenticAI.OpenAIConn.LLM_Provider` / `LLM_Base_URL` | `OpenAI` / leave empty for OpenAI, or your provider's endpoint |
| `LLM_Model` | a model your key can use (ships as `gpt-5.5`) |
| `PostgreSQL.PostgresConn.*` | the same values as the MCP Server |

**`CorporatePaymentsAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? Update the port property (`MCP_SERVER_PORT`, `payment_triage_agent_PORT` together with
> `payment_triage_agent_URL`, `WebSocket_PORT`) **and** the matching connection URL in the orchestrator:
> `http://localhost:9872/corporate-payments-mcp` (MCP) and `http://localhost:9873` (A2A).

### 3. Start the apps in this order

**MCP Server (9872) → Agents (9873) → Orchestrator (9870).** Wait for each to log a clean start.

### 4. Open the chat client and connect

The chat client is the shared web app in [`samples/Agentic_AI/Chatbot`](../../Chatbot/). It needs Node.js 16+.

```bash
cd ../../Chatbot
npm install    # first time only
npm start
```

1. Open **http://localhost:3000**.
2. In the URL box at the top right, enter **`ws://localhost:9870/corporatepayments`**.
3. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
4. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. Make sure the orchestrator
is running on port 9870. The chatbot remembers the last URL you applied, so a URL from another demo is a
common cause.

### 5. Run the demo

Sign in as one of the demo clients (in production the Aurelia corporate portal would already know them; here
they type their client ID and the 6-digit passcode).

| Client | Client ID | Passcode | What they show |
|---|---|---|---|
| Northwind Manufacturing | `CLI-2026-00101` | `486201` | €48,500 SEPA **RETURNED** → agent decodes **AC04 (account closed)**; $250,000 SWIFT **IN_TRANSIT** → trace → investigation + email (the flagship) |
| Helios Trading | `CLI-2026-00102` | `730955` | $780,000 SWIFT to the **wrong beneficiary** → two-step **recall** → Payment Operations case; $54,000 **HELD** (sanctions) → **SANCTIONS_QUERY** case for a person |
| Veridian Foods | `CLI-2026-00103` | `615338` | €56,000 **INCOMING** → recall refused **NOT_RECALLABLE**; a $45 ACH fee → **FEE_WAIVER** case; a payment **COMPLETED** more than 5 business days ago → recall refused |
| Barco Logistics | `CLI-2026-00104` | `904177` | A clean COMPLETED payment; used to show cross-client scoping (no other client can see or act on Barco's payment) |

The flagship walkthrough, as Northwind:

1. *"This is treasury at Northwind. My client ID is CLI-2026-00101 and my passcode is 486201."*
2. *"Why was our €48,500 SEPA payment to our supplier returned?"* → the assistant explains it is the payment
   to **Lyon Textiles SARL**, returned with **AC04 — the beneficiary's account is closed**, and recommends
   confirming the supplier's current account details and re-sending (or opening a payment-repair case).
3. *"Separately, our $250,000 payment to Pacific Components has been in transit for three days — can you trace
   it?"* → it proposes a trace and **reads back the amount ($250,000.00), the beneficiary (Pacific Components
   Ltd), the decoded reason and the estimated response date** exactly as the tool returned them, then asks you
   to confirm.
4. *"Yes, please open the trace."* → the trace is opened as investigation **INV-…** with the estimated response
   date; a timeline event and an audit row are written by the database.
5. *"Email me the confirmation."* → sent to the operations inbox.
6. *"What investigations and cases do we have open?"* → the assistant lists the new trace with its status and
   expected response date.
7. Open a new tab, sign in as Helios (`CLI-2026-00102` / `730955`) and say *"We sent $780,000 to the wrong
   company — can you get it back?"* → the assistant proposes a recall and **states plainly that a recall is a
   request a person at Payment Operations decides: it is not guaranteed and does not reverse the funds
   automatically**, reading back the amount and beneficiary. On your explicit *"Yes, submit the recall,"* a
   Payment Operations review case is opened and the payment moves to **RECALL_REQUESTED** — a person decides it.
   Then ask *"Why is my $54,000 payment to Gulf Trading on hold?"* → the assistant explains it is **HELD for
   sanctions screening**, opens a **SANCTIONS_QUERY** case with Sanctions & Compliance, gives the case ID and
   reply time, and does not predict the outcome.

More prompts — including ones that show the rules holding (cross-client refusal, confirm without a proposal,
a recall that is too old, a trace that is too soon, prompt injection, lockout) — are in
[prompts.md](prompts.md).

**Reset between demos** (run from this folder):

```bash
psql -U postgres -d payments_governed -f reset_data.sql
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The assistant never manages to verify the client | Use the exact client ID and passcode from the table. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it would mask the client ID and passcode. |
| "I can't reach the tools" or no decoded return reason | Start the MCP Server and the Agents app **before** the orchestrator, and check the orchestrator's connection URLs match their ports. |
| Weak return-code decoding or the wrong payment picked | Use a capable `LLM_Model` (ships as `gpt-5.5`); small models delegate to the payment-triage agent unreliably. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For non-OpenAI providers, set `LLM_Base_URL`. |
| No confirmation email | Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, re-entered so it stores as `SECRET:`) and `To_Email`; confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed. |
| A new browser tab asks the client to verify again | Expected: each connection is a separate conversation. |
| Payment dates or delivery estimates look wrong, or a trace/recall is refused as too old or too soon | Reload `reset_data.sql`. Demo dates are relative to today. |
| Verification keeps failing with "locked" | After 5 wrong passcodes a client ID is locked for 15 minutes (brute-force throttle). Wait, or `TRUNCATE verify_attempts;` in dev. |
