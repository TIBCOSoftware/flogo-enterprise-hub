# TIBCO Flogo® Agentic AI Connector Samples

This directory contains **real-world sample applications** demonstrating the full capabilities of the **TIBCO Flogo® Agentic AI Connector** — the enterprise-grade way to build, orchestrate, and govern AI agents inside Flogo integration flows.

---

## What Is the Agentic AI Connector?

The Agentic AI Connector provides two primary building blocks:

| Component | Best For | Key Capabilities |
|---|---|---|
| **AI Agent Activity** | Embedding LLM intelligence inside an existing Flogo flow | LLM provider config, model selection, default PII guardrails, token limits, MCP tools, in-memory conversation history, agent handoff |
| **AI Agent Trigger** | Building full-featured autonomous agents with custom logic | All AI Agent Activity features **plus** custom tools (Flogo flows), custom guardrails (prompt injection / advanced PII), custom conversation stores (DB, file, Redis), agent hand-off orchestration |

An **Invoke AI Agent Trigger Activity** (`callagent`) bridges the two worlds: it lets any Flogo trigger (REST, WebSocket, Kafka, Timer, …) deterministically dispatch a user prompt to an Agent Trigger and receive its response.

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

## Prerequisites

- **TIBCO Flogo® 2.26.2 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An API key for your chosen LLM provider (OpenAI, Gemini, or Anthropic)
- A WebSocket client for testing: [Postman](https://www.postman.com/) or [websocat](https://github.com/vi/websocat)

## Quick Start

1. Clone or download this repository.
2. Open the `flogo-enterprise-hub` folder in VS Code with the Flogo extension installed.
3. Navigate to `samples/Agentic_AI/<sample-name>/` and click the `.flogo` file.
4. Configure your LLM Provider connection with your API key.
5. Run the app from VS Code and connect via WebSocket to test.

See each sample's individual `README.md` for detailed configuration and usage instructions.
