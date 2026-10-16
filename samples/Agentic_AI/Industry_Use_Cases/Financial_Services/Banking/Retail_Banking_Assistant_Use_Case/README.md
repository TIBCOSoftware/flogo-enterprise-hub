> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# Banking — Retail Banking Assistant

The **Kestrel Bank Assistant** is a chat assistant for the customers of a fictional retail bank, **Kestrel
Bank**. A customer verifies their identity, checks balances, transactions, cards and loans, gets an
unrecognized card charge decoded into the real merchant, disputes it in two confirmed steps, blocks a lost or
compromised card, pays one of their saved payees with **scam protection**, and emails themselves the
confirmation. Fee refunds, hardship and deferral requests, held payments, credit-limit increases, complaints,
account changes and closures, bereavement and fraud reviews go to the right team — and Kestrel's **staff
reviewers decide them in the same chatbot**. The assistant never decides them.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation and three genuinely
semantic steps: working out which charge the customer means and who the merchant really is, spotting the signs
of a payment scam in the customer's own story, and turning a hardship story into a brief for a person.
PostgreSQL decides identity, dispute eligibility, provisional credit, payment rules and the scam risk band,
card status and every change. People decide the exceptions.

> Kestrel Bank and all customers, staff, accounts, payees, cards and merchants in this sample are fictional.
> The app uses its own database (`banking_governed`).

## Why an agent here?

| Part | Who owns it | Why |
|---|---|---|
| Decoding a cryptic statement descriptor (`QUICKPAY*XYZ 872-555`), matching the customer's words to one transaction, suggesting the dispute reason | **AI agent** (`dispute_triage_agent`) | "I don't recognize that QUICKPAY thing from last week" has to be matched against similar charges and a merchant directory. A fixed lookup can't tell "I canceled it" from "I never signed up". |
| Reading a customer's story about a payment ("the bank's fraud team called and told me to move my savings to a safe account") for the signs of an authorized push payment scam | **AI agent** (`scam_signal_agent`) | Scam signs — impersonation, a "safe account", secrecy, pressure, remote access, investment or romance pitches — live in free text, phrased a thousand ways. The agent names them from Kestrel's scam signal guide and quotes the customer's words. |
| Turning a hardship story (job loss, illness, separation, bereavement) into a structured brief | **AI agent** (`hardship_intake_agent`) | The cause, the expected duration, the affected products, the programs worth considering and the documents to ask for have to be read out of the customer's own words — for a specialist, not for an outcome. |
| Understanding the request, explaining outcomes, chaining the steps | **AI agent** (orchestrator) | Conversation, ambiguity, multi-step planning across tools. |
| Who the customer (or staff reviewer) is and what they can see | **Deterministic** (session token, role, scoped reads) | A model must not be able to talk its way into someone else's account, or into a reviewer's queue. |
| Dispute eligibility, provisional credit, decision date, the write | **Deterministic, two-step** (`propose_dispute` → `confirm_dispute`) | The customer confirms an exact quote; the database files it, posts any provisional credit and re-checks the rules. |
| Blocking a card and ordering the replacement | **Deterministic, two-step** (`propose_card_block` → `confirm_card_block`) | The customer confirms the exact card; the database blocks it atomically. |
| Whether a payment can go, needs a warning, or is held — and the payment itself | **Deterministic** (`propose_payment` → `confirm_payment`) | SQL validates the agent's scam indicators against the guide and adds its own checks (new payee, unusual amount, first payment of that kind, share of the balance). Low risk: the customer confirms. Medium: the customer must acknowledge a warning first. High: the payment is **held** and the fraud team gets a case. The customer never sees a score. |
| Fee refunds, hardship deferrals, releasing a held payment, credit limits, complaints, account changes and closures, bereavement, fraud review | **Human** (`service_cases` → `service_teams`, staff reviewer decides) | Discretion and accountability. A reviewer of the right team approves or rejects with an internal note and a customer message; approval runs the parked action (refund, deferral, release) through the same database rules, within the reviewer's approval limit. |

Without the AI, balances, card blocks, disputes and payments still work through a form. What you would lose is
reading "I don't recognize a QUICKPAY charge" and knowing it is the $249.99 electronics order from XYZ
Gadgets Online; noticing that "move my savings to a safe account, and don't tell the branch" is a textbook
scam before the money leaves; and handing Financial Support a clean, neutral hardship brief. The agents are given
only the customer's words and the minimum facts they need — never the customer's name, customer ID, account or
card number, or session.

The demo is designed for retail and commercial banks and consumer-finance lenders: card disputes, lost
cards, authorized push payment scams and hardship requests are their everyday service questions.

## Architecture

```
Chat UI ──WebSocket :9860 /retailbanking──► RetailBankingAIOrchestrator  (AI Agent: customers + staff reviewers)
                                              │
                  MCP :9862 ◄─────────────────┤──────────────► A2A :9863 dispute_triage_agent
                  RetailBankingMCPServer       │               A2A :9864 scam_signal_agent
                  20 governed tools            │               A2A :9865 hardship_intake_agent
                          │                    │               RetailBankingAgents (reference tables only)
                          └────────────► PostgreSQL `banking_governed` ◄──┘
                                         rule functions · triggers · service teams · reviewers · Gmail SMTP (email tool)
```

| App | Port / path | What it does |
|---|---|---|
| `RetailBankingAIOrchestrator.flogo` | WebSocket `9860` `/retailbanking` | The assistant customers and staff reviewers chat with. Each browser connection is its own conversation. |
| `RetailBankingMCPServer.flogo` | MCP `9862` `/retail-banking-mcp` | 20 governed tools: verify, accounts, transactions, cards, loans, payees, branch finder, propose/confirm card block, propose/confirm dispute, propose/confirm payment, open service case, list disputes and cases, email confirmation, and the reviewer tools (verify reviewer, review queue, review case, decide case). |
| `RetailBankingAgents.flogo` | A2A `9863`, `9864`, `9865` | Three read-only agents: `dispute_triage_agent` (merchant behind a descriptor, matching transaction, dispute reason), `scam_signal_agent` (scam signs in a payment story) and `hardship_intake_agent` (hardship brief). Each reads **reference tables only** in PostgreSQL (the merchant directory, the scam signal guide, the hardship guide), never sees the customer's identity and never changes anything. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (customer ID + passcode, staff ID + code). Before building anything like it for real customers or data,
> review and follow your own organization's security, privacy, and compliance policies and standards.

What the demo already enforces:

| Control | How |
|---|---|
| Identity + brute-force throttle | customer ID + 6-digit passcode → session token (30 min); staff ID + code → reviewer session; 5 wrong codes lock the ID for 15 min |
| Roles in the database | customer and reviewer tokens are not interchangeable — every function checks the role; saying "I'm a reviewer" in chat changes nothing |
| Rules in the database, not the prompt | guarded `INSERT…SELECT rule_fn`; the agents are read-only, read reference tables only and never receive identity |
| Per-user scoping | every read/write resolves the customer from the session token; a reviewer sees only their own team's queue |
| Two-step confirm for state changes | dispute, card block and payment: propose → explicit yes → confirm (proposals expire after 15 min; event row + trigger) |
| Scam protection | the agent's indicators are checked against Kestrel's scam signal guide and combined with the database's own checks; medium risk needs the customer to acknowledge a warning, high risk holds the payment for the fraud team |
| Human-in-the-loop for discretion | fee refund, hardship, held payments, credit limit, complaint, details change, closure, bereavement, fraud review → routed `service_cases`; a reviewer of that team decides within an approval limit (above it: blocked, needs a senior reviewer), with a required internal note; approval runs the parked action |
| Audit trail | every consequential change — sign-ins, proposals, blocks, disputes, payments, holds, cases, decisions, deferrals — is written to `agent_audit` by triggers |
| Resource limits | `rateLimit` + `tokenLimit` on the AI Agents |
| Transparency | the assistant says it is an AI when asked |
| Prompt-injection resistance | an injection cannot change state because the rules are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.7 or later.
- **PostgreSQL** 14 or later.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- An **OpenAI API key** (the apps ship set to model `gpt-5.5`; use a model your key can access — a capable
  model matches charges, merchants and scam signs more reliably).
- A **Gmail App Password** for the confirmation email (or change the SMTP settings in the MCP app).
- **Node.js** 16 or later, for the shared [Chatbot](../../../../Chatbot/) web client.

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
| `PostgreSQL.PostgresConn.Host` / `Port` / `User` / `Password` | the same values as the MCP Server (the agents only read the reference tables) |
| `PostgreSQL.PostgresConn.Database_Name` | `banking_governed` |

**`RetailBankingAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? In the Agents app set `<agent>_PORT` together with `<agent>_URL`
> (`dispute_triage_agent`, `scam_signal_agent`, `hardship_intake_agent`); in the MCP app `MCP_SERVER_PORT`; in the
> orchestrator `WebSocket_PORT` and the matching URL properties `RetailBankingMCPServer_URL`
> (`http://localhost:9862/retail-banking-mcp`) and `dispute_triage_agent_URL` / `scam_signal_agent_URL` /
> `hardship_intake_agent_URL` (`http://localhost:9863` / `9864` / `9865`).

### 3. Start the apps in this order

> **How to build and start these apps** (the same for every sample in this folder): see
> **[Running the Industry Use-Case samples »](../../../RUNNING_THE_SAMPLES.md#start-the-apps)** — the run
> prerequisites (Flogo App Build CLI + Go, or deploy to TIBCO Platform) and the exact build/run commands.
>
> Then start them in the order below, each in its own terminal:

**MCP Server (9862) → Agents (9863–9865) → Orchestrator (9860).** Wait for each to log a clean start.

### 4. Open the chat client and connect

The chat client is the shared web app in [`samples/Agentic_AI/Chatbot`](../../../../Chatbot/). It needs Node.js 16+.

```bash
cd ../../../../Chatbot
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
| James Miller | `CUST-2026-00101` | `482913` | Unrecognized `QUICKPAY*XYZ 872-555` $249.99 → agent decodes **XYZ Gadgets Online** → dispute with provisional credit + fraud review → block debit card ••1123 → email (the flagship) |
| Patricia Wilson | `CUST-2026-00108` | `641205` | "Kestrel's fraud team called — move my savings to a safe account" → the scam agent spots the signs → the $9,500 payment is **held** and the fraud team gets a case |
| Benjamin Lee | `CUST-2026-00105` | `204867` | Debit card ••3390 **already blocked**; lost his job → the hardship agent writes the brief → **hardship case** with a parked 3-payment auto-loan deferral for Financial Support |
| Olivia Davis | `CUST-2026-00102` | `730516` | `STRMPLS*MEMBERSHIP` $15.99 after canceling → **canceled subscription** dispute, no provisional credit; $35.00 overdraft fee → **fee refund** case for a person |
| Emma Johnson | `CUST-2026-00106` | `918342` | Pays her landlord as usual (confirm and send); a new crypto-exchange payee for a "20 percent a month" investment → a **warning** she must acknowledge first |
| William Garcia | `CUST-2026-00103` | `615204` | `LUXEJET TRAVEL` $1,850.00 → dispute with **no automatic provisional credit**, fraud review opened; a $6,200 payment already held for review |
| Sophia Martinez | `CUST-2026-00104` | `559371` | Open dispute **DSP-2026-0001**; a single `CAFE LUMEN` charge is **not a duplicate**; `ACME HARDWARE #212` $64.10 charged twice → valid duplicate dispute |
| Michael Brown | `CUST-2026-00107` | `377150` | Credit card ••8857 **expired** → nothing to block; a $29 late-fee refund waiting for Customer Care |

The flagship walkthrough, as James:

1. *"My customer ID is CUST-2026-00101 and my passcode is 482913."*
2. *"I don't recognize a $249.99 charge from QUICKPAY."* → the assistant explains it is **XYZ Gadgets
   Online**, an electronics web store billed through the QuickPay processor.
3. *"I never ordered anything from them, please dispute it."* → it reads back the amount, the **$249.99
   provisional credit**, the fraud review and the decision date, and asks you to confirm.
4. *"Yes, I confirm."* → dispute **DSP-…** is filed; the provisional credit is posted and the fraud team
   gets a case.
5. *"Please block my debit card ending 1123."* → it shows the card and the replacement delivery date and
   asks you to confirm → *"Yes, block it."* → the card is blocked and a replacement is ordered.
6. *"Email me the dispute confirmation."* → sent.

The scam-protection walkthrough, as Patricia (new tab):

1. *"Customer ID CUST-2026-00108, passcode 641205."*
2. *"I need to move $9,500 from my savings to the R. Hale secure holding payee I added today. Someone from
   Kestrel's fraud team called and said my account is compromised, and told me not to tell anyone at the
   branch."* → the assistant tells her the payment is **paused for a security check**, nothing has left her
   account, a fraud specialist will contact her (case ID and date), and Kestrel never asks anyone to move money to
   keep it safe. She never sees a score.

The hardship walkthrough, as Benjamin (new tab):

1. *"Customer ID CUST-2026-00105, passcode 204867."*
2. *"I lost my job last month. I start a new job in about two months, but until then I can't make my car loan
   payments."* → a **hardship case** opens with Financial Support (case ID, reply time); the assistant passes on
   Kestrel's support line and says a specialist decides — no deferral is promised.

### 6. Reviewer (human-in-the-loop)

Open a new tab and sign in as a Kestrel staff reviewer: *"I'm a Kestrel staff reviewer. My staff ID is KST-7002
and my code is 135790."*

| Reviewer | Staff ID | Code | Team | Approval limit | Try |
|---|---|---|---|---|---|
| Daniel Ortiz | `KST-7002` | `135790` | Financial Support | $5,000.00 | Benjamin's hardship case → approve the 3-payment deferral → the loan's next due date moves 3 months |
| Priya Nair | `KST-7003` | `864209` | Fraud Operations | $20,000.00 | Patricia's held payment → sees the scam indicators and signals → reject → the payment is cancelled, no money moves |
| Maya Chen | `KST-7001` | `246810` | Customer Care | $25.00 | Michael's $29 late fee → approving the full amount is **above her limit** (the case stays open for a senior reviewer); approving $20 refunds $20 |

The flow: *"Show me my queue."* → *"Open case CASE-…"* → the assistant shows the customer's statement, the facts
from Kestrel's records and the AI-prepared brief (marked as unverified) → *"Approve it in full. Internal note: … .
Message to the customer: … ."* → the assistant restates the decision and asks you to **confirm** → *"Confirm."* →
the decision is recorded and the parked action runs. Then switch back to the customer (new tab, sign in again) and
ask *"What's the status of my hardship request?"* — they see the outcome and your customer message, never your
internal note or name. A reviewer only ever sees their own team's queue; a customer who claims to be a reviewer
gets nothing without the staff code.

More prompts, including ones that show the rules holding, are in [prompts.md](prompts.md).

**Reset between demos** (run from this folder):

```bash
psql -U postgres -d banking_governed -f reset_data.sql
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The assistant never manages to verify the customer or reviewer | Use the exact IDs and codes from the tables. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it would mask the IDs and codes. |
| "I can't reach the tools" or no merchant explanation | Start the MCP Server and the Agents app **before** the orchestrator, and check the orchestrator's URL properties match their ports. |
| Wrong charge picked, scam signs missed or a weak hardship brief | Use a capable `LLM_Model` (ships as `gpt-5.5`); small models delegate to the agents unreliably. |
| An agent answers without Kestrel's wording (no merchant name, indicator names or support line) | Check the Agents app's `PostgreSQL.PostgresConn.*` properties: the agents read their reference tables from `banking_governed`. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For non-OpenAI providers, set `LLM_Base_URL`. |
| No confirmation email | Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, re-entered so it stores as `SECRET:`) and `To_Email`; confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed. |
| A new browser tab asks to verify again | Expected: each connection is a separate conversation. |
| Transaction dates look wrong, a dispute is refused as too old, or Patricia's payee is no longer "new" | Reload `reset_data.sql`. Demo dates are relative to the time you reset. |
| Verification keeps failing with "locked" | After 5 wrong codes an ID is locked for 15 minutes (brute-force throttle). Wait, or reload `reset_data.sql` in dev. |

## Rebuild from code

To regenerate these apps from code or run the automated checks, see [`_rebuild/README.md`](_rebuild/README.md).
