# COPA Airlines Passenger Services Agent — Demo Blueprint

## 1. Executive Summary

COPA Airlines operates a hub-and-spoke network through Tocumen International Airport (PTY) in Panama City, connecting 80+ destinations across the Americas. When an inbound flight is delayed, passengers risk missing their onward connections — triggering manual rebooking by gate agents and call center staff.

This demo shows a **Passenger Services AI Agent** built with TIBCO Flogo that:
1. Checks real-time flight status
2. Looks up passenger bookings by PNR
3. Automatically rebooks disrupted passengers to the next available connection

**Architecture:** REST API (mock backend) → MCP Server (AI tools) → AI Agent (OpenAI GPT-4o) → WebSocket Chat

## 2. Architecture Overview

```
                          COPA Passenger Services Agent
 ┌─────────────────────────────────────────────────────────────────────┐
 │                                                                     │
 │  ┌──────────────┐     ┌───────────────────┐     ┌───────────────┐  │
 │  │  WebSocket    │     │  AI Agent Activity │     │  MCP Server   │  │
 │  │  Chat Client  │────▶│  (OpenAI GPT-4o)   │────▶│  Connection   │  │
 │  │  port 8082    │◀────│  System Prompt:     │     │              │  │
 │  │  /ws/chat     │     │  COPA Customer Svc  │     └──────┬───────┘  │
 │  └──────────────┘     └───────────────────┘            │           │
 │                                                         │           │
 │  copa-agent.flogo                                       │           │
 └─────────────────────────────────────────────────────────┼───────────┘
                                                           │
                                                           ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │  copa-mcp-server.flogo                                              │
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
 │  copa-rest-api.flogo                                                │
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
| REST Backend | `copa-rest-api.flogo` | 3000 | Mock COPA APIs — flight status, bookings, rebooking |
| MCP Server | `copa-mcp-server.flogo` | 9091 | Expose REST APIs as AI tools via MCP protocol |
| AI Agent | `copa-agent.flogo` | 8082 | OpenAI-powered customer service agent with WebSocket chat |

## 3. Agent Definition

```yaml
Agent: COPA Passenger Services Agent
  Type: AI Agent Activity (embedded in WebSocket flow)
  LLM: OpenAI GPT-4o
  Temperature: 0.3
  ConversationStore: Memory (in-memory, max 20 messages)
  MCP Servers: copa-mcp-server (http://localhost:9091/mcp)

  System Prompt: |
    You are a COPA Airlines customer service agent specializing in flight
    disruptions and passenger rebooking at the Panama (PTY) hub.

    CAPABILITIES (via MCP tools):
    - CheckFlightStatus: Look up any COPA flight by flight number (e.g., CM801)
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
    - Mention their ConnectMiles tier if Gold or Presidential (VIP treatment)
    - Reference the Panama hub (PTY) — passengers connect through Tocumen
    - NEVER fabricate flight numbers — only use data from CheckFlightStatus
    - If you cannot find a flight or booking, say so honestly

    COPA CONTEXT:
    - Hub: Tocumen International Airport (PTY), Panama City
    - Alliance: Star Alliance member
    - Loyalty: ConnectMiles (PreferMember, Silver, Gold, Presidential)
    - Network: 80+ destinations across North, Central, South America & Caribbean
    - Fleet: Boeing 737 MAX 9 and Boeing 737-800
```

## 4. MCP Tool Specification

### Tool: CheckFlightStatus

```yaml
Name: CheckFlightStatus
Description: Check the current status of a COPA Airlines flight
Input:
  flightNumber: string (required) — e.g., "CM801"
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
    connectMilesTier: string — PreferMember | Silver | Gold | Presidential
    connectMilesNumber: string
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
  flightNumber: string — COPA flight number (e.g., CM801)
Response 200:
  {
    "flightNumber": "CM801",
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
      "connectMilesTier": "Gold",
      "connectMilesNumber": "CM-98765432"
    },
    "segments": [
      {
        "flightNumber": "CM801",
        "origin": "BOG",
        "destination": "PTY",
        "departureTime": "2026-05-21T08:30:00-05:00",
        "arrivalTime": "2026-05-21T11:15:00-05:00",
        "seatNumber": "4A",
        "cabin": "Business",
        "status": "CHECKED_IN"
      },
      {
        "flightNumber": "CM445",
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
    "newFlightNumber": "CM447"
  }
Response 200:
  {
    "success": true,
    "message": "Passenger Carlos Martinez rebooked from CM445 to CM447",
    "updatedSegments": [
      {
        "flightNumber": "CM801",
        "origin": "BOG",
        "destination": "PTY",
        "departureTime": "2026-05-21T08:30:00-05:00",
        "arrivalTime": "2026-05-21T12:45:00-05:00",
        "seatNumber": "4A",
        "cabin": "Business",
        "status": "CHECKED_IN"
      },
      {
        "flightNumber": "CM447",
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

## 6. End-to-End Scenario

### Scenario: Disrupted Connection — BOG → PTY → MIA

**Passenger:** Carlos Martinez (Gold ConnectMiles member)
**Booking:** PNR ABCDE1 — CM801 BOG→PTY + CM445 PTY→MIA (Business class)
**Problem:** CM801 delayed 90 minutes — will arrive PTY at 12:45, but CM445 departs at 12:30

```
Timeline:
  08:30  CM801 BOG→PTY scheduled departure
  10:00  CM801 actual departure (90 min delay — late aircraft from GYE)
  12:30  CM445 PTY→MIA scheduled departure ← MISSED
  12:45  CM801 arrives PTY ← passenger arrives AFTER CM445 departed
  15:30  CM447 PTY→MIA next available flight ← REBOOKING TARGET

Agent Conversation:

  Passenger: "Hi, I'm on flight CM801 from Bogota. Is it delayed?"

  Agent: [calls CheckFlightStatus(CM801)]
         "Yes, flight CM801 from Bogota to Panama City is currently delayed
          by 90 minutes. The new estimated departure is 10:00 AM, arriving
          PTY at 12:45 PM. The delay is due to a late arriving aircraft
          from Guayaquil. May I check if this affects a connection?"

  Passenger: "Yes, my PNR is ABCDE1. I have a connection to Miami."

  Agent: [calls GetBooking(ABCDE1)]
         "Mr. Martinez, I can see your booking. You're a Gold ConnectMiles
          member — thank you for your loyalty. Your connection CM445 to
          Miami departs at 12:30 PM, but with the delay you'll arrive at
          12:45 PM — unfortunately you'll miss that connection.

          The next available flight to Miami is CM447 departing at 3:30 PM,
          arriving at 7:45 PM. Shall I rebook you on CM447?"

  Passenger: "Yes please, go ahead."

  Agent: [calls RebookPassenger(ABCDE1, CM447)]
         "Done! You've been rebooked on CM447 to Miami:
          - New departure: 3:30 PM from PTY
          - New arrival: 7:45 PM in Miami
          - Seat 5A, Business class
          Your first segment CM801 is unchanged. Is there anything
          else I can help you with?"
```

## 7. Quick Reference Tables

### Flight Schedule (Demo Data)

| Flight | Route | Departure | Arrival | Status | Gate |
|--------|-------|-----------|---------|--------|------|
| CM801 | BOG → PTY | 08:30 | 11:15 | DELAYED (90 min) | B12 |
| CM445 | PTY → MIA | 12:30 | 16:45 | ON_TIME | A08 |
| CM447 | PTY → MIA | 15:30 | 19:45 | ON_TIME | A12 |
| CM215 | GRU → PTY | 06:00 | 11:30 | ON_TIME | C04 |
| CM302 | PTY → JFK | 13:00 | 19:15 | ON_TIME | A15 |
| CM510 | SCL → PTY | 07:15 | 12:45 | DELAYED (45 min) | C08 |
| CM612 | PTY → ORD | 14:00 | 19:30 | ON_TIME | A20 |
| CM725 | LIM → PTY | 09:00 | 13:30 | ON_TIME | B06 |

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
| GetBooking | `pnr` | Passenger info, segments, ConnectMiles tier |
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
| REST API Backend | TIBCO Flogo (ReceiveHTTPMessage trigger) | Mock COPA flight/booking APIs |
| MCP Server | TIBCO Flogo (MCP Server trigger) | Expose APIs as AI-consumable tools |
| AI Agent | TIBCO Flogo (AI Agent Activity + WebSocket trigger) | Intelligent customer service orchestration |
| LLM Provider | OpenAI GPT-4o (via Flogo LLM Provider connection) | Natural language understanding and generation |

## 9. Demo Script (5 minutes)

### Step 1: Show the Architecture (30 sec)
- Show this document's architecture diagram
- "Three Flogo apps: REST backend, MCP Server, AI Agent — all lightweight Go containers"

### Step 2: Show the REST API (1 min)
- Open copa-rest-api.flogo in VS Code — show the 3 flows
- `curl http://localhost:3000/api/flights/CM801` — show delayed flight response
- "This is your existing flight operations API — we connect to it, not replace it"

### Step 3: Show the MCP Server (1 min)
- Open copa-mcp-server.flogo — show 3 tool handlers
- "MCP is the standard protocol for connecting AI models to enterprise tools"
- "Each API becomes an AI-callable tool — CheckFlightStatus, GetBooking, RebookPassenger"

### Step 4: Live Agent Conversation (2 min)
- Connect to WebSocket at ws://localhost:8082/ws/chat
- Run the disruption scenario from Section 6
- Show the agent checking flight status, looking up booking, offering rebooking

### Step 5: Key Takeaways (30 sec)
- "Built in under an hour with TIBCO Flogo — no custom code"
- "Same pattern works for any COPA system: loyalty, cargo, crew scheduling"
- "Runs in a < 30 MB container — deploy anywhere"

## 10. Appendix — Sample JSON Payloads

### Flight Status Response (CM801 — Delayed)
```json
{
  "flightNumber": "CM801",
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
    "connectMilesTier": "Gold",
    "connectMilesNumber": "CM-98765432"
  },
  "segments": [
    {
      "flightNumber": "CM801",
      "origin": "BOG",
      "destination": "PTY",
      "departureTime": "2026-05-21T08:30:00-05:00",
      "arrivalTime": "2026-05-21T11:15:00-05:00",
      "seatNumber": "4A",
      "cabin": "Business",
      "status": "CHECKED_IN"
    },
    {
      "flightNumber": "CM445",
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

### Rebook Response (ABCDE1 → CM447)
```json
{
  "success": true,
  "message": "Passenger Carlos Martinez rebooked from CM445 to CM447",
  "updatedSegments": [
    {
      "flightNumber": "CM801",
      "origin": "BOG",
      "destination": "PTY",
      "departureTime": "2026-05-21T08:30:00-05:00",
      "arrivalTime": "2026-05-21T12:45:00-05:00",
      "seatNumber": "4A",
      "cabin": "Business",
      "status": "CHECKED_IN"
    },
    {
      "flightNumber": "CM447",
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
