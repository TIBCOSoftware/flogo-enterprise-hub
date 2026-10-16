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

Focused, single-capability samples that each teach one building block of the Agentic AI Connector — AI Agent guardrails, multi-agent handoff, Flogo-as-MCP-server, Agent-to-Agent (A2A), the LLM Client Activity, memory, dynamic MCP/A2A config, semantic tool selection at scale, scheduled reasoning, and agent governance.

**➡️ Full catalogue, suggested learning order and per-sample details: [Feature Samples README »](./Feature_Samples/README.md)** (15 samples).

---

# Part 2 — Industry Use-Case Demos

End-to-end, PostgreSQL-backed **governed** chat assistants: the same three-app pattern — an **MCP Server** (scoped reads + guarded two-step writes), a read-only **A2A reasoning-agents** app, and a **WebSocket AI Orchestrator** — applied to a different industry each time (14 governed use cases, plus a BW6 "Better Together" sample).

**➡️ Full catalogue, the three-app pattern and per-use-case detail: [Industry Use-Case Demos README »](./Industry_Use_Cases/README.md)**

**▶ How to build & run them: [Industry_Use_Cases/RUNNING_THE_SAMPLES.md](./Industry_Use_Cases/RUNNING_THE_SAMPLES.md)** — or the one-command helper [`setup.py`](./Industry_Use_Cases/setup.py).

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

<!-- SEO Keywords: TIBCO Flogo, Agentic AI, AI Agents, MCP, MCP Server, Model Context Protocol, A2A, Agent-to-Agent, LLM Orchestration, WebSocket, PostgreSQL, RAG, Retrieval Augmented Generation, BusinessWorks, Industry Use Cases, Banking, Insurance, Healthcare, Telecom, Utilities, Aerospace, Manufacturing, Retail, Real Estate, Scholarly Publishing, Logistics, Airline, Governed AI, Agent Governance, Low-Code, iPaaS, Enterprise AI -->

**Topics:** `Agentic AI` · `MCP Server` · `A2A` · `LLM Orchestration` · `Industry Demos` · `Low-Code`
