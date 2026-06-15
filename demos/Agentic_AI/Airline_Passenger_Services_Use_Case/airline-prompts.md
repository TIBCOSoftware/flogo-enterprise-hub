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

