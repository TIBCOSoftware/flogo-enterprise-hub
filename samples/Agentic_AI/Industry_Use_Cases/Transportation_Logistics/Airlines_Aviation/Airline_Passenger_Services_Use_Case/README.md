# Airline — Passenger Services Assistant

The **Meridian Passenger Services Assistant** is a chat assistant for the travelers of a fictional airline,
**Meridian** (ATL hub). A traveler caught in a disruption verifies their booking, checks flight status and
connection risk, gets agent-ranked alternative flights for a missed connection, rebooks in two confirmed
steps, and emails themselves the confirmation. Compensation claims, baggage claims, special-assistance,
complaints and name changes go to the right team — the assistant never decides them.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation and ranks
replacement flights against the traveler's preferences. PostgreSQL decides identity, connection risk,
eligibility, seats and every change. People decide the exceptions.

> Meridian and all travelers, bookings and flights in this sample are fictional.
> The app uses its own database (`airline_governed`); an earlier, simpler version of this demo is
> kept under [`Industry_Use_Cases_old/`](../../../../Industry_Use_Cases_old/Airline_Passenger_Services_Use_Case/).

## Why an agent here?

| Part | Who owns it | Why |
|---|---|---|
| Ranking replacement flights against free-text preferences ("land before 8pm, window seat, no red-eye") | **AI agent** (`rebooking_options_agent`) | Free-text preferences weighed against a structured list of valid flights, with trade-offs. A fixed sort can't read "I have a morning meeting". |
| Understanding the request, explaining outcomes, chaining the steps | **AI agent** (orchestrator) | Conversation, ambiguity, multi-step planning across tools. |
| Who the traveler is and which booking they can see | **Deterministic** (`session_booking`) | A model must not be able to talk its way into someone else's booking. |
| Will they make the connection? | **Deterministic arithmetic** (`connection_risk`) | SAFE / AT_RISK / MISSED is computed from the live times and the minimum connection — never guessed. |
| Rebooking eligibility, seats, the write | **Deterministic, two-step** (`rebook_eval` → `pending_actions` → `rebookings` + trigger) | The traveler confirms an exact change; the database applies it atomically and re-checks the rules. |
| Compensation, baggage, special assistance, complaints, name changes | **Human** (`service_cases` → `service_teams`) | Discretion and accountability. Money and duty of care are not an assistant's call. |

Without the AI, status, risk and rebooking still work through a form. What you would lose is reading
"I need to land before my evening meeting" and knowing which flight that means. That is the part the agent
is for. The agent is given only the route, the earliest legal departure and the preferences — never the
traveler's name, PNR or email.

## Architecture

```
Chat UI ──WebSocket :9850 /passengerservices──► PassengerServicesAIOrchestrator  (AI Agent)
                                                  │
                  MCP :9852 ◄─────────────────────┤──────────────► A2A :9853
                  PassengerServicesMCPServer    │               PassengerServicesAgents
                  10 governed tools                │               rebooking_options_agent
                          └────────────► PostgreSQL `airline_governed` ◄──┘
                                         rule functions · trigger · service teams · Gmail SMTP (email tool)
```

| App | Port / path | What it does |
|---|---|---|
| `PassengerServicesAIOrchestrator.flogo` | WebSocket `9850` `/passengerservices` | The assistant the traveler chats with. Each browser connection is its own conversation. |
| `PassengerServicesMCPServer.flogo` | MCP `9852` `/passenger-services-gov-mcp` | 10 governed tools: verify, itinerary, flight status, loyalty, connection risk, propose/confirm rebook, email confirmation, open service case, list cases. |
| `PassengerServicesAgents.flogo` | A2A `9853` | `rebooking_options_agent`: ranks alternative flights from the route + preferences. It never sees the traveler's identity. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (PNR + PIN). Before building anything like it for real travelers or data, review and follow
> your own organization's security, privacy, and compliance policies and standards.

What the demo already enforces:

| Control | How |
|---|---|
| Identity + brute-force throttle | PNR + PIN → session token; 5 wrong PINs lock a PNR for 15 min (`verify_attempts`) |
| Rules in the database, not the prompt | guarded `INSERT…SELECT rule_fn`; the A2A agent is read-only and never receives identity |
| Per-user scoping | every read/write resolves the booking from the session token |
| Two-step confirm for state changes | `propose_rebook` → explicit yes → `confirm_rebook` (event row + trigger) |
| Human-in-the-loop for discretion | compensation / baggage / assistance / complaint / name-change → routed `service_cases` |
| Audit trail | every consequential change is written to `agent_audit` by triggers (query it by `pnr` / `action`) |
| Resource limits | `rateLimit` + `tokenLimit` on the AI Agents |
| Transparency | the assistant says it is an AI when asked |
| Prompt-injection resistance | an injection cannot change state because the rules are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.7 or later.
- **PostgreSQL** 14 or later.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- An **OpenAI API key** (the apps ship set to model `gpt-5.5`; use a model your key can access — a capable
  model gives better flight suggestions).
- A **Gmail App Password** for the confirmation email (or change the SMTP settings in the MCP app).
- **Node.js** 16 or later, for the shared [Chatbot](../../../../Chatbot/) web client.

## Steps to run

### 1. Create the database

```bash
createdb -U postgres airline_governed
psql -U postgres -d airline_governed -f database.sql
```

### 2. ⚠️ Configure the apps — these are NOT configured in the shipped files

Open each `.flogo` in VS Code and set these **App Properties**:

**`PassengerServicesMCPServer.flogo`**

| Property | Set to |
|---|---|
| `PostgreSQL.PostgresConn.Host` / `Port` / `User` | your PostgreSQL server (default `localhost` / `5432` / `postgres`) |
| `PostgreSQL.PostgresConn.Password` | your PostgreSQL password |
| `PostgreSQL.PostgresConn.Database_Name` | `airline_governed` |
| `Email_Username` | the Gmail address that sends the confirmation |
| `Email_App_Password` | your Gmail **App Password** — re-enter it in App Properties so it stores as a `SECRET:` (keep the property type `string`) |
| `To_Email` | the operations inbox that receives confirmations |

**`PassengerServicesAgents.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` | your LLM API key |
| `AgenticAI.OpenAIConn.LLM_Provider` / `LLM_Base_URL` | `OpenAI` / leave empty for OpenAI, or your provider's endpoint |
| `LLM_Model` | a model your key can use (ships as `gpt-5.5`) |
| `PostgreSQL.PostgresConn.*` | the same values as the MCP Server |

**`PassengerServicesAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? Update the port property (`MCP_SERVER_PORT`, `rebooking_options_agent_PORT`,
> `WebSocket_PORT`) **and** the matching connection URL in the orchestrator:
> `http://localhost:9852/passenger-services-gov-mcp` (MCP) and `http://localhost:9853` (A2A).

### 3. Start the apps in this order

**MCP Server (9852) → Agents (9853) → Orchestrator (9850).** Wait for each to log a clean start.

### 4. Open the chat client and connect

The chat client is the shared web app in [`samples/Agentic_AI/Chatbot`](../../../../Chatbot/). It needs Node.js 16+.

```bash
cd ../../../../Chatbot
npm install    # first time only
npm start
```

1. Open **http://localhost:3000**.
2. In the URL box at the top right, enter **`ws://localhost:9850/passengerservices`**.
3. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
4. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. Make sure the orchestrator
is running on port 9850. The chatbot remembers the last URL you applied, so a URL from another demo is a
common cause.

### 5. Run the demo

Sign in as one of the demo travelers (in production the portal would already know them; here they type
their PNR and the 4-digit PIN from the Meridian app / booking email).

| Traveler | PNR | PIN | What they show |
|---|---|---|---|
| Carlos Martinez (Gold) | `ABCDE1` | `4821` | FL801 delayed 90 min → **MISSES** Miami connection; rebook to FL447 |
| Maria Fernandez (Basic) | `PQRST4` | `7310` | **AT_RISK** Chicago connection; alternative FL614 |
| Sofia Castro (Gold) | `MNOPQ0` | `5533` | **MISSED**, with **no same-day alternative** to Seattle |

The flagship walkthrough, as Carlos:

1. *"My PNR is ABCDE1 and my PIN is 4821."*
2. *"What's my itinerary and will I make my connection to Miami?"* → MISSED.
3. *"Find me an alternative to Miami — I need to arrive before 8pm, window seat."* → the agent ranks FL447.
4. *"Rebook me onto FL447."* → it shows the new seat/time and asks you to confirm.
5. *"Yes, I confirm."* → the rebooking is made.
6. *"Email me the confirmation."* → sent.
7. *"My inbound was delayed 90 minutes and I want compensation."* → a case goes to Customer Care; the
   assistant does not decide it.

More prompts, including ones that show the rules holding, are in [prompts.md](prompts.md).

**Reset between demos:**

```bash
psql -U postgres -d airline_governed -f reset_data.sql
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The assistant never manages to verify the traveler | Use the exact PNR and PIN from the table. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it would mask the PNR and PIN. |
| "I can't reach the tools" or no flight suggestions | Start the MCP Server and the Agents app **before** the orchestrator, and check the orchestrator's connection URLs match their ports. |
| Weak or no flight suggestions | Use a capable `LLM_Model` (ships as `gpt-5.5`); small models delegate to the rebooking agent unreliably. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For non-OpenAI providers, set `LLM_Base_URL`. |
| No confirmation email | Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, re-entered so it stores as `SECRET:`) and `To_Email`; confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed. |
| A new browser tab asks the traveler to verify again | Expected: each connection is a separate conversation. |
| Flight times or delays look wrong | Reload `reset_data.sql`. Demo times are relative to today. |
| Verification keeps failing with "locked" | After 5 wrong PINs a PNR is locked for 15 minutes (brute-force throttle). Wait, or `TRUNCATE verify_attempts;` in dev. |

## Rebuild from code

To regenerate these apps from code or run the automated checks, see [`_rebuild/README.md`](_rebuild/README.md).
