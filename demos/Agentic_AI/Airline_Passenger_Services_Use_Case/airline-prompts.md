# Airline Use Case — All Prompts

## Demo Prompts (Copy-Paste Ready)

Use these prompts to demo the Airline Passenger Services AI Agent end-to-end via the WebSocket chat at `ws://localhost:8054/ws/passengerserviceagent`.

### Scenario 1: Carlos Martinez — Missed Connection + Rebooking (Gold)

> **Prompt 1:** Hi, I'm on flight FL801 from Bogota. Is it delayed?

> **Prompt 2:** Yes, my PNR is ABCDE1. I have a connection to Miami.

> **Prompt 3:** Yes please, rebook me on that flight.

**What happens:** FL801 is delayed 90 min → arrives PTY at 12:45 → misses FL445 (departs 12:30) → agent finds FL447 at 15:30 → rebooks. Hits all 3 tools: CheckFlightStatus → GetBooking → RebookPassenger.

---

### Scenario 2: Ana Rodriguez — Platinum VIP + Rebooking

> **Prompt 1:** Can you check the status of flight FL302 from Guayaquil?

> **Prompt 2:** My booking is FGHIJ2. I'm connecting to Sao Paulo.

> **Prompt 3:** Please rebook me to the next available flight.

**What happens:** FL302 delayed 45 min → arrives PTY at 10:00 → tight connection to FL510 (departs 11:00, only 60 min) → agent finds FL612 at 14:30 → rebooks. Agent recognizes Platinum tier and gives VIP treatment.

---

### Scenario 3: Roberto Silva — Simple Status Check (Silver, No Disruption)

> **Prompt 1:** What's the status of flight FL215 from Medellin?

> **Prompt 2:** Great, my PNR is KLMNO3. Is everything on schedule?

**What happens:** FL215 is on time, one-way flight, no connection issues. Shows the "happy path" where no rebooking is needed.

---

### Scenario 4: Direct Flight Queries (No Booking Needed)

> Check the status of flight FL445

> Is flight FL612 on time?

> What gate is flight FL447 departing from?

**What happens:** Quick single-tool calls to CheckFlightStatus. Good for showing the agent can answer standalone questions.

---

## Build Prompts (Citizen Developer — Natural Language)

These 3 simple prompts are all you need to build the entire Airline Passenger Services demo end-to-end. No technical knowledge required — just describe what you want and let the AI generate everything including mock data.

**Pre-requisite:** Make sure skills from `skills-library/` are available in your session.

---

### Step 1 — Create the API Spec

> I want to build an airline passenger services demo. Create an OpenAPI/Swagger spec with 3 endpoints: check flight status by flight number, look up a passenger booking by PNR code, and rebook a passenger to a different flight. Include fields for flight times, delays, gate, aircraft, passenger name, loyalty tier, seat, cabin class, and booking segments.

---

### Step 2 — Create the MCP Server

> Create a Flogo MCP Server app called "airline-mcp-server" with 3 AI tools based on the API spec I just created: CheckFlightStatus, GetBooking, and RebookPassenger. Generate multiple realistic mock datasets with hardcoded data — include some delayed flights and some on-time flights so I can demo a scenario where a passenger misses a connection and gets rebooked to a later flight on the same route.

---

### Step 3 — Create the AI Agent

> Create a Flogo AI Agent app called "airline-agent" that connects to the MCP server I just created and lets passengers chat via WebSocket. Use OpenAI with low temperature. The agent should check flight status, look up bookings, figure out if a passenger will miss their connection due to a delay, find an alternative on-time flight, and rebook them after they confirm. Be empathetic, address passengers by name, and give VIP treatment to top-tier loyalty members.

---

### What These Prompts Produce

| Step | App | What Gets Generated |
|------|-----|-------------------|
| 1 | `swagger.json` | Full OpenAPI spec with schemas for flights, bookings, rebooking |
| 2 | `airline-mcp-server.flogo` | MCP Server with 3 tools, realistic flight/booking data, conditional routing |
| 3 | `airline-agent.flogo` | AI Agent with WebSocket chat, OpenAI connection, MCP connection, system prompt |

The AI will:
- Infer schemas from the API spec
- Generate realistic flight numbers, passenger names, loyalty tiers, and timings
- Make sure delayed flights create missed-connection scenarios that actually work
- Wire up the agent to the MCP server automatically
- Write a system prompt that drives the correct agent behavior

---

## Build Prompts (Historical)

The original 7 prompts used to build the first version of these apps.

**Total prompts:** 7
**First prompt:** 2026-05-21 12:53:58 UTC
**Last prompt:** 2026-05-21 14:55:17 UTC
**Sessions:**
- Session A — c--Work-github-cp-integration-pm (`d56aaef5-f5dd-4540-9ae5-85ec139f6b68`) — 2 prompts
- Session B — c--Work-VsCode (`0b9f9652-a8fe-45e2-8e9b-92e4a774c0f2`) — 5 prompts

---

### Prompt #1

- **Timestamp:** 2026-05-21 12:53:58 UTC
- **Session:** A (Session A — c--Work-github-cp-integration-pm)

> I have meeting with Airline in 1 hour and I want to introduce flogo to them and show them quick demo ...so can you help me build a very simple use cases relevant to airline industry/vertical which makes them relate to the use case .... for eg you can generate a swagger api spec ...then generate a rest service from that api spec ..then we can expose those api as mcp server tools using flogo MCP Server and then finally use flogo agentic ai connector to build some agentic workflow/orchestration .... first just come up with a very simple / real world use case ...then once i approve the use case ..then you start creating api spec, schema, apps etc after my approval

### Prompt #2

- **Timestamp:** 2026-05-21 12:59:40 UTC
- **Session:** A (Session A — c--Work-github-cp-integration-pm)

> yes .... looks good ... now you can refer to Hospital AI Agent use case - C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case ... create a similar readme first on the workflow like this C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case\hospital-poc.md ... then create database scripts with dummy data like this one ... "C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case\database.sql" and "C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case\reset_data.sql" ...then create api spec .... flogo rest app, mcp server app, agentic ai app ..... you can also use these skills C:\Work\VsCode\FDA\.claude or bring in relevant skills here which ever is easier to you .....first plan then once i approve start building

### Prompt #3

- **Timestamp:** 2026-05-21 13:37:59 UTC
- **Session:** B (Session B — c--Work-VsCode)

> Create a flogo rest service app -  airline-rest-api-demo from this api spec - C:\Work\VsCode\Agentic_AI\Airline_Passenger_Services_Use_Case\swagger.json ... use dummy values in return/reply activities wherever required

### Prompt #4

- **Timestamp:** 2026-05-21 13:45:51 UTC
- **Session:** B (Session B — c--Work-VsCode)

> I do not see schemas created ...nor schemas configured in REST Trigger request/reply settings ... Return activity flow output message field is also not mapped .... pls check for all the missing configurations .... this app is not at all usable .....look at how rest trigger, return activity is configured C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case\endevour-api.flogo

### Prompt #5

- **Timestamp:** 2026-05-21 13:54:57 UTC
- **Session:** B (Session B — c--Work-VsCode)

> you have set path as incorrect in rest trigger settings .... you have set it like - 
> 
> /api/flights/:flightNumber
> 
> it should be - /api/flights/{flightNumber} ... pls fix it for all the rest triggers

### Prompt #6

- **Timestamp:** 2026-05-21 13:59:26 UTC
- **Session:** B (Session B — c--Work-VsCode)

> remember this ..if i ask you create another app from api spec ..you have to make sure you configure it correctly

### Prompt #7

- **Timestamp:** 2026-05-21 14:55:17 UTC
- **Session:** B (Session B — c--Work-VsCode)

> Create a flogo rest service app airline-rest-service-demo2 from this API Spec C:\Work\VsCode\Agentic_AI\Airline_Passenger_Services_Use_Case\swagger.json
