# Agentic AI — Connector Feature Samples

These are the Part-1 **building-block** samples: focused Flogo apps that each teach one capability of the **TIBCO Flogo® Agentic AI Connector** — the **LLM Client Activity**, **AI Agent Activity**, **AI Agent Trigger**, custom guardrails and conversation stores, the "Flogo as an MCP tool server" pattern, the **A2A** (Agent-to-Agent) protocol, and agent privilege IDs. Start here to learn *how* the connector works, one feature at a time, then see the complete end-to-end demos in the parent catalogue.

**Parent catalogue:** [../README.md](../README.md) · **Shared chat client:** [Flogo Chatbot](../Chatbot/) (browser-based WebSocket test client)

---

**Real-world sample applications** demonstrating the full capabilities of the Agentic AI Connector, one building block at a time. Browse the **[Sample Catalog](#sample-catalog)** by industry vertical, follow the **[Suggested Learning Order](#suggested-learning-order)**, then dig into the **[Sample Details](#sample-details)**.

> **Using TIBCO Flogo® 3?** Nine of these feature samples are also provided in the **Flogo 3.x** folder-based project format (each app is a folder with `app.fgmd`, `flows/`, `triggers/`, and `connections/` rather than a single `.flogo` file) under [`Flogo3x/`](../Flogo3x/) — Healthcare Patient Support, Mobile Customer Care, Smart Supply Chain, Travel Itinerary Planner, AI Triage, Insurance Claims Processor, Dynamic Semantic Tool Selection, Scheduled Reasoning, and IT Help Desk Advisor. See the [Flogo 3.x samples README](../Flogo3x/README.md).

## Sample Catalog

Samples grouped by **industry vertical**. The **Flogo Features Used** column lists the Agentic AI building blocks, activities, triggers, and MCP/A2A features each sample exercises. Click any sample name to open its folder and full README.

### Banking, Financial Services & Insurance

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 1 | [Insurance Claims Processor](./InsuranceClaimsProcessor/) | Coverage verification + fraud scoring → APPROVE / REVIEW / DENY | **LLM Client Activity** (×2, chained) · MCP Server · A2A Server · REST trigger · PII redaction | REST |
| 2 | [Mortgage AI Processor](./mortgagedemo/) | Autonomous loan assessment (credit, DTI, employment) with binding decision | **Flogo MCP Server** (10 tools) · PostgreSQL · REST (mock APIs) · JsExec (DTI) · EMS queue | MCP (Claude Desktop) |

### Healthcare

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 3 | [Healthcare Patient Support Agent](./Healthcare-Compliance-Agent/) | HIPAA-aware patient assistant with PHI protection + auditable history | **AI Agent Trigger** · Custom Guardrail (PHI: SSN/DOB/MRN) · Custom Conversation Store (file, STORE+FETCH) · 3 Custom Tools · WebSocket trigger | WebSocket |

### Retail & Consumer

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 4 | [BeautyCo Retail Intelligence](./demo_retail/) | Hyper-personalized in-store consultations, loyalty offers, next-best-action | **Flogo MCP Server** (12 tools) · PostgreSQL · REST (mock APIs) · MCP Server trigger | MCP (Claude Desktop) |

### Telecommunications & Customer Service

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 5 | [Mobile Customer Care Multi-Agent Hub](./Mobile-Customer-Care-Multi-Agent/) | Triage dispatcher routing to Billing / Technical / Upgrade specialists | **AI Agent Activity** (dispatcher) · 3 **AI Agent Triggers** · `agentHandoffs` list · Invoke AI Agent Trigger (`callagent`) · 6 Custom Tools · PII guardrails · WebSocket trigger | WebSocket |

### Travel & Hospitality

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 6 | [Travel Itinerary Planner with A2A Server](./Travel-Itinerary-Planner/) | Conference travel coordination via collaborating agents | **AI Agent Trigger** · A2A Server (`agentType: A2A Server`) · `remoteAgents` list · Invoke AI Agent Trigger (`callagent`) · Custom Tools (local + remote) · REST trigger | REST |

### Manufacturing & Supply Chain

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 7 | [Smart Supply Chain Assistant](./Smart-Supply-Chain-Assistant/) | Procurement intelligence: live inventory/supplier lookup + PO creation | **AI Agent Trigger** · List of MCP Servers (`mcpServers`, 2 servers) · 2 MCP Server triggers · Custom write Tool (`CreatePurchaseOrder`) · Invoke AI Agent Trigger (`callagent`) · WebSocket trigger | WebSocket |

### IT Operations & Service Management

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 8 | [AI-Powered Incident Triage Agent](./Ai-Triage-Agent/) | Deduplicate error events, cut ServiceNow ticket noise ~90% | **AI Agent Activity** · MCP tools (ServiceNow) · low-confidence guardrail · Ollama / OpenAI / Azure OpenAI | Web dashboard |
| 9 | [IT Help Desk Advisor](./LLMClient-Dynamic-Config-And-Memory/) | Multi-turn WiFi troubleshooting with escalation to a ticket | **LLM Client Activity** · Memory Conversation Store · dynamic `mcpServerConfigs` · dynamic `a2aServerConfigs` · MCP Server · A2A Server · WebSocket trigger | WebSocket |
| 10 | [Dynamic Semantic Tool Selection at Scale](./DynamicSemanticToolSelectionAtScale/) | Service-desk orchestration across 150 tools on 3 MCP servers | **LLM Client Activity** (selector) → **AI Agent Activity** (executor) · `filteredToolNames` · 3 MCP Servers · REST trigger | REST |

### Cross-Industry / Workplace Productivity

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 11 | [Scheduled Reasoning Agent](./ScheduledReasoningAgent/) | Unattended weekly sales report → styled HTML → email | **LLM Client Activity** (×3, chained) · Timer trigger (cron) · REST trigger · MCP Server · File Write · Send Mail | Timer + REST |
| 12 | [Morning Briefing](./morning-briefing/) | Aggregate Slack / email / calendar / reminders → prioritized AI briefing | **AI Agent Activity** (Preview) · REST trigger · Timer trigger · REST (data gathering) · JsExec · Log / Return | REST + Timer |

### Real Estate & Property Management

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 13 | [Apartment Finder Agent](./Apartment-Finder-Agent/) | Conversational apartment search that ends in a booked, emailed tour | **AI Agent Activity** · Memory Conversation Store · **Flogo MCP Server** (8 tools) · Send Mail write tool · `#mapper` `@conditional` lookup · prompt-level scope guardrails · WebSocket trigger | WebSocket |

### Pharmaceutical & Life Sciences

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 14 | [Drug Safety Intake Advisor](./LLMClient-Dynamic-Auth/) | Pharmacovigilance SUSAR triage that ends in a filed E2B(R3) expedited report | **LLM Client Activity** · dynamic `llmConfiguration` (no LLM connection resource in the orchestrator) · **authenticated** `mcpServerConfigs` (`authType: Token`) · **authenticated** `a2aServerConfigs` (`authType: Static Token`) · MCP Server (`API Key` + per-tool `scope`) · A2A Server (`agentAuthMode: Static Token`) · Memory Conversation Store · WebSocket trigger | WebSocket |

### Agent Governance (cross-industry)

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 15 | [Agent Privilege IDs](./Agent-Privilege-IDs/) | Bank back-office agents, each with its own privilege ID: least privilege, kill switch, human approval, full audit | **MCP Server trigger** (`JWT Token` auth + per-tool `scope` + `tokenInfo.sub`) · 2 **AI Agent Activities**, each with its own JWT (`authType: Token`) · PostgreSQL agent registry · guarded writes · human-only approval · WebSocket trigger | WebSocket |

> **Testing any WebSocket sample?** Use the shared browser **[Flogo Chatbot](../Chatbot/)** in [`Chatbot/`](../Chatbot/) — it also drives every Part 2 use case.

## Suggested Learning Order

New to the Agentic AI Connector? This path moves from the simplest building block to the most advanced, so each sample builds on the last:

1. **[Scheduled Reasoning Agent](./ScheduledReasoningAgent/)** — start with the **LLM Client Activity**: chained, stateless LLM calls driven by a timer and fed from an MCP server.
2. **[Insurance Claims Processor](./InsuranceClaimsProcessor/)** — chain LLM Client calls across an MCP server and an A2A agent to reach a decision.
3. **[IT Help Desk Advisor](./LLMClient-Dynamic-Config-And-Memory/)** — add multi-turn memory and dynamic MCP/A2A configuration to the LLM Client.
4. **[Dynamic Semantic Tool Selection at Scale](./DynamicSemanticToolSelectionAtScale/)** — combine an LLM Client selector with an AI Agent Activity to handle very large tool sets.
5. **[Morning Briefing](./morning-briefing/)** — move to the **AI Agent Activity** to summarize aggregated data inside a flow.
6. **[AI-Powered Incident Triage Agent](./Ai-Triage-Agent/)** — give the AI Agent Activity MCP tools and reasoning to deduplicate incidents.
7. **[Mobile Customer Care Multi-Agent Hub](./Mobile-Customer-Care-Multi-Agent/)** — use the AI Agent Activity as a dispatcher with multi-agent handoff.
8. **[Healthcare Patient Support Agent](./Healthcare-Compliance-Agent/)** — build a full **AI Agent Trigger** with a custom guardrail and custom conversation store.
9. **[Smart Supply Chain Assistant](./Smart-Supply-Chain-Assistant/)** — connect an Agent Trigger to multiple MCP servers plus a custom write tool.
10. **[Travel Itinerary Planner with A2A Server](./Travel-Itinerary-Planner/)** — orchestrate agents across apps with the Agent-to-Agent (A2A) protocol.
11. **[BeautyCo Retail Intelligence](./demo_retail/)** — turn Flogo into an **MCP tool server** that external AI clients (e.g. Claude Desktop) can call.
12. **[Mortgage AI Processor](./mortgagedemo/)** — apply the MCP-server pattern to autonomous, auditable decisioning.
13. **[Apartment Finder Agent](./Apartment-Finder-Agent/)** — put both halves together: an AI Agent Activity chats over your own MCP tool server, and one of those tools sends real email.
14. **[Drug Safety Intake Advisor](./LLMClient-Dynamic-Auth/)** — revisit the LLM Client with **bearer-token authentication** on both hops, and matching auth on the MCP and A2A servers it calls.
15. **[Agent Privilege IDs](./Agent-Privilege-IDs/)** — govern the agents themselves: give each AI Agent Activity its **own JWT privilege ID**, enforced by per-tool scopes on a Flogo MCP Server, a PostgreSQL agent registry (kill switch) and human-only approval.

Ready to see the full pattern applied end-to-end? Continue to **[Part 2 — Industry Use-Case Demos](../README.md#part-2--industry-use-case-demos)**.

## Sample Details

### 1. [Insurance Claims Processor](./InsuranceClaimsProcessor/) — *Banking, Financial Services & Insurance*
A claims pipeline where a REST API chains two **LLM Client** calls: step 1 verifies policy coverage via an **MCP Server**, step 2 assesses fraud risk via an **A2A Server**, and the combined results yield an APPROVE/REVIEW/DENY recommendation. Three collaborating Flogo apps (orchestrator, policy MCP server, fraud A2A agent) with dynamic LLM config, PII redaction, and composite risk scoring.

### 2. [Mortgage AI Processor](./mortgagedemo/) — *Banking, Financial Services & Insurance*
An autonomous mortgage assessment system where Flogo acts as an **MCP tool server** exposing **10 tools** — read tools (applicant profile, credit score, valuation, debts, employment, DTI) and mutually-exclusive write tools (approve / escalate / decline + audit log). Claude Desktop conducts a full assessment in seconds, autonomously chaining tools. Includes a PostgreSQL schema with three pre-seeded scenarios (approve / escalate / decline) and mock REST backends.

### 3. [Healthcare Patient Support Agent](./Healthcare-Compliance-Agent/) — *Healthcare*
A HIPAA-aware patient support assistant built on the **AI Agent Trigger** with a **custom PHI guardrail** that redacts SSN, Date-of-Birth, and Medical Record Numbers from every LLM input and output, plus a **file-based custom conversation store** (STORE + FETCH) for persistent, auditable session history with HIPAA metadata on every turn. Three patient-service tools; compliance-first architecture.

### 4. [BeautyCo Retail Intelligence](./demo_retail/) — *Retail & Consumer*
An enterprise retail demo where Flogo acts as the **MCP tool server**, exposing the retailer's data as **12 AI-callable tools** (PostgreSQL + mock REST). Claude autonomously calls them to produce hyper-personalized beauty consultations, loyalty offers, and next-best-actions — all with data kept on-prem. Ships with seed data, a PostgreSQL schema, a mock API app, and a dashboard.

### 5. [Mobile Customer Care Multi-Agent Hub](./Mobile-Customer-Care-Multi-Agent/) — *Telecommunications & Customer Service*
A mobile carrier's support hub where one **AI Agent Activity** acts as an intelligent dispatcher over a configurable list of three specialist **AI Agent Triggers** (Billing, Technical Support, Upgrade Advisor). Demonstrates the "list of agents for handoff" feature, multi-hop handoff (Technical → Upgrade), and contrasts non-deterministic AI routing with deterministic `callagent` routing in the same app.

### 6. [Travel Itinerary Planner with A2A Server](./Travel-Itinerary-Planner/) — *Travel & Hospitality*
A conference travel coordinator demonstrating the **Agent-to-Agent (A2A) protocol**: a reusable **TravelPlannerAgent** (A2A Server) exposes flight/hotel/weather/itinerary tools, and an **EventTravelCoordinator** (Local Agent) adds event-specific intelligence (venue details, partner hotels, attendee registration) and delegates travel operations to the A2A Server via the `remoteAgents` list. Bridged to a REST trigger via `callagent`.

### 7. [Smart Supply Chain Assistant](./Smart-Supply-Chain-Assistant/) — *Manufacturing & Supply Chain*
A procurement assistant combining the **list of MCP servers** feature (one Agent Trigger connected to two running Flogo MCP servers at once) with a **custom `CreatePurchaseOrder` write tool**. The agent queries live inventory and supplier data via MCP, confirms details with the user, then creates purchase orders — all in one natural-language conversation invoked from a WebSocket trigger via `callagent`.

### 8. [AI-Powered Incident Triage Agent](./Ai-Triage-Agent/) — *IT Operations & Service Management*
An incident triage system that watches an integration error stream and cuts ServiceNow ticket noise ~90%. Each error is reasoned over by an **AI Agent Activity** using MCP tools: it decides new incident vs. duplicate (semantic, not string matching) vs. bad data, and for new incidents synthesizes a resolution recommendation from historical tickets. Includes a live browser dashboard with an error simulator; supports Ollama, OpenAI, and Azure OpenAI. Pre-built binaries included.

### 9. [IT Help Desk Advisor](./LLMClient-Dynamic-Config-And-Memory/) — *IT Operations & Service Management*
A multi-turn help desk advisor showcasing two Flogo 2.26.7 features: the **Memory Conversation Store** (history keyed by `conversationId`) and **dynamic MCP/A2A configuration** (`mcpServerConfigs` / `a2aServerConfigs` as activity inputs, no connection resource). An employee reports a WiFi issue, gets KB-guided steps across turns, and escalates to a ticket in one continuous conversation.

### 10. [Dynamic Semantic Tool Selection at Scale](./DynamicSemanticToolSelectionAtScale/) — *IT Operations & Service Management*
An IT Service Desk orchestrator handling requests across **150 tools** on three MCP servers via a two-step pattern: an **LLM Client** reads a text catalog and returns the relevant tool names, then an **AI Agent Activity** runs only those via `filteredToolNames`. A side-by-side comparison app shows the OpenAI 128-tool limit this pattern solves — scaling to hundreds or thousands of tools.

### 11. [Scheduled Reasoning Agent](./ScheduledReasoningAgent/) — *Cross-Industry / Workplace Productivity*
A timer-triggered agent (every Monday 8am) that queries a Sales Data MCP Server, generates a structured analysis, formats it into styled HTML via a third LLM call, saves it to disk, and emails stakeholders — zero human interaction. Three chained **LLM Client** calls with per-step temperatures (0.2 / 0.5 / 0.3), File Write, and Send Mail. A REST trigger is included for on-demand testing.

### 12. [Morning Briefing](./morning-briefing/) — *Cross-Industry / Workplace Productivity*
A workflow that aggregates data from four sources (Slack, email, calendar, reminders), sends it to Claude via an **AI Agent Activity**, and returns a prioritized markdown report in three tiers: 🔴 Needs Attention · 🟡 Important Today · 🟢 Awareness. Runs on a REST trigger or a 7am daily timer, with Docker-based mocks (Wiremock + MailHog) and guidance for swapping in real APIs (Slack, Outlook/Graph, Google Calendar, Todoist).

### 13. [Apartment Finder Agent](./Apartment-Finder-Agent/) — *Real Estate & Property Management*
A renter describes what they want in plain English and an **AI Agent Activity** chains eight tools on a **Flogo MCP Server** to answer it — resolving a place name to zip codes, shortlisting communities, then fanning out to rent, amenities, proximity and trailing-12-month crime data before ranking the options. The eighth tool, `schedule_visit`, **sends real email**: a `#mapper` `@conditional` step resolves the chosen `community_id` to its leasing office server-side, so the LLM can never redirect the confirmation, and `#sendmail` delivers it to the renter and the office at once. Prompt-level guardrails pin the agent to Texas apartment search and roll "Houston" up to its serviced suburbs.

### 14. [Drug Safety Intake Advisor](./LLMClient-Dynamic-Auth/) — *Pharmaceutical & Life Sciences*
The authenticated counterpart to the IT Help Desk Advisor: the orchestrator configures nothing through a connection resource, and **both backends require a bearer token**. A drug safety associate reports an adverse event over WebSocket and one **LLM Client Activity** triages it against ICH E2A — reading product labeling and prior case history from a token-protected **MCP Server** (`authType: Token` on the client, `API Key` on the server, per-tool `scope` values ready for a JWT upgrade), then opening the ICSR and filing the E2B(R3) expedited report through a token-protected **A2A Server** (`Static Token` on both sides). Provider, model, API key, base URL, both URLs and both tokens all resolve from App Properties, so rotating a credential or moving to an on-premises model never touches a flow. The A2A server app deliberately goes the other way and *does* use an `#llmprovider` connection, so the two styles sit side by side. A Memory Conversation Store keyed on a required `caseId` carries one case across turns.

### 15. [Agent Privilege IDs](./Agent-Privilege-IDs/) — *Agent Governance (cross-industry)*
Answers the question banks ask about AI agents: *"How do you manage privilege IDs for agents?"* Back-office agents for a fictional bank each carry **their own identity** — a JWT whose `sub` is the agent's privilege ID and whose `scp` lists its granted scopes — in the MCP connection of their **AI Agent Activity**. The **MCP Server trigger** validates the token with `JWT Token` auth and a per-tool `scope`, so a tool the agent isn't entitled to is never even listed. Every tool flow reads the verified `tokenInfo.sub` and lets a **PostgreSQL agent registry** decide on each call (owner, status, expiry, entitlements): suspend an agent and its next call is refused even though its token is still valid. Agents can only *request* a privileged change — a named human approves it — and every call, allowed or refused, is audited under the agent ID from the token, never from the model. An **orchestrated** variant adds agent-to-agent delegation through JWT-protected MCP tools, and a **no-MCP** variant does the same with OAuth 2.0 client identities and an API gateway.
