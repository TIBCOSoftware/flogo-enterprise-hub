> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# Airline — Passenger Services Assistant

The **Meridian Passenger Services Assistant** is a chat assistant for the travelers of a fictional airline,
**Meridian** (ATL hub). A traveler caught in a disruption verifies their booking, checks flight status and
connection risk, gets agent-ranked alternative flights for a missed connection, rebooks in two confirmed
steps, and emails themselves the confirmation. A traveler whose bag did not arrive describes it in their own words
and gets a recorded baggage claim; a traveler who needs help at the airport describes their needs and gets the
standard assistance codes added to their flight. Compensation, interim baggage expenses and assistance are decided
by Meridian staff — **in the same chatbot** — and the database then applies the decision.

**Agentic in the middle, deterministic at the edges:** the AI handles the conversation, ranks replacement flights,
turns a bag description into a structured claim and turns free-text needs into assistance codes. PostgreSQL decides
identity, connection risk, eligibility, seats, which codes are valid and every change. People decide the money and
the exceptions.

> Meridian and all travelers, staff, bookings and flights in this sample are fictional.
> The app uses its own database (`airline_governed`).

## Why an agent here?

| Part | Who owns it | Why |
|---|---|---|
| Ranking replacement flights against free-text preferences ("land before 8pm, window seat, no red-eye") | **AI agent** (`rebooking_options_agent`) | Free-text preferences weighed against a structured list of valid flights, with trade-offs. A fixed sort can't read "I have a morning meeting". |
| Turning "blue soft-sided suitcase, broken wheel, laptop charger inside" into a claim type, bag-type and color codes, content categories and the report fields still missing | **AI agent** (`baggage_claim_agent`) | A description in the traveler's words mapped onto Meridian's bag-type chart and claim rules. SQL then validates every code and records the claim. |
| Turning "she can't manage the stairs but can walk to her seat" into the standard IATA assistance code (WCHS, not WCHR or WCHC) | **AI agent** (`special_assistance_agent`) | Reading what a person can and cannot do and matching it to the code definitions. SQL keeps only valid, requestable codes. |
| Understanding the request, explaining outcomes, chaining the steps | **AI agent** (orchestrator) | Conversation, ambiguity, multi-step planning across tools. |
| Who the traveler is and which booking they can see | **Deterministic** (`session_booking`) | A model must not be able to talk its way into someone else's booking. |
| Will they make the connection? | **Deterministic arithmetic** (`connection_risk`) | SAFE / AT_RISK / MISSED is computed from the live times and the minimum connection — never guessed. |
| Rebooking eligibility, seats, the write | **Deterministic, two-step** (`rebook_eval` → `pending_actions` → `rebookings` + trigger) | The traveler confirms an exact change; the database applies it atomically and re-checks the rules. |
| Claim and code validation, compensation bands, interim-expense caps | **Database rules** | A bag is "lost" only five days after the flight arrived; a request carries at most one wheelchair code; the most a person may approve comes from a table. |
| Compensation, interim baggage expenses, confirming assistance, complaints, name changes | **People** (staff reviewers) | Discretion and accountability. The reviewer decides in the chatbot within their approval limit; the database then pays or confirms. |

Without the AI, status, risk and rebooking still work through a form. What you would lose is reading
"I need to land before my evening meeting", a bag description or a description of someone's mobility and knowing
what it means. That is the part the agents are for. The agents are given only the route and preferences, the bag
description or the needs — never the traveler's name, PNR, email or any id.

## Architecture

```
Chat UI ──WebSocket :9850 /passengerservices──► PassengerServicesAIOrchestrator  (AI Agent: travelers + staff reviewers)
                                                  │
                  MCP :9852 ◄─────────────────────┤──────────────► A2A :9853 rebooking_options_agent
                  PassengerServicesMCPServer      │                A2A :9854 baggage_claim_agent
                  16 governed tools               │                A2A :9855 special_assistance_agent
                          │                       │                PassengerServicesAgents (reference tables only)
                          └────────────► PostgreSQL `airline_governed` ◄──┘
                                         rule functions · triggers · service teams · reviewers · Gmail SMTP (email tool)
```

| App | Port / path | What it does |
|---|---|---|
| `PassengerServicesAIOrchestrator.flogo` | WebSocket `9850` `/passengerservices` | The assistant travelers and staff reviewers chat with. Each browser connection is its own conversation. |
| `PassengerServicesMCPServer.flogo` | MCP `9852` `/passenger-services-gov-mcp` | 16 governed tools: verify, itinerary, flight status, loyalty, connection risk, propose/confirm rebook, email confirmation, open service case, list cases, record a baggage claim, request assistance, and the reviewer tools (verify reviewer, review queue, review case, decide case). |
| `PassengerServicesAgents.flogo` | A2A `9853`, `9854`, `9855` | Three read-only agents: `rebooking_options_agent` (ranks alternative flights), `baggage_claim_agent` (bag description → structured claim) and `special_assistance_agent` (needs → assistance codes). Each reads **reference tables only** in PostgreSQL (the flight schedule, the baggage guide, the assistance codes), never sees who the traveler is and never changes anything. |

## Security & governance

> ⚠️ **This is a demonstration use case, not a production system.** It uses fictional data and simplified
> identity (PNR + PIN; staff ID + staff code). Before building anything like it for real travelers or data, review
> and follow your own organization's security, privacy, and compliance policies and standards.

What the demo already enforces:

| Control | How |
|---|---|
| Identity + brute-force throttle | PNR + PIN → session token; 5 wrong PINs lock a PNR for 15 min (`verify_attempts`). Staff reviewers sign in with a staff ID + code (5 wrong codes lock it for 15 minutes). Traveler and reviewer tokens are not interchangeable. |
| Rules in the database, not the prompt | guarded `INSERT…SELECT rule_fn`; the agents' claim types and codes are validated in SQL; compensation bands, interim caps and what a reviewer may approve come from tables |
| Per-user scoping | every read/write resolves the booking from the session token; a reviewer only sees their own team's queue |
| Data minimization | the agents never receive identity; reviewers see a first name and surname initial, never the email, phone or PIN |
| Two-step confirm for state changes | `propose_rebook` → explicit yes → `confirm_rebook` (event row + trigger); reviewers restate and confirm every decision |
| Human-in-the-loop for discretion | compensation / baggage / assistance / complaint / name-change → routed `service_cases`; a reviewer of that team decides within their approval limit, and approval runs the parked action (a payment, or confirming the assistance) through the same rules |
| Audit trail | sign-ins, proposals, rebookings, claims, assistance requests, cases, decisions, payments, confirmations and emails are written to `agent_audit` by triggers |
| Resource limits | `rateLimit` + `tokenLimit` on the AI Agents |
| Transparency | the assistant says it is an AI when asked |
| Prompt-injection resistance | claiming to be a gate agent or a supervisor changes nothing, because the rules and roles are in the database |

## Prerequisites

- **TIBCO Flogo VS Code extension** 2.26.7 or later.
- **PostgreSQL** 14 or later.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- An **OpenAI API key** (the apps ship set to model `gpt-5.5`; use a model your key can access — a capable
  model gives better flight suggestions and codes).
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
| `PostgreSQL.PostgresConn.Host` / `Port` / `User` / `Password` | ⚠️ the same values as the MCP Server (the agents only read the reference tables) |
| `PostgreSQL.PostgresConn.Database_Name` | ⚠️ `airline_governed` |

**`PassengerServicesAIOrchestrator.flogo`**

| Property | Set to |
|---|---|
| `AgenticAI.OpenAIConn.API_Key` / `LLM_Provider` / `LLM_Base_URL` / `LLM_Model` | the same values as the Agents app |

Then open each app's **Connections** and click **Connect** (or **Test**) on the PostgreSQL and LLM
connections. If a trigger shows a red ✗ after import, open it and click **Sync**.

> Changing a port? In the Agents app set `<agent>_PORT` together with `<agent>_URL` (`rebooking_options_agent`,
> `baggage_claim_agent`, `special_assistance_agent`); in the MCP app `MCP_SERVER_PORT`; in the orchestrator
> `WebSocket_PORT` and the matching URL properties `PassengerServicesMCPServer_URL`
> (`http://localhost:9852/passenger-services-gov-mcp`) and `rebooking_options_agent_URL` / `baggage_claim_agent_URL` /
> `special_assistance_agent_URL` (`http://localhost:9853` / `9854` / `9855`).

### 3. Start the apps in this order

> **How to build and start these apps** (the same for every sample in this folder): see
> **[Running the Industry Use-Case samples »](../../../RUNNING_THE_SAMPLES.md#start-the-apps)** — the run
> prerequisites (Flogo App Build CLI + Go, or deploy to TIBCO Platform) and the exact build/run commands.
>
> Then start them in the order below, each in its own terminal:

**MCP Server (9852) → Agents (9853–9855) → Orchestrator (9850).** Wait for each to log a clean start.

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
| Carlos Martinez (Gold) | `ABCDE1` | `4821` | FL801 delayed 90 min → **MISSES** Miami connection; rebook to FL447; compensation claim |
| Maria Fernandez (Basic) | `PQRST4` | `7310` | **AT_RISK** Chicago connection; alternative FL614 |
| Sofia Castro (Gold) | `MNOPQ0` | `5533` | **MISSED**, with **no same-day alternative** to Seattle |
| Linda Park (Silver) | `WXYZA7` | `3046` | Her bag did not arrive on yesterday's FL721 → **baggage claim** + interim expenses for a person to decide |
| Rosa Delgado (Basic) | `HJKLM8` | `2468` | Flies FL305 tomorrow; can't manage the aircraft stairs → **WCHS** assistance, pending confirmation |
| Kevin Wright (Gold) | `TUVWX9` | `8152` | A lost bag and a wheelchair request already with the teams |

The flagship walkthrough, as Carlos:

1. *"My PNR is ABCDE1 and my PIN is 4821."*
2. *"What's my itinerary and will I make my connection to Miami?"* → MISSED.
3. *"Find me an alternative to Miami — I need to arrive before 8pm, window seat."* → the agent ranks FL447.
4. *"Rebook me onto FL447."* → it shows the new seat/time and asks you to confirm.
5. *"Yes, I confirm."* → the rebooking is made.
6. *"Email me the confirmation."* → sent.
7. *"My inbound was delayed 90 minutes and I want compensation."* → a case goes to Customer Care with the
   amount a person could approve (up to $100 for a 1–3 hour delay); the assistant does not decide it.

A delayed bag, as Linda:

1. *"My PNR is WXYZA7 and my PIN is 3046."*
2. *"My checked bag never came off the belt after my flight from Boston yesterday. It's a blue fabric suitcase that
   stands upright on wheels. Inside are a suit, some shirts, my laptop charger and toiletries. I had to buy a suit and
   toiletries for a meeting - about $300. Can you file a claim?"* → the baggage agent maps it to a **DELAYED** claim,
   bag type `22`, color `BU`; the claim is recorded, the assistant asks for the bag tag number and other missing
   details, and Baggage Services gets a case for the $300 of interim expenses.

Special assistance, as Rosa:

1. *"My PNR is HJKLM8 and my PIN is 2468."*
2. *"I'm flying to Boston tomorrow. I can't manage the stairs up to the plane, but I can walk from the aircraft door to
   my seat. Can you arrange help for me?"* → **WCHS** (wheelchair, no steps) is added to her flight as **pending
   confirmation** and the Accessibility Desk gets a case.

### 6. Reviewer (human-in-the-loop)

Open a new tab and sign in as a staff reviewer: *"I'm Meridian staff - a Baggage Services reviewer. My staff ID is
MER-7001 and my code is 246810."*

| Reviewer | Staff ID | Code | Team | Approval limit | Try |
|---|---|---|---|---|---|
| Dana Brooks | `MER-7001` | `246810` | Baggage Services | $250.00 | Linda's $300 interim expenses (or Kevin's seeded $450) → approving the full amount is **above her limit** (the case stays open for a senior reviewer); approving $200 pays $200 |
| Victor Hale | `MER-7002` | `135790` | Baggage Services | $2,000.00 | approve Kevin's $450 in full |
| Marcus Lee | `MER-7003` | `864209` | Accessibility Desk | — | confirm Rosa's WCHS → her flight shows it **CONFIRMED**; Kevin's seeded WCHR |
| Elena Ruiz | `MER-7004` | `502468` | Customer Care (compensation) | $500.00 | Carlos's compensation (up to $100) or Sofia's seeded one (up to $250) → a travel credit is issued |
| Nadia Karim | `MER-7005` | `719350` | Customer Relations | $500.00 | Maria's seeded complaint |
| Owen Price | `MER-7006` | `357911` | Ticketing | — | Daniel's seeded name change |

The flow: *"Show me my queue."* → *"Open case SC-…"* → the assistant shows the traveler's statement, the facts from
Meridian's records and the AI-prepared brief (marked as unverified) → *"Approve the full $300. Internal note: … .
Message to the traveler: … ."* → the assistant restates the decision and asks you to **confirm** → *"Confirm."* →
the decision is recorded and the parked action runs (or, above your limit, the case stays open for a senior
reviewer). Then switch back to the traveler (new tab, sign in again) and ask *"What's the status of my baggage
claim?"* — they see the outcome and your message, never your internal note or name. A reviewer only ever sees their
own team's queue; a traveler who claims to be staff gets nothing without the staff code.

More prompts, including ones that show the rules holding, are in [prompts.md](prompts.md).

**Reset between demos:**

```bash
psql -U postgres -d airline_governed -f reset_data.sql
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| The assistant never manages to verify the traveler | Use the exact PNR and PIN from the table. Keep **Redact Sensitive Data** off on the orchestrator's AI Agent; it would mask the PNR and PIN. |
| "I can't reach the tools" or no flight suggestions | Start the MCP Server and the Agents app **before** the orchestrator, and check the orchestrator's URL properties match their ports. |
| Weak or no flight suggestions, wrong codes | Use a capable `LLM_Model` (ships as `gpt-5.5`); small models delegate to the agents unreliably. |
| An agent answers but its codes are generic | Check the Agents app's PostgreSQL connection: each agent reads its reference table (`ref_baggage_guide`, `ref_assistance_codes`, `search_alternatives`) from `airline_governed`. |
| LLM errors (401, model not found) | Check the API key and that your key can use the model in `LLM_Model`. For non-OpenAI providers, set `LLM_Base_URL`. |
| No confirmation email | Set `Email_Username`, `Email_App_Password` (a Gmail **App Password**, re-entered so it stores as `SECRET:`) and `To_Email`; confirm outbound SMTP (`smtp.gmail.com:465`, SSL) is allowed. |
| A new browser tab asks the traveler to verify again | Expected: each connection is a separate conversation. |
| Flight times, delays or "yesterday's" flight look wrong | Reload `reset_data.sql`. Demo times are relative to today. |
| Verification keeps failing with "locked" | After 5 wrong PINs a PNR is locked for 15 minutes (brute-force throttle). Wait, or `TRUNCATE verify_attempts;` in dev. |

## Rebuild from code

To regenerate these apps from code or run the automated checks, see [`_rebuild/README.md`](_rebuild/README.md).


---

<!-- SEO Keywords: Agentic AI Use Cases, MCP Use Cases, Build MCP Server, Zero-Code MCP Server, No-Code MCP Server, No-Code Agent Builder, Zero-Code Agent Builder, Best Integration Tool, Fastest Integration Tool, Most Performant Integration Tool, High-Performance Integration, Low-Code Integration, No-Code Integration, Agentic AI, AI Agents, MCP, MCP Server, Model Context Protocol, TIBCO Flogo, Governed AI, PostgreSQL, WebSocket, Enterprise Integration -->

**Hashtags:** #AgenticAI #AgenticAIUseCases #AIAgents #NoCodeAgentBuilder #MCP #MCPServer #ModelContextProtocol #ZeroCodeMCP #BuildMCPServer #LLMOrchestration #EnterpriseIntegration #TIBCOFlogo
