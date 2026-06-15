# Airline Passenger Services Use Case

An agentic AI system built on TIBCO Flogo that handles flight disruption management for an airline hub. A customer service AI agent communicates with passengers via WebSocket chat, checks flight status, looks up bookings, identifies at-risk connections, and rebooks disrupted passengers -- all through natural language conversation.

---

## Architecture Overview

```
                    ┌─────────────────────────┐
                    │     Chatbot UI          │
                    │  (Chatbot app or HTML)  │
                    └───────┬─────────────────┘
                            │ WebSocket
                            │ /ws/passengerserviceagent
                            ▼
               ┌────────────────────────────┐
               │   Airline AI Agent         │
               │   (airline-agent)          │
               │   Port 8054 (WebSocket)    │
               │   LLM: OpenAI GPT-5.5     │
               └────────────┬───────────────┘
                            │ MCP (Streamable HTTP)
                            ▼
               ┌────────────────────────────┐
               │   Airline MCP Server       │
               │   (airline-mcp-server)     │
               │   Port 9044               │
               │                            │
               │   Tools:                   │
               │   - CheckFlightStatus      │
               │   - GetBooking             │
               │   - RebookPassenger        │
               └────────────┬───────────────┘
                            │ (internal mock data
                            │  or REST backend)
                            ▼
               ┌────────────────────────────┐
               │   Airline REST API         │
               │   (airline-rest-api)       │
               │   Port 9111 / 3001         │
               └────────────────────────────┘
```

---

## Flogo Apps

### 1. `airline-agent.flogo` -- AI Agent (Port 8054)

The main agentic AI app. Exposes a WebSocket endpoint for natural language passenger service interactions. Uses OpenAI GPT-5.5 and connects to the MCP Server to access airline tools.

| Setting | Value |
|---------|-------|
| WebSocket Path | `/ws/passengerserviceagent` |
| LLM | OpenAI GPT-5.5 |
| Temperature | 0.1 |
| MCP Server | `http://localhost:9044/mcp` |

**Agent Capabilities:**
- Check flight status for any flight number
- Look up passenger booking by PNR confirmation code
- Detect at-risk connections (< 60 min connection time)
- Suggest and execute rebooking to alternative flights
- Address passengers by name, acknowledge loyalty tier (Gold/Platinum VIP treatment)

### 2. `airline-mcp-server.flogo` -- MCP Server (Port 9044)

Exposes 3 AI tools via the Model Context Protocol over Streamable HTTP at `/mcp`:

| Tool | Type | Description |
|------|------|-------------|
| **CheckFlightStatus** | Read-only | Look up flight by number -- returns origin, destination, times, status, delay, gate, aircraft |
| **GetBooking** | Read-only | Look up booking by PNR -- returns passenger info, loyalty tier, all flight segments |
| **RebookPassenger** | Write | Rebook a passenger to a new flight -- updates the affected segment |

**Mock flight data built in:** FL801 (DELAYED 90 min), FL445 (ON_TIME), FL447 (ON_TIME), FL302 (DELAYED 45 min), FL510 (ON_TIME), FL612 (ON_TIME), FL215 (ON_TIME)

**Mock bookings:** ABCDE1 (Carlos Martinez, Gold), FGHIJ2 (Ana Rodriguez, Platinum), KLMNO3 (Roberto Silva, Silver)

### 3. `airline-rest-api.flogo` -- REST API Backend (Port 9111)

Mock REST API backend with hardcoded dummy data. Can be used as the backend for the MCP server or as a standalone API.

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/flights/{flightNumber}` | Get flight status |
| GET | `/api/bookings/{pnr}` | Get booking details |
| POST | `/api/bookings/{pnr}/rebook` | Rebook passenger (body: `{"newFlightNumber": "..."}`) |


---

## Supporting Files

| File | Description |
|------|-------------|
| `swagger.json` | OpenAPI 3.0.3 spec for the Airline Passenger Services API |
| `database.sql` | PostgreSQL schema -- 5 tables (flights, passengers, frequentflyer, bookings, booking_segments) with 10 passengers, 8 flights, 8 PNRs |
| `reset_data.sql` | Data reset script using `CURRENT_DATE` for always-current flight times |
| `airline-poc.md` | Full POC blueprint -- architecture, agent definition, MCP tools, REST APIs, end-to-end scenarios, demo script |
| `airline-prompts.md` | Demo prompts organized by scenario + build prompts for citizen developers |
| `airline-session-history.md` | Development session history with chronological action timeline |

---

## Database Setup

The system includes a PostgreSQL database with 5 tables:

| Table | Purpose | Sample Data |
|-------|---------|-------------|
| `flights` | Flight schedule and status | 8 flights through PTY hub |
| `passengers` | Passenger records | 10 passengers from 6 countries |
| `frequentflyer` | Loyalty program tiers and miles | Basic through Platinum |
| `bookings` | PNR booking records | 8 PNRs |
| `booking_segments` | Multi-leg itineraries | Connecting flights through hub |

```bash
# Initialize schema and sample data
psql -U <user> -d <database> -f database.sql

# Reset with today-relative flight times (for live demos)
psql -U <user> -d <database> -f reset_data.sql
```

> **Note:** The MCP server includes built-in mock data, so the database is optional. It is needed if you configure the REST API to query PostgreSQL instead of returning hardcoded responses.

---

## How to Run the Demo

### Prerequisites

- TIBCO Flogo Enterprise (v2.26+)
- OpenAI API key (for the AI agent, configured as an app property)
- PostgreSQL (optional, for database-backed REST API)

### Step 1: Deploy the Flogo apps

Import and deploy in this order:

1. **`airline-rest-api.flogo`** (or one of the demo variants) -- Starts on port 9111 (or 3001 for demo variants)
2. **`airline-mcp-server.flogo`** -- Configure the MCP server port. Starts on port 9044
3. **`airline-agent.flogo`** -- Configure the OpenAI API key and MCP server URL. Starts on port 8054

### Step 2: Start the chatbot UI

```bash
cd demos/Agentic_AI/Chatbot
npm install
npm start
```

Open http://localhost:3000 in your browser. Paste the WebSocket URL in the top-right input field and click **Connect**:

```
ws://localhost:8054/ws/passengerserviceagent
```

### Step 3: Run the demo

Use natural language to interact with the agent. See the demo scenarios below.

---

## Demo Scenarios

### Scenario 1: Carlos Martinez (Gold) -- Missed Connection

Carlos is on FL801 BOG->PTY (delayed 90 min) connecting to FL445 PTY->MIA. His new arrival at 12:45 means he'll miss FL445 departing at 12:30.

```
Prompt 1: Hi, I'm on flight FL801 from Bogota. What's the status?
Prompt 2: Oh no, I have a connection. My booking is ABCDE1. Will I make it?
Prompt 3: Yes please rebook me on that flight.
```

**Expected:** Agent detects delay, identifies missed connection, suggests FL447 (PTY->MIA, 15:30 departure), and rebooks after confirmation.

### Scenario 2: Ana Rodriguez (Platinum VIP) -- Tight Connection

Ana is on FL302 PTY->JFK (delayed 45 min). Her booking is FGHIJ2.

```
Prompt 1: Can you check FL302 for me?
Prompt 2: I'm a bit worried. My PNR is FGHIJ2. Am I going to miss my connection?
Prompt 3: Please go ahead and rebook me.
```

**Expected:** Agent recognizes Platinum tier, provides VIP treatment, identifies the tight connection, and rebooks.

### Scenario 3: Roberto Silva (Silver) -- No Disruption

Roberto is on FL445 PTY->MIA, which is on time. PNR: KLMNO3.

```
Prompt 1: What's the status of FL445?
Prompt 2: Great, my booking is KLMNO3. Can you confirm everything looks good?
```

**Expected:** Agent confirms flight is on time and booking is in order.

### Direct Queries

```
What's the status of flight FL801?
Can you check FL447 for me?
What flights are available from PTY to MIA?
```

See [airline-prompts.md](airline-prompts.md) for the full prompt collection.

---

## Sample Passengers

| PNR | Passenger | Loyalty | Route | Scenario |
|-----|-----------|---------|-------|----------|
| ABCDE1 | Carlos Martinez | Gold | BOG->PTY->MIA | FL801 delayed 90 min, misses FL445 connection |
| FGHIJ2 | Ana Rodriguez | Platinum | GRU->PTY->JFK | FL302 delayed 45 min, tight connection |
| KLMNO3 | Roberto Silva | Silver | PTY->MIA | FL445 on time, no disruption |

## Sample Flights

| Flight | Route | Status | Delay | Gate | Aircraft |
|--------|-------|--------|-------|------|----------|
| FL801 | BOG -> PTY | DELAYED | 90 min | B12 | Boeing 737 MAX 9 |
| FL302 | PTY -> JFK | DELAYED | 45 min | A08 | Boeing 737 MAX 9 |
| FL445 | PTY -> MIA | ON_TIME | -- | C03 | Boeing 737-800 |
| FL447 | PTY -> MIA | ON_TIME | -- | C07 | Boeing 737 MAX 9 |
| FL510 | SCL -> PTY | ON_TIME | -- | B05 | Boeing 737-800 |
| FL612 | PTY -> ORD | ON_TIME | -- | A12 | Boeing 737 MAX 9 |
| FL215 | GRU -> PTY | ON_TIME | -- | B09 | Boeing 737 MAX 9 |
