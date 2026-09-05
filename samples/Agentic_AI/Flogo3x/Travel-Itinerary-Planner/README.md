# Travel Itinerary Planner — Agent Trigger with A2A Server and Remote Agents

## Overview

This sample demonstrates the **Agent-to-Agent (A2A) protocol** capability of the **TIBCO Flogo® Agentic AI Connector** using a real-world conference travel coordination scenario. Two independent Flogo applications work together:

- **TravelItineraryPlannerA2A** — An **A2A Server** agent that exposes flight search, hotel search, weather forecast, and itinerary building as tools accessible to any A2A-compatible client over HTTP.
- **EventTravelCoordinator** — A **Local Agent** that adds event-specific intelligence (venue details, partner hotels, attendee registration) and delegates travel operations to the A2A Server via the `remoteAgents` list.

This architecture shows how to decompose a complex workflow into **two decoupled agents** — one domain-generic (travel), one domain-specific (events) — that collaborate via the A2A protocol.

| Pattern | Component | What It Shows |
|---|---|---|
| **A2A Server** | `TravelItineraryPlannerA2A` | Agent Trigger with `agentType: "A2A Server"` — a reusable travel planning service |
| **Remote Agent Client** | `EventTravelCoordinator` | Agent Trigger with `remoteAgents` list — consumes the A2A Server as a remote agent |
| **Invoke AI Agent Trigger** | `EventTravelCoordinator` | REST trigger → `callagent` activity → Agent Trigger dispatch |

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
 │  EventTravelCoordinator (port 9091)                                    │
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
 │  TravelItineraryPlannerA2A (port 9898)                                │
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

## Projects in This Sample

Each project is a Flogo 3 app module (a folder containing `app.fgmd`).

| Project Folder | Description |
|---|---|
| `TravelItineraryPlannerA2A` | **A2A Server** — a standalone travel planning agent exposed via the A2A protocol on port 9898. Has 4 tool handlers (SearchFlights, SearchHotels, GetWeatherForecast, BuildItinerary) with realistic mock data. Can be reused by any A2A-compatible client. |
| `EventTravelCoordinator` | **A2A Client** — a conference travel coordinator with a REST entry point on port 9091. Has 2 local tool handlers (GetEventDetails, RegisterAttendeeTravel) and delegates travel operations to the A2A Server via `remoteAgents`. |

---

## The A2A Feature — How It Works

### A2A Server Configuration (TravelItineraryPlannerA2A)

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

This makes the agent discoverable and callable via HTTP on port 9898. Any A2A-compatible client can connect, discover the agent's capabilities, and delegate travel-related tasks to it. The port, URL, auth mode, and auth token are exposed as App Properties (`A2A.port`, `A2A.AgentUrl`, `A2A.AuthMode`, `A2A.AuthToken`) so you can retarget the server without editing the flow.

### Remote Agent Client Configuration (EventTravelCoordinator)

The client uses `remoteAgents` on its own local Agent Trigger:

```json
{
  "ref": "#agent",
  "id": "EventTravelAgentTrigger",
  "settings": {
    "agentName": "EventTravelAgent",
    "agentType": "Local",
    "remoteAgents": ["conn://TravelPlannerA2A"]
  }
}
```

The connection references the `TravelPlannerA2A` A2A server connection (`connections/TravelPlannerA2A.fgconn`):

```json
{
  "ref": "#a2aserverconnection",
  "name": "TravelPlannerA2A",
  "settings": {
    "serverUrl": "http://localhost:9898",
    "authType": "Static Token",
    "authToken": ""
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

### A2A Server Tools (TravelItineraryPlannerA2A — port 9898)

| Tool | Parameters | Returns |
|---|---|---|
| `SearchFlights` | origin, destination, departureDate, returnDate, passengers, cabinClass | List of matching flights with airline, times, duration, stops, price, seats |
| `SearchHotels` | city, checkInDate, checkOutDate, guests, minStarRating | List of hotels with name, stars, distance, room type, price, amenities |
| `GetWeatherForecast` | destination, startDate, durationDays | Daily forecast with conditions, temps, precipitation, UV, packing tips |
| `BuildItinerary` | tripName, travelerName, startDate, endDate, selectedFlightIds, selectedHotelId, notes | Confirmed itinerary with reference ID, cost summary, next steps |

### Local Tools (EventTravelCoordinator)

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

- **TIBCO Flogo® 3.0.0 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or swap for Anthropic or Gemini in the LLM Provider connection)
- A REST client for testing: [Postman](https://www.postman.com/) or curl

---

## App Properties

Set these in each app's `.fgprops` file (or via the Flogo 3 extension's App Properties view) before running.

### TravelItineraryPlannerA2A

| Property | Default | Set to |
|---|---|---|
| `AgenticAI.openai.LLM_Provider` | `OpenAI` | LLM provider (`OpenAI`, `Anthropic`, or `Gemini`) |
| `AgenticAI.openai.API_Key` | *(secret)* | Your LLM provider API key |
| `AgenticAI.openai.LLM_Base_URL` | *(empty)* | Optional custom endpoint base URL |
| `Trigger_Settings.AgentName` | `TravelPlannerAgent` | Agent name advertised over A2A |
| `Trigger_Settings.AgentDescription` | `A travel itinerary planning agent via A2A protocol. Searches flights, hotels, and weather, then builds complete itineraries.` | Agent description |
| `Trigger_Settings.LLM_Model` | `gpt-5.2` | Model name |
| `Trigger_Settings.LLM_temperature` | `0.7` | Sampling temperature |
| `Trigger_Settings.Token_Limit` | `10000` | Max tokens per request |
| `Trigger_Settings.Rate_Limit` | `25` | Requests per minute |
| `Trigger_Settings.Redact_Sensitive_Data` | `true` | Redact sensitive data in logs |
| `A2A.AgentUrl` | `http://localhost:9898` | Public URL of the A2A Server |
| `A2A.port` | `9898` | Port the A2A Server listens on |
| `A2A.AuthMode` | `Static Token` | Auth mode; set to `None` to disable authentication |
| `A2A.AuthToken` | *(secret)* | Token A2A clients must present when `AuthMode` is `Static Token` |

### EventTravelCoordinator

| Property | Default | Set to |
|---|---|---|
| `AgenticAI.openai.LLM_Provider` | `OpenAI` | LLM provider (`OpenAI`, `Anthropic`, or `Gemini`) |
| `AgenticAI.openai.API_Key` | *(secret)* | Your LLM provider API key |
| `AgenticAI.openai.LLM_Base_URL` | *(empty)* | Optional custom endpoint base URL |
| `Trigger_Settings.AgentName` | `EventTravelAgent` | Local agent name |
| `Trigger_Settings.AgentDescription` | `Conference travel coordinator that manages attendee logistics using a remote A2A travel planning agent.` | Agent description |
| `Trigger_Settings.LLM_Model` | `gpt-5.2` | Model name |
| `Trigger_Settings.LLM_temperature` | `0.7` | Sampling temperature |
| `Trigger_Settings.Token_Limit` | `10000` | Max tokens per request |
| `Trigger_Settings.Rate_Limit` | `25` | Requests per minute |
| `Trigger_Settings.Redact_Sensitive_Data` | `true` | Redact sensitive data in logs |

> **A2A Server connection:** EventTravelCoordinator reaches the A2A Server through the `TravelPlannerA2A` connection (`connections/TravelPlannerA2A.fgconn`), not an App Property. Its defaults are `serverUrl: http://localhost:9898`, `authType: Static Token`, and an empty `authToken`. If you enable authentication on the A2A Server, set the same token here (and match the `A2A.AgentUrl`/`A2A.port` if you change them).

---

## Setup & Run

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `TravelItineraryPlannerA2A`, `EventTravelCoordinator`.
2. Open each app's `.fgprops` file and set the App Properties for your environment (see App Properties above) — LLM provider/API key, A2A URL/auth token, ports.
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select an app module → right-click → **Run As Executable**. The native binary is produced in that app's `bin/` folder and logs stream to the integrated terminal. Start `TravelItineraryPlannerA2A` first, then `EventTravelCoordinator`.
5. Verify and invoke the running agents:

   **Verify the A2A Server** is up (started in step 4 on port 9898):
   ```bash
   curl http://localhost:9898/.well-known/agent.json
   ```

   **Send a travel request** to the Event Travel Coordinator. Its REST endpoint runs on port **9091** and the `EventTravelAgent` Agent Trigger runs internally on port **8091**.

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
| Add authentication | A2A Server App Properties | Set `A2A.AuthMode` to `Static Token` and configure `A2A.AuthToken` (match it in the `TravelPlannerA2A` connection) |
| Use Anthropic Claude | LLM Provider connection | Set `AgenticAI.openai.LLM_Provider` to `Anthropic` and `Trigger_Settings.LLM_Model` to `claude-sonnet-4-5` |
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
</content>
</invoke>
