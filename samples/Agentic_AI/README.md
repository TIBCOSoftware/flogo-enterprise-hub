# TIBCO Flogo® Agentic AI — Samples & Industry Use Cases

This directory brings together two complementary collections for the **TIBCO Flogo® Agentic AI Connector** — the enterprise-grade way to build, orchestrate, and govern AI agents inside Flogo integration flows:

- **[Part 1 — Connector Feature Samples](#part-1--connector-feature-samples)** — focused apps that each teach a building block: **LLM Client Activity**, **AI Agent Activity**, **AI Agent Trigger**, custom guardrails, custom conversation stores, the "Flogo as an MCP tool server" pattern, and the **A2A** (Agent-to-Agent) protocol. Start here to learn *how* the connector works.
- **[Part 2 — Industry Use-Case Demos](#part-2--industry-use-case-demos)** — complete, PostgreSQL-backed, vertical-specific demos (banking, insurance, healthcare, telecom, utilities, aerospace, manufacturing, retail, real estate, and more). Each applies the same repeatable **three-app pattern** — an **MCP Server** (read-only tools), an **A2A Agents** app (guarded write workflows), and a **WebSocket AI Orchestrator** (the conversational brain). Start here to see *what* you can build.

New here? Skim **[What Is the Agentic AI Connector?](#what-is-the-agentic-ai-connector)**, then follow the feature-sample **[Suggested Learning Order](#suggested-learning-order)** or jump straight to an **[industry use case](#use-case-catalog)**. Both collections share the **[Prerequisites](#prerequisites)**, **[Quick Start](#quick-start)**, and the browser **[Flogo Chatbot](#flogo-chatbot--browser-based-websocket-test-client)** test client.

### Folder layout

| Folder | What's inside |
|---|---|
| [`Feature_Samples/`](./Feature_Samples/) | Part 1 — connector feature samples, one building block at a time (Flogo 2.x). |
| [`Industry_Use_Cases/`](./Industry_Use_Cases/) | Part 2 — governed, vertical-specific demos: business rules, identity, prices and state changes enforced in PostgreSQL, built with the `agentic-ai-use-case-builder` skill. The canonical industry use cases going forward. |
| [`Industry_Use_Cases_old/`](./Industry_Use_Cases_old/) | Earlier vertical demos on the three-app pattern, being migrated to the governed style above. |
| [`Chatbot/`](./Chatbot/) | Shared browser WebSocket test client for every use case that exposes a WebSocket endpoint. |
| [`Flogo3x/`](./Flogo3x/) | Flogo 3.x folder-based project versions of nine feature samples. |

---

## What Is the Agentic AI Connector?

The connector provides three primary building blocks. The **Flogo Features Used** column in the feature-sample catalog below tells you which one (and which activities, triggers, and MCP/A2A features) each sample exercises.

| Building Block | Best For | Key Capabilities |
|---|---|---|
| **LLM Client Activity** | Lightweight, stateless, one-shot LLM inference in a flow | Dynamic LLM config (provider, model, apiKey as inputs — no pre-configured connection), MCP tools, A2A remote agents, text or JSON response |
| **AI Agent Activity** | Embedding LLM intelligence inside an existing Flogo flow | LLM provider connection, model selection, default PII guardrails, token limits, MCP tools, in-memory conversation history, agent handoff |
| **AI Agent Trigger** | Building full-featured autonomous agents with custom logic | All AI Agent Activity features **plus** custom tools (Flogo flows), custom guardrails (prompt injection / advanced PII), custom conversation stores (DB, file, Redis), agent hand-off orchestration |

An **Invoke AI Agent Trigger Activity** (`callagent`) bridges the two worlds: it lets any Flogo trigger (REST, WebSocket, Kafka, Timer, …) deterministically dispatch a user prompt to an Agent Trigger and receive its response.

A fourth pattern in this folder — **Flogo as an MCP Tool Server** — turns a Flogo app into a Model Context Protocol server that exposes enterprise data and actions as tools that any MCP client (e.g. Claude Desktop) can call autonomously.

### Supported LLM Providers

**OpenAI** (GPT-4o, GPT-4.1, o3) · **Gemini** (2.0 Flash, 2.5 Pro) · **Anthropic** (Claude Sonnet, Claude Opus) · **Ollama** (local: Llama 3, Mistral) · **vLLM** (self-hosted OpenAI-compatible endpoint)

### Handler Types (Agent Trigger only)

| Handler Type | Purpose |
|---|---|
| **Tool** | A Flogo flow the LLM can call as a tool. Receives `toolParams` and returns `response`. |
| **Custom Guardrail** | A Flogo flow invoked on every LLM input **and** output — advanced PII redaction, prompt-injection prevention, jailbreak detection, content policy. |
| **Custom Conversation Store** | Two Flogo flows — **STORE** (persist a message) and **FETCH** (retrieve all messages) — giving the agent durable, restartable memory backed by any store (DB, file, Redis, S3, …). |

---

# Part 1 — Connector Feature Samples

**Real-world sample applications** demonstrating the full capabilities of the Agentic AI Connector, one building block at a time. Browse the **[Sample Catalog](#sample-catalog)** by industry vertical, follow the **[Suggested Learning Order](#suggested-learning-order)**, then dig into the **[Sample Details](#sample-details)**.

> **Using TIBCO Flogo® 3?** Nine of these feature samples are also provided in the **Flogo 3.x** folder-based project format (each app is a folder with `app.fgmd`, `flows/`, `triggers/`, and `connections/` rather than a single `.flogo` file) under [`Flogo3x/`](./Flogo3x/) — Healthcare Patient Support, Mobile Customer Care, Smart Supply Chain, Travel Itinerary Planner, AI Triage, Insurance Claims Processor, Dynamic Semantic Tool Selection, Scheduled Reasoning, and IT Help Desk Advisor. See the [Flogo 3.x samples README](./Flogo3x/README.md).

## Sample Catalog

Samples grouped by **industry vertical**. The **Flogo Features Used** column lists the Agentic AI building blocks, activities, triggers, and MCP/A2A features each sample exercises. Click any sample name to open its folder and full README.

### Banking, Financial Services & Insurance

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 1 | [Insurance Claims Processor](./Feature_Samples/InsuranceClaimsProcessor/) | Coverage verification + fraud scoring → APPROVE / REVIEW / DENY | **LLM Client Activity** (×2, chained) · MCP Server · A2A Server · REST trigger · PII redaction | REST |
| 2 | [Mortgage AI Processor](./Feature_Samples/mortgagedemo/) | Autonomous loan assessment (credit, DTI, employment) with binding decision | **Flogo MCP Server** (10 tools) · PostgreSQL · REST (mock APIs) · JsExec (DTI) · EMS queue | MCP (Claude Desktop) |

### Healthcare

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 3 | [Healthcare Patient Support Agent](./Feature_Samples/Healthcare-Compliance-Agent/) | HIPAA-aware patient assistant with PHI protection + auditable history | **AI Agent Trigger** · Custom Guardrail (PHI: SSN/DOB/MRN) · Custom Conversation Store (file, STORE+FETCH) · 3 Custom Tools · WebSocket trigger | WebSocket |

### Retail & Consumer

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 4 | [BeautyCo Retail Intelligence](./Feature_Samples/demo_retail/) | Hyper-personalized in-store consultations, loyalty offers, next-best-action | **Flogo MCP Server** (12 tools) · PostgreSQL · REST (mock APIs) · MCP Server trigger | MCP (Claude Desktop) |

### Telecommunications & Customer Service

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 5 | [Mobile Customer Care Multi-Agent Hub](./Feature_Samples/Mobile-Customer-Care-Multi-Agent/) | Triage dispatcher routing to Billing / Technical / Upgrade specialists | **AI Agent Activity** (dispatcher) · 3 **AI Agent Triggers** · `agentHandoffs` list · Invoke AI Agent Trigger (`callagent`) · 6 Custom Tools · PII guardrails · WebSocket trigger | WebSocket |

### Travel & Hospitality

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 6 | [Travel Itinerary Planner with A2A Server](./Feature_Samples/Travel-Itinerary-Planner/) | Conference travel coordination via collaborating agents | **AI Agent Trigger** · A2A Server (`agentType: A2A Server`) · `remoteAgents` list · Invoke AI Agent Trigger (`callagent`) · Custom Tools (local + remote) · REST trigger | REST |

### Manufacturing & Supply Chain

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 7 | [Smart Supply Chain Assistant](./Feature_Samples/Smart-Supply-Chain-Assistant/) | Procurement intelligence: live inventory/supplier lookup + PO creation | **AI Agent Trigger** · List of MCP Servers (`mcpServers`, 2 servers) · 2 MCP Server triggers · Custom write Tool (`CreatePurchaseOrder`) · Invoke AI Agent Trigger (`callagent`) · WebSocket trigger | WebSocket |

### IT Operations & Service Management

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 8 | [AI-Powered Incident Triage Agent](./Feature_Samples/Ai-Triage-Agent/) | Deduplicate error events, cut ServiceNow ticket noise ~90% | **AI Agent Activity** · MCP tools (ServiceNow) · low-confidence guardrail · Ollama / OpenAI / Azure OpenAI | Web dashboard |
| 9 | [IT Help Desk Advisor](./Feature_Samples/LLMClient-Dynamic-Config-And-Memory/) | Multi-turn WiFi troubleshooting with escalation to a ticket | **LLM Client Activity** · Memory Conversation Store · dynamic `mcpServerConfigs` · dynamic `a2aServerConfigs` · MCP Server · A2A Server · WebSocket trigger | WebSocket |
| 10 | [Dynamic Semantic Tool Selection at Scale](./Feature_Samples/DynamicSemanticToolSelectionAtScale/) | Service-desk orchestration across 150 tools on 3 MCP servers | **LLM Client Activity** (selector) → **AI Agent Activity** (executor) · `filteredToolNames` · 3 MCP Servers · REST trigger | REST |

### Cross-Industry / Workplace Productivity

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 11 | [Scheduled Reasoning Agent](./Feature_Samples/ScheduledReasoningAgent/) | Unattended weekly sales report → styled HTML → email | **LLM Client Activity** (×3, chained) · Timer trigger (cron) · REST trigger · MCP Server · File Write · Send Mail | Timer + REST |
| 12 | [Morning Briefing](./Feature_Samples/morning-briefing/) | Aggregate Slack / email / calendar / reminders → prioritized AI briefing | **AI Agent Activity** (Preview) · REST trigger · Timer trigger · REST (data gathering) · JsExec · Log / Return | REST + Timer |

### Real Estate & Property Management

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 13 | [Apartment Finder Agent](./Feature_Samples/Apartment-Finder-Agent/) | Conversational apartment search that ends in a booked, emailed tour | **AI Agent Activity** · Memory Conversation Store · **Flogo MCP Server** (8 tools) · Send Mail write tool · `#mapper` `@conditional` lookup · prompt-level scope guardrails · WebSocket trigger | WebSocket |

### Pharmaceutical & Life Sciences

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 14 | [Drug Safety Intake Advisor](./Feature_Samples/LLMClient-Dynamic-Auth/) | Pharmacovigilance SUSAR triage that ends in a filed E2B(R3) expedited report | **LLM Client Activity** · dynamic `llmConfiguration` (no LLM connection resource in the orchestrator) · **authenticated** `mcpServerConfigs` (`authType: Token`) · **authenticated** `a2aServerConfigs` (`authType: Static Token`) · MCP Server (`API Key` + per-tool `scope`) · A2A Server (`agentAuthMode: Static Token`) · Memory Conversation Store · WebSocket trigger | WebSocket |

### Agent Governance (cross-industry)

| # | Sample | Use Case | Flogo Features Used | Interface |
|---|---|---|---|---|
| 15 | [Agent Privilege IDs](./Feature_Samples/Agent-Privilege-IDs/) | Bank back-office agents, each with its own privilege ID: least privilege, kill switch, human approval, full audit | **MCP Server trigger** (`JWT Token` auth + per-tool `scope` + `tokenInfo.sub`) · 2 **AI Agent Activities**, each with its own JWT (`authType: Token`) · PostgreSQL agent registry · guarded writes · human-only approval · WebSocket trigger | WebSocket |

> **Testing any WebSocket sample?** Use the shared browser **[Flogo Chatbot](#flogo-chatbot--browser-based-websocket-test-client)** in [`Chatbot/`](./Chatbot/) — it also drives every Part 2 use case.

## Suggested Learning Order

New to the Agentic AI Connector? This path moves from the simplest building block to the most advanced, so each sample builds on the last:

1. **[Scheduled Reasoning Agent](./Feature_Samples/ScheduledReasoningAgent/)** — start with the **LLM Client Activity**: chained, stateless LLM calls driven by a timer and fed from an MCP server.
2. **[Insurance Claims Processor](./Feature_Samples/InsuranceClaimsProcessor/)** — chain LLM Client calls across an MCP server and an A2A agent to reach a decision.
3. **[IT Help Desk Advisor](./Feature_Samples/LLMClient-Dynamic-Config-And-Memory/)** — add multi-turn memory and dynamic MCP/A2A configuration to the LLM Client.
4. **[Dynamic Semantic Tool Selection at Scale](./Feature_Samples/DynamicSemanticToolSelectionAtScale/)** — combine an LLM Client selector with an AI Agent Activity to handle very large tool sets.
5. **[Morning Briefing](./Feature_Samples/morning-briefing/)** — move to the **AI Agent Activity** to summarize aggregated data inside a flow.
6. **[AI-Powered Incident Triage Agent](./Feature_Samples/Ai-Triage-Agent/)** — give the AI Agent Activity MCP tools and reasoning to deduplicate incidents.
7. **[Mobile Customer Care Multi-Agent Hub](./Feature_Samples/Mobile-Customer-Care-Multi-Agent/)** — use the AI Agent Activity as a dispatcher with multi-agent handoff.
8. **[Healthcare Patient Support Agent](./Feature_Samples/Healthcare-Compliance-Agent/)** — build a full **AI Agent Trigger** with a custom guardrail and custom conversation store.
9. **[Smart Supply Chain Assistant](./Feature_Samples/Smart-Supply-Chain-Assistant/)** — connect an Agent Trigger to multiple MCP servers plus a custom write tool.
10. **[Travel Itinerary Planner with A2A Server](./Feature_Samples/Travel-Itinerary-Planner/)** — orchestrate agents across apps with the Agent-to-Agent (A2A) protocol.
11. **[BeautyCo Retail Intelligence](./Feature_Samples/demo_retail/)** — turn Flogo into an **MCP tool server** that external AI clients (e.g. Claude Desktop) can call.
12. **[Mortgage AI Processor](./Feature_Samples/mortgagedemo/)** — apply the MCP-server pattern to autonomous, auditable decisioning.
13. **[Apartment Finder Agent](./Feature_Samples/Apartment-Finder-Agent/)** — put both halves together: an AI Agent Activity chats over your own MCP tool server, and one of those tools sends real email.
14. **[Drug Safety Intake Advisor](./Feature_Samples/LLMClient-Dynamic-Auth/)** — revisit the LLM Client with **bearer-token authentication** on both hops, and matching auth on the MCP and A2A servers it calls.

Ready to see the full pattern applied end-to-end? Continue to **[Part 2 — Industry Use-Case Demos](#part-2--industry-use-case-demos)**.

## Sample Details

### 1. [Insurance Claims Processor](./Feature_Samples/InsuranceClaimsProcessor/) — *Banking, Financial Services & Insurance*
A claims pipeline where a REST API chains two **LLM Client** calls: step 1 verifies policy coverage via an **MCP Server**, step 2 assesses fraud risk via an **A2A Server**, and the combined results yield an APPROVE/REVIEW/DENY recommendation. Three collaborating Flogo apps (orchestrator, policy MCP server, fraud A2A agent) with dynamic LLM config, PII redaction, and composite risk scoring.

### 2. [Mortgage AI Processor](./Feature_Samples/mortgagedemo/) — *Banking, Financial Services & Insurance*
An autonomous mortgage assessment system where Flogo acts as an **MCP tool server** exposing **10 tools** — read tools (applicant profile, credit score, valuation, debts, employment, DTI) and mutually-exclusive write tools (approve / escalate / decline + audit log). Claude Desktop conducts a full assessment in seconds, autonomously chaining tools. Includes a PostgreSQL schema with three pre-seeded scenarios (approve / escalate / decline) and mock REST backends.

### 3. [Healthcare Patient Support Agent](./Feature_Samples/Healthcare-Compliance-Agent/) — *Healthcare*
A HIPAA-aware patient support assistant built on the **AI Agent Trigger** with a **custom PHI guardrail** that redacts SSN, Date-of-Birth, and Medical Record Numbers from every LLM input and output, plus a **file-based custom conversation store** (STORE + FETCH) for persistent, auditable session history with HIPAA metadata on every turn. Three patient-service tools; compliance-first architecture.

### 4. [BeautyCo Retail Intelligence](./Feature_Samples/demo_retail/) — *Retail & Consumer*
An enterprise retail demo where Flogo acts as the **MCP tool server**, exposing the retailer's data as **12 AI-callable tools** (PostgreSQL + mock REST). Claude autonomously calls them to produce hyper-personalized beauty consultations, loyalty offers, and next-best-actions — all with data kept on-prem. Ships with seed data, a PostgreSQL schema, a mock API app, and a dashboard.

### 5. [Mobile Customer Care Multi-Agent Hub](./Feature_Samples/Mobile-Customer-Care-Multi-Agent/) — *Telecommunications & Customer Service*
A mobile carrier's support hub where one **AI Agent Activity** acts as an intelligent dispatcher over a configurable list of three specialist **AI Agent Triggers** (Billing, Technical Support, Upgrade Advisor). Demonstrates the "list of agents for handoff" feature, multi-hop handoff (Technical → Upgrade), and contrasts non-deterministic AI routing with deterministic `callagent` routing in the same app.

### 6. [Travel Itinerary Planner with A2A Server](./Feature_Samples/Travel-Itinerary-Planner/) — *Travel & Hospitality*
A conference travel coordinator demonstrating the **Agent-to-Agent (A2A) protocol**: a reusable **TravelPlannerAgent** (A2A Server) exposes flight/hotel/weather/itinerary tools, and an **EventTravelCoordinator** (Local Agent) adds event-specific intelligence (venue details, partner hotels, attendee registration) and delegates travel operations to the A2A Server via the `remoteAgents` list. Bridged to a REST trigger via `callagent`.

### 7. [Smart Supply Chain Assistant](./Feature_Samples/Smart-Supply-Chain-Assistant/) — *Manufacturing & Supply Chain*
A procurement assistant combining the **list of MCP servers** feature (one Agent Trigger connected to two running Flogo MCP servers at once) with a **custom `CreatePurchaseOrder` write tool**. The agent queries live inventory and supplier data via MCP, confirms details with the user, then creates purchase orders — all in one natural-language conversation invoked from a WebSocket trigger via `callagent`.

### 8. [AI-Powered Incident Triage Agent](./Feature_Samples/Ai-Triage-Agent/) — *IT Operations & Service Management*
An incident triage system that watches an integration error stream and cuts ServiceNow ticket noise ~90%. Each error is reasoned over by an **AI Agent Activity** using MCP tools: it decides new incident vs. duplicate (semantic, not string matching) vs. bad data, and for new incidents synthesizes a resolution recommendation from historical tickets. Includes a live browser dashboard with an error simulator; supports Ollama, OpenAI, and Azure OpenAI. Pre-built binaries included.

### 9. [IT Help Desk Advisor](./Feature_Samples/LLMClient-Dynamic-Config-And-Memory/) — *IT Operations & Service Management*
A multi-turn help desk advisor showcasing two Flogo 2.26.5 features: the **Memory Conversation Store** (history keyed by `conversationId`) and **dynamic MCP/A2A configuration** (`mcpServerConfigs` / `a2aServerConfigs` as activity inputs, no connection resource). An employee reports a WiFi issue, gets KB-guided steps across turns, and escalates to a ticket in one continuous conversation.

### 10. [Dynamic Semantic Tool Selection at Scale](./Feature_Samples/DynamicSemanticToolSelectionAtScale/) — *IT Operations & Service Management*
An IT Service Desk orchestrator handling requests across **150 tools** on three MCP servers via a two-step pattern: an **LLM Client** reads a text catalog and returns the relevant tool names, then an **AI Agent Activity** runs only those via `filteredToolNames`. A side-by-side comparison app shows the OpenAI 128-tool limit this pattern solves — scaling to hundreds or thousands of tools.

### 11. [Scheduled Reasoning Agent](./Feature_Samples/ScheduledReasoningAgent/) — *Cross-Industry / Workplace Productivity*
A timer-triggered agent (every Monday 8am) that queries a Sales Data MCP Server, generates a structured analysis, formats it into styled HTML via a third LLM call, saves it to disk, and emails stakeholders — zero human interaction. Three chained **LLM Client** calls with per-step temperatures (0.2 / 0.5 / 0.3), File Write, and Send Mail. A REST trigger is included for on-demand testing.

### 12. [Morning Briefing](./Feature_Samples/morning-briefing/) — *Cross-Industry / Workplace Productivity*
A workflow that aggregates data from four sources (Slack, email, calendar, reminders), sends it to Claude via an **AI Agent Activity**, and returns a prioritized markdown report in three tiers: 🔴 Needs Attention · 🟡 Important Today · 🟢 Awareness. Runs on a REST trigger or a 7am daily timer, with Docker-based mocks (Wiremock + MailHog) and guidance for swapping in real APIs (Slack, Outlook/Graph, Google Calendar, Todoist).

### 13. [Apartment Finder Agent](./Feature_Samples/Apartment-Finder-Agent/) — *Real Estate & Property Management*
A renter describes what they want in plain English and an **AI Agent Activity** chains eight tools on a **Flogo MCP Server** to answer it — resolving a place name to zip codes, shortlisting communities, then fanning out to rent, amenities, proximity and trailing-12-month crime data before ranking the options. The eighth tool, `schedule_visit`, **sends real email**: a `#mapper` `@conditional` step resolves the chosen `community_id` to its leasing office server-side, so the LLM can never redirect the confirmation, and `#sendmail` delivers it to the renter and the office at once. Prompt-level guardrails pin the agent to Texas apartment search and roll "Houston" up to its serviced suburbs.

### 14. [Drug Safety Intake Advisor](./Feature_Samples/LLMClient-Dynamic-Auth/) — *Pharmaceutical & Life Sciences*
The authenticated counterpart to the IT Help Desk Advisor: the orchestrator configures nothing through a connection resource, and **both backends require a bearer token**. A drug safety associate reports an adverse event over WebSocket and one **LLM Client Activity** triages it against ICH E2A — reading product labeling and prior case history from a token-protected **MCP Server** (`authType: Token` on the client, `API Key` on the server, per-tool `scope` values ready for a JWT upgrade), then opening the ICSR and filing the E2B(R3) expedited report through a token-protected **A2A Server** (`Static Token` on both sides). Provider, model, API key, base URL, both URLs and both tokens all resolve from App Properties, so rotating a credential or moving to an on-premises model never touches a flow. The A2A server app deliberately goes the other way and *does* use an `#llmprovider` connection, so the two styles sit side by side. A Memory Conversation Store keyed on a required `caseId` carries one case across turns.

---

# Part 2 — Industry Use-Case Demos

End-to-end, **industry-specific Agentic AI demos** built on **TIBCO Flogo® Enterprise**. Where Part 1 isolates individual features, these use cases assemble them into complete, PostgreSQL-backed business scenarios — the same reusable pattern applied to a different vertical each time.

## The Three-App Pattern

Most use cases here ship the same **standard trio** of Flogo apps plus a PostgreSQL database. Understand it once and every use case reads the same way:

| App | Role | Trigger | Talks to |
|---|---|---|---|
| **`*MCPServer.flogo`** | Exposes **read-only** business data as MCP tools (query customers, policies, invoices, tickets…). Returns all rows; the orchestrator filters. | HTTP (streamable MCP) | PostgreSQL |
| **`*A2AServers.flogo`** *(a.k.a. `*Agents.flogo`)* | One **A2A agent per guarded write action** (open a ticket, submit a claim, schedule a visit, send email…). Each agent runs on its own port. | A2A server (one port each) | PostgreSQL / SMTP |
| **`*AIOrchestrator.flogo`** | The **conversational brain**: classifies intent, calls MCP read tools, hands off to A2A write agents, and enforces confirm-before-write guardrails. | WebSocket (`wsserver`) | LLM · MCP · A2A |

```
   Browser Chatbot  ──ws──▶  AI Orchestrator  ──▶  LLM (OpenAI / Gemini / Anthropic)
                                   │  ├──▶ MCP Server   ──▶ PostgreSQL   (reads)
                                   │  └──▶ A2A Agents   ──▶ PostgreSQL / SMTP  (guarded writes)
```

> **Naming:** the write-tier app is the **A2A Agents** app. The current samples name its file `*A2AServers.flogo`; newer apps and the build skills name it `*Agents.flogo` — **same app, either name**.

A few use cases deliberately vary this shape — see the **Variant** badge in the [status legend](#status-legend). BusinessWorks (BW6) and REST-tier variants ship their own detailed READMEs.

## Use-Case Catalog

Grouped by **industry vertical**. Click a use case to open its folder and full README. Ports are the defaults baked into each app (all configurable). "Endpoints" reads *WebSocket · MCP · A2A range*.

### Aerospace & Defense

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Aerospace MRO & AOG Operations](./Industry_Use_Cases_old/Aerospace_Defense_MRO_Use_Case/) | Maintenance/repair/overhaul + aircraft-on-ground assistant — check work orders & parts, then schedule/dispatch. | WS `:8085` `/mro` · MCP `:9095` · A2A `8091–8094` | `aerospace_mro` | ✅ Complete |

### Banking, Financial Services & Insurance

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Retail Banking Assistant](./Industry_Use_Cases_old/Retail_Banking_Assistant_Use_Case/) | Balances, transactions, cards & payments self-service with guarded write actions. | WS `:8088` `/banking` · MCP `:9096` · A2A `8710–8712` | `banking` | ✅ Complete · 🖼️ deck |
| [Life & Pensions Member Assistant](./Industry_Use_Cases_old/Life_And_Pensions_Use_Case/) | Pension pots, holdings, contributions, beneficiaries, claims & adviser callbacks; email confirmations. | WS `:9600` `/lifepensions` · MCP `:9982` · A2A `9983–9988` | `life_pensions` | ✅ Complete |
| [Auto Insurance Policyholder Assistant](./Industry_Use_Cases_old/Auto_Insurance_Assistant_RAG_Use_Case/) | Policy, coverage & claims assistant, **grounded on policy documents via RAG**. | WS `:9700` `/auto-insurance` · MCP `:9701` · A2A `9711–9714` | `auto_insurance` (+ vector store) | 🔍 RAG |

### Healthcare

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Hospital Post-Discharge Assistant](./Industry_Use_Cases_old/Hospital_AI-Agent_Use_Case/) | Post-discharge coordination — care instructions, appointments, refills, follow-ups. | WS `:8652` `/hospital` · MCP `:9092` · A2A `8070–8073` | `hospital` | 🔌 REST-tier |

### Telecommunications

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Telecom Invoice Chatbot](./Industry_Use_Cases_old/Telecom_Invoice_Chatbot_Use_Case/) | Explain invoices, usage & charges; dispute, adjust and email confirmations. | WS `:9500` `/telecom` · MCP `:9882` · A2A `9883–9885` | `telecom` | ✅ Complete |

### Utilities & Energy

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Electric Power Distribution](./Industry_Use_Cases_old/Power_Distribution_Use_Case/) | Residential self-service — bills, usage, outages; report outage, schedule visit, reconnect (past-due guardrail). | WS `:9680` `/grid` · MCP `:9682` · A2A `9683–9686` | `power_distribution` | ✅ Complete · 🖼️ deck |

### Manufacturing & Industrial

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Semiconductor Customer & Order Assistant](./Industry_Use_Cases_old/Semiconductor_Customer_Use_Case/) | Parts catalog, orders, RMAs & lead times for a semiconductor supplier. | WS `:9310` `/semiconductor` · MCP `:9098` · A2A `8730–8735` | `semiconductor` | ✅ Complete |
| [Predictive Maintenance & Asset Monitoring](./Industry_Use_Cases_old/Predictive_Maintenance_Use_Case/) | Asset health, sensor readings & failure prediction with a REST backend and a single chat agent. | WS `:8083` `/ws/chat` · MCP `:9093` · REST api `:9095` | `predictive_maintenance` | 🔌 REST-tier |

### Transportation, Travel & Logistics

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Airline Passenger Services](./Industry_Use_Cases_old/Airline_Passenger_Services_Use_Case/) | Flights, bookings, seats & baggage passenger assistant. | WS `:8083` `/airline` · MCP `:9093` · A2A `8074–8076` | `airline` | 🔌 REST-tier |
| [Logistics / Transport Shipper Assistant](./Industry_Use_Cases_old/Logistics_Transport_Use_Case/) | Shipment tracking, quotes & bookings; ships runnable binaries + FDA build script. | WS `:9690` `/logistics` · MCP `:9790` · A2A `9791–9794` | `logistics` | 📦 Prebuilt binaries |

### Retail & Consumer

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Retail — BW & Flogo, Better Together](./Industry_Use_Cases_old/Retail_AI_BW_Flogo/) | Retail assistant where **BW6 apps expose domain REST/MCP** and a Flogo **REST** orchestrator drives the LLM. | Flogo REST `:18085` `/api/query` · BW6 MCP `:18000` | *(inside BW6 apps)* | 🏛️ BW6 |

### Real Estate

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Real Estate Lead Engagement Assistant](./Industry_Use_Cases_old/Real_Estate_Lead_Assistant_Use_Case/) | MLS search & lead engagement; trio generated via `fda` CLI build scripts. | WS `:9590` `/realestate` · MCP `:9592` · A2A `9593–9597` | `realestate` | ✅ Complete |

### Publishing & Education

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Scholarly Publishing — Author Services](./Industry_Use_Cases/Scholarly_Publishing_Author_Services_Use_Case/) | Verified authors check manuscript status, get journal suggestions from an agent, see APC coverage, transfer in two confirmed steps; waivers & appeals routed to people. **Governed:** rules in SQL, tested end to end incl. prompt injection. | WS `:9840` `/authorservices` · MCP `:9842` · A2A `:9843` | `author_services` | ✅ Complete · 🛡️ Governed |

### Transportation, Travel & Logistics

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Airline Passenger Services — Meridian](./Industry_Use_Cases/Airline_Passenger_Services_Use_Case/) | Verified travellers check flight status & connection risk (computed in SQL), get agent-ranked rebooking options, rebook in two confirmed steps and email the confirmation; compensation, baggage & name-change requests routed to people. **Governed:** rules in SQL, tested end to end incl. prompt injection. An earlier, simpler version is kept under `Industry_Use_Cases_old/`. | WS `:9850` `/passengerservices` · MCP `:9852` · A2A `:9853` | `airline_governed` | ✅ Complete · 🛡️ Governed |
| [Parcel Delivery — Swiftbound Last-Mile](./Industry_Use_Cases/Parcel_Delivery_Last_Mile_Use_Case/) | Verified recipients track parcels, hear what a cryptic delivery exception means (decoded in SQL), get agent-ranked delivery options, reschedule onto a slot or redirect to a pickup point in two confirmed steps and email the confirmation; signature-required / high-value parcels can't go to an unattended locker; lost & damaged claims routed to people. **Governed:** rules in SQL, tested end to end incl. prompt injection. | WS `:9890` `/parceldelivery` · MCP `:9892` · A2A `:9893` | `parcel_delivery` | ✅ Complete · 🛡️ Governed |

### Banking & Financial Services

| Use Case | What it does | Endpoints | Database | Status |
|---|---|---|---|---|
| [Retail Banking Assistant — Kestrel Bank](./Industry_Use_Cases/Retail_Banking_Assistant_Use_Case/) | Verified customers check balances, transactions, cards & loans, get an agent to decode an unrecognised charge into the real merchant, dispute it (provisional credit computed in SQL) or block a card in two confirmed steps and email the confirmation; fee refunds, hardship & credit-limit requests routed to people. **Governed:** rules in SQL, tested end to end incl. prompt injection. An earlier, simpler version is kept under `Industry_Use_Cases_old/`. | WS `:9860` `/retailbanking` · MCP `:9862` · A2A `:9863` | `banking_governed` | ✅ Complete · 🛡️ Governed |
| [Corporate Payment Investigation & Status — Aurelia Global Bank](./Industry_Use_Cases/Corporate_Payments_Investigation_Use_Case/) | Verified corporate treasury users check payment status, rail, FX & fees, get an agent to decode cryptic return/reason codes, raise a trace in two confirmed steps or request a recall (money reversal) that a person decides, and email the confirmation; recalls, fee waivers, compensation, fraud & sanctions queries routed to people. **Governed:** rules in SQL, tested end to end incl. prompt injection. | WS `:9870` `/corporatepayments` · MCP `:9872` · A2A `:9873` | `payments_governed` | ✅ Complete · 🛡️ Governed |

### Status Legend

| Badge | Meaning |
|---|---|
| ✅ **Complete** | Standard MCP + A2A + Orchestrator trio, ready to run out of the box. |
| 🔍 **RAG** | Adds retrieval-augmented generation (a document ingestion app + vector store) on top of the trio. |
| 🏛️ **BW6** | Built on **TIBCO BusinessWorks 6** rather than (or alongside) the Flogo trio — different runtime; see its own README. |
| 🔌 **REST-tier** | Includes legacy REST API / single-agent apps alongside (or instead of) the standard trio. |
| 📦 **Prebuilt binaries** | Ships compiled `.exe` executables so you can run without building. |
| 🚧 **WIP** | Work in progress — some apps are unconverted copies; read the in-folder "Build status" note first. |
| 📄 **Stub** | README documents the intended design, but the runnable apps are not present yet. |
| 🖼️ **deck** | Includes an architecture slide deck. |
| 🛡️ **Governed** | Built with the `agentic-ai-use-case-builder` skill: passes the decision framework (agent vs. deterministic vs. human-owned); identity, scoping, prices and state changes enforced in PostgreSQL; ships a 4-step test ladder. |

> **Port collisions — don't run these pairs at once (defaults overlap):**
> The fourteen MCP + A2A + Orchestrator use cases listed above are now mutually conflict-free and can all
> run at the same time (Parcel Delivery uses WS `:9890` / MCP `:9892` / A2A `:9893`). A former clash was resolved by remapping: Semiconductor's orchestrator moved
> `:8088` → **`:9310`** (Retail Banking keeps `:8088`).
>
> Overlaps that remain involve the standalone/secondary samples — bring these up one at a time, or change
> the port in the app properties: `:8083` (Airline orchestrator · Predictive Maintenance · Mobile Customer
> Care) · `:9095` (Hospital `endevour-api` · Predictive Maintenance REST API · Morning Briefing) · `:8080`
> (Hospital · Predictive Maintenance · AI Triage · Smart Supply Chain) · `:8091` (Aerospace A2A · Travel
> Itinerary Planner · Beauty Intelligence) · `:8081`/`:8082` (Mobile Customer Care vs Healthcare Compliance
> and Hospital) · `:9998` (Healthcare Compliance · Smart Supply Chain).
>
> **If you change a port, change it in three places:** the app property / trigger setting, the matching
> `serverUrl` in the orchestrator's MCP and A2A connections, and this table plus the use case's README.

---

## Prerequisites

**Every sample and use case needs:**

- **TIBCO Flogo® 2.26.4 or later** (2.26.5+ for the [IT Help Desk Advisor](./Feature_Samples/LLMClient-Dynamic-Config-And-Memory/) and [Drug Safety Intake Advisor](./Feature_Samples/LLMClient-Dynamic-Auth/) memory / dynamic-config samples), with the [Flogo VS Code extension](https://marketplace.visualstudio.com/items?itemName=tibco.flogo). See the [Agentic AI documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm).
- An **API key** for your chosen LLM provider (OpenAI, Gemini, or Anthropic). Where a base URL is used, point it at a **real endpoint** (e.g. `https://api.openai.com/v1`). The default model referenced in the Part 2 demos is `gpt-5.6`; substitute any model your account can access.
- A **WebSocket client** for testing WebSocket samples/use cases: the included [Flogo Chatbot](#flogo-chatbot--browser-based-websocket-test-client) (Node.js 16+) or [websocat](https://github.com/vi/websocat).

**The Part 2 industry use cases additionally need:**

- **PostgreSQL 14+** (local or remote) — each use case creates its own database (`database.sql` + `reset_data.sql`).

**Some samples/use cases have extra prerequisites** — check the catalogs and each folder's README:

- **🔍 RAG** ([Auto Insurance](./Industry_Use_Cases_old/Auto_Insurance_Assistant_RAG_Use_Case/)): a document set + vector store; it ingests policy PDFs.
- **🏛️ BW6** ([Retail — BW & Flogo](./Industry_Use_Cases_old/Retail_AI_BW_Flogo/)): **TIBCO BusinessWorks 6.12** and Node.js for the MCP proxy.
- **SMTP** (Life & Pensions, Telecom, Power Distribution and others with an email agent): an SMTP account — e.g. Gmail with an App Password over SSL (port 465).
- **PostgreSQL / Docker / Claude Desktop** for several Part 1 samples (Mortgage AI, BeautyCo Retail, Morning Briefing) — see each sample's README.

> **Credentials are not shipped.** Every app property that held a secret is reset to a placeholder (`SECRET:YOURKEY` for connection API keys). Set your own LLM key, PostgreSQL password, and SMTP credentials before running — see each folder's README / manual-steps section.

---

## Quick Start

### Part 1 — a connector feature sample

1. Clone or download this repository.
2. Open the `flogo-enterprise-hub` folder in VS Code with the Flogo extension installed.
3. Navigate to `samples/Agentic_AI/<sample-name>/` and open the `.flogo` file.
4. Configure your LLM Provider connection with your API key.
5. Run the app from VS Code and connect via the [Flogo Chatbot](#flogo-chatbot--browser-based-websocket-test-client), websocat, or a REST client — see the sample's README for the exact endpoint and port.

### Part 2 — an industry use case (standard trio)

The steps are identical for each ✅ use case; only the database name, ports, and WebSocket path change (see the [catalog](#use-case-catalog)). Example uses Life & Pensions:

**1. Create and load the database:**

```bash
cd samples/Agentic_AI/Industry_Use_Cases_old/Life_And_Pensions_Use_Case
createdb life_pensions                          # or: psql -U postgres -c "CREATE DATABASE life_pensions;"
psql -U postgres -d life_pensions -f database.sql
psql -U postgres -d life_pensions -f reset_data.sql   # optional: refresh demo dates relative to today
```

**2. Import the three apps** into Flogo Enterprise (VS Code Flogo extension): the `*MCPServer.flogo`, `*A2AServers.flogo` (a.k.a. `*Agents.flogo`), and `*AIOrchestrator.flogo` for that use case.

**3. Set the app properties** — PostgreSQL host/port/database/user/password, your **LLM API key** and model, ports, and (if the use case has an email agent) SMTP settings. The exact property names are in each folder's README / manual-steps section.

**4. Start the apps in order** (the orchestrator needs the others running first):

```
1) *MCPServer               → HTTP MCP port ready first
2) *A2AServers / *Agents    → all A2A agent ports
3) *AIOrchestrator          → WebSocket port (needs MCP + A2A up)
```

**5. Connect the Chatbot** and start chatting:

```bash
cd samples/Agentic_AI/Chatbot
npm install
npm start                 # http://localhost:3000
```

In the UI, enter your use case's WebSocket URL (for example `ws://localhost:9600/lifepensions`), **click the ↻
(refresh) icon next to the URL box** to apply it, then click **Connect**. Typing the URL alone does nothing.

**6. Run the demo** using the prompts in that use case's `prompts.md`. After a run that performed writes, re-run `reset_data.sql` to restore the seeded data.

> 🏛️ **BW6** and 📦 **prebuilt-binary** use cases start differently (TIBCO Business Studio / running the `.exe` directly) — follow their own READMEs.

### Flogo Chatbot — Browser-Based WebSocket Test Client

A ready-to-use, domain-agnostic chat UI in [`Chatbot/`](./Chatbot/) drives any sample or use case that exposes a WebSocket endpoint. It supports multiple concurrent sessions, an editable WebSocket URL, and a live connection indicator.

```bash
cd samples/Agentic_AI/Chatbot
npm install
npm start
```

Open http://localhost:3000, enter the sample's WebSocket URL (`ws://localhost:<port><path>`), **click the ↻
icon next to the URL box** to apply it, then click **Connect**.

See each folder's individual `README.md` for detailed configuration and usage instructions.

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

<!-- SEO Keywords: TIBCO Flogo, Agentic AI, AI Agents, MCP, MCP Server, Model Context Protocol, A2A, Agent-to-Agent, LLM Orchestration, WebSocket, PostgreSQL, RAG, Retrieval Augmented Generation, BusinessWorks, Industry Use Cases, Banking, Insurance, Healthcare, Telecom, Utilities, Aerospace, Manufacturing, Retail, Real Estate, Scholarly Publishing, Low-Code, iPaaS, Enterprise AI -->

**Topics:** `Agentic AI` · `MCP Server` · `A2A` · `LLM Orchestration` · `Industry Demos` · `Low-Code`
