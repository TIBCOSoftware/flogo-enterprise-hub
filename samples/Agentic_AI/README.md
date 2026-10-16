# TIBCO Flogo® Agentic AI — Samples & Industry Use Cases

This directory brings together two complementary collections for the **TIBCO Flogo® Agentic AI Connector** — the enterprise-grade way to build, orchestrate, and govern AI agents inside Flogo integration flows:

- **[Part 1 — Connector Feature Samples](#part-1--connector-feature-samples)** — focused apps that each teach a building block: **LLM Client Activity**, **AI Agent Activity**, **AI Agent Trigger**, custom guardrails, custom conversation stores, the "Flogo as an MCP tool server" pattern, the **A2A** (Agent-to-Agent) protocol, and agent privilege IDs. Start here to learn *how* the connector works.
- **[Part 2 — Industry Use-Case Demos](#part-2--industry-use-case-demos)** — complete, PostgreSQL-backed, industry-specific chat assistants. Each applies the same repeatable **three-app pattern**, governed by design: an **MCP Server** (verified identity, scoped reads and guarded two-step writes, with the rules in SQL), an **A2A Agents** app (read-only reasoning agents that never see the customer's identity), and a **WebSocket AI Orchestrator** (the conversation). Start here to see *what* you can build.

> ### Where to start
>
> | You want to… | Go to |
> |---|---|
> | **Learn a connector feature**, one building block at a time | [`Feature_Samples/`](./Feature_Samples/) — [Part 1](#part-1--connector-feature-samples) |
> | **Run an end-to-end demo** | [`Industry_Use_Cases/`](./Industry_Use_Cases/) — the governed, canonical industry use cases ([Part 2](#industry-use-cases-governed--start-here)) |
> | See BusinessWorks 6 and Flogo working together | [`BW6_Flogo_Samples/`](./BW6_Flogo_Samples/) — BW6 + Flogo "Better Together" samples ([details](#bw6--flogo-samples)) |
> | Chat with any WebSocket sample or use case | [`Chatbot/`](./Chatbot/) — the shared browser chat client |

Both collections share the **[Prerequisites](#prerequisites)**, the **[Quick Start](#quick-start)**, and the browser **[Flogo Chatbot](#flogo-chatbot--browser-based-websocket-test-client)** chat client.

### Folder layout

| Folder | What's inside |
|---|---|
| [`Feature_Samples/`](./Feature_Samples/) | Part 1 — connector feature samples, one building block at a time (Flogo 2.x). |
| [`Industry_Use_Cases/`](./Industry_Use_Cases/) | Part 2 — governed, industry-specific demos: business rules, identity, prices and state changes enforced in PostgreSQL, built with the `agentic-ai-use-case-builder` skill. The canonical industry use cases, organized as `<Industry>/<Sub_Category>/<UseCase>_Use_Case/` (e.g. `Financial_Services/Banking/`). |
| [`BW6_Flogo_Samples/`](./BW6_Flogo_Samples/) | TIBCO BusinessWorks 6 + Flogo "Better Together" samples — BW6 apps provide the domain APIs/MCP tools, Flogo does the AI orchestration. Needs a BW6 runtime / Business Studio. |
| [`Chatbot/`](./Chatbot/) | Shared browser WebSocket chat client for every sample and use case that exposes a WebSocket endpoint. |
| [`Flogo3x/`](./Flogo3x/) | Flogo 3.x folder-based project versions of nine feature samples. |

---

## Prerequisites

**Every sample and use case needs:**

- **TIBCO Flogo® 2.26.7 or later** — the **TIBCO Flogo® Extension for Visual Studio Code**, downloadable from the [TIBCO downloads page](https://www.tibco.com/downloads/11810) (also on the [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=tibco.flogo)). That is all you need to open, design and run the apps from VS Code. See the [Agentic AI documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm).
- An **API key** for your chosen LLM provider. Where a base URL is used, point it at a **real endpoint** (e.g. `https://api.openai.com/v1`). The Part 2 industry use cases need a capable tool-calling model; set the model your account can access in the app properties.
- A **WebSocket client** for testing WebSocket samples/use cases: the included [Flogo Chatbot](#flogo-chatbot--browser-based-websocket-test-client) (Node.js 16+) or [websocat](https://github.com/vi/websocat).
- **Connector prerequisites (design time):** install the driver / client library for each connector a sample uses **before** opening its apps in the designer or fetching metadata — VS Code **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for Flogo Connectors…**, then reload VS Code. Most samples here use **PostgreSQL** (PostgreSQL ODBC driver); a few use Oracle, MySQL, TIBCO EMS, FTL, ActiveSpaces or SAP Solutions. Per-connector install steps: [connector-prereqs.md](../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/connector-prereqs.md).

**The Part 2 industry use cases additionally need:**

- **PostgreSQL 14+** (local or remote) — each use case creates its own database from its `database.sql`, and `reset_data.sql` restores the demo data between runs.

**Some samples/use cases have extra prerequisites** — check the catalogs and each folder's README:

- **SMTP** (the use cases that email a confirmation): an SMTP account — e.g. Gmail with an App Password over SSL (port 465).
- **PostgreSQL / Docker / Claude Desktop** for several Part 1 samples (Mortgage AI, BeautyCo Retail, Morning Briefing, Agent Privilege IDs) — see each sample's README.
- **Building executables outside VS Code** (`flogobuild`, e.g. the use cases' `_rebuild` test ladders) needs the **Flogo App Build CLI** from the [TIBCO downloads page](https://www.tibco.com/downloads/11810) and the [Go runtime](https://go.dev/dl/); **deploying** to TIBCO Platform needs `tibcop`. See [skills-library/AGENT.md → Prerequisites and preflight](../../skills-library/AGENT.md#prerequisites-and-preflight).
- 🔍 **RAG:** [Insurance — Auto Policy & Claims Assistant (RAG)](./Industry_Use_Cases/Insurance/PC_Multi_Line/Auto_Insurance_Policy_Claims_RAG_Use_Case/) needs the local [`extensions/openAI`](../../extensions/openAI/) extension, a document set and a vector store.
- **BW6 + Flogo samples:** 🏛️ [Retail — BW & Flogo](./BW6_Flogo_Samples/Retail_AI_BW_Flogo/) needs **TIBCO BusinessWorks 6.12** and Node.js for the MCP proxy.

> **Credentials are not shipped.** Every app property that held a secret is reset to a placeholder (`SECRET:YOURKEY` for connection API keys). Set your own LLM key, PostgreSQL password, and SMTP credentials before running — see each folder's README.

---

## Quick Start

### Part 1 — a connector feature sample

1. Clone or download this repository.
2. Open the `flogo-enterprise-hub` folder in VS Code with the Flogo extension installed.
3. Navigate to `samples/Agentic_AI/Feature_Samples/<sample-name>/` and open the `.flogo` file.
4. Configure your LLM Provider connection with your API key.
5. Run the app from VS Code and connect via the [Flogo Chatbot](#flogo-chatbot--browser-based-websocket-test-client), websocat, or a REST client — see the sample's README for the exact endpoint and port.

### Part 2 — a governed industry use case

The steps are the same for every governed use case; only the database name, ports, WebSocket path and demo logins change (see the [catalog](#use-case-catalog) and the use case's README). This example uses **Telecom — Mobile Billing & Spend Control**:

> **Shared run guide:** the one-time build toolchain and the exact commands to **build and start the three apps** (the same for every sample) are in **[Running the Industry Use-Case samples](./Industry_Use_Cases/RUNNING_THE_SAMPLES.md)**. Each sample README links to it from its "Start the apps" step.

**1. Create and load the database:**

```bash
cd samples/Agentic_AI/Industry_Use_Cases/Telecommunications/Mobile_Fixed_Cable_Operators/Telecom_Mobile_Billing_Use_Case
createdb -U postgres mobile_billing
psql -U postgres -d mobile_billing -f database.sql     # creates the schema + rule functions, then loads seed_data.sql
```

**2. Open the three apps** in VS Code: `MobileBillingMCPServer.flogo`, `MobileBillingAgents.flogo`, and `MobileBillingAIOrchestrator.flogo`.

**3. Set the app properties** — PostgreSQL host/port/database/user/password, your **LLM API key** and model, and the SMTP settings for the confirmation email. The exact property names are in the use case's README.

**4. Start the apps in order** (the orchestrator needs the others running first):

```
1) MobileBillingMCPServer        → MCP  :9902
2) MobileBillingAgents           → A2A  :9903–9905
3) MobileBillingAIOrchestrator   → WebSocket :9900 /mobilebilling
```

**5. Connect the [Flogo Chatbot](#flogo-chatbot--browser-based-websocket-test-client)** to `ws://localhost:9900/mobilebilling`.

**6. Run the demo.** Sign in as Maria Lopez: *"Hi, my number is (212) 555-0101 and my code is 4821."* Then ask *"Why is my bill so high this month?"* The use case's README has the full walkthrough, and its `prompts.md` has more. After a run that made changes, restore the demo data:

```bash
psql -U postgres -d mobile_billing -f reset_data.sql
```

> 🏛️ **BW6 + Flogo samples** under `BW6_Flogo_Samples/` start from TIBCO Business Studio.

### Flogo Chatbot — Browser-Based WebSocket Test Client

A ready-to-use, domain-agnostic chat UI in [`Chatbot/`](./Chatbot/) drives any sample or use case that exposes a WebSocket endpoint. It supports multiple concurrent sessions, an editable WebSocket URL, and a live connection indicator.

```bash
cd samples/Agentic_AI/Chatbot
npm install               # first time only
npm start                 # http://localhost:3000
```

Open http://localhost:3000, enter the WebSocket URL (`ws://localhost:<port><path>`, for example `ws://localhost:9900/mobilebilling`), **click the ↻ (refresh) icon next to the URL box** to apply it, then click **Connect**. Typing the URL alone does nothing.

See each folder's individual `README.md` for detailed configuration and usage instructions.

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

**OpenAI** · **Gemini** · **Anthropic** · **Ollama** (local) · **vLLM** (self-hosted OpenAI-compatible endpoint)

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
15. **[Agent Privilege IDs](./Feature_Samples/Agent-Privilege-IDs/)** — govern the agents themselves: give each AI Agent Activity its **own JWT privilege ID**, enforced by per-tool scopes on a Flogo MCP Server, a PostgreSQL agent registry (kill switch) and human-only approval.

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
A multi-turn help desk advisor showcasing two Flogo 2.26.7 features: the **Memory Conversation Store** (history keyed by `conversationId`) and **dynamic MCP/A2A configuration** (`mcpServerConfigs` / `a2aServerConfigs` as activity inputs, no connection resource). An employee reports a WiFi issue, gets KB-guided steps across turns, and escalates to a ticket in one continuous conversation.

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

### 15. [Agent Privilege IDs](./Feature_Samples/Agent-Privilege-IDs/) — *Agent Governance (cross-industry)*
Answers the question banks ask about AI agents: *"How do you manage privilege IDs for agents?"* Back-office agents for a fictional bank each carry **their own identity** — a JWT whose `sub` is the agent's privilege ID and whose `scp` lists its granted scopes — in the MCP connection of their **AI Agent Activity**. The **MCP Server trigger** validates the token with `JWT Token` auth and a per-tool `scope`, so a tool the agent isn't entitled to is never even listed. Every tool flow reads the verified `tokenInfo.sub` and lets a **PostgreSQL agent registry** decide on each call (owner, status, expiry, entitlements): suspend an agent and its next call is refused even though its token is still valid. Agents can only *request* a privileged change — a named human approves it — and every call, allowed or refused, is audited under the agent ID from the token, never from the model. An **orchestrated** variant adds agent-to-agent delegation through JWT-protected MCP tools, and a **no-MCP** variant does the same with OAuth 2.0 client identities and an API gateway.

---

# Part 2 — Industry Use-Case Demos

End-to-end, **industry-specific Agentic AI demos** built on **TIBCO Flogo® Enterprise**. Where Part 1 isolates individual features, these use cases assemble them into complete, PostgreSQL-backed chat assistants — the same reusable, governed pattern applied to a different industry each time.

## The Three-App Pattern

Every governed use case ships the same **trio** of Flogo apps plus a PostgreSQL database. The design rule is *agentic in the middle, deterministic at the edges*: the AI handles the conversation and the fuzzy reasoning, PostgreSQL decides identity, scope, prices and every state change, and people decide the exceptions. Understand it once and every use case reads the same way:

| App | Role | Trigger | Talks to |
|---|---|---|---|
| **`*MCPServer.flogo`** | The **governed gateway** to the data. **Verified identity:** the caller signs in once and gets a short-lived session token. **Scoped reads:** every tool resolves the caller from that token and SQL decides what they can see — another customer's record is simply "not found". **Guarded two-step writes:** a change is first proposed, then confirmed after an explicit yes, and the database re-checks every rule before applying it. **Human-review routing:** refunds, waivers, appeals and other discretionary requests become routed cases for the right team. | HTTP (streamable MCP) | PostgreSQL · SMTP |
| **`*Agents.flogo`** | One or more **A2A reasoning agents** for the fuzzy step (explain a bill, decode a reason code, rank rebooking or delivery options). They are **read-only** and get only the **minimized input** they need — they never see the customer's identity and cannot change anything. | A2A server (one port per agent) | LLM |
| **`*AIOrchestrator.flogo`** | The **conversation**: understands the request, calls the MCP tools and the A2A agents, asks for a yes before each change, and keeps **per-connection memory** — each browser connection is its own conversation. | WebSocket (`wsserver`) | LLM · MCP · A2A |

```
   Browser Chatbot ──ws──▶ AI Orchestrator ──▶ LLM (OpenAI / Gemini / Anthropic)
                                 │  ├──▶ MCP Server ──▶ PostgreSQL   (identity · scoped reads · guarded writes · cases)
                                 │  └──▶ A2A Agents ──▶ LLM          (read-only reasoning on minimized input)
```

## Use-Case Catalog

Click a use case to open its folder and full README, which lists its ports, database and demo logins.

### Industry use cases (governed — start here)

Grouped by **Industry → Sub-category**, mirroring the [`Industry_Use_Cases/`](./Industry_Use_Cases/) folders. Every one passes the decision framework (agent vs. deterministic vs. human-owned), enforces its rules in SQL, and was tested end to end, including prompt injection.

#### Financial Services → Banking

| Use Case | What it does |
|---|---|
| [Banking — Retail Banking Assistant](./Industry_Use_Cases/Financial_Services/Banking/Retail_Banking_Assistant_Use_Case/) | Verified customers of fictional Kestrel Bank check balances, transactions, cards & loans, get an agent to decode an unrecognized charge into the real merchant, and dispute it (provisional credit computed in SQL) or block a card in two confirmed steps. Payments to saved payees get scam protection: an agent reads the customer's story for scam signs and SQL bands it (warn, or hold the payment for the fraud team); a third agent turns a hardship story into a brief for Financial Support. Fee refunds, hardship deferrals and held payments go to staff reviewers, who decide them in the same chatbot. |
| [Banking — Corporate Payments Investigation Assistant](./Industry_Use_Cases/Financial_Services/Banking/Corporate_Payments_Investigation_Use_Case/) | Verified corporate treasury, AP and AR users of fictional Aurelia Global Bank check payment status, rail, FX & fees, get an agent to decode cryptic return/reason codes, and raise a trace or request a recall in two confirmed steps. An agent matches a buyer's short-pay note to invoices and deduction reasons (SQL computes the earned discount and the disputed amount); another compares a new payee's typed name with the name on file, and SQL holds the payment on a mismatch. Recalls, held payments, disputed deductions and fee waivers go to staff reviewers, who decide them in the same chatbot. |

#### Telecommunications → Mobile, Fixed & Cable Operators

| Use Case | What it does |
|---|---|
| [Telecom — Mobile Billing & Spend Control Assistant](./Industry_Use_Cases/Telecommunications/Mobile_Fixed_Cable_Operators/Telecom_Mobile_Billing_Use_Case/) | Verified customers of fictional US carrier Tidewell Mobile hear why their bill jumped, usually pay-per-use roaming abroad or a premium content subscription (bill-to-bill deltas computed in SQL, narrated by an agent). An agent classifies charges they don't recognize and another recommends a plan from their real usage and travel. Customers then cancel a subscription, add TravelPass, set a roaming limit or change plan in two confirmed steps and email the confirmation; past-due balances and device installment lock-in are enforced in SQL. Refunds/disputes, port-out and suspected fraud go to staff reviewers, who decide them in the same chatbot. |

#### Energy & Utilities → Electric, Gas & Utilities Grid

| Use Case | What it does |
|---|---|
| [Utilities — Electric Outage & Billing Assistant](./Industry_Use_Cases/Energy_Utilities/Electric_Gas_Utilities_Grid/Electric_Utility_Outage_Billing_Use_Case/) | Verified residential customers of fictional Texas utility Ridgeline Power & Light hear why their bill went up (bill-to-bill deltas, weather and estimated reads computed in SQL, narrated by an agent), report outages (an agent triages hazards; SQL links the report to a known area outage instead of opening a duplicate), pick a rate plan from SQL cost estimates on their real usage, and book a smart-meter upgrade or a reconnect (blocked in SQL while a past-due balance remains). Estimated-read disputes, payment arrangements, medical-baseline protection and hazards go to people, who decide them in the same chatbot. |

#### Energy & Utilities → Oil & Gas

| Use Case | What it does |
|---|---|
| [Energy & Utilities — Oilfield Asset Health Monitoring Assistant](./Industry_Use_Cases/Energy_Utilities/Oil_Gas/Oilfield_Asset_Health_Monitoring_Use_Case/) | Verified control-room operators of fictional Mesa Ridge Energy watch the health of their region's rod pumps, compressors and wellhead valves, classified deterministically in SQL (threshold table, worst sensor wins). An agent triages a technician's free-text field note (failure mode, parts, safety language — reconciled with the sensors in SQL, safety routed to HSE), another matches past failures and a third drafts the shift handover. Work orders are raised in two confirmed steps (rules enforced in SQL); estimates above $25,000, shut-ins, threshold changes and alert closures go to Production Engineering and safety signals to HSE, who decide them in the same chatbot. |

#### Healthcare & Life Sciences → Providers & Health Systems

| Use Case | What it does |
|---|---|
| [Healthcare — Hospital Post-Discharge Care Assistant](./Industry_Use_Cases/Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case/) | Verified discharge coordinators of fictional Bellmont Regional Medical Center run each patient's post-discharge checklist for their own ward: an agent ranks clinic slots and the follow-up is booked in two confirmed steps (specialty, window and open slot enforced in SQL); discharge medicines are ordered only from the discharge list and a bed goes to housekeeping only once its patient has left; agents write plain-language instructions and flag home-medicine conflicts for the pharmacist. High-alert medicines, early bed turnovers, prescription changes and discharge decisions go to pharmacists, the charge nurse and the attending, who decide them in the same chatbot. |

#### Transportation & Logistics → Airlines & Aviation

| Use Case | What it does |
|---|---|
| [Airline — Passenger Services Assistant](./Industry_Use_Cases/Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case/) | Verified travelers of fictional carrier Meridian check flight status & connection risk (computed in SQL), get agent-ranked rebooking options and rebook in two confirmed steps. An agent turns a delayed, lost or damaged bag description into a claim (type, bag and color codes, missing fields — validated and recorded in SQL), and another turns free-text needs into IATA assistance codes (WCHR / WCHS / WCHC …) added to the traveler's own flight as pending. Compensation, interim baggage expenses, assistance confirmation, complaints and name changes go to staff reviewers, who decide them in the same chatbot. |

#### Transportation & Logistics → Parcel & Postal Logistics

| Use Case | What it does |
|---|---|
| [Logistics — Parcel Delivery Assistant](./Industry_Use_Cases/Transportation_Logistics/Parcel_Postal_Logistics/Parcel_Delivery_Last_Mile_Use_Case/) | Verified recipients of fictional last-mile carrier Swiftbound track parcels, hear what a cryptic delivery exception means (decoded in SQL), get agent-ranked delivery options and reschedule or redirect in two confirmed steps. An agent structures free-text access notes into delivery instructions (SQL checks the safe place, blocks risky instructions and never stores the access code); another classifies damage, missing-contents or lost claims, capped in SQL at the declared value and coverage limit. Signature-required / high-value parcels can't be left unattended. Claims go to staff reviewers, who decide them in the same chatbot. |

#### High Tech & Software → Semiconductors & Electronics

| Use Case | What it does |
|---|---|
| [High Tech — Semiconductor Orders & RMA Assistant](./Industry_Use_Cases/High_Tech_Software/Semiconductors_Electronics/Semiconductor_Orders_RMA_Use_Case/) | Verified buyers at the US customers of fictional distributor Arcwell Components look up parts, prices, stock, lead times and change notices: an agent matches a pasted BOM line to catalog parts; orders are priced from the price-break table and placed in two confirmed steps (MOQ, stock, credit and the end-of-life last-time-buy date enforced in SQL); an agent classifies a failure story for a two-step RMA and another explains what a change notice means for open orders. RMA dispositions, special pricing, credit changes, factory expedites and large last-time-buys go to quality, sales & pricing and credit reviewers, who decide them in the same chatbot. |

#### Insurance → Property & Casualty / Multi-Line

| Use Case | What it does |
|---|---|
| [Insurance — Auto Policy & Claims Assistant (RAG)](./Industry_Use_Cases/Insurance/PC_Multi_Line/Auto_Insurance_Policy_Claims_RAG_Use_Case/) | Verified policyholders of fictional Copperleaf Auto Insurance check their policy, coverages, claims and payments (from PostgreSQL) and ask what the policy wording says (RAG over four policy PDFs through the `extensions/openAI` vector search). They file claims in two confirmed steps: agents structure the accident story, read the retrieved wording for exclusions and score the narrative; SQL adds its own signal points, bands the score and routes the claim to normal handling, an adjuster, or Special Investigations with the payment held. Adjusters and investigators decide cases in the same chatbot. |

#### Insurance → Life, Pensions & Wealth

| Use Case | What it does |
|---|---|
| [Insurance — Life & Retirement Member Services Assistant](./Industry_Use_Cases/Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case/) | Verified members of fictional Harborline Life & Retirement check policies, beneficiaries, 401(k)/IRA balances, holdings and claims. They raise their 401(k) deferral and switch funds in two confirmed steps (plan maximum, IRS limit and holdings enforced in SQL), and file Critical Illness / Income Protection claims after an agent turns their story into a claim type and document list; other agents build a life-event checklist and write the examiner's appeal brief. Beneficiary changes, claim decisions, appeals, withdrawals/rollovers and advice go to people, who decide them in the same chatbot. |

#### Media & Travel → Media & Publishing

| Use Case | What it does |
|---|---|
| [Publishing — Author Services Assistant](./Industry_Use_Cases/Media_Travel/Media_Publishing/Scholarly_Publishing_Author_Services_Use_Case/) | Verified authors of a fictional scholarly publisher check manuscript status and APC coverage, get an agent's revision checklist from the reviewer comments and journal suggestions for a declined paper, and transfer a manuscript in two confirmed steps after an agent checks their data, ethics, funding and competing-interest statements against the target journal's policy (SQL blocks an incomplete transfer). Fee waivers, appeals, authorship changes, integrity questions and statement exceptions go to staff reviewers, who decide them in the same chatbot. |

#### Aerospace & Defense → Defense & Space

| Use Case | What it does |
|---|---|
| [Aerospace & Defense — MRO AOG Operations Assistant](./Industry_Use_Cases/Aerospace_Defense/Defense_Space/Aerospace_MRO_AOG_Operations_Use_Case/) | Verified MRO controllers of fictional Northvale Aero Services run aircraft-on-ground recovery for their own base: agents triage a crew write-up to an ATA chapter and likely parts, flag repeat defects and draft the shift handover. Parts are ordered and technicians dispatched in two confirmed steps (part applicability, lead time, certification + type rating and availability enforced in SQL). Spend above the controller's $25,000 limit goes to a maintenance manager, and return-to-service, AD compliance, MEL deferrals and grounding changes to Quality & Airworthiness, who decide them in the same chatbot. |

#### Real Estate → Residential Brokerage

| Use Case | What it does |
|---|---|
| [Real Estate — Lead Engagement Assistant](./Industry_Use_Cases/Real_Estate/Residential_Brokerage/Real_Estate_Lead_Engagement_Use_Case/) | Verified buyer and seller leads of fictional brokerage Brightpath Realty search listings (filters applied in SQL) and check showings, their agent and market statistics: an agent ranks listings against the buyer's own words; showings are booked in two confirmed steps (slot and double-booking rules enforced in SQL) and move the lead to Active; an agent reads a lead's plans and SQL sets how soon their agent calls; another catches Fair-Housing-sensitive questions so they are answered neutrally. Offers, list-price changes, contract updates and legal or mortgage questions go to sales-agent and compliance reviewers, who decide them in the same chatbot. |

### BW6 + Flogo samples

TIBCO BusinessWorks 6 + Flogo "Better Together" samples, kept under [`BW6_Flogo_Samples/`](./BW6_Flogo_Samples/). They are not on the three-app pattern and are not migrated to the governed style; they need a BW6 runtime / Business Studio.

| Sample | Industry | Description | Ports | Database | Status |
|---|---|---|---|---|---|
| [Retail — BW & Flogo, Better Together](./BW6_Flogo_Samples/Retail_AI_BW_Flogo/) | Retail & Consumer Goods | Retail assistant where **BW6 apps expose domain REST/MCP** and a Flogo **REST** orchestrator drives the LLM. | Flogo REST `:18085` `/api/query` · BW6 MCP `:18000` | *(inside BW6 apps)* | 🏛️ BW6 |

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

<!-- SEO Keywords: TIBCO Flogo, Agentic AI, AI Agents, MCP, MCP Server, Model Context Protocol, A2A, Agent-to-Agent, LLM Orchestration, WebSocket, PostgreSQL, RAG, Retrieval Augmented Generation, BusinessWorks, Industry Use Cases, Banking, Insurance, Healthcare, Telecom, Utilities, Aerospace, Manufacturing, Retail, Real Estate, Scholarly Publishing, Logistics, Airline, Governed AI, Agent Governance, Low-Code, iPaaS, Enterprise AI -->

**Topics:** `Agentic AI` · `MCP Server` · `A2A` · `LLM Orchestration` · `Industry Demos` · `Low-Code`
