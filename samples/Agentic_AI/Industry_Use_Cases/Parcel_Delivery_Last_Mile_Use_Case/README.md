# Parcel Delivery — Swiftbound Last-Mile Assistant

A chat assistant for a parcel carrier's recipients (fictional last-mile carrier **Swiftbound**). A recipient
verifies their account, tracks a parcel, hears what a cryptic delivery exception actually means, gets
agent-ranked delivery options for a missed delivery, reschedules onto a new slot or redirects to a pickup
point in two confirmed steps, and emails themselves the confirmation. Lost-parcel, damaged-parcel,
missing-contents, wrong-delivery and complaint requests go to the right team — the assistant never decides
them and never promises compensation.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation and ranks delivery
options against the recipient's preferences. PostgreSQL decides identity, delivery status, eligibility,
capacity and every change. People decide the claims.

> Swiftbound and all recipients, parcels, slots and pickup points in this sample are fictional.
> The app uses its own database (`parcel_delivery`). An earlier, ungoverned shipper-focused logistics demo
> is kept under [`Industry_Use_Cases_old/Logistics_Transport_Use_Case/`](../../Industry_Use_Cases_old/Logistics_Transport_Use_Case/).

## Why an agent here?

| Part | Who owns it | Why |
|---|---|---|
| Ranking delivery options against free-text preferences ("I'm away till Friday, prefer an evening slot or a locker near the office") | **AI agent** (`delivery_options_agent`) | Free-text constraints weighed against a structured list of valid slots and pickup points, with trade-offs. A fixed sort can't read "evenings only, near work". |
| Understanding the request, explaining outcomes, chaining the steps | **AI agent** (orchestrator) | Conversation, ambiguity, multi-step planning across tools. |
| Who the recipient is and which parcels they can see | **Deterministic** (`session_recipient`) | A model must not be able to talk its way into someone else's parcels. |
| What a tracking exception code means, and whether a parcel is late | **Deterministic lookup / arithmetic** (`exception_codes`, `delivery_health`) | The meaning of `NSH`/`DMG`/`CUS` and ON_TRACK / NEEDS_ATTENTION / LATE come from the data — never invented by the model. |
| Reschedule & redirect eligibility, capacity, the write | **Deterministic, two-step** (`reschedule_eval` / `redirect_eval` → `pending_actions` → `delivery_changes` + trigger) | The recipient confirms an exact change; the database applies it atomically and re-checks the rules. A signature-required or high-value parcel can never go to an unattended locker. |
| Lost, damaged, missing-contents, wrong-delivery, complaints | **Human** (`service_cases` → `service_teams`) | Discretion and accountability. Compensation and liability are not an assistant's call. |

Without the AI, tracking, rescheduling and redirecting still work through a form. What you would lose is
reading "I won't be in until the weekend, somewhere near the station is fine" and knowing which slot or
pickup point that means. That is the part the agent is for. The agent is given only the parcel's area, size
and constraints and the preferences — never the recipient's name, account reference or address.

## Architecture

```
Chat UI ──WebSocket :9890 /parceldelivery──► ParcelDeliveryAIOrchestrator  (AI Agent)
                                              │
              MCP :9892 ◄─────────────────────┤──────────────► A2A :9893
              ParcelDeliveryMCPServer       │               ParcelDeliveryAgents
              11 governed tools                │               delivery_options_agent
                      └────────────► PostgreSQL `parcel_delivery` ◄──┘
                                     rule functions · trigger · service teams · Gmail SMTP (email tool)
```

| App | Port / path | What it does |
|---|---|---|
| `ParcelDeliveryAIOrchestrator.flogo` | WebSocket `9890` `/parceldelivery` | The assistant the recipient chats with. Each browser connection is its own conversation. |
| `ParcelDeliveryMCPServer.flogo` | MCP `9892` `/parcel-delivery-mcp` | 11 governed tools: verify, list parcels, parcel detail, tracking history, propose/confirm reschedule, propose/confirm redirect, email confirmation, open service case, list cases. |
| `ParcelDeliveryAgents.flogo` | A2A `9893` | `delivery_options_agent`: ranks delivery slots and pickup points from the area + constraints + preferences. It never sees the recipient's identity. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (account reference + PIN). Before building anything like it for real recipients or data, review
> and follow your own organisation's security, privacy, and compliance policies and standards.

What the demo already enforces:

| Control | How |
|---|---|
| Identity + brute-force throttle | account reference + PIN → session token; 5 wrong PINs lock an account for 15 min (`verify_attempts`) |
| Rules in the database, not the prompt | guarded `INSERT…SELECT rule_fn`; the A2A agent is read-only and never receives identity |
| Per-user scoping | every read/write resolves the recipient from the session token |
| Two-step confirm for state changes | `propose_reschedule` / `propose_redirect` → explicit yes → `confirm_*` (event row + trigger) |
| Guardrails that can't be talked past | signature-required / high-value parcels can't go to an unattended locker; oversize parcels can't go to a locker; slots are area- and capacity-scoped |
| Human-in-the-loop for discretion | lost / damaged / missing-contents / wrong-delivery / complaint → routed `service_cases` |
| Audit trail | every consequential change is written to `agent_audit` by triggers (query it by `account_ref` / `action`) |
| Resource limits | `rateLimit` + `tokenLimit` on the AI Agents |
| Transparency | the assistant says it is an AI when asked |
| Prompt-injection resistance | an injection cannot change state because the rules are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.6 or later.
- **PostgreSQL** 14 or later.
- An **OpenAI API key** (the apps ship set to model `gpt-5.5`; use a model your key can access — a capable
  model gives better delivery-option suggestions).
- A **Gmail App Password** for the confirmation email (or change the SMTP settings in the MCP app).
- **Node.js** 16 or later, for the shared [Chatbot](../../Chatbot/) web client.

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
| `PostgreSQL.PostgresConn.*` | the same values as the MCP Server |

**`ParcelDeliveryAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? Update the port property (`MCP_SERVER_PORT`, `delivery_options_agent_PORT`,
> `WebSocket_PORT`) **and** the matching connection URL in the orchestrator:
> `http://localhost:9892/parcel-delivery-mcp` (MCP) and `http://localhost:9893` (A2A).

### 3. Start the apps in this order

**MCP Server (9892) → Agents (9893) → Orchestrator (9890).** Wait for each to log a clean start.

### 4. Test it in the chatbot

The chat client is the shared web app in [`samples/Agentic_AI/Chatbot`](../../Chatbot/). It needs Node.js 16+.

```bash
cd ../../Chatbot
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
| Emma Carter | `K4R2QX` | `4021` | Headphones `SB100000000001` had a **failed delivery** → reschedule; watch / console → locker guards |
| Liam Walsh | `W7M9PL` | `7788` | Office chair `SB100000000003` is **too big for a locker**; grocery box is **out for delivery** |
| Noah Reyes | `D3H8TN` | `5590` | Books already **delivered**; ceramic vase arrived **damaged** → a claim for a person |

The flagship walkthrough, as Emma:

1. *"My account reference is K4R2QX and my PIN is 4021."*
2. *"What's going on with my headphones parcel SB100000000001?"* → a failed-delivery exception, explained.
3. *"Find me a delivery option — I'd prefer an evening slot this week."* → the agent ranks the evening slot.
4. *"Reschedule SB100000000001 to SLOT-N1."* → it shows the new slot and asks you to confirm.
5. *"Yes, I confirm."* → the reschedule is made.
6. *"Email me the confirmation."* → sent.
7. *"My vase arrived smashed — I want compensation."* (as Noah) → a case goes to Claims; the assistant does
   not decide it.

More prompts, including ones that show the rules holding, are in [prompts.md](prompts.md).

**Reset between demos:**

```bash
psql -U postgres -d parcel_delivery -f reset_data.sql
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The assistant never manages to verify the recipient | Use the exact account reference and PIN from the table. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it would mask the account reference and PIN. |
| "I can't reach the tools" or no delivery-option suggestions | Start the MCP Server and the Agents app **before** the orchestrator, and check the orchestrator's connection URLs match their ports. |
| Weak or no delivery-option suggestions | Use a capable `LLM_Model` (ships as `gpt-5.5`); small models delegate to the delivery-options agent unreliably. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For non-OpenAI providers, set `LLM_Base_URL`. |
| No confirmation email | Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, re-entered so it stores as `SECRET:`) and `To_Email`; confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed. |
| A new browser tab asks the recipient to verify again | Expected: each connection is a separate conversation. |
| Parcel dates or statuses look wrong | Reload `reset_data.sql`. Demo dates are relative to today. |
| Verification keeps failing with "locked" | After 5 wrong PINs an account is locked for 15 minutes (brute-force throttle). Wait, or `TRUNCATE verify_attempts;` in dev. |
