# TIBCO Flogo® Agentic AI Connector Samples

This directory contains **real-world sample applications** demonstrating the full capabilities of the **TIBCO Flogo® Agentic AI Connector** — the enterprise-grade way to build, orchestrate, and govern AI agents inside Flogo integration flows.

New here? Browse the **[Sample Catalog](#sample-catalog)** by industry vertical, follow the **[Suggested Learning Order](#suggested-learning-order)**, then see the **[Quick Start](#quick-start)**.

---

## What Is the Agentic AI Connector?

The connector provides three primary building blocks. The **Flogo Features Used** column in the catalog below tells you which one (and which activities, triggers, and MCP/A2A features) each sample exercises.

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

## Sample Catalog

Samples grouped by **industry vertical**, plus a browser chat client for testing. The **Flogo Features Used** column lists the Agentic AI building blocks, activities, triggers, and MCP/A2A features each sample exercises. Click any sample name to open its folder and full README.

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

### Utility

| Tool | Purpose |
|---|---|
| [Flogo Chatbot](./Chatbot/) | Browser-based WebSocket test client for any sample that exposes a WebSocket endpoint. Multiple sessions, editable WS URL, connection status. |

---

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

---

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
A multi-turn help desk advisor showcasing two Flogo 2.26.5 features: the **Memory Conversation Store** (history keyed by `conversationId`) and **dynamic MCP/A2A configuration** (`mcpServerConfigs` / `a2aServerConfigs` as activity inputs, no connection resource). An employee reports a WiFi issue, gets KB-guided steps across turns, and escalates to a ticket in one continuous conversation.

### 10. [Dynamic Semantic Tool Selection at Scale](./DynamicSemanticToolSelectionAtScale/) — *IT Operations & Service Management*
An IT Service Desk orchestrator handling requests across **150 tools** on three MCP servers via a two-step pattern: an **LLM Client** reads a text catalog and returns the relevant tool names, then an **AI Agent Activity** runs only those via `filteredToolNames`. A side-by-side comparison app shows the OpenAI 128-tool limit this pattern solves — scaling to hundreds or thousands of tools.

### 11. [Scheduled Reasoning Agent](./ScheduledReasoningAgent/) — *Cross-Industry / Workplace Productivity*
A timer-triggered agent (every Monday 8am) that queries a Sales Data MCP Server, generates a structured analysis, formats it into styled HTML via a third LLM call, saves it to disk, and emails stakeholders — zero human interaction. Three chained **LLM Client** calls with per-step temperatures (0.2 / 0.5 / 0.3), File Write, and Send Mail. A REST trigger is included for on-demand testing.

### 12. [Morning Briefing](./morning-briefing/) — *Cross-Industry / Workplace Productivity*
A workflow that aggregates data from four sources (Slack, email, calendar, reminders), sends it to Claude via an **AI Agent Activity**, and returns a prioritized markdown report in three tiers: 🔴 Needs Attention · 🟡 Important Today · 🟢 Awareness. Runs on a REST trigger or a 7am daily timer, with Docker-based mocks (Wiremock + MailHog) and guidance for swapping in real APIs (Slack, Outlook/Graph, Google Calendar, Todoist).

---

## Prerequisites

- **TIBCO Flogo® 2.26.4 or later** (2.26.5+ for the [IT Help Desk Advisor](./LLMClient-Dynamic-Config-And-Memory/) memory / dynamic-config sample). See the [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm).
- An API key for your chosen LLM provider (OpenAI, Gemini, or Anthropic).
- A WebSocket client for testing: [Flogo Chatbot](./Chatbot/) (included — see below) or [websocat](https://github.com/vi/websocat).
- Some samples have extra prerequisites (PostgreSQL, Docker, Claude Desktop) — see each sample's README.

## Quick Start

1. Clone or download this repository.
2. Open the `flogo-enterprise-hub` folder in VS Code with the Flogo extension installed.
3. Navigate to `samples/Agentic_AI/<sample-name>/` and open the `.flogo` file.
4. Configure your LLM Provider connection with your API key.
5. Run the app from VS Code and connect via the [Flogo Chatbot](./Chatbot/), websocat, or a REST client — see the sample's README for the exact endpoint and port.

### Flogo Chatbot — Browser-Based WebSocket Test Client

A ready-to-use chat UI in [`Chatbot/`](./Chatbot/) for testing any sample that exposes a WebSocket endpoint:

```bash
cd samples/Agentic_AI/Chatbot
npm install
npm start
# Open http://localhost:3000, set the WebSocket URL for your sample, and click Connect
```

See each sample's individual `README.md` for detailed configuration and usage instructions.
