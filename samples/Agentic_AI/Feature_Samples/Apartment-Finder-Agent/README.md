# Apartment Finder Agent

## Overview

A conversational apartment-hunting assistant built on the **TIBCO Flogo® AI Agent Activity**, fronted by a **WebSocket trigger** so renters can chat with it in a browser, and backed by a **Flogo MCP Server** that exposes eight apartment-search tools over the Model Context Protocol.

The renter describes what they want in plain English — budget, bedrooms, commute, amenities, safety — and the agent autonomously chains MCP tool calls to resolve a place name to zip codes, shortlist communities, pull rent and availability, compare amenities and proximity, check the trailing-12-month crime record, and finally **book a tour and email the confirmation** to both the renter and the community's leasing office.

Two Flogo applications:

| App | Trigger | Role |
|---|---|---|
| `ApartmentFinderAgent.flogo` | **WebSocket Server** (`:9097`) | Chat front end. AI Agent Activity with conversation memory and the MCP tool set attached. |
| `ApartmentFinderMCPTools.flogo` | **MCP Server** (`:9606`, stateless HTTP) | Eight tools over a synthetic Houston-metro apartment dataset, plus a **Send Mail** action tool. |

---

## Real-World Scenario

**Persona**: Priya is relocating to Houston and wants a one-bedroom near a gym, with a short hop to the interstate and a clean safety record.

```
Priya: "I'm moving to Houston, Texas. I'm looking for a 1 bedroom apartment
        with rent between $1200 and $1700. I'm a sports enthusiast so I need
        great amenities — gym, swimming pool, sports facility. Lowest crime
        reports, and easy access to a major interstate."

Agent:  [search_locations("Houston") -> resolves the whole serviced metro]
        [find_communities("77494"), ("77477"), ("77479") -> 11 communities + rent summary]
        [get_rent_pricing / get_amenities / get_proximity / get_safety_record on the shortlist]

        "Springs at Katy is the closest match to your amenity list, and I-10 is
         2.4 miles out. Katy West Bend has a stronger safety record if you'd
         trade the yoga studio for it."

        * **Springs at Katy** (CMTY-0076, 77494)
          - **1BR rent:** $1,500 - $1,700 (median $1,575)
          - **Availability:** 11 units, Available Now
          - **Recreation:** Swimming Pool
          - **Recreation:** Yoga & Spin Studio
          - **Recreation:** Dog Park
          - **Highway access:** I-10 Katy Freeway 2.4 mi
          - **Safety:** Safe, score 77
        ...

Priya: "Book me a visit to Springs at Katy this Saturday at 2pm."

Agent:  [get_community_contact("CMTY-0076") -> office hours, lead time, phone]
        "Saturday is 2026-09-19 — the office is open 10:00-17:00, so 14:00 works.
         What's your name and email so I can send the confirmation?"

Priya: "Priya Raman, priya.raman@mailinator.com"

Agent:  [schedule_visit(...) -> emails renter AND leasing office]
        "Booked. Confirmation sent to you and to the Springs at Katy leasing
         office. Arrive 10 minutes early and call (281) 555-1467 before you go."
```

**One conversation. Eight tools. A real email in two inboxes.**

---

## Architecture

```
┌────────────┐   ws://localhost:9097/apartment-finder?sessionId=…
│  Browser   │◄──────────────────────────────────────────────┐
│  Chatbot   │                                               │
└────────────┘                                               │
                                                             │
┌────────────────────────────────────────────────────────────┴─────────────┐
│ ApartmentFinderAgent.flogo                          WebSocket Server :9097│
│                                                                           │
│   StartActivity ──► ProcessAIAgent ──► WebsocketWriteData                 │
│      (#noop)        (AI Agent Activity)   (#wswritedata)                  │
│                       • conversationStoreType: Memory (20 turns)          │
│                       • conversationId: apartment-session-<sessionId>     │
│                       • mcpServers: [ApartmentFinderMCPTools]             │
│                       • temperature 0.0 = provider default                │
└───────────────────────────────┬───────────────────────────────────────────┘
                                │ MCP streamable HTTP
                                ▼  http://localhost:9606/mcp
┌──────────────────────────────────────────────────────────────────────────┐
│ ApartmentFinderMCPTools.flogo                        MCP Server :9606     │
│                                                                           │
│  Read tools        StartActivity ──► Return                               │
│                       (#noop)       (#actreturn, @conditional lookup)     │
│                                                                           │
│  schedule_visit    StartActivity ──► ResolveCommunity ──► SendAppointment │
│                       (#noop)          (#mapper)            Email         │
│                                                           (#sendmail)     │
│                                              └──► Return (#actreturn)     │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## The Tools

| # | Tool | Argument(s) | Returns |
|---|---|---|---|
| 1 | `search_locations` | `city` | Zip codes for a city, with county, metro, cost-of-living index and major highways. Pass `Houston` to resolve the whole serviced metro in one call. |
| 2 | `find_communities` | `zip_code` | Every community in a zip, plus a `rentSummary` (median 1BR, rent range, available units, unit types) so the agent can shortlist before fanning out. |
| 3 | `get_rent_pricing` | `community_id` | Rent range, specials, utilities, pet rent, parking, and per-unit-type detail: sq ft, `rentRange [low, median, high]`, availability, next available date, deposits and fees. |
| 4 | `get_amenities` | `community_id` | Amenity count and score, pet policy, parking, full amenity list by category, in-unit features, green certifications. |
| 5 | `get_proximity` | `community_id` | Location/walk/transit/bike scores, a `valueException` flag, distance summary, and nearby places with drive times and GreatSchools ratings. |
| 6 | `get_safety_record` | `community_id` | Trailing-12-month incidents (total / violent / property), per-1000-units rate, safety score and rating, on-site security, incident breakdown by type. |
| 7 | `get_community_contact` | `community_id` | Leasing office card: agent name, email, phone, address, office hours, tour types, `appointmentLeadTimeHours`, `arriveMinutesEarly`. |
| 8 | `schedule_visit` | `community_id`, `visit_date`, `visit_time`, `customer_name`, `customer_email`, `unit_type` | **Sends email.** Books a tour and mails the confirmation to the renter *and* the leasing office. Returns the confirmed details as `key=value` lines. |

Tools 1–7 are read-only. **`schedule_visit` is the only one with a side effect.**

### Why the email addresses come from the server

`schedule_visit` takes a `community_id`, not a community email. The flow's `#mapper` step resolves the ID to the leasing office's contact card via a `@conditional` lookup, and `#sendmail` builds its recipient list from *that*:

```
recipients = string.concat($flow.arguments.customer_email, ",",
                           $activity[ResolveCommunity].output.contact.email)
```

The LLM supplies the renter's address and nothing else. It cannot redirect the community's copy of the confirmation, even if it hallucinates an address — a small but useful containment property for any agent tool that reaches the outside world.

---

## The Dataset

Synthetic data for a **Houston-metro pilot slice** — 11 communities across three zip codes:

| Zip | City | Communities |
|---|---|---|
| 77477 | Stafford | CMTY-0077 – CMTY-0080 |
| 77479 | Sugar Land | CMTY-0085 – CMTY-0087 |
| 77494 | Katy | CMTY-0073 – CMTY-0076 |

The slice is deliberately shaped for demos: it includes a `valueException` community (cheap but unusually well located) and a spread of safety scores, so trade-off questions have real answers.

Every value is fabricated. Phone numbers use the reserved `555` exchange, websites point at `example-apartments.com`, and **every leasing office email is a public [mailinator.com](https://www.mailinator.com) inbox** — no signup needed to read the confirmation mail, and unusable for anything real.

**Coverage is enforced in the system prompt.** Houston-metro requests are answered; other Texas locations get an honest "not in the serviced data yet"; anything outside Texas or off-topic gets a fixed refusal. See *Guardrails* below.

---

## Guardrails

The agent's behaviour is pinned by the `AgenticAI.systemPrompt` app property (~9 KB), which enforces:

- **Scope** — Texas apartment search only. Off-topic questions, non-Texas locations, invalid places, and prompt-injection attempts all get one fixed sentence, with no tool call burned first.
- **Houston resolution** — Katy, Stafford and Sugar Land *are* the Houston inventory. The agent never tells a renter that Houston is unavailable, and never asks which suburb to search first.
- **Grounding** — never invent a rent, date, fee, distance, school rating or crime figure. If a tool returns not-found, say so.
- **Response format** — bold community names as top-level bullets, one feature per indented sub-bullet line, no markdown tables.
- **Booking discipline** — resolve relative dates to `YYYY-MM-DD` and read them back, validate the slot against office hours and lead time, never call `schedule_visit` twice, never claim a booking the tool did not confirm.
- **Fair housing** — compare on rent, amenities, commute, schools and reported statistics only; never on the demographics of residents.

---

## Prerequisites

- **TIBCO Flogo® Enterprise 2.26.7+** with the **Agentic AI (Tech Preview)**, **MCP** and **General** connectors
- An **OpenAI API key** (or any provider the connector supports)
- **Node.js 14+** — only if you want the browser chat client
- An **SMTP account** for `schedule_visit` (Gmail needs an *App Password*, not your account password)

---

## Steps to Run the Sample

### 1. Import both apps

Import `ApartmentFinderMCPTools.flogo` and `ApartmentFinderAgent.flogo` into Flogo (VS Code extension or the web UI).

### 2. Configure `ApartmentFinderMCPTools`

| Property | Default | Set to |
|---|---|---|
| `FlogoMcpServer.PORT` | `9606` | leave as-is unless the port is taken |
| `SendMail.Server` | `smtp.gmail.com` | your SMTP host |
| `SendMail.Port` | `465` | your SMTP SSL port |
| `SendMail.username` | `sender@example.com` | your sending mailbox |
| `SendMail.Password` | `SET_YOUR_EMAIL_APP_PASSWORD` | **your SMTP password / app password** |

`SendMail.Password` ships as a placeholder — `schedule_visit` will fail until you set it. The other seven tools work without it.

> The connection security is fixed to `SSL` on the `SendAppointmentEmail` activity. Change it there if your relay needs `TLS` or `NONE`.

### 3. Configure `ApartmentFinderAgent`

| Property | Default | Set to |
|---|---|---|
| `AgenticAI.OpenAI.LLM_Provider` | `OpenAI` | your provider |
| `AgenticAI.OpenAI.API_Key` | *(empty)* | **your API key** |
| `AgenticAI.OpenAI.LLM_Base_URL` | *(empty)* | only for Azure / vLLM / Ollama |
| `AgenticAI.OpenAI.LLM_Model` | `gpt-5.2` | your model |
| `AgenticAI.systemPrompt` | *(the prompt)* | leave as-is |

Check the **MCP connection** on the AI Agent Activity points at your MCP server — it defaults to `http://localhost:9606/mcp`. If you changed the MCP port in step 2, change it here too.

> `temperature` is `0.0`, which is the connector's sentinel for *use the provider's own default* — not "be deterministic". Leave it there unless you have a reason.

### 4. Start the MCP server first

Run `ApartmentFinderMCPTools`. The agent's first tool call fails if this isn't already listening.

Verify:

```bash
curl -s -X POST http://localhost:9606/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

You should see all eight tools.

### 5. Start the agent

Run `ApartmentFinderAgent`. It listens on `ws://localhost:9097/apartment-finder`.

### 6. Connect the chat client

```bash
cd ../../Chatbot
npm install
npm start
```

Open **http://localhost:3000**, set the WebSocket URL to:

```
ws://localhost:9097/apartment-finder?sessionId=session-001
```

click the refresh icon to apply it, then **Connect**.

> The `sessionId` matters. The flow builds `conversationId` as `apartment-session-<sessionId>`, so each distinct value gets its own 20-turn memory. Omit it and every tab shares one bucket.

### 7. Chat

```
I'm moving to Houston, Texas. I need a 1 bedroom between $1200 and $1700
with a gym and pool, low crime, and quick interstate access.
```

Then follow up — the agent remembers your constraints:

```
Which of those is closest to a good school?
How safe is the second one?
Book me a tour of Springs at Katy on 2026-09-19 at 14:00.
```

It will ask for your name and email before booking.

### 8. Read the confirmation

Both emails land immediately. The renter's copy goes wherever you told it; the community's copy goes to a public mailinator inbox you can open in a browser:

```
https://www.mailinator.com/v4/public/inboxes.jsp?to=springs-at-katy
```

The body reads:

```
Hello Priya Raman,

Your appointment is scheduled for 1 bedroom apartment at Springs at Katy.

Date: 2026-09-19
Time: 14:00
Unit type: 1 bedroom (1BR)
Address: … , Katy, TX 77494
Leasing office hours: Mon-Fri …, Sat …, Sun … (America/Chicago)
Your host: …

Please reach 10 minutes before your appointment time, and call on this
number (281) 555-1467 before your visit.
```

---

## Try These Prompts

| Prompt | What it exercises |
|---|---|
| `Which zip codes are in Sugar Land, TX?` | `search_locations` |
| `Show me apartments in 77477` | `find_communities` + rent summary shortlisting |
| `2BR under $2000 in Katy that's available now` | Unit-type-level rent and availability, not community-level |
| `Which ones have a pool and a dog park?` | `get_amenities` across a shortlist |
| `I need to be within 5 miles of a good school and US-59` | `get_proximity`, GreatSchools ratings |
| `How many car break-ins were reported there last year?` | `get_safety_record` incident breakdown |
| `Anything cheap that's still in a good location?` | The `valueException` flag |
| `What are their office hours?` | `get_community_contact` |
| `Book me a tour of the second one on Saturday at 2pm` | Follow-up resolution → relative date → `schedule_visit` |
| `Find me apartments in Mumbai` | Scope guardrail — fixed refusal, no tool call |
| `What's the weather in Katy?` | Scope guardrail |
| `Apartments in Dallas?` | Coverage message, *not* a refusal |

---

## Flogo Features Demonstrated

- **AI Agent Activity** — `mcpServers` tool attachment, `conversationStoreType: Memory`, provider-default temperature, system prompt as an app property
- **WebSocket Server trigger** + `#wswritedata` — full-duplex browser chat on one connection
- **MCP Server trigger** — stateless streamable HTTP, eight tool handlers with draft-07 argument schemas
- **`#mapper` with `@conditional`** — server-side lookup that keeps sensitive routing data out of the LLM's hands
- **`#sendmail`** — a genuine side-effecting agent tool, with comma-split multi-recipient delivery
- **`#actreturn` with `@conditional`** — mock-data lookup keyed on tool arguments
- **App properties** — every endpoint, credential and prompt externalized

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Chatbot connects, no reply | Agent is up but the LLM call is failing — check the API key and model |
| `No serviced city found` | The location is outside the 11-community pilot slice |
| Agent answers without tool data | `mcpServers` is empty on the AI Agent Activity, or the MCP server isn't running |
| `schedule_visit` fails | `SendMail.Password` is empty, or the relay rejected the SSL connection |
| Email never arrives | Check the mailinator inbox, then your SMTP provider's sent/blocked log |
| Agent forgets earlier turns | Missing or changing `sessionId` in the WebSocket URL |
| Old WS URL after editing it | Cached — run `localStorage.removeItem('flogoChatbot_wsUrl')` in the browser console |

---

## Notes

All data in this sample is **synthetic and generated for demonstration purposes**. Communities, addresses, phone numbers, rents, school ratings and crime statistics are fabricated and describe no real property. Do not use any of it as real-world housing information.
