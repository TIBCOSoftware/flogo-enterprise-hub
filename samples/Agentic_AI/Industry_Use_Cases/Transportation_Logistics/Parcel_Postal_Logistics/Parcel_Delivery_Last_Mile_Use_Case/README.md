# Logistics — Parcel Delivery Assistant

The **Swiftbound Parcel Delivery Assistant** is a chat assistant for the recipients of a fictional last-mile
parcel carrier, **Swiftbound**, and for the Swiftbound staff who decide their claims. A recipient verifies their
account, tracks a parcel, hears what a cryptic delivery exception actually means, gets agent-ranked delivery options
for a missed delivery, reschedules onto a new slot or redirects to a pickup point in two confirmed steps, saves
delivery instructions (a safe place, a gate code, a dog in the yard) and opens a claim for a damaged, incomplete or
lost parcel. A Swiftbound claims reviewer then works the claim in the same chatbot: they see the queue, open the case,
approve or reject it within their approval limit, and the approved compensation is paid automatically.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation, ranks delivery options,
turns a damage description into claim facts and turns free-text access notes into structured instructions.
PostgreSQL decides identity, delivery status, eligibility, the claimable amount, which safe places are allowed and
every change. People decide the claims.

> Swiftbound and all recipients, staff, parcels, slots and pickup points in this sample are fictional.
> The app uses its own database (`parcel_delivery`).

## Why an agent here?

| Part | Who owns it | Why |
|---|---|---|
| Ranking delivery options against free-text preferences ("I'm away till Friday, prefer an evening slot or a locker near the office") | **AI agent** (`delivery_options_agent`) | Free-text constraints weighed against a structured list of valid slots and pickup points, with trade-offs. A fixed sort can't read "evenings only, near work". |
| Turning "box crushed on one corner, laptop screen cracked, outer tape intact" into a claim type, packaging condition, likely cause and the evidence to send | **AI agent** (`damage_claim_agent`) | Free-text damage descriptions mapped onto Swiftbound's claim categories. The terms come from Swiftbound's claim guide table, and SQL checks them. |
| Turning "leave behind the blue side gate, code 4521, dog in the yard, not on the porch" into a safe place, an access-code flag (the code is masked), hazards and risky-instruction flags | **AI agent** (`delivery_instructions_agent`) | Free text with negations, codes and hazards mapped onto Swiftbound's allowed safe places. SQL checks the place, scans for risky phrases itself and never stores the code. |
| Understanding the request, explaining outcomes, chaining the steps | **AI agent** (orchestrator) | Conversation, ambiguity, multi-step planning across tools. |
| Who the recipient or reviewer is and what they can see | **Deterministic** (`session_recipient` / `session_reviewer`) | A model must not be able to talk its way into someone else's parcels, or into the staff role. |
| What a tracking exception code means, and whether a parcel is late | **Deterministic lookup / arithmetic** (`exception_codes`, `delivery_health`) | The meaning of `NSH`/`DMG`/`CUS` and ON_TRACK / NEEDS_ATTENTION / LATE come from the data — never invented by the model. |
| Reschedule & redirect eligibility, capacity, the write | **Deterministic, two-step** (`reschedule_eval` / `redirect_eval` → `pending_actions` → `delivery_changes` + trigger) | The recipient confirms an exact change; the database applies it atomically and re-checks the rules. A signature-required or high-value parcel can never go to an unattended locker. |
| Delivery instructions: which safe places are allowed, risky instructions, signature and high-value parcels | **Deterministic, two-step** (`instructions_eval` → `pending_actions` → `delivery_instructions` + trigger) | "Leave it on the street" or "with any neighbour" is refused; a signature parcel can only be handed over; a high-value parcel only goes to an attended place. |
| Whether a claim can be opened and how much is claimable | **Deterministic** (`claim_eval` / `claim_row_for`) | Only the recipient's own parcel, the right delivery status, within 30 days of delivery, one open claim per parcel; the amount is capped at the declared value and Swiftbound's coverage limit. |
| Compensation, wrong deliveries, complaints | **Human** (`service_cases` → `service_teams` → a reviewer's decision) | Discretion and accountability. A claims reviewer approves or rejects within their approval limit; the system pays the approved amount. |

Without the AI, tracking, rescheduling and claims still work through forms. What you would lose is reading free
text — "I won't be in until the weekend", "the screen is cracked but the tape was intact", "behind the side gate, not
on the porch" — and knowing what it means in Swiftbound's terms. That is what the three agents are for. They are
given only the parcel facts and the recipient's own words — never the recipient's name, account reference, address or
tracking number.

## Architecture

```
Chat UI ──WebSocket :9890 /parceldelivery──► ParcelDeliveryAIOrchestrator  (AI Agent)
                                              │
              MCP :9892 ◄─────────────────────┤──────────────► A2A :9893 / :9894 / :9896
              ParcelDeliveryMCPServer         │               ParcelDeliveryAgents
              18 governed tools               │               delivery_options_agent · damage_claim_agent
                      │                       │               delivery_instructions_agent
                      └────────────► PostgreSQL `parcel_delivery` ◄──┘ (agents: reference tables only)
                                     rule functions · triggers · service teams · reviewers · Gmail SMTP (email tool)
```

| App | Port / path | What it does |
|---|---|---|
| `ParcelDeliveryAIOrchestrator.flogo` | WebSocket `9890` `/parceldelivery` | The assistant recipients and reviewers chat with. Each browser connection is its own conversation. |
| `ParcelDeliveryMCPServer.flogo` | MCP `9892` `/parcel-delivery-mcp` | 18 governed tools: verify, list parcels, parcel detail, tracking history, propose/confirm reschedule, propose/confirm redirect, propose/confirm delivery instructions, open damage claim, email confirmation, open service case, list cases, and the four reviewer tools (verify reviewer, review queue, review case, decide case). |
| `ParcelDeliveryAgents.flogo` | A2A `9893`, `9894`, `9896` | Three read-only agents. Each one reads a PostgreSQL **reference table** with no personal data: `delivery_options_agent` (feasible slots and pickup points), `damage_claim_agent` (Swiftbound's claim guide), `delivery_instructions_agent` (allowed safe places, risky-instruction flags, hazards). They never see the recipient's identity and never write. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (account reference + PIN, staff ID + code). Before building anything like it for real recipients or data,
> review and follow your own organization's security, privacy, and compliance policies and standards.

What the demo already enforces:

| Control | How |
|---|---|
| Identity + brute-force throttle | account reference + PIN → session token; 5 wrong PINs lock an account for 15 min. Staff: staff ID + code → a REVIEWER token, with the same lockout |
| Two roles that can't be swapped | recipient and reviewer tokens are not interchangeable; every rule function checks the role. Saying "I'm a reviewer" changes nothing |
| Rules in the database, not the prompt | guarded `INSERT…SELECT rule_fn`; the A2A agents are read-only, never receive identity, and SQL validates their output against the same reference tables |
| Per-user and per-team scoping | every read/write resolves the recipient from the session token; reviewers see only their own team's queue |
| Two-step confirm for state changes | reschedule, redirect and delivery instructions: propose → explicit yes → confirm (event row + trigger) |
| Guardrails that can't be talked past | signature-required / high-value parcels can't go to an unattended locker or safe place; risky instructions are refused (agent flags **and** a SQL phrase scan); access codes are masked and never stored; claimable amounts are capped in SQL |
| Human-in-the-loop for discretion | claims open a case parked for the right Claims team; the reviewer's decision (with a required internal note) executes the compensation payment; amounts above the reviewer's approval limit are blocked and stay open for a senior reviewer |
| Audit trail | every consequential change — sessions, proposals, changes, claims, decisions, payments — is written to `agent_audit` by triggers |
| Resource limits | `rateLimit` + `tokenLimit` on the AI Agents |
| Transparency | the assistant says it is an AI when asked |
| Prompt-injection resistance | an injection cannot change state because the rules are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.7 or later.
- **PostgreSQL** 14 or later.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- An **OpenAI API key** (the apps ship set to model `gpt-5.5`; use a model your key can access — a capable
  model gives better results from the three agents).
- A **Gmail App Password** for the confirmation email (or change the SMTP settings in the MCP app).
- **Node.js** 16 or later, for the shared [Chatbot](../../../../Chatbot/) web client.

## Steps to run

### 1. Create the database

```bash
createdb -U postgres parcel_delivery
psql -U postgres -d parcel_delivery -f database.sql
```

### 2. ⚠️ Configure the apps — these are NOT configured in the shipped files

Open each `.flogo` in VS Code and set these **App Properties**:

**`ParcelDeliveryMCPServer.flogo`**

| Property | Set to |
|---|---|
| `PostgreSQL.PostgresConn.Host` / `Port` / `User` | your PostgreSQL server (default `localhost` / `5432` / `postgres`) |
| `PostgreSQL.PostgresConn.Password` | your PostgreSQL password |
| `PostgreSQL.PostgresConn.Database_Name` | `parcel_delivery` |
| `Email_Username` | the Gmail address that sends the confirmation |
| `Email_App_Password` | your Gmail **App Password** — re-enter it in App Properties so it stores as a `SECRET:` (keep the property type `string`) |
| `To_Email` | the operations inbox that receives confirmations |

**`ParcelDeliveryAgents.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` | your LLM API key |
| `AgenticAI.OpenAIConn.LLM_Provider` / `LLM_Base_URL` | `OpenAI` / leave empty for OpenAI, or your provider's endpoint |
| `LLM_Model` | a model your key can use (ships as `gpt-5.5`) |
| ⚠️ `PostgreSQL.PostgresConn.Host` / `Port` / `User` | the same PostgreSQL server as the MCP Server (the agents read their reference tables) |
| ⚠️ `PostgreSQL.PostgresConn.Password` | your PostgreSQL password |
| ⚠️ `PostgreSQL.PostgresConn.Database_Name` | `parcel_delivery` |

**`ParcelDeliveryAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? Update the port property (`MCP_SERVER_PORT`, `delivery_options_agent_PORT`,
> `damage_claim_agent_PORT`, `delivery_instructions_agent_PORT`, `WebSocket_PORT`) **and** the matching URL
> property in the orchestrator (`ParcelDeliveryMCPServer_URL`, `delivery_options_agent_URL`,
> `damage_claim_agent_URL`, `delivery_instructions_agent_URL`).

### 3. Start the apps in this order

**MCP Server (9892) → Agents (9893, 9894, 9896) → Orchestrator (9890).** Wait for each to log a clean start.
Port 9890 is also used by another sample (`Feature_Samples/Agent-Privilege-IDs/no-mcp`), so don't run both at once.

### 4. Open the chat client and connect

The chat client is the shared web app in [`samples/Agentic_AI/Chatbot`](../../../../Chatbot/). It needs Node.js 16+.

```bash
cd ../../../../Chatbot
npm install    # first time only
npm start
```

1. Open **http://localhost:3000**.
2. In the URL box at the top right, enter **`ws://localhost:9890/parceldelivery`**.
3. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
4. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. Make sure the orchestrator
is running on port 9890. The chatbot remembers the last URL you applied, so a URL from another demo is a
common cause.

### 5. Run the demo

Sign in as one of the demo recipients (in production the app would already know them; here they type their
account reference and the 4-digit PIN from the Swiftbound app / delivery notification).

| Recipient | Account ref | PIN | What they show |
|---|---|---|---|
| Emma Carter | `K4R2QX` | `4021` | Headphones `SB100000000001` had a **failed delivery** → agent-ranked options → reschedule; watch / console → locker and safe-place guards |
| Olivia Grant | `M2P7VB` | `6150` | Laptop `SB100000000011` arrived **damaged** → the claim agent → a claim for $1,000.00 (capped at the coverage limit) → a claims reviewer decides |
| Sofia Ramirez | `T8J4NC` | `2468` | Garden tools `SB100000000009` → **delivery instructions** (side gate, code masked, dog); smartphone `SB100000000010` needs a signature, so "leave it on the street" is refused |
| Liam Walsh | `W7M9PL` | `7788` | Office chair `SB100000000003` is **too big for a locker**; grocery box is **out for delivery** |
| Noah Reyes | `D3H8TN` | `5590` | Books already **delivered**; ceramic vase **damaged in transit** → a claim capped at its declared value |

The flagship walkthroughs:

**Emma — missed delivery**
1. *"My account reference is K4R2QX and my PIN is 4021."*
2. *"What's going on with my headphones parcel SB100000000001?"* → a failed-delivery exception, explained.
3. *"Find me a delivery option — I'd prefer an evening slot this week."* → the agent ranks the evening slot.
4. *"Reschedule SB100000000001 to SLOT-N1."* → it shows the new slot and asks you to confirm.
5. *"Yes, I confirm."* → the reschedule is made. *"Email me the confirmation."* → sent.

**Olivia — damaged laptop**
1. *"Account reference M2P7VB, PIN 6150."*
2. *"My laptop parcel SB100000000011 came yesterday. The box was crushed on one corner, the laptop screen is cracked,
   and the outer tape was intact. I want to claim the full value."* → the claim agent classifies it (DAMAGED, CRUSHED),
   the claim opens for $1,000.00 (Swiftbound's coverage limit, below the $1,180 declared value) and the assistant lists
   the evidence to send. It does not promise any compensation.

**Sofia — delivery instructions**
1. *"Account reference T8J4NC, PIN 2468."*
2. *"For my garden tools parcel SB100000000009: leave it behind the blue side gate, code 4521, dog in the yard, not on
   the porch."* → safe place SIDE_GATE, hazard DOG, the code shown as *[code withheld]*. *"Yes, save them."* → saved;
   the code is stored nowhere.
3. *"And for my smartphone SB100000000010, just leave it on the street by the mailbox."* → refused.

### 6. Reviewer (human-in-the-loop)

Open a new tab and sign in as a Swiftbound staff reviewer: *"I'm a Swiftbound staff reviewer in Claims. My staff ID
is SWB-4101 and my code is 418302."*

| Reviewer | Staff ID | Code | Team | Approval limit | Try |
|---|---|---|---|---|---|
| Hannah Brooks | `SWB-4101` | `418302` | Claims (damaged parcels) | $500.00 | Olivia's $1,000.00 laptop claim → approving it is **above her limit** (the case stays open for a senior reviewer); the camera-lens claim → approve $400 |
| Victor Osei | `SWB-4102` | `905127` | Claims (damaged parcels) | $2,500.00 | Olivia's laptop claim → approve in full → $1,000.00 compensation is paid |
| Mei Tanaka | `SWB-4103` | `336914` | Claims (missing contents) | $750.00 | A missing face-serum claim → approve or reject |
| Daniel Ruiz | `SWB-4104` | `772049` | Claims (lost parcels) | $1,500.00 | Overdue hiking boots → approve the $160.00 lost-parcel claim |
| Grace Mensah | `SWB-4105` | `260581` | Investigations | $300.00 | A desk lamp left at the wrong house → approve (no automatic payment; the team completes it) |
| Owen Fitzgerald | `SWB-4106` | `649273` | Customer Relations | $250.00 | A complaint about a parcel left in view of the street |

The flow: *"Show me my queue."* → *"Open case SC-…"* → the assistant shows the recipient's statement, the facts from
Swiftbound's records (declared value, coverage limit, packaging, likely cause, earlier claims) and the AI-prepared
brief (marked as unverified) → *"Approve it in full. Internal note: … . Message to the recipient: … ."* → the
assistant restates the decision and asks you to **confirm** → *"Confirm."* → the decision is recorded and the
compensation is paid. Then switch back to the recipient (new tab, sign in again) and ask *"What's the status of my
laptop claim?"* — they see the outcome and your message, never your internal note or name. A reviewer only ever sees
their own team's queue; a recipient who claims to be a reviewer gets nothing without the staff code.

More prompts, including ones that show the rules holding, are in [prompts.md](prompts.md).

**Reset between demos:**

```bash
psql -U postgres -d parcel_delivery -f reset_data.sql
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The assistant never manages to verify the recipient or reviewer | Use the exact codes from the tables. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it would mask the account reference, PIN and staff code. |
| "I can't reach the tools" or no agent results | Start the MCP Server and the Agents app **before** the orchestrator, and check the orchestrator's URL properties match their ports. |
| An agent answers without Swiftbound's terms, or its tool fails | Set the Agents app's `PostgreSQL.PostgresConn.*` properties (the agents read their reference tables from `parcel_delivery`) and click **Connect** on its PostgreSQL connection. |
| Weak or no agent suggestions | Use a capable `LLM_Model` (ships as `gpt-5.5`); small models delegate to agents unreliably. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For non-OpenAI providers, set `LLM_Base_URL`. |
| No confirmation email | Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, re-entered so it stores as `SECRET:`) and `To_Email`; confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed. |
| A reviewer's approval is refused as above their limit | Expected: the case stays open for a reviewer with a higher limit (try Victor Osei). |
| A new browser tab asks to verify again | Expected: each connection is a separate conversation. |
| Parcel dates or statuses look wrong | Reload `reset_data.sql`. Demo dates are relative to today. |
| Verification keeps failing with "locked" | After 5 wrong PINs or staff codes the login is locked for 15 minutes (brute-force throttle). Wait, or reload `reset_data.sql` in dev. |

## Rebuild from code

To regenerate these apps from code or run the automated checks, see [`_rebuild/README.md`](_rebuild/README.md).
