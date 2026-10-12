# Airline Passenger Services Assistant

An **Agentic AI** demo for the **airline / passenger-services** vertical, built on TIBCO Flogo
Enterprise. A **traveler** caught in a flight disruption chats with an AI assistant over WebSocket
to **check flight status, look up their booking/itinerary, and assess connection risk** — and, on
confirmation, to **rebook onto an alternative flight and receive a confirmation email**. The
assistant looks the data up, performs the action against PostgreSQL, and emails the traveler.

## What this demo does

- **Persona:** Passenger / traveler (self-service), identified by a 6-character **PNR** (e.g.
  `ABCDE1`) or a flight number (e.g. `FL801`). Airline ops runs a hub-and-spoke network through
  **Atlanta (ATL)**.
- **Problem automated:** the "is my flight delayed, will I make my connection, please rebook me,
  and email me the confirmation" load that normally ties up a gate agent or a call-center rep —
  resolved conversationally, grounded in live flight and booking data.
- **Solution shape:** 3 Flogo apps — **1 MCP Server** (read-only lookup tools), **1 A2A Servers / Agents app**
  (action agents that assess risk, write **directly to PostgreSQL**, and send email), and **1 AI
  Orchestrator** (WebSocket chat, LLM routing). All state lives in **PostgreSQL**.
- **Locale:** No currency — loyalty value is expressed as **miles / tier** (Basic, Silver, Gold,
  Platinum). Times are **timezone-aware** across multiple US timezones, airports use **IATA
  3-letter codes**, and the demo dataset is **`CURRENT_DATE`-relative** so it always looks live.

---

## Architecture

```
Chatbot UI --WebSocket--> AI Orchestrator --MCP (HTTP streamable)--> MCP Server --\
                                 |                                                 +--> PostgreSQL
                                 \-A2A (HTTP)-----> A2A Servers / Agents ----------/   (+ Gmail SMTP for email)
```

```
                    ┌─────────────────────────┐
                    │     Chatbot UI          │
                    │  (WebSocket Client)     │
                    └───────┬─────────────────┘
                            │ WebSocket
                            │ ws://<host>:8083/airline
                            ▼
               ┌────────────────────────────────┐
               │  Passenger Services            │
               │  AI Orchestrator               │
               │  (PassengerServicesAIOrch.)    │
               │  Port 8083 (WebSocket)         │
               │  LLM: OpenAI-compatible        │
               └───────┬───────────┬────────────┘
                       │           │
          MCP (HTTP)   │           │  A2A Protocol
                       ▼           ▼
    ┌──────────────────────┐   ┌──────────────────────────────┐
    │  Passenger Services  │   │  Passenger Services          │
    │  MCP Server          │   │  A2A Servers / Agents        │
    │  Port 9093           │   │                              │
    │  /airlinemcpserver   │   │  connection_risk_agent :8074 │
    │                      │   │  rebook_passenger_agent:8075 │
    │  Tools (read-only):  │   │  send_confirmation_email:8076│
    │  - GetFlights        │   │                              │
    │  - GetPassengers     │   │  Writes to PostgreSQL        │
    │  - GetFrequentFlyer  │   │  + Gmail SMTP for email      │
    │  - GetBookings       │   │                              │
    │  - GetBookingSegments│   │                              │
    └──────────┬───────────┘   └──────────────┬───────────────┘
               │                              │
               └──────────────┬───────────────┘
                              ▼
               ┌────────────────────────────┐
               │  PostgreSQL Database       │
               │  Database: airline         │
               │  6 Tables                  │
               └────────────────────────────┘
```

- **MCP Server** — read-only lookups. Stateless, safe to retry; the LLM picks a tool from its
  description and filters the returned rows (by flight number, PNR, passenger id, etc.).
- **A2A Servers / Agents** — action/analysis workflows. Each agent has its own trigger/port, guardrails, and
  system prompt. `rebook_passenger_agent` **writes directly to PostgreSQL**; `send_confirmation_email`
  sends via Gmail SMTP; `connection_risk_agent` is read-only analysis.
- **Orchestrator** — the AI brain. WebSocket chat endpoint; the LLM decides intent and either calls
  an MCP tool (data lookup) or hands off to an A2A agent (risk assessment, rebook, email).

---

## Apps / Components

| App | File | Trigger | Port (property) + path |
|-----|------|---------|------------------------|
| MCP Server | `PassengerServicesMCPServer.flogo` | `#mcpserver` | `MCP_SERVER_PORT` = **9093**, path `/airlinemcpserver` (Streamable HTTP) |
| A2A Servers / Agents | `PassengerServicesA2AServers.flogo` | `#agent` ×3 | see agent table below (**8074–8076**) |
| AI Orchestrator | `PassengerServicesAIOrchestrator.flogo` | `#wsserver` | **8083**, WebSocket path `/airline` |

> **Legacy / alternate apps (kept for reference — not part of the current 3-app set):**
> `airline-mcp-server.flogo` (original MCP server exposing flight/booking/rebooking tools with mock
> data, no PostgreSQL), `airline-agent.flogo` (original 2-tier AI agent — WebSocket chat + MCP only,
> no A2A), and `airline-rest-api.flogo` (a mock REST backend used by the earliest prototype). Their
> companion notes `airline-prompts.md` and `airline-poc.md` describe that earlier design. Document
> and demo the **PassengerServices\*** apps above; the `airline-*` apps are historical.

---

## MCP tools (read-only)

All served by `PassengerServicesMCPServer.flogo`. Each tool runs a `SELECT * FROM public.<table>`
and returns the rows as a string; the LLM filters/joins by flight number, PNR, passenger id, etc.

| Tool | Table / source | What it answers |
|------|----------------|-----------------|
| `GetFlights` | `flights` | Flight schedule + real-time status: number, origin/destination, scheduled/estimated times, status (ON_TIME/DELAYED/CANCELLED), gate, delay minutes/reason, aircraft |
| `GetPassengers` | `passengers` | Passenger contact + identity: id, name, email, phone, nationality |
| `GetFrequentFlyer` | `frequentflyer` | Loyalty: FF number, tier (Basic/Silver/Gold/Platinum), miles balance, YTD tier miles |
| `GetBookings` | `bookings` | PNR booking records: PNR, passenger id, booking date, status (CONFIRMED/CANCELLED/COMPLETED) |
| `GetBookingSegments` | `booking_segments` | Per-booking flight legs: segment order, flight, origin/destination, times, seat, cabin, segment status |

---

## A2A action agents

All served by `PassengerServicesA2AServers.flogo`. Each agent has its own trigger, port, LLM, and
system prompt.

| Agent | Port (property) | Action | Writes to |
|-------|-----------------|--------|-----------|
| `connection_risk_agent` | `Connection_Risk_A2AServer_PORT` = **8074** | Assess connection risk for a PNR — reads booking segments + all flights, computes connection time, flags SAFE / AT_RISK / MISSED, and suggests alternatives | *(read-only — no writes)* |
| `rebook_passenger_agent` | `Rebook_Passenger_A2AServer_PORT` = **8075** | Rebook a disrupted passenger onto a new flight/seat | UPDATE `booking_segments` (new flight, seat, status=`REBOOKED`) + INSERT `rebooking_log` |
| `send_confirmation_email` | `SendEmail_A2AServer_PORT` = **8076** | Email the rebooking confirmation (invoked **once**, only after rebooking is complete) | Gmail SMTP (recipient pre-configured on the email service) |

> Risk assessment and the rebooking write are **separate single-purpose agents** — the risk agent
> never mutates data, and the rebook agent performs a clean UPDATE + INSERT — which is more reliable
> and easier to demo than one branching flow.

---

## Database

PostgreSQL (14+). `database.sql` creates the schema and seeds demo data; `reset_data.sql` re-seeds
with **`CURRENT_DATE`-relative** flight times (so delays/connections always look "today") and clears
the agent-written `rebooking_log`. Six tables:

| Table | Purpose | Seed count |
|-------|---------|------------|
| `flights` | Flight schedule with status, delays, gates | **32** (hub-and-spoke via ATL; several DELAYED/CANCELLED, plus later-frequency alternatives per route) |
| `passengers` | Passenger master records | **22** (8 nationalities) |
| `frequentflyer` | Loyalty program (Basic/Silver/Gold/Platinum) | **22** |
| `bookings` | PNR booking records | **22** |
| `booking_segments` | Multi-leg itineraries per booking | **41** |
| `rebooking_log` | Audit of all rebookings | **0** — starts empty, populated by `rebook_passenger_agent` |

```bash
# Load schema + demo data
psql -h <host> -p <port> -U <user> -d airline -f database.sql

# Reset between demos (today-relative flight times, clears rebooking_log)
psql -h <host> -p <port> -U <user> -d airline -f reset_data.sql
```

> Create the `airline` database first if it does not exist:
> `psql -h <host> -p <port> -U <user> -c "CREATE DATABASE airline;"`

**Flagship data hooks** (the anchors the demo scenarios rely on):

- **`ABCDE1` / Carlos Martinez (Gold)** — `DEN→ATL→MIA`. Inbound **FL801 delayed 90 min** →
  **MISSES** FL445 (12:30). Alternatives **FL447 (15:30)** / FL449 (18:30). Drives the flagship
  end-to-end: risk → rebook → email.
- **`PQRST4` / Maria Fernandez (Basic)** — `SEA→ATL→ORD`. **FL510 delayed 45 min** → **AT_RISK**
  (~30 min to FL612).
- **`KLMNO3` / Roberto Gonzalez (Platinum)** — `ATL→MIA` direct, on time → no-disruption path.
- **`NPQRS5` / Daniel Ortiz** — inbound **FL932 CANCELLED** → rebook-needed scenario.
- **`MNOPQ0` / Sofia Castro** — **FL620 delayed 180 min** → MISSES last SEA flight, **no same-day
  alternative** (graceful "no option" handling).

### Sample data reference

**Passengers & bookings (22 PNRs):**

| PNR | Passenger | Loyalty | Route | Connection scenario |
|-----|-----------|---------|-------|---------------------|
| ABCDE1 | Carlos Martinez | Gold | DEN→ATL→MIA | FL801 delayed 90 min → **MISSED** FL445 (alt FL447/FL449) |
| FGHIJ2 | Ana Silva | Silver | LAX→ATL→JFK | On time → SAFE (90 min) |
| KLMNO3 | Roberto Gonzalez | Platinum | ATL→MIA (direct) | Direct, no connection |
| PQRST4 | Maria Fernandez | Basic | SEA→ATL→ORD | FL510 delayed 45 min → **AT_RISK** (30 min) |
| UVWXY5 | Jorge Lopez | Silver | BOS→ATL→MIA | On time → SAFE (120 min) |
| BCDEF6 | Isabella Ramirez | Gold | DEN→ATL (one-way) | FL801 delayed, no connection |
| GHIJK7 | Diego Torres | Basic | DEN→ATL→JFK | FL801 delayed 90 min → **MISSED** FL302 (alt FL304/FL306) |
| LMNOP8 | Camila Rojas | Gold | LAX→ATL→ORD | On time → SAFE (150 min) |
| HIJKL9 | Lucas Pereira | Silver | LAX→ATL→JFK | FL217 delayed 120 min → **MISSED** FL304 (alt FL306) |
| MNOPQ0 | Sofia Castro | Gold | SFO→ATL→SEA | FL620 delayed 180 min → **MISSED** FL717 (no same-day alt) |
| RSTUV1 | Mateo Ramos | Basic | JFK→ATL→ORD | FL412 delayed 75 min → **AT_RISK** (45 min; alt FL616) |
| WXYZA2 | Valeria Cruz | Platinum | BOS→ATL→MIA | FL727 delayed 60 min → **MISSED** FL447 (alt FL449) |
| BCDFG3 | Nicolas Vargas | Silver | SEA→ATL→LAX | On time → SAFE (120 min) |
| HJKLM4 | Gabriela Mendez | Gold | DEN→ATL→SEA | FL801 delayed 90 min but SAFE (105 min) |
| NPQRS5 | Daniel Ortiz | Basic | ORD→ATL→MIA | Inbound FL932 **CANCELLED** (rebook needed) |
| TVWXY6 | Renata Alves | Silver | JFK→ATL→MIA | On time → **AT_RISK** (45 min; alt FL447) |
| ZABCD7 | Tomas Reyes | Gold | LAX→ATL→SEA | On time → SAFE (180 min) |
| EFGHI8 | Elena Navarro | Platinum | SFO→ATL→DEN | FL620 delayed 180 min but SAFE (60 min) |
| JKLMN9 | Felipe Guerrero | Basic | DEN→ATL→BOS | Tight schedule → **MISSED** FL730 (0 min; alt FL732) |
| OPQRS0 | Paula Rios | Silver | ATL→SFO (direct) | Direct, no connection |
| UVWXZ1 | Valentina Herrera | Platinum | MIA→ATL→DEN | On time → SAFE (225 min, long layover) |
| CDEFH2 | Andres Morales | Silver | BOS→ATL→JFK | FL727 delayed 60 min → **AT_RISK** (30 min; alt FL306) |

**Inbound flights to ATL (delays here drive connection risk):**

| Flight | Route | Status | Delay | Gate |
|--------|-------|--------|-------|------|
| FL801 | DEN → ATL | DELAYED | 90 min | B12 |
| FL803 | DEN → ATL | ON_TIME | -- | B14 |
| FL215 | LAX → ATL | ON_TIME | -- | C04 |
| FL217 | LAX → ATL | DELAYED | 120 min | C06 |
| FL510 | SEA → ATL | DELAYED | 45 min | C08 |
| FL512 | SEA → ATL | ON_TIME | -- | C10 |
| FL725 | BOS → ATL | ON_TIME | -- | B06 |
| FL727 | BOS → ATL | DELAYED | 60 min | B08 |
| FL930 | ORD → ATL | ON_TIME | -- | B10 |
| FL932 | ORD → ATL | CANCELLED | -- | B11 |
| FL410 | JFK → ATL | ON_TIME | -- | A05 |
| FL412 | JFK → ATL | DELAYED | 75 min | A07 |
| FL620 | SFO → ATL | DELAYED | 180 min | C12 |
| FL450 | MIA → ATL | ON_TIME | -- | A09 |

**Outbound from ATL (multiple frequencies per route give rebooking alternatives):**

| Flights | Route | Dep (ATL) | Gate |
|---------|-------|-----------|------|
| FL445 / FL447 / FL449 | ATL → MIA | 12:30 / 15:30 / 18:30 | A08 / A12 / A10 |
| FL302 / FL304 / FL306 | ATL → JFK | 13:00 / 16:00 / 19:30 | A15 / A16 / A17 |
| FL612 / FL614 / FL616 | ATL → ORD | 14:00 / 17:00 / 20:00 | A20 / A21 / A23 |
| FL520 / FL522 | ATL → LAX | 15:00 / 18:00 | A22 / A24 |
| FL715 / FL717 | ATL → SEA | 14:30 / 18:15 | C14 / C16 |
| FL810 / FL812 | ATL → DEN | 16:00 / 19:00 | B16 / B18 |
| FL730 / FL732 | ATL → BOS | 15:45 / 19:15 | B20 / B22 |
| FL625 | ATL → SFO | 16:30 | C18 |

---

## Demo scenarios

Each scenario maps to the MCP tool(s) / A2A agent(s) it exercises. See **`prompts.md`** for the
full, copy-pasteable prompt list (organized by scenario, including edge cases and multi-turn flows).

1. **Flight status.** "What's the status of flight FL801?" → `GetFlights`.
2. **Booking / itinerary lookup.** "Look up booking ABCDE1 — what are my segments?" → `GetBookings` + `GetBookingSegments`.
3. **Loyalty check.** "What tier and how many miles for PAX-2026-00101?" → `GetFrequentFlyer` (+ `GetPassengers`).
4. **Connection risk — AT_RISK.** "My PNR is PQRST4, will I make my connection to Chicago?" → `GetFlights`/`GetBookingSegments` → `connection_risk_agent`.
5. **Connection risk — MISSED.** "I'm on FL801, booking ABCDE1 — will I make Miami?" → `connection_risk_agent` (flags MISSED, suggests FL447/FL449).
6. **Rebook.** "Yes, please rebook me on FL447." → `rebook_passenger_agent` (UPDATE `booking_segments` + INSERT `rebooking_log`).
7. **Email confirmation.** "Send me a confirmation email." → `send_confirmation_email` (once, after rebooking).
8. **Cancelled inbound.** "My FL932 from Chicago was cancelled (PNR NPQRS5) — get me to Miami." → `connection_risk_agent` → `rebook_passenger_agent`.
9. **No same-day alternative.** "Booking MNOPQ0 — can I still reach Seattle tonight?" → `connection_risk_agent` (graceful "no option").
10. **⭐ Flagship end-to-end.** Carlos Martinez (ABCDE1): status → "will I make my connection?" → "rebook me on FL447" → "email me the confirmation" → `GetFlights` → `connection_risk_agent` → `rebook_passenger_agent` → `send_confirmation_email`.
11. **No-disruption / SAFE.** "Booking KLMNO3, confirm everything looks good." → MCP tools only.
12. **Edge / out-of-scope.** Invalid PNR (`ZZZZZ9`), or "upgrade me / where's my luggage / refund me" → assistant declines gracefully.

### Illustrative dialogue — Carlos Martinez (Gold), missed connection

```
You:   Hi, I'm on flight FL801 from Denver. What's the status?
Agent: FL801 is currently DELAYED by 90 minutes... estimated arrival at ATL is 12:45 PM.

You:   Oh no, I have a connection. My booking is ABCDE1. Will I make it?
Agent: Your connecting flight FL445 ATL→MIA departs at 12:30. With FL801 arriving at 12:45 you
       would MISS your connection. I recommend rebooking you on FL447 ATL→MIA at 15:30.

You:   Yes, please rebook me on FL447.
Agent: Done! You've been rebooked from FL445 to FL447 ATL→MIA, seat 5A. New departure 15:30,
       arriving Miami 19:45.

You:   Can you send me a confirmation email?
Agent: Confirmation email sent.
```

---

## Prerequisites

- **PostgreSQL 14+** running; a database named **`airline`** created for this demo.
- **PostgreSQL ODBC driver** (Flogo connector prerequisite) — install it before you open the apps in the designer: VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…** → PostgreSQL, then reload VS Code ([details](../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md)).
- **TIBCO Flogo Enterprise** — VS Code extension 2.26.7 or later (import the `.flogo` apps into the designer) — or the `flogobuild` CLI
  if you prefer to build `.exe`s; set the app properties listed below before you run.
- An **LLM provider** key (OpenAI-compatible). The `LLM_Base_URL` must be a **real endpoint**, e.g.
  `https://api.openai.com/v1`, and `LLM_Model` must be a model your key can access.
- **SMTP** access for the email agent (Gmail App Password — see Setup & Run).
- A **WebSocket chat UI** — the bundled one lives at `samples/Agentic_AI/Chatbot`.

---

## Setup & Run

### 1. Database

```bash
# Create the database (once)
psql -h <host> -p <port> -U <user> -c "CREATE DATABASE airline;"

# Load schema + demo data
psql -h <host> -p <port> -U <user> -d airline -f database.sql

# (for live demos) reset with today-relative flight times
psql -h <host> -p <port> -U <user> -d airline -f reset_data.sql

# Verify
psql -h <host> -p <port> -U <user> -d airline \
  -c "SELECT flight_number, origin, destination, status, delay_minutes FROM flights ORDER BY flight_number;"
```

### 2. Import the three apps

Import into TIBCO Flogo Enterprise (or build each with `flogobuild`):
`PassengerServicesMCPServer.flogo`, `PassengerServicesA2AServers.flogo`,
`PassengerServicesAIOrchestrator.flogo`.

### 3. Set app properties

**PassengerServicesMCPServer**

| Property | Value |
|----------|-------|
| `PostgreSQL.PostgresConn.Host` / `Port` / `Database_Name` / `User` / `Password` | your DB (`Database_Name` = `airline`) |
| `MCP_SERVER_PORT` | `9093` |

**PassengerServicesA2AServers**

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | your LLM key (stored as `SECRET:`) |
| `AgenticAI.OpenAIConn.LLM_Base_URL` | a real endpoint, e.g. `https://api.openai.com/v1` |
| `LLM_Model` | a model your key can access |
| `PostgreSQL.PostgresConn.*` | your DB (as above) |
| `To_Email` | recipient for confirmation emails |
| `Email_Username` | Gmail address for SMTP |
| `Email_App_Password` | Gmail **App Password** (16-char), stored as `SECRET:` |
| `Connection_Risk_A2AServer_PORT` / `Rebook_Passenger_A2AServer_PORT` / `SendEmail_A2AServer_PORT` | `8074` / `8075` / `8076` |

**PassengerServicesAIOrchestrator**

| Property | Value |
|----------|-------|
| `AgenticAI.OpenAIConn.API_Key` | your LLM key (stored as `SECRET:`) |
| `AgenticAI.OpenAIConn.LLM_Base_URL` | a real endpoint (must **not** be blank) |
| `LLM_Model` | a model your key can access |

### 4. Check connections (if not localhost)

The orchestrator's MCP + A2A `serverUrl`s default to `localhost`. If apps run on different hosts,
update them (in App Properties / the connections) to match:

- MCP → `http://<mcp-host>:9093/airlinemcpserver`
- `connection_risk` → `http://<a2a-host>:8074`
- `rebook_passenger` → `http://<a2a-host>:8075`
- `send_confirmation_email` → `http://<a2a-host>:8076`

Also validate the `PostgreSQL` connection host/port/database in the MCP and A2A apps.

### 5. Configure the email (Gmail App Password)

1. Enable 2-Step Verification at https://myaccount.google.com/security
2. Create an App Password ("Mail") at https://myaccount.google.com/apppasswords
3. Use the 16-character value as `Email_App_Password` (re-enter it in App Properties so it stores as
   a `SECRET:` — keep the property type `string`).

### 6. Start the apps (in order)

1. **PassengerServicesMCPServer** (port 9093 ready first)
2. **PassengerServicesA2AServers** (ports 8074, 8075, 8076)
3. **PassengerServicesAIOrchestrator** (port 8083 — needs MCP + A2A running)

### 7. Connect a WebSocket client

Start the chat UI and point it at the orchestrator:

```bash
cd samples/Agentic_AI/Chatbot
npm install    # first time only
npm start
```

Open **http://localhost:3000**, then:

1. In the URL box at the top right, enter **`ws://localhost:8083/airline`**.
2. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it,
   and an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
3. Click **Connect**. The status turns green: **● Connected**.

**Won't connect?** Click **Disconnect**, click **↻** again, then **Connect**. The chatbot remembers the
last URL you applied, so a URL from another demo is a common cause.

Then run the prompts from `prompts.md`. After a demo (especially after rebooking), run
`reset_data.sql` to restore the dataset.

---

## Ports

| Component | Property | Default | Protocol / path |
|-----------|----------|---------|-----------------|
| MCP Server | `MCP_SERVER_PORT` | 9093 | HTTP (MCP), `/airlinemcpserver` |
| Connection-risk agent | `Connection_Risk_A2AServer_PORT` | 8074 | HTTP (A2A) |
| Rebook-passenger agent | `Rebook_Passenger_A2AServer_PORT` | 8075 | HTTP (A2A) |
| Email agent | `SendEmail_A2AServer_PORT` | 8076 | HTTP (A2A) |
| AI Orchestrator | `#wsserver` (port `8083`) | 8083 | WebSocket, `/airline` |

---

## Troubleshooting

- **`unsupported protocol scheme` / posts to `/New_value/...`** — the LLM base URL is blank. Set
  `AgenticAI.OpenAIConn.LLM_Base_URL` to a real endpoint (`https://api.openai.com/v1`). *(The
  committed apps ship with `LLM_Base_URL` empty — this is the #1 first-run failure.)*
- **MCP runtime panics `missing input schema`** — a tool handler is missing its input/output schema;
  open the MCP trigger and **Sync** it.
- **A2A write fails with `missing substitution for: <name>`** — the runtime `input.mapping.parameters`
  is missing that param; patch it, then **Sync** the agent's trigger to regenerate the design-time
  schemas.
- **`Configured connection is not a WebSocket Connection`** — the orchestrator's `wsconnection` /
  `content` were coerced to `object`; they must stay type **`any`**.
- **Email field warns "type … differs from bound app property"** — re-enter `Email_App_Password` in
  App Properties so it's stored as a `SECRET:` (keep the property type `string`; there is no
  `password` app-property type). Use a Gmail **App Password**, not the account password, and enable
  2FA first.
- **Orchestrator can't reach a tool/agent** — the MCP/A2A `serverUrl`s must match the ports above
  (MCP 9093, A2A 8074/8075/8076). If you change a port, change it in the app property **and** in the
  orchestrator connection URL.
- **Agent returns stale / wrong data** — re-run `reset_data.sql`.
- **WebSocket won't connect** — confirm the Orchestrator is running on 8083 and you used path
  `/airline` (not `/ws/chat`), and that you clicked the ↻ icon next to the URL box before **Connect**.

---

## ⚠️ Below things are NOT configured — please configure them manually before running end to end

The committed `.flogo` files carry placeholders / reference-app values for every secret and a
**blank** LLM base URL. Replace them with your own before an end-to-end run. **Never commit real
secrets.**

1. **LLM credentials & endpoint.**
   - `AgenticAI.OpenAIConn.API_Key` — your real provider key (stored as a `SECRET:` app property).
   - `AgenticAI.OpenAIConn.LLM_Base_URL` — a **real endpoint** (`https://api.openai.com/v1`). It is
     **empty** in the committed apps; a blank value fails with `unsupported protocol scheme`.
   - `LLM_Model` — set a model your key can access (confirm the configured value is valid for you).

2. **PostgreSQL database & credentials.**
   - Create the `airline` database, load `database.sql`; run `reset_data.sql` to reset between demos.
   - Set `PostgreSQL.PostgresConn` `Host` / `Port` / `Database_Name` / `User` / `Password` (the
     `Password` is a `SECRET:` app property) in **both** the MCP and A2A apps.

3. **Ports must be free & consistent.**
   - MCP **9093**, connection-risk **8074**, rebook **8075**, email **8076**, orchestrator WebSocket
     **8083** must all be free on the host.
   - The orchestrator's MCP `serverUrl` and each A2A `serverUrl` must match those ports.

4. **Email / SMTP** (the `send_confirmation_email` agent).
   - Set `Email_Username`, `Email_App_Password` (an app-specific password, **not** the account
     password), and the recipient `To_Email`.
   - **Re-enter `Email_App_Password` in App Properties so it's stored as a `SECRET:`** (property type
     stays `string`). Confirm outbound Gmail SMTP is allowed from the host/network.

5. **Chatbot / WebSocket client.**
   - The orchestrator exposes `ws://<host>:8083/airline`. Point your chat UI (bundled at
     `samples/Agentic_AI/Chatbot`) or a WS test client at it. See `prompts.md` for demo prompts.

6. **Flogo designer manual steps** (clear design-time validation).
   - **Sync every trigger** (MCP, each A2A agent, the WS server) once so tool/agent params and WS
     input mappings render without a red ✗.
   - **Validate every connection** (PostgreSQL, LLM provider, MCP server config, all three A2A server
     connections) — click **Connect / Test** before running.

### Quick pre-flight checklist

- [ ] DB `airline` created, `database.sql` loaded, row counts sane (flights 32, passengers 22, bookings 22, booking_segments 41)
- [ ] LLM `API_Key`, `LLM_Base_URL` (real endpoint — **not blank**), `LLM_Model` set in **both** the A2A and Orchestrator apps
- [ ] PostgreSQL `Password` set in MCP + A2A; MCP `SELECT`s and the rebook UPDATE/INSERT run cleanly
- [ ] All 5 ports free (9093, 8074, 8075, 8076, 8083); orchestrator MCP/A2A URLs match the MCP/A2A ports
- [ ] `Email_App_Password` re-entered as a `SECRET:` (type stays `string`); Gmail App Password + 2FA; SMTP reachable
- [ ] Every trigger Synced; every connection validated in the designer
- [ ] Start order: MCP → A2A → Orchestrator; each logs a clean start
- [ ] WebSocket client connects to `ws://<host>:8083/airline` and gets a reply

---

## Supporting files

| File | Description |
|------|-------------|
| `database.sql` | PostgreSQL schema (6 tables) + demo data |
| `reset_data.sql` | Reset with `CURRENT_DATE`-relative flight times; clears `rebooking_log` |
| `prompts.md` | Demo prompts organized by scenario |
| `manual-steps.md` | Original step-by-step setup notes (folded into **Setup & Run** above) |
| `airline-mcp-server.flogo`, `airline-agent.flogo`, `airline-rest-api.flogo` | Legacy / alternate prototype apps (see **Apps / Components**) |
| `airline-prompts.md`, `airline-poc.md` | Notes for the legacy prototype |
