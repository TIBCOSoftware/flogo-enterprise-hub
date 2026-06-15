# Airline Passenger Services Agent — Demo Blueprint

## 1. Executive Summary

Airline operates a hub-and-spoke network through hub International Airport (PTY) in Panama City, connecting 80+ destinations across the Americas. When an inbound flight is delayed, passengers risk missing their onward connections — triggering manual rebooking by gate agents and call center staff.

This demo shows a **Passenger Services AI Agent** built with TIBCO Flogo that:
1. Checks real-time flight status
2. Looks up passenger bookings by PNR
3. Automatically rebooks disrupted passengers to the next available connection

**Architecture:** REST API (mock backend) → MCP Server (AI tools) → AI Agent (OpenAI GPT-4o) → WebSocket Chat

## 2. Architecture Overview

```
                          Airline Passenger Services Agent
 ┌─────────────────────────────────────────────────────────────────────┐
 │                                                                     │
 │  ┌──────────────┐     ┌───────────────────┐     ┌───────────────┐  │
 │  │  WebSocket    │     │  AI Agent Activity │     │  MCP Server   │  │
 │  │  Chat Client  │────▶│  (OpenAI GPT-4o)   │────▶│  Connection   │  │
 │  │  port 8082    │◀────│  System Prompt:     │     │              │  │
 │  │  /ws/chat     │     │  Airline Customer Svc  │     └──────┬───────┘  │
 │  └──────────────┘     └───────────────────┘            │           │
 │                                                         │           │
 │  airline-agent.flogo                                       │           │
 └─────────────────────────────────────────────────────────┼───────────┘
                                                           │
                                                           ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │  airline-mcp-server.flogo                                              │
 │                                                                     │
 │  MCP Server Trigger — port 9091, path /mcp, stateless              │
 │  ┌────────────────┐ ┌──────────────┐ ┌──────────────────┐          │
 │  │CheckFlightStatus│ │ GetBooking   │ │ RebookPassenger  │          │
 │  │ GET /flights/   │ │ GET /bookings│ │ POST /bookings/  │          │
 │  │ {flightNumber}  │ │ /{pnr}       │ │ {pnr}/rebook     │          │
 │  └───────┬─────────┘ └──────┬───────┘ └────────┬─────────┘          │
 │          │                  │                   │                    │
 │          └──────────────────┼───────────────────┘                    │
 │                             │ InvokeRestService                     │
 └─────────────────────────────┼───────────────────────────────────────┘
                               │
                               ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │  airline-rest-api.flogo                                                │
 │                                                                     │
 │  ReceiveHTTPMessage — port 3000, path /api/*                       │
 │  ┌────────────────┐ ┌──────────────┐ ┌──────────────────┐          │
 │  │GET /api/flights/│ │GET /api/     │ │POST /api/bookings│          │
 │  │{flightNumber}   │ │bookings/{pnr}│ │/{pnr}/rebook     │          │
 │  │                 │ │              │ │                   │          │
 │  │ Returns mock    │ │ Returns mock │ │ Returns mock      │          │
 │  │ flight status   │ │ booking data │ │ rebooked itinerary│          │
 │  └─────────────────┘ └──────────────┘ └───────────────────┘          │
 └─────────────────────────────────────────────────────────────────────┘
```

**Component Summary:**

| Component | Flogo App | Port | Purpose |
|-----------|-----------|------|---------|
| REST Backend | `airline-rest-api.flogo` | 3000 | Mock Airline APIs — flight status, bookings, rebooking |
| MCP Server | `airline-mcp-server.flogo` | 9091 | Expose REST APIs as AI tools via MCP protocol |
| AI Agent | `airline-agent.flogo` | 8082 | OpenAI-powered customer service agent with WebSocket chat |

## 3. Agent Definition

```yaml
Agent: Airline Passenger Services Agent
  Type: AI Agent Activity (embedded in WebSocket flow)
  LLM: OpenAI GPT-4o
  Temperature: 0.3
  ConversationStore: Memory (in-memory, max 20 messages)
  MCP Servers: airline-mcp-server (http://localhost:9091/mcp)

  System Prompt: |
    You are a Airline customer service agent specializing in flight
    disruptions and passenger rebooking at the Panama (PTY) hub.

    CAPABILITIES (via MCP tools):
    - CheckFlightStatus: Look up any Airline flight by flight number (e.g., FL801)
    - GetBooking: Retrieve passenger booking by PNR confirmation code
    - RebookPassenger: Rebook a passenger to an alternative flight

    WORKFLOW:
    1. When a passenger asks about a flight, ALWAYS check flight status first
    2. If the flight is delayed and they have a connection, check their booking
    3. Calculate if they'll miss their connection (< 60 min connection = at risk)
    4. If at risk, suggest rebooking and offer the next available flight
    5. Only rebook after the passenger confirms

    RULES:
    - Be empathetic — disruptions are stressful
    - Always address the passenger by name after looking up their booking
    - Mention their FrequentFlyer tier if Gold or Platinum (VIP treatment)
    - Reference the Panama hub (PTY) — passengers connect through hub
    - NEVER fabricate flight numbers — only use data from CheckFlightStatus
    - If you cannot find a flight or booking, say so honestly

    AIRLINE CONTEXT:
    - Hub: Main Hub Airport
    - Alliance: Global airline alliance member
    - Loyalty: FrequentFlyer (Basic, Silver, Gold, Platinum)
    - Network: 80+ destinations across North, Central, South America & Caribbean
    - Fleet: Boeing 737 MAX 9 and Boeing 737-800
```

## 4. MCP Tool Specification

### Tool: CheckFlightStatus

```yaml
Name: CheckFlightStatus
Description: Check the current status of a Airline flight
Input:
  flightNumber: string (required) — e.g., "FL801"
Output:
  flightNumber: string
  origin: string — IATA code (e.g., "BOG")
  destination: string — IATA code (e.g., "PTY")
  scheduledDeparture: string — ISO datetime
  estimatedDeparture: string — ISO datetime (null if on time)
  status: string — ON_TIME | DELAYED | BOARDING | DEPARTED | CANCELLED
  gate: string
  delayMinutes: integer
  delayReason: string (null if on time)
  aircraft: string
```

### Tool: GetBooking

```yaml
Name: GetBooking
Description: Look up a passenger booking by PNR confirmation code
Input:
  pnr: string (required) — 6-character PNR code (e.g., "ABCDE1")
Output:
  pnr: string
  passenger:
    name: string
    passengerId: string
    email: string
    phone: string
    loyaltyTier: string — Basic | Silver | Gold | Platinum
    loyaltyNumber: string
  segments:
    - flightNumber: string
      origin: string
      destination: string
      departureTime: string
      arrivalTime: string
      seatNumber: string
      cabin: string — Economy | Business
      status: string — CONFIRMED | CHECKED_IN | BOARDED
```

### Tool: RebookPassenger

```yaml
Name: RebookPassenger
Description: Rebook a disrupted passenger to an alternative flight
Input:
  pnr: string (required) — PNR to rebook
  newFlightNumber: string (required) — Target flight for rebooking
Output:
  success: boolean
  message: string
  updatedSegments:
    - flightNumber: string
      origin: string
      destination: string
      departureTime: string
      seatNumber: string
      cabin: string
      status: string
```

## 5. REST API Specifications

### GET /api/flights/{flightNumber}

```yaml
Description: Get current flight status
Path Parameters:
  flightNumber: string — Airline flight number (e.g., FL801)
Response 200:
  {
    "flightNumber": "FL801",
    "origin": "BOG",
    "originCity": "Bogota",
    "destination": "PTY",
    "destinationCity": "Panama City",
    "scheduledDeparture": "2026-05-21T08:30:00-05:00",
    "estimatedDeparture": "2026-05-21T10:00:00-05:00",
    "scheduledArrival": "2026-05-21T11:15:00-05:00",
    "estimatedArrival": "2026-05-21T12:45:00-05:00",
    "status": "DELAYED",
    "gate": "B12",
    "delayMinutes": 90,
    "delayReason": "Late arriving aircraft from GYE",
    "aircraft": "Boeing 737 MAX 9"
  }
Response 404:
  { "error": "Flight not found" }
```

### GET /api/bookings/{pnr}

```yaml
Description: Get passenger booking details
Path Parameters:
  pnr: string — 6-character PNR (e.g., ABCDE1)
Response 200:
  {
    "pnr": "ABCDE1",
    "passenger": {
      "name": "Carlos Martinez",
      "passengerId": "PAX-2026-00101",
      "email": "carlos.martinez@email.com",
      "phone": "+57-310-555-0101",
      "loyaltyTier": "Gold",
      "loyaltyNumber": "FF-98765432"
    },
    "segments": [
      {
        "flightNumber": "FL801",
        "origin": "BOG",
        "destination": "PTY",
        "departureTime": "2026-05-21T08:30:00-05:00",
        "arrivalTime": "2026-05-21T11:15:00-05:00",
        "seatNumber": "4A",
        "cabin": "Business",
        "status": "CHECKED_IN"
      },
      {
        "flightNumber": "FL445",
        "origin": "PTY",
        "destination": "MIA",
        "departureTime": "2026-05-21T12:30:00-05:00",
        "arrivalTime": "2026-05-21T16:45:00-04:00",
        "seatNumber": "3C",
        "cabin": "Business",
        "status": "CONFIRMED"
      }
    ]
  }
Response 404:
  { "error": "Booking not found" }
```

### POST /api/bookings/{pnr}/rebook

```yaml
Description: Rebook passenger to alternative flight
Path Parameters:
  pnr: string — PNR to rebook
Request Body:
  {
    "newFlightNumber": "FL447"
  }
Response 200:
  {
    "success": true,
    "message": "Passenger Carlos Martinez rebooked from FL445 to FL447",
    "updatedSegments": [
      {
        "flightNumber": "FL801",
        "origin": "BOG",
        "destination": "PTY",
        "departureTime": "2026-05-21T08:30:00-05:00",
        "arrivalTime": "2026-05-21T12:45:00-05:00",
        "seatNumber": "4A",
        "cabin": "Business",
        "status": "CHECKED_IN"
      },
      {
        "flightNumber": "FL447",
        "origin": "PTY",
        "destination": "MIA",
        "departureTime": "2026-05-21T15:30:00-05:00",
        "arrivalTime": "2026-05-21T19:45:00-04:00",
        "seatNumber": "5A",
        "cabin": "Business",
        "status": "CONFIRMED"
      }
    ]
  }
Response 404:
  { "error": "Booking not found" }
```

## 6. End-to-End Scenarios

### Scenario 1: Carlos Martinez — Disrupted Connection (BOG → PTY → MIA)

**Passenger:** Carlos Martinez (Gold FrequentFlyer member)
**Booking:** PNR ABCDE1 — FL801 BOG→PTY + FL445 PTY→MIA (Business class)
**Problem:** FL801 delayed 90 minutes — will arrive PTY at 12:45, but FL445 departs at 12:30

```
Timeline:
  08:30  FL801 BOG→PTY scheduled departure
  10:00  FL801 actual departure (90 min delay — late aircraft from GYE)
  12:30  FL445 PTY→MIA scheduled departure ← MISSED
  12:45  FL801 arrives PTY ← passenger arrives AFTER FL445 departed
  15:30  FL447 PTY→MIA next available flight ← REBOOKING TARGET

Sample Prompts:
  1. "Hi, I'm on flight FL801 from Bogota. Is it delayed?"
  2. "Yes, my PNR is ABCDE1. I have a connection to Miami."
  3. "Yes please, rebook me on that flight."
```

### Scenario 2: Ana Rodriguez — Platinum VIP Disrupted Connection (GYE → PTY → GRU)

**Passenger:** Ana Rodriguez (Platinum FrequentFlyer member — VIP)
**Booking:** PNR FGHIJ2 — FL302 GYE→PTY + FL510 PTY→GRU (Business class)
**Problem:** FL302 delayed 45 minutes — will arrive PTY at 10:00, FL510 departs at 11:00 (only 60 min connection — at risk)

```
Timeline:
  07:00  FL302 GYE→PTY scheduled departure
  07:45  FL302 actual departure (45 min delay — weather at GYE)
  10:00  FL302 arrives PTY ← only 60 min before connection
  11:00  FL510 PTY→GRU scheduled departure ← AT RISK (< 60 min after deplaning/transit)
  14:30  FL612 PTY→GRU next available flight ← REBOOKING TARGET

Sample Prompts:
  1. "Can you check the status of flight FL302 from Guayaquil?"
  2. "My booking is FGHIJ2. I'm connecting to Sao Paulo."
  3. "Please rebook me to the next available flight."
```

### Scenario 3: Roberto Silva — Simple Status Check (MDE → PTY)

**Passenger:** Roberto Silva (Silver FrequentFlyer member)
**Booking:** PNR KLMNO3 — FL215 MDE→PTY (Economy, one-way)
**Problem:** None — flight is on time

```
Sample Prompts:
  1. "What's the status of flight FL215 from Medellin?"
  2. "Great, my PNR is KLMNO3. Is everything on schedule?"
```

### Scenario 4: Direct Tool Queries (No Booking Needed)

```
Sample Prompts:
  - "Check the status of flight FL445"
  - "Is flight FL612 on time?"
  - "What gate is flight FL447 departing from?"
```

## 7. Quick Reference Tables

### Flight Schedule (Demo Data)

| Flight | Route | Departure | Arrival | Status | Gate | Aircraft |
|--------|-------|-----------|---------|--------|------|----------|
| FL801 | BOG → PTY | 08:30 (est 10:00) | 11:15 (est 12:45) | DELAYED (90 min) | B12 | Boeing 737 MAX 9 |
| FL445 | PTY → MIA | 12:30 | 16:45 | ON_TIME | A05 | Boeing 737-800 |
| FL447 | PTY → MIA | 15:30 | 19:45 | ON_TIME | A08 | Boeing 737 MAX 9 |
| FL302 | GYE → PTY | 07:00 (est 07:45) | 09:15 (est 10:00) | DELAYED (45 min) | C03 | Airbus A320neo |
| FL510 | PTY → GRU | 11:00 | 19:30 | ON_TIME | D12 | Boeing 787-9 Dreamliner |
| FL612 | PTY → GRU | 14:30 | 23:00 | ON_TIME | D15 | Boeing 787-9 Dreamliner |
| FL215 | MDE → PTY | 06:00 | 08:00 | ON_TIME | B07 | Embraer E195-E2 |

### Booking Data (Demo Data)

| PNR | Passenger | FrequentFlyer Tier | Segments | Scenario |
|-----|-----------|-------------------|----------|----------|
| ABCDE1 | Carlos Martinez | Gold | FL801 BOG→PTY + FL445 PTY→MIA (Business) | Delayed → missed connection → rebook to FL447 |
| FGHIJ2 | Ana Rodriguez | Platinum (VIP) | FL302 GYE→PTY + FL510 PTY→GRU (Business) | Delayed → tight connection → rebook to FL612 |
| KLMNO3 | Roberto Silva | Silver | FL215 MDE→PTY (Economy, one-way) | Simple status check, no disruption |

### API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/flights/{flightNumber}` | Flight status lookup |
| GET | `/api/bookings/{pnr}` | Booking details by PNR |
| POST | `/api/bookings/{pnr}/rebook` | Rebook passenger to new flight |

### MCP Tools

| Tool | Arguments | Returns |
|------|-----------|---------|
| CheckFlightStatus | `flightNumber` | Flight status, times, delay info |
| GetBooking | `pnr` | Passenger info, segments, FrequentFlyer tier |
| RebookPassenger | `pnr`, `newFlightNumber` | Updated itinerary |

### Flight Status Codes

| Status | Meaning |
|--------|---------|
| ON_TIME | Departure within 15 min of schedule |
| DELAYED | Departure delayed — delayMinutes and delayReason provided |
| BOARDING | Passengers boarding at gate |
| DEPARTED | Aircraft has departed |
| CANCELLED | Flight cancelled |

## 8. TIBCO Integration Points

| Component | TIBCO Product | Role |
|-----------|--------------|------|
| REST API Backend | TIBCO Flogo (ReceiveHTTPMessage trigger) | Mock Airline flight/booking APIs |
| MCP Server | TIBCO Flogo (MCP Server trigger) | Expose APIs as AI-consumable tools |
| AI Agent | TIBCO Flogo (AI Agent Activity + WebSocket trigger) | Intelligent customer service orchestration |
| LLM Provider | OpenAI GPT-4o (via Flogo LLM Provider connection) | Natural language understanding and generation |

## 9. Demo Script (5–8 minutes)

### Step 1: Show the Architecture (30 sec)
- Show this document's architecture diagram
- "Two Flogo apps: MCP Server with hardcoded data, AI Agent — all lightweight Go containers"

### Step 2: Show the MCP Server (1 min)
- Open airline-mcp-server.flogo — show 3 tool handlers
- "MCP is the standard protocol for connecting AI models to enterprise tools"
- "Each API becomes an AI-callable tool — CheckFlightStatus, GetBooking, RebookPassenger"

### Step 3: Live Demo — Scenario 1: Carlos (2 min)
- Connect to WebSocket at ws://localhost:8082/ws/chat
- **Prompt 1:** "Hi, I'm on flight FL801 from Bogota. Is it delayed?"
- **Prompt 2:** "Yes, my PNR is ABCDE1. I have a connection to Miami."
- **Prompt 3:** "Yes please, rebook me on that flight."
- Show the agent checking flight status, looking up booking, finding FL447, and rebooking

### Step 4: Live Demo — Scenario 2: Ana / Platinum VIP (2 min)
- Start a new chat session
- **Prompt 1:** "Can you check the status of flight FL302 from Guayaquil?"
- **Prompt 2:** "My booking is FGHIJ2. I'm connecting to Sao Paulo."
- **Prompt 3:** "Please rebook me to the next available flight."
- Highlight: agent recognizes Platinum tier and provides VIP treatment

### Step 5: (Optional) Scenario 3: Roberto — No Disruption (1 min)
- **Prompt 1:** "What's the status of flight FL215 from Medellin?"
- **Prompt 2:** "Great, my PNR is KLMNO3. Is everything on schedule?"
- Show the agent confirming everything is on time — no action needed

### Step 6: Key Takeaways (30 sec)
- "Built in under an hour with TIBCO Flogo — no custom code"
- "Same pattern works for any airline system: loyalty, cargo, crew scheduling"
- "Runs in a < 30 MB container — deploy anywhere"

## 10. Appendix — Sample JSON Payloads

### Flight Status Response (FL801 — Delayed)
```json
{
  "flightNumber": "FL801",
  "origin": "BOG",
  "originCity": "Bogota",
  "destination": "PTY",
  "destinationCity": "Panama City",
  "scheduledDeparture": "2026-05-21T08:30:00-05:00",
  "estimatedDeparture": "2026-05-21T10:00:00-05:00",
  "scheduledArrival": "2026-05-21T11:15:00-05:00",
  "estimatedArrival": "2026-05-21T12:45:00-05:00",
  "status": "DELAYED",
  "gate": "B12",
  "delayMinutes": 90,
  "delayReason": "Late arriving aircraft from GYE",
  "aircraft": "Boeing 737 MAX 9"
}
```

### Booking Response (PNR ABCDE1)
```json
{
  "pnr": "ABCDE1",
  "passenger": {
    "name": "Carlos Martinez",
    "passengerId": "PAX-2026-00101",
    "email": "carlos.martinez@email.com",
    "phone": "+57-310-555-0101",
    "loyaltyTier": "Gold",
    "loyaltyNumber": "FF-98765432"
  },
  "segments": [
    {
      "flightNumber": "FL801",
      "origin": "BOG",
      "destination": "PTY",
      "departureTime": "2026-05-21T08:30:00-05:00",
      "arrivalTime": "2026-05-21T11:15:00-05:00",
      "seatNumber": "4A",
      "cabin": "Business",
      "status": "CHECKED_IN"
    },
    {
      "flightNumber": "FL445",
      "origin": "PTY",
      "destination": "MIA",
      "departureTime": "2026-05-21T12:30:00-05:00",
      "arrivalTime": "2026-05-21T16:45:00-04:00",
      "seatNumber": "3C",
      "cabin": "Business",
      "status": "CONFIRMED"
    }
  ]
}
```

### Rebook Response (ABCDE1 → FL447)
```json
{
  "success": true,
  "message": "Passenger Carlos Martinez rebooked from FL445 to FL447",
  "updatedSegments": [
    {
      "flightNumber": "FL801",
      "origin": "BOG",
      "destination": "PTY",
      "departureTime": "2026-05-21T08:30:00-05:00",
      "arrivalTime": "2026-05-21T12:45:00-05:00",
      "seatNumber": "4A",
      "cabin": "Business",
      "status": "CHECKED_IN"
    },
    {
      "flightNumber": "FL447",
      "origin": "PTY",
      "destination": "MIA",
      "departureTime": "2026-05-21T15:30:00-05:00",
      "arrivalTime": "2026-05-21T19:45:00-04:00",
      "seatNumber": "5A",
      "cabin": "Business",
      "status": "CONFIRMED"
    }
  ]
}
```
