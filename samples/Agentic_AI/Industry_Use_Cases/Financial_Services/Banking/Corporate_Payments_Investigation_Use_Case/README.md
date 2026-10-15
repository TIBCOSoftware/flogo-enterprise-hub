> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# Banking — Corporate Payments Investigation Assistant

The **Aurelia Global Bank Corporate Payments Assistant** is a chat assistant for the corporate clients of a
fictional bank, **Aurelia Global Bank**. An authorized treasury, accounts-payable or accounts-receivable user
verifies their identity, checks a payment's status, rail, FX and fees, gets a cryptic return/reason code decoded
into plain language, raises a trace on a delayed payment in two confirmed steps, requests a recall on a wrong or
erroneous payment, applies an incoming payment to their open invoices straight from the buyer's remittance or
short-pay note, makes a new payment with a payee name check that stops payments to the wrong account, and emails
themselves the confirmation. Recalls, held payments, disputed deductions, fee waivers, compensation, suspected
fraud, sanctions queries and payment repairs go to the right team — and Aurelia staff **decide them in the same
chatbot**: a reviewer works the team queue, approves or rejects, and the approved action runs.

This pattern applies to retail, commercial and transaction-banking institutions alike: "where is my payment, why
was it returned or held, trace it, recall it, apply this short payment, and make sure we pay the right company" is
the universal payments-servicing question.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation, decodes cryptic
return-reason codes, works out which payment the client means, reads free-text remittance notes and compares
company names. PostgreSQL decides identity, scope, status, delivery estimates, eligibility, the cash-application
split, the payee name-check outcome and every state change. People decide recalls, held payments, disputed
deductions and compliance.

> Aurelia Global Bank and all clients, staff, accounts, buyers, beneficiaries and payments in this sample are
> fictional. The app uses its own database (`payments_governed`).

## Why an agent here?

| Part | Who owns it | Why |
|---|---|---|
| Decoding a cryptic return/reason code (`AC04`, `BE01`), matching the client's words to one payment, recommending trace vs recall | **AI agent** (`payment_triage_agent`) | "Our €48,500 payment to the supplier came back" has to be matched against the client's recent payments and a reason-code directory. A fixed lookup can't tell "trace a delayed payment" from "recall one sent to the wrong company". |
| Reading a free-text remittance or short-pay note ("INV 4417/4425 less 2% early pay + freight dispute $312") and matching it to open invoices with deduction reasons | **AI agent** (`remittance_match_agent`) | Buyers write remittances in their own shorthand. Turning that into "invoices 4417 and 4425, early-pay discount, freight deduction of $312" is reading, not lookup. |
| Comparing the beneficiary name the client typed with the account name on file ("ACME Corp" vs "Acme Corporation Ltd") | **AI agent** (`payee_name_match_agent`) | Legal-form words, abbreviations, accents and trading names make exact string matching useless; a person-like comparison with clear reasons is needed. |
| Understanding the request, explaining outcomes, chaining the steps | **AI agent** (orchestrator) | Conversation, ambiguity, multi-step planning across tools. |
| Who the client is and which payments, invoices and cases they can see | **Deterministic** (session token, scoped reads) | A model must not be able to talk its way into another company's payments. |
| Payment status, rail, FX, fees, delivery estimate, trace eligibility, the write | **Deterministic, two-step** (`propose_trace` → `confirm_trace`) | Settlement dates come from `cutoff_rules` arithmetic, never guessed. |
| Which invoices are paid, the early-pay discount actually earned, what is disputed | **Deterministic, two-step** (`propose_cash_application` → `confirm_cash_application`) | SQL checks the agent's invoices are the client's open invoices, keeps only known deduction reasons, computes the discount from the invoice terms and writes off small differences within a tolerance. |
| Whether a new payment can go, needs a warning or is held | **Deterministic, two-step** (`propose_payment` → `confirm_payment`) | SQL combines the agent's verdict with its own name score (built from the same rule table) and the amount: MATCH goes ahead, a close match needs the client's acknowledgement, a mismatch or a large close match is held. |
| Recalls, held payments, disputed deductions over the tolerance, fee waivers | **Human** (reviewer loop: queue → case → decide) | A person decides; approval runs the parked action (recall, payment release, deduction write-off, fee refund) through the same database checks, within the reviewer's approval limit. |
| Compensation, fraud, sanctions queries, payment repair | **Human** (`review_cases` → `service_teams`) | Discretion and accountability. Money and compliance are not an assistant's call. |

The agents are given only what they need: the client's words and the candidate payments; the remittance note, the
incoming amount and the candidate invoices; or just the two company names. They never receive the client's legal
name, client ID, account numbers, contact details or session.

## Architecture

```
Chat UI ──WebSocket :9870 /corporatepayments──► CorporatePaymentsAIOrchestrator  (AI Agent)
                                                  │
                  MCP :9872 ◄─────────────────────┤──────────────► A2A :9873–9875
                  CorporatePaymentsMCPServer       │               CorporatePaymentsAgents
                  22 governed tools                │               payment_triage_agent · remittance_match_agent
                  (client + reviewer)              │               · payee_name_match_agent
                          └────────────────► PostgreSQL `payments_governed` ◄──┘
                     rule functions · triggers · service teams · reviewers · agent reference tables · SMTP (email tool)
```

| App | Port / path | What it does |
|---|---|---|
| `CorporatePaymentsAIOrchestrator.flogo` | WebSocket `9870` `/corporatepayments` | The assistant clients and staff reviewers chat with. Each browser connection is its own conversation. |
| `CorporatePaymentsMCPServer.flogo` | MCP `9872` `/corporate-payments-mcp` | 22 governed tools: verify, payments, status, timeline, delivery estimate, propose/confirm trace, propose/confirm recall, open invoices, propose/confirm cash application, payee account check, propose/confirm payment, open review case, cases, email confirmation, and the four reviewer tools (verify reviewer, queue, case, decide). |
| `CorporatePaymentsAgents.flogo` | A2A `9873`, `9874`, `9875` | Three read-only agents. `payment_triage_agent` decodes the return/reason code and recommends a trace, recall or human review. `remittance_match_agent` matches a remittance note to open invoices and names the deduction reasons. `payee_name_match_agent` compares the typed beneficiary name with the name on file. Each reads only its own reference table in PostgreSQL (reason codes, the cash-application guide, the payee name-check rules); none sees the client's identity or writes anything. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (client ID + passcode, staff ID + code). Before building anything like it for real customers or data,
> review and follow your own organization's security, privacy, and compliance policies and standards.

What the demo already enforces:

| Control | How |
|---|---|
| Identity + brute-force throttle | client ID + 6-digit passcode → session token (30 min); 5 wrong passcodes lock the client ID for 15 min. Staff reviewers sign in the same way with a staff ID + code |
| Two roles, checked in SQL | client and reviewer tokens are not interchangeable; the role comes only from the verify result, never from what someone says in chat |
| Rules in the database, not the prompt | guarded `INSERT…SELECT rule_fn`; the agents are read-only and never receive identity |
| Per-client scoping | every read and write resolves the client from the session token; one client can never see or act on another's payment, invoice or case |
| Two-step confirm for state changes | trace, recall, cash application and new payment: propose → explicit yes → confirm (proposals expire after 15 min; event row + trigger) |
| Agent output validated in SQL | invoice matches must be the client's open invoices, unknown deduction reasons are ignored, the early-pay discount is recomputed from the terms; the payee verdict is combined with SQL's own name score and can never upgrade a weak match |
| Human-in-the-loop for money & compliance | recalls, held payments, disputed deductions and fee waivers are decided by a staff reviewer of the routed team, within their approval limit; approving runs the parked action through the same checks, rejecting runs nothing (or cancels the held payment / declines the recall) |
| Deterministic delivery estimates | settlement dates come from `cutoff_rules` arithmetic (rail + currency, business-day aware), never guessed by the model |
| Audit trail | every consequential change (including each reviewer decision) is written to `agent_audit` by triggers |
| Resource limits | `rateLimit` + `tokenLimit` on the AI Agents |
| Transparency | the assistant says it is an AI when asked |
| Prompt-injection resistance | an injection cannot change state because the rules are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.7 or later.
- **PostgreSQL** 14 or later.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- An **OpenAI API key** (the apps ship set to model `gpt-5.5`; use a model your key can access — a capable
  model decodes reason codes, reads remittance notes and compares names more reliably).
- A **Gmail App Password** for the confirmation email (or change the SMTP settings in the MCP app).
- **Node.js** 16 or later, for the shared [Chatbot](../../../../Chatbot/) web client.

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
| ⚠️ `PostgreSQL.PostgresConn.Host` / `Port` / `User` | the same server as the MCP Server — the agents read their reference tables only |
| ⚠️ `PostgreSQL.PostgresConn.Password` | your PostgreSQL password |
| ⚠️ `PostgreSQL.PostgresConn.Database_Name` | `payments_governed` |

**`CorporatePaymentsAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? Update the port property (`MCP_SERVER_PORT`; `payment_triage_agent_PORT`,
> `remittance_match_agent_PORT`, `payee_name_match_agent_PORT` together with their `_URL` properties;
> `WebSocket_PORT`) **and** the matching URL properties in the orchestrator: `CorporatePaymentsMCPServer_URL`
> (`http://localhost:9872/corporate-payments-mcp`) and the three `<agent>_URL` properties
> (`http://localhost:9873`, `9874`, `9875`).

### 3. Start the apps in this order

**MCP Server (9872) → Agents (9873–9875) → Orchestrator (9870).** Wait for each to log a clean start.

### 4. Open the chat client and connect

The chat client is the shared web app in [`samples/Agentic_AI/Chatbot`](../../../../Chatbot/). It needs Node.js 16+.

```bash
cd ../../../../Chatbot
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
| Northwind Manufacturing | `CLI-2026-00101` | `486201` | €48,500 SEPA **RETURNED** → agent decodes **AC04 (account closed)**; $250,000 SWIFT **IN_TRANSIT** → trace → investigation + email (the flagship); Harbor Retail Group paid **$46,728** with a short-pay note → **cash application** with a $312 freight deduction for review |
| Helios Trading | `CLI-2026-00102` | `730955` | $780,000 SWIFT to the **wrong beneficiary** → two-step **recall** → Payment Operations case; $54,000 **HELD** (sanctions) → **SANCTIONS_QUERY** case for a person |
| Veridian Foods | `CLI-2026-00103` | `615338` | €56,000 **INCOMING** → recall refused **NOT_RECALLABLE**; a $45 ACH fee → **FEE_WAIVER** case parked for Client Servicing |
| Bramwell Logistics | `CLI-2026-00104` | `904177` | Pays **ACME Corp** $185,000 → name on file *Acme Corporation Ltd* → **MATCH** → payment submitted; "new bank details" for **Rotterdam Shipping BV** → account is *RD Global Trading LLC* → **NO_MATCH** → payment **held** for Payment Operations |

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
6. *"We received $46,728 from Harbor Retail Group yesterday with this remittance note: 'INV 4417/4425 less 2%
   early pay + freight dispute $312'. Please apply it."* → the assistant reads the note with the remittance agent
   and proposes: invoices **4417 and 4425** ($48,000.00), early-pay discount **earned $960.00**, freight deduction
   **$312.00 sent to Client Servicing for review**. On *"Yes, apply it."* invoice 4417 is paid, 4425 stays open for
   $312.00, and a review case is opened.
7. Open a new tab, sign in as Bramwell (`CLI-2026-00104` / `904177`) and say *"Rotterdam Shipping BV emailed us
   new bank details: account 7781200456. Please pay their $96,500 invoice from our USD account."* → the name on
   that account is **RD Global Trading LLC**; the assistant tells you the payment is **paused for a payee check**,
   gives the case ID and when Payment Operations will contact you, and asks you not to send the money another way.
   Nothing leaves the account. (Paying *"ACME Corp $185,000 to account 4410028811"* instead goes through: the name
   on file is Acme Corporation Ltd, a match.)

### 6. Reviewer (human-in-the-loop)

Open a new tab and sign in as an Aurelia staff reviewer: *"I'm an Aurelia staff reviewer in Client Servicing.
My staff ID is AGB-5003 and my code is 615920."*

| Reviewer | Staff ID | Code | Team | Approval limit | Try |
|---|---|---|---|---|---|
| Sofia Alvarez | `AGB-5003` | `615920` | Client Servicing | $2,500.00 | Northwind's $312 freight deduction → approve in full → the deduction is written off and invoice 4425 closes. Helios's **$3,150** damaged-goods deduction (`CASE-00004`) is **above her limit**: the case stays open for a senior reviewer. Bramwell's $40 SWIFT fee waiver → approve → the fee is refunded |
| Marcus Webb | `AGB-5002` | `739104` | Payment Operations | $2,000,000.00 | Bramwell's held payment to RD Global Trading → reject → the payment is cancelled, no money moves. Northwind's $310,000 duplicate-payment recall (`CASE-00001`) → approve → the payment is recalled |
| Elena Park | `AGB-5001` | `482615` | Payment Operations | $250,000.00 | The $310,000 recall is **above her limit** (OVER_AUTHORITY). Veridian's held $42,500 payment to Pacific Rim (`CASE-00002`, a close-match name) → approve → the payment is released |

The flow: *"Show me my queue."* → *"Open case CASE-…"* → the assistant shows the client's statement, the facts
from Aurelia's records (the payment, the name check, or the cash application and its deductions) and the
AI-prepared brief (marked as unverified) → *"Approve it in full. Internal note: … . Message to the client: … ."* →
the assistant restates the decision and asks you to **confirm** → *"Confirm."* → the decision is recorded and the
parked action runs. Then switch back to the client (new tab, sign in again) and ask *"What's the status of the
freight deduction on the Harbor Retail payment?"* — they see the outcome and your client message, never your
internal note or name. A reviewer only ever sees their own team's queue; a client who claims to be a reviewer gets
nothing without the staff code.

More prompts — including ones that show the rules holding (cross-client refusal, confirm without a proposal,
a recall that is too old, a trace that is too soon, an invoice that is not yours, a close-match warning, prompt
injection, lockout) — are in [prompts.md](prompts.md).

**Reset between demos** (run from this folder):

```bash
psql -U postgres -d payments_governed -f reset_data.sql
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The assistant never manages to verify the client or reviewer | Use the exact ID and code from the tables. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it would mask the IDs and codes. |
| "I can't reach the tools" or no decoded return reason / remittance match / name check | Start the MCP Server and the Agents app **before** the orchestrator, check the orchestrator's URL properties match their ports, and set the Agents app's PostgreSQL properties (the agents read their reference tables from the database). |
| Weak decoding, the wrong invoices picked, or an odd name verdict | Use a capable `LLM_Model` (ships as `gpt-5.5`); small models delegate to the agents unreliably. The database still validates every agent answer. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For non-OpenAI providers, set `LLM_Base_URL`. |
| No confirmation email | Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, re-entered so it stores as `SECRET:`) and `To_Email`; confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed. |
| A new browser tab asks the client to verify again | Expected: each connection is a separate conversation. |
| Payment dates, invoice early-pay windows or delivery estimates look wrong, or a trace/recall is refused as too old or too soon | Reload `reset_data.sql`. Demo dates are relative to today. |
| A reviewer's queue is empty or a decision says ALREADY_DECIDED | Reload `reset_data.sql`; each team starts with two open cases. |
| Verification keeps failing with "locked" | After 5 wrong passcodes (or staff codes) the ID is locked for 15 minutes. Wait, or `TRUNCATE verify_attempts, reviewer_verify_attempts;` in dev. |

## Rebuild from code

To regenerate these apps from code or run the automated checks, see [`_rebuild/README.md`](_rebuild/README.md).
