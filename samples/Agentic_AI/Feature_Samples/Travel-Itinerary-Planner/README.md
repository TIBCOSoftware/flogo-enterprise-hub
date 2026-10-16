# Travel Itinerary Planner — Agent Trigger with A2A Server and Remote Agents

## Overview

This sample demonstrates the **Agent-to-Agent (A2A) protocol** capability of the **TIBCO Flogo® Agentic AI Connector** using a real-world conference travel coordination scenario. Two independent Flogo applications work together:

- **TravelItineraryPlannerA2A.flogo** — An **A2A Server** agent that exposes flight search, hotel search, weather forecast, and itinerary building as tools accessible to any A2A-compatible client over HTTP.
- **EventTravelCoordinator.flogo** — A **Local Agent** that adds event-specific intelligence (venue details, partner hotels, attendee registration) and delegates travel operations to the A2A Server via the `remoteAgents` list.

This architecture shows how to decompose a complex workflow into **two decoupled agents** — one domain-generic (travel), one domain-specific (events) — that collaborate via the A2A protocol.

| Pattern | Component | What It Shows |
|---|---|---|
| **A2A Server** | `TravelItineraryPlannerA2A.flogo` | Agent Trigger with `agentType: "A2A Server"` — a reusable travel planning service |
| **Remote Agent Client** | `EventTravelCoordinator.flogo` | Agent Trigger with `remoteAgents` list — consumes the A2A Server as a remote agent |
| **Invoke AI Agent Trigger** | `EventTravelCoordinator.flogo` | REST trigger → `callagent` activity → Agent Trigger dispatch |

---

## Real-World Scenario

**Persona**: Maria, an event coordinator at Summit Events, needs to book travel for a conference speaker.

```
Maria: "I need to arrange travel for Alex Rivera, a speaker at the European
        Tech Summit 2026. He's flying from New York."

EventTravelAgent: [Calls GetEventDetails for SUMMIT-2026-EU]
        "The European Tech Summit 2026 runs July 14–16 at Palais des Congrès
         in Paris. Pre-conference workshops start July 13. The nearest airport
         is CDG (28 km, 45 min by RER B).

         We have 3 partner hotels with event-negotiated rates:
         • Hyatt Regency Paris Étoile (4★, 300m) — $195/night (code: SUMMIT2026)
         • Hotel Concorde Montparnasse (4★, 1.5km) — $165/night
         • Ibis Paris Porte Maillot (3★, 200m) — $110/night

         As a speaker, I'd recommend arriving July 13 for the workshops.
         Let me search flights from JFK to CDG..."

EventTravelAgent: [Delegates to TravelPlanner A2A → SearchFlights]
        "Here are the available flights for July 13:

         | Airline        | Flight | Departs  | Arrives  | Stops | Price |
         |----------------|--------|----------|----------|-------|-------|
         | United Airlines| UA 456 | 08:30    | 22:15    | 0     | $598  |
         | Air France     | AF 006 | 23:55    | 13:25+1  | 0     | $645  |
         | Delta          | DL 402 | 11:00    | 01:20+1  | 1     | $512  |

         For a speaker, I'd recommend the UA 456 — nonstop and arrives
         evening of Jul 13 with time to settle in."

Maria: "Go with United and the Hyatt Regency."

EventTravelAgent: [Delegates to TravelPlanner A2A → BuildItinerary]
                   [Calls RegisterAttendeeTravel]
        "All set! Here's Alex's confirmed travel:

         ✓ Flight: UA 456 JFK → CDG, Jul 13 (nonstop, 7h 45m) — $598
         ✓ Hotel: Hyatt Regency Paris Étoile, Jul 13–17 (4 nights) — $780
         ✓ Total: $1,378
         ✓ Shuttle: Complimentary CDG shuttle booked for Jul 13 at 2:00 PM

         Registration ID: REG-SUMMIT-2026-00848
         Badge type: Speaker
         Speaker prep session: Jul 14 at 8:00 AM in Room B3

         E-badge and hotel voucher will be sent to alex.r@techcorp.com."
```

**One conversation. Two cooperating agents. Local event context + remote travel search — seamlessly combined via A2A.**

---

## Architecture

```
 User (REST Client — Postman, curl, etc.)
      │  POST http://localhost:9091/event-travel/{eventId}
      │  Body: {"request": "Book travel for a speaker at the European Tech Summit"}
      ▼
 ┌───────────────────────────────────────────────────────────────────────┐
 │  EventTravelCoordinator.flogo (port 9091)                            │
 │                                                                       │
 │  REST Trigger ──► event_travel_flow                                  │
 │                          │                                            │
 │          ┌───────────────▼───────────────────┐                       │
 │          │  InvokeAIAgentTrigger (callagent)  │                       │
 │          │  agentName: "EventTravelAgent"     │                       │
 │          └───────────────┬───────────────────┘                       │
 │                          │ dispatches to                              │
 │          ┌───────────────▼───────────────────────────┐               │
 │          │  Agent Trigger: EventTravelAgent           │               │
 │          │  agentType: Local  (port 8091)              │               │
 │          │                                             │               │
 │          │  remoteAgents: [              KEY FEATURE   │               │
 │          │    TravelPlannerA2A ──────────────────────────────┐        │
 │          │  ]                                          │     │        │
 │          │                                             │     │        │
 │          │  Local Tools (Flogo flows):                 │     │        │
 │          │    • GetEventDetails (venue, airports, etc.) │     │        │
 │          │    • RegisterAttendeeTravel (log booking)   │     │        │
 │          └─────────────────────────────────────────────┘     │        │
 └──────────────────────────────────────────────────────────────│────────┘
                                                                │
                                        A2A protocol (HTTP)     │
                                                                │
 ┌──────────────────────────────────────────────────────────────▼────────┐
 │  TravelItineraryPlannerA2A.flogo (port 9898)                          │
 │  agentType: "A2A Server"                                              │
 │                                                                        │
 │  Agent Trigger: TravelPlannerAgent                                    │
 │                                                                        │
 │  Tools (exposed to any A2A client):                                   │
 │    • SearchFlights      (origin, destination, date, passengers, class) │
 │    • SearchHotels       (city, check-in, check-out, guests, stars)    │
 │    • GetWeatherForecast (destination, start date, duration)           │
 │    • BuildItinerary     (trip details → confirmed itinerary)          │
 │                                                                        │
 │  System Prompt: Travel itinerary planning specialist                  │
 │  Conversation Store: Memory (20 messages)                             │
 │  Guardrails: Enabled                                                  │
 └────────────────────────────────────────────────────────────────────────┘
```

---

## Files in This Sample

| File | Description |
|---|---|
| `TravelItineraryPlannerA2A.flogo` | **A2A Server** — a standalone travel planning agent exposed via the A2A protocol on port 9898. Has 4 tool handlers (SearchFlights, SearchHotels, GetWeatherForecast, BuildItinerary) with realistic mock data. Can be reused by any A2A-compatible client. |
| `EventTravelCoordinator.flogo` | **A2A Client** — a conference travel coordinator with a REST entry point on port 9091. Has 2 local tool handlers (GetEventDetails, RegisterAttendeeTravel) and delegates travel operations to the A2A Server via `remoteAgents`. |

---

## The A2A Feature — How It Works

### A2A Server Configuration (TravelItineraryPlannerA2A.flogo)

The key is `agentType: "A2A Server"` on the Agent Trigger:

```json
{
  "ref": "#agent",
  "id": "TravelPlannerA2AServer",
  "settings": {
    "agentName": "TravelPlannerAgent",
    "agentType": "A2A Server",
    "agentPort": "9898",
    "agentUrl": "http://localhost:9898",
    "agentAuthMode": "Static Token",
    "model": "gpt-5.2",
    "conversationStoreType": "Memory"
  },
  "handlers": [
    { "agentToolName": "SearchFlights",      "handlerType": "Tool" },
    { "agentToolName": "SearchHotels",       "handlerType": "Tool" },
    { "agentToolName": "GetWeatherForecast", "handlerType": "Tool" },
    { "agentToolName": "BuildItinerary",     "handlerType": "Tool" }
  ]
}
```

This makes the agent discoverable and callable via HTTP on port 9898. Any A2A-compatible client can connect, discover the agent's capabilities, and delegate travel-related tasks to it.

### Remote Agent Client Configuration (EventTravelCoordinator.flogo)

The client uses `remoteAgents` on its own local Agent Trigger:

```json
{
  "ref": "#agent",
  "id": "EventTravelAgentTrigger",
  "settings": {
    "agentName": "EventTravelAgent",
    "agentType": "Local",
    "remoteAgents": ["conn://ca33bbbb-1111-2222-3333-444455550003"]
  }
}
```

The connection ID references an `a2aserverconnection`:

```json
{
  "ref": "#a2aserverconnection",
  "name": "TravelPlannerA2A",
  "settings": {
    "serverUrl": "http://localhost:9898",
    "authType": "Static Token",
    "authToken": "..."
  }
}
```

At runtime, the client agent's LLM sees both its **local tools** (GetEventDetails, RegisterAttendeeTravel) and all **remote tools** from the A2A Server (SearchFlights, SearchHotels, etc.) as one unified toolset. The Agentic AI Connector transparently routes each tool call to the right destination — local Flogo flow or remote A2A Server.

### REST → Agent Dispatch (event_travel_flow)

```json
{
  "ref": "#callagent",
  "input": {
    "agentName": "EventTravelAgent",
    "prompt": "=$flow.body.request",
    "conversationId": "=$flow.pathParams.eventId"
  }
}
```

The `eventId` path parameter serves as the conversation ID, so multiple requests about the same event share context.

---

## Tool Reference

### A2A Server Tools (TravelItineraryPlannerA2A.flogo — port 9898)

| Tool | Parameters | Returns |
|---|---|---|
| `SearchFlights` | origin, destination, departureDate, returnDate, passengers, cabinClass | List of matching flights with airline, times, duration, stops, price, seats |
| `SearchHotels` | city, checkInDate, checkOutDate, guests, minStarRating | List of hotels with name, stars, distance, room type, price, amenities |
| `GetWeatherForecast` | destination, startDate, durationDays | Daily forecast with conditions, temps, precipitation, UV, packing tips |
| `BuildItinerary` | tripName, travelerName, startDate, endDate, selectedFlightIds, selectedHotelId, notes | Confirmed itinerary with reference ID, cost summary, next steps |

### Local Tools (EventTravelCoordinator.flogo)

| Tool | Parameters | Returns |
|---|---|---|
| `GetEventDetails` | eventId, eventName | Venue, dates, nearest airports (IATA codes + transit times), partner hotels with event rates, shuttle service, registration count |
| `RegisterAttendeeTravel` | eventId, attendeeName, attendeeEmail, attendeeRole, flightDetails, hotelDetails, arrivalDate, departureDate | Registration ID, badge type, shuttle booking, speaker prep details, next steps |

---

## Sample Data

### Event: European Tech Summit 2026

| Field | Value |
|---|---|
| Event ID | SUMMIT-2026-EU |
| Venue | Palais des Congrès, Paris |
| Dates | Jul 14–16, 2026 (workshops Jul 13) |
| Nearest Airport | CDG (28 km, 45 min RER B) |
| Registered | 847 / 1,200 |

### Partner Hotels (event-negotiated rates)

| Hotel | Stars | Distance | Event Rate | Promo Code |
|---|---|---|---|---|
| Hyatt Regency Paris Étoile | 4★ | 300m | $195/night | SUMMIT2026 |
| Hotel Concorde Montparnasse | 4★ | 1.5 km | $165/night | SUMMIT2026 |
| Ibis Paris Porte Maillot | 3★ | 200m | $110/night | SUMMIT2026 |

### Flight Results (mock — JFK → CDG)

| Airline | Flight | Departure | Arrival | Stops | Price |
|---|---|---|---|---|---|
| United Airlines | UA 456 | 08:30 | 22:15 | Nonstop | $598 |
| Air France | AF 006 | 23:55 | 13:25+1 | Nonstop | $645 |
| Delta | DL 402 | 11:00 | 01:20+1 | 1 (BOS) | $512 |

---

## Prerequisites

- **TIBCO Flogo® 2.26.7 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or swap for Anthropic or Gemini in the LLM Provider connection)
- A REST client for testing: [Postman](https://www.postman.com/) or curl

---

## Setup & Configuration

### Step 1 — Configure the A2A Server

Open `TravelItineraryPlannerA2A.flogo` in the Flogo VS Code extension. In the **App Properties**, set your API key:

```
AgenticAI.openai.API_Key = sk-your-key-here
```

Optionally update `A2A.AuthToken` if you want a custom authentication token, or set `A2A.AuthMode` to `None` to disable authentication.

### Step 2 — Start the A2A Server

Run `TravelItineraryPlannerA2A.flogo`. This starts the A2A Server agent on port **9898**.

Verify it is running:
```bash
curl http://localhost:9898/.well-known/agent.json
```

### Step 3 — Configure the Event Travel Coordinator

Open `EventTravelCoordinator.flogo`. In the **App Properties**, set:

~~~
AgenticAI.openai.API_Key = sk-your-key-here
~~~

If you enabled authentication on the A2A Server, update the `TravelPlannerA2A` connection in `EventTravelCoordinator.flogo` to set the A2A `serverUrl` and `authToken` accordingly.

### Step 4 — Start the Event Travel Coordinator

Run `EventTravelCoordinator.flogo`. This starts:
- The **EventTravelAgent** Agent Trigger internally on port 8091
- The **REST endpoint** on port **9091**

### Step 5 — Send a Travel Request

Use any REST client to POST a travel coordination request.

**curl**:
```bash
curl -X POST http://localhost:9091/event-travel/SUMMIT-2026-EU \
  -H "Content-Type: application/json" \
  -d '{"request": "I need to book travel for Alex Rivera, a speaker flying from New York for the European Tech Summit."}'
```

**Postman**: Create a POST request to `http://localhost:9091/event-travel/SUMMIT-2026-EU` with JSON body:
```json
{
  "request": "I need to book travel for Alex Rivera, a speaker flying from New York for the European Tech Summit."
}
```

---

## Sample Queries

### Event-Aware Travel Planning

```
Book travel for a speaker named Alex Rivera flying from JFK for the European Tech Summit.
```
```
What are the nearest airports to the summit venue and which partner hotels are available?
```
```
Find economy flights from SFO to Paris arriving July 12 for a general attendee.
```
```
What's the weather forecast for Paris during the summit week? What should attendees pack?
```

### Multi-Turn Conversation (uses same eventId for context)

```
Turn 1: What are the details for the European Tech Summit 2026?
Turn 2: Search flights from JFK to CDG on July 13 for 1 passenger.
Turn 3: I'll take the United flight. Book the Hyatt Regency for 4 nights.
Turn 4: Register this travel for Alex Rivera, speaker, alex.r@techcorp.com.
```

### Group Coordination

```
I need to arrange travel for 3 attendees from Chicago to the European Tech Summit.
All arriving July 13, departing July 17. Find flights and recommend the
budget-friendly partner hotel.
```

---

## Why A2A Architecture Matters

| Without A2A | With A2A (this sample) |
|---|---|
| Travel logic embedded in every app that needs it | One reusable A2A travel agent, consumed by many clients |
| Adding event context = modifying the travel app | Event logic stays in EventTravelCoordinator, travel agent untouched |
| Tight coupling between travel and domain logic | Loose coupling — swap the travel agent or add new clients independently |
| One monolithic system prompt trying to do everything | Two focused prompts — each agent is an expert in its domain |
| Scaling = scaling the whole monolith | Scale the travel A2A Server independently from client apps |

The A2A protocol lets you build **composable AI agents** — each one a focused expert, discoverable over HTTP, and orchestrated by the LLM's own judgment about which tool to call.

---

## What to Customize

| Customization | Where | How |
|---|---|---|
| Connect to a real flight API | `search_flights_flow` in A2A Server | Replace `actreturn` with an Invoke REST Service activity calling Amadeus, Sabre, or Duffel API |
| Connect to a real hotel API | `search_hotels_flow` in A2A Server | Replace `actreturn` with a call to Booking.com, Expedia, or HotelBeds API |
| Use a real weather service | `get_weather_flow` in A2A Server | Replace `actreturn` with OpenWeatherMap or AccuWeather API call |
| Persist attendee registrations | `register_attendee_travel_flow` in Coordinator | Replace `actreturn` with a database insert (JDBC) or CRM API call |
| Load real event data | `get_event_details_flow` in Coordinator | Replace `actreturn` with a call to your event management system |
| Add authentication | A2A Server trigger settings | Change `agentAuthMode` to `Static Token` or `JWT` and configure the token |
| Use Anthropic Claude | LLM Provider connection | Change `llmProvider` to `Anthropic` and set model to `claude-sonnet-4-5` |
| Add a second A2A client | New Flogo app | Create another app with `remoteAgents` pointing to the same A2A Server — e.g., a corporate travel assistant or a travel agency concierge |
| Add spending guardrails | Agent Trigger handler | Add a `CustomGuardrail` handler on the Coordinator to enforce budget limits |

---

## Extending to Production

1. **Replace mock data** in each tool flow's `actreturn` with live API calls to flight, hotel, and weather services
2. **Connect `register_attendee_travel_flow`** to your event management database or CRM
3. **Add a custom guardrail** to enforce budget limits per attendee role (Speaker vs. General Attendee)
4. **Switch to a durable conversation store** for audit trails — add a `CustomConversationStore` handler backed by a database
5. **Deploy the A2A Server independently** — it can serve multiple client applications (event coordinator, corporate travel, travel agency) simultaneously
6. **Add more A2A Server agents** — e.g., a ground transportation A2A agent or a restaurant reservation agent — and reference them all in `remoteAgents`

See the [Healthcare Compliance Agent](../Healthcare-Compliance-Agent/) sample for a full demonstration of custom guardrails and durable conversation stores, and the [Mobile Customer Care Multi-Agent Hub](../Mobile-Customer-Care-Multi-Agent/) for the complementary `agentHandoffs` pattern.
