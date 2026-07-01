# TIBCO Flogo® Agentic AI Connector Samples

This directory contains **real-world sample applications** demonstrating the full capabilities of the **TIBCO Flogo® Agentic AI Connector** — the enterprise-grade way to build, orchestrate, and govern AI agents inside Flogo integration flows.

---

## What Is the Agentic AI Connector?

The Agentic AI Connector provides three primary building blocks:

| Component | Best For | Key Capabilities |
|---|---|---|
| **LLM Client Activity** | Lightweight, stateless, one-shot LLM inference in a flow | Dynamic LLM config (provider, model, apiKey as inputs — no pre-configured connection), MCP tools, A2A remote agents, text or JSON response |
| **AI Agent Activity** | Embedding LLM intelligence inside an existing Flogo flow | LLM provider connection, model selection, default PII guardrails, token limits, MCP tools, in-memory conversation history, agent handoff |
| **AI Agent Trigger** | Building full-featured autonomous agents with custom logic | All AI Agent Activity features **plus** custom tools (Flogo flows), custom guardrails (prompt injection / advanced PII), custom conversation stores (DB, file, Redis), agent hand-off orchestration |

An **Invoke AI Agent Trigger Activity** (`callagent`) bridges the two worlds: it lets any Flogo trigger (REST, WebSocket, Kafka, Timer, ...) deterministically dispatch a user prompt to an Agent Trigger and receive its response.

### Supported LLM Providers
- **OpenAI** (e.g. GPT-4o, GPT-4.1, o3)
- **Gemini** (e.g. Gemini 2.0 Flash, Gemini 2.5 Pro)
- **Anthropic** (e.g. Claude Sonnet, Claude Opus)
- **Ollama** (local models, e.g. Llama 3, Mistral)
- **vLLM** (self-hosted OpenAI-compatible endpoint)

### Handler Types (Agent Trigger only)

| Handler Type | Purpose |
|---|---|
| **Tool** | A Flogo flow the LLM can call as a tool. Receives `toolParams` and returns `response`. |
| **Custom Guardrail** | A Flogo flow invoked on every LLM input **and** output. Use it for advanced PII redaction, prompt-injection prevention, jailbreak detection, or content policy enforcement. |
| **Custom Conversation Store** | Two Flogo flows — one for **STORE** (persist a new message) and one for **FETCH** (retrieve all messages). Together they give the agent durable, restartable conversation memory backed by any store (database, file system, Redis, S3, …). |

---

## Samples in This Directory

### 1. [Healthcare Patient Support Agent with HIPAA Guardrails](./Healthcare-Compliance-Agent/)
**Agent Trigger + Custom Guardrail + Custom Conversation Store + Custom Tools**

A HIPAA-aware patient support assistant built with OpenAI GPT-5.4. Features a custom PHI guardrail that redacts SSN, Date-of-Birth, and Medical Record Numbers (MRN) from every LLM input and output — and a file-based custom conversation store that provides a persistent, auditable session history.

**Highlights**: Custom PHI guardrail (SSN / DOB / MRN redaction) · Per-session JSON conversation store (STORE + FETCH, `array.append()` pattern) · HIPAA metadata enrichment on every stored turn · Compliance-first architecture · Three patient-service tools

---

### 2. [Mobile Customer Care Multi-Agent Hub](./Mobile-Customer-Care-Multi-Agent/)
**AIAgent Activity + List of Agents for Handoff + Invoke AI Agent Trigger + Multi-hop Handoff**

A mobile company's AI-powered customer support hub where one **AI Agent Activity** acts as an intelligent dispatcher with a configurable list of three specialist Agent Triggers: *BillingSpecialistAgent*, *TechnicalSupportAgent*, and *UpgradeAdvisorAgent*. Demonstrates the "List of Agents for Handoff" feature and contrasts non-deterministic AI routing with deterministic `InvokeAIAgentTrigger` routing side by side in the same app.

**Highlights**: AIAgent Activity as triage orchestrator · `agentHandoffs` list with three specialist targets · Multi-hop handoff (Technical → Upgrade) · Deterministic `callagent` path alongside non-deterministic AI routing · Six custom tool handlers with realistic mock data · PII guardrails on the billing agent

---

### 3. [Smart Supply Chain Assistant](./Smart-Supply-Chain-Assistant/)
**Agent Trigger + List of MCP Servers + Custom Tool**

A procurement intelligence assistant demonstrating two key features working together: the **List of MCP Servers** (connecting one Agent Trigger to two independently running Flogo MCP Servers simultaneously) and a **custom `CreatePurchaseOrder` tool** (a Flogo flow the LLM can call to write data back into the system). The agent queries live inventory and supplier data via MCP, then creates purchase orders through the custom tool — all in one natural language conversation.

**Highlights**: `mcpServers` list available on both Agent Activity and Agent Trigger · Two MCP server triggers in one Flogo app (ports 9091/9092) · Custom Flogo write tool alongside MCP read tools · Agent Trigger invoked via `callagent` from a WebSocket trigger · LLM confirms order details with user before calling `CreatePurchaseOrder` · Realistic supply chain mock data: 6 products, 4 suppliers, 4 purchase orders

---

### 4. [Travel Itinerary Planner with A2A Server](./Travel-Itinerary-Planner/)
**Agent Trigger + A2A Server + Remote Agents + Invoke AI Agent Trigger**

A conference travel coordination system demonstrating the **Agent-to-Agent (A2A) protocol** — two independent Flogo apps collaborating via HTTP. A reusable **TravelPlannerAgent** (A2A Server on port 9898) exposes flight search, hotel search, weather forecast, and itinerary building tools. An **EventTravelCoordinator** (Local Agent) adds event-specific intelligence (venue details, partner hotels, attendee registration) and delegates travel operations to the A2A Server via the `remoteAgents` list.

**Highlights**: `agentType: "A2A Server"` for reusable travel agent · `remoteAgents` list connecting Local Agent to remote A2A Server · `callagent` activity bridging REST trigger to Agent Trigger · Local + remote tools unified into one LLM toolset · Event-aware partner hotel recommendations with negotiated rates · Attendee registration with shuttle booking · Realistic mock data: 3 flights, 3 partner hotels, 5-day weather forecast

---

### 5. [AI-Powered Incident Triage Agent](./Ai-Triage-Agent/)
**AI Agent Activity + MCP Tools + ServiceNow Integration + Real-Time Dashboard**

An intelligent incident triage system that watches an integration middleware error stream and slashes ServiceNow ticket noise by ~90%. Each incoming error event is validated, reasoned over by a Flogo AI Agent, then acted on: the LLM decides whether the event is a new unique incident, a duplicate of an existing open ticket, or bad data — and calls the right MCP tool accordingly. For every new incident it also synthesises a resolution recommendation from past resolved tickets and attaches it immediately.

**Highlights**: AI Agent Activity with MCP tools for ServiceNow access · Semantic duplicate detection (not string matching) · Low-confidence guardrail (< 0.75 → new ticket + possible-duplicate note) · Resolution recommendations from historical tickets · Live browser dashboard with built-in error simulator · Supports Ollama (local), OpenAI, and Azure OpenAI · Pre-built binaries included — no Go or Flogo CLI needed

---

### 6. [Insurance Claims Processor with LLM Client Activity](./InsuranceClaimsProcessor/)
**LLM Client Activity + MCP Server + A2A Server + Sequential Chaining**

An insurance claims processing pipeline demonstrating the **LLM Client Activity** — a lightweight, stateless alternative to the AI Agent Activity for one-shot LLM inference. A REST API chains two LLM Client Activity calls: step 1 verifies policy coverage via an MCP Server, step 2 assesses fraud risk via an A2A Server agent, and the combined results produce an APPROVE/REVIEW/DENY recommendation. Three independent Flogo apps collaborate: orchestrator, policy MCP server, and fraud detection A2A agent.

**Highlights**: LLM Client Activity with dynamic LLM configuration (no pre-configured connection) · MCP Server integration for policy lookup and coverage check · A2A Server for fraud pattern analysis and risk scoring · Sequential chaining (`$activity[LookupPolicy].response` feeds Step 2) · PII redaction on the A2A agent · Stateless MCP server with tool annotations · Multi-dimensional fraud scoring with composite risk score

---

### 7. [Dynamic Semantic Tool Selection at Scale](./DynamicSemanticToolSelectionAtScale/)
**LLM Client Activity + AI Agent Activity + filteredToolNames + 3 MCP Servers (150 Tools)**

An IT Service Desk orchestrator that handles natural-language requests across **150 tools** spread over three MCP Servers using a **two-step tool selection pattern**. Step 1: an LLM Client Activity reads a text catalog of all 150 tool names and returns a JSON array of relevant tools. Step 2: an AI Agent Activity receives the filtered tool names via `filteredToolNames` and executes only those tools. Includes a comparison app (`ITServiceDeskDirect.flogo`) that sends all 150 tools directly — demonstrating the OpenAI 128-tool API limit that the two-step pattern solves.

**Highlights**: Two-step tool selection (LLMClient selector → Agent executor) · `filteredToolNames` input on AI Agent Activity · Text-based tool catalog bypasses API tool-count limits · 150 tools across 3 domains (Identity & Access, Infrastructure Monitoring, IT Ticketing) · Side-by-side comparison app proving the pattern is required at scale · Scales to hundreds or thousands of tools

---

### 8. [Scheduled Reasoning Agent](./ScheduledReasoningAgent/)
**LLM Client Activity + Timer Trigger + MCP Server + File Write + Send Mail**

A timer-triggered autonomous agent that fires every Monday at 8am, queries a Sales Data MCP Server, generates a structured analysis report, converts it to a professional styled HTML document via a third LLM call, saves it to disk, and emails it to stakeholders — all with zero human interaction. A REST trigger is also provided for on-demand testing. Demonstrates three-step LLM chaining with different temperatures per step, File Write for report persistence, and Send Mail for automated delivery.

**Highlights**: Timer trigger with cron scheduling (`0 0 8 ? * MON`) · Three chained LLM Client Activity calls (data fetch → analysis → HTML formatting) · Different temperatures per step (0.2, 0.5, 0.3) · File Write Activity saves styled HTML report · Send Mail Activity delivers via SMTP/TLS with HTML body and file attachment · MCP Server with 4 no-argument sales data tools · REST trigger for manual testing · Print-friendly HTML output (Save as PDF)

---

### 9. [IT Help Desk Advisor with Memory Conversation Store and Dynamic MCP/A2A Configuration](./LLMClient-Dynamic-Config-And-Memory/)
**LLM Client Activity + Memory Conversation Store + Dynamic mcpServerConfigs + Dynamic a2aServerConfigs**

A multi-turn IT help desk advisor demonstrating two **new features in Flogo 2.26.5**: the **Memory Conversation Store** (in-memory multi-turn conversation history keyed by `conversationId`) and **Dynamic MCP/A2A Server Configuration** (`mcpServerConfigs` and `a2aServerConfigs` as activity inputs instead of connection-level settings). An employee describes a WiFi issue, receives KB-guided troubleshooting steps across multiple turns, and escalates to a support ticket — all within one continuous conversation.

**Highlights**: Memory Conversation Store with `memoryMaxSize: 20` and query-param `sessionId` as `conversationId` · Dynamic `mcpServerConfigs` input mapping (no MCP connection resource) · Dynamic `a2aServerConfigs` input mapping (no A2A connection resource) · Property-resolved server names and URLs for environment portability · Knowledge Base MCP Server with search and troubleshooting tools · A2A Ticket Service agent for escalation · Multi-turn conversation memory across WebSocket messages

---

## Prerequisites

- **TIBCO Flogo® 2.26.4 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An API key for your chosen LLM provider (OpenAI, Gemini, or Anthropic)
- A WebSocket client for testing: [Flogo Chatbot](./Chatbot/) (included — see below) or [websocat](https://github.com/vi/websocat)

## Quick Start

1. Clone or download this repository.
2. Open the `flogo-enterprise-hub` folder in VS Code with the Flogo extension installed.
3. Navigate to `samples/Agentic_AI/<sample-name>/` and click the `.flogo` file.
4. Configure your LLM Provider connection with your API key.
5. Run the app from VS Code and connect via the [Flogo Chatbot](./Chatbot/) or websocat to test.

### Flogo Chatbot — Browser-Based WebSocket Test Client

A ready-to-use chat UI is included in [`Chatbot/`](./Chatbot/) for testing any sample that exposes a WebSocket endpoint:

```bash
cd samples/Agentic_AI/Chatbot
npm install
npm start
# Open http://localhost:3000, update the WebSocket URL if needed, and click Connect
```

See each sample's individual `README.md` for detailed configuration and usage instructions.
