# IT Help Desk Advisor — LLM Client Activity with Memory Conversation Store and Dynamic MCP/A2A Configuration

## Overview

This sample demonstrates two key features of the **TIBCO Flogo® 3** Agentic AI Connector LLM Client Activity:

1. **Memory Conversation Store** — Multi-turn conversation memory that persists across requests sharing the same `conversationId`, enabling stateful interactions without a database.
2. **Dynamic MCP Server and A2A Server Configuration** — MCP and A2A server endpoints configured as **activity inputs** (not connection-level settings), allowing runtime-configurable server discovery.

Three independent Flogo applications work together:

- **ITHelpDeskAdvisor** — A **WebSocket server** with an LLM Client Activity that remembers previous messages in a session and dynamically connects to an MCP Server and an A2A Server.
- **KnowledgeBaseMCPServer** — A **stateless MCP Server** exposing IT knowledge base search and troubleshooting tools.
- **TicketServiceA2A** — An **A2A Server** agent that creates and tracks IT support tickets.

| Pattern | Component | What It Shows |
|---|---|---|
| **Memory Conversation Store** | `ITHelpDeskAdvisor` | `conversationStoreType: "Memory"` + `memoryMaxSize` + `conversationId` from query param |
| **Dynamic MCP Config** | `ITHelpDeskAdvisor` | `mcpServerConfigs` input mapping with property-resolved server URL |
| **Dynamic A2A Config** | `ITHelpDeskAdvisor` | `a2aServerConfigs` input mapping with property-resolved server URL |
| **MCP Server** | `KnowledgeBaseMCPServer` | Stateless MCP Server with KB search and troubleshooting tools |
| **A2A Server** | `TicketServiceA2A` | Agent Trigger with `agentType: "A2A Server"` for ticket management |

---

## Real-World Scenario

**Persona**: Alex, a corporate employee, can't connect to the office WiFi. Alex opens a chat with the IT Help Desk and has a multi-turn conversation:

```
Connect via WebSocket:
  ws://localhost:9200/helpdesk?sessionId=wifi-issue-001

Turn 1 — Alex describes the problem:
  > My laptop can't connect to WiFi

  System:
    [Calls search_kb_articles → KnowledgeBaseMCPServer]
    [Calls get_troubleshooting_steps → KnowledgeBaseMCPServer]

    "I found a relevant article: WiFi Connection Troubleshooting Guide (KB-1001).
     Let's start with Step 1: Open Settings > Network & Internet > WiFi,
     toggle WiFi OFF, wait 10 seconds, then toggle back ON.
     Did that help?"

Turn 2 — Alex reports back (same WebSocket session = conversation memory kicks in):
  > I tried that but it still doesn't work

  System (remembers Turn 1 — does NOT re-ask the problem):
    "OK, let's try Step 2: Forget the corporate network (CorpNet-5G)
     and reconnect using your Active Directory credentials.
     Let me know if that resolves it."

Turn 3 — Escalation:
  > Still not working after forgetting and reconnecting

  System (remembers Turns 1 & 2):
    [Calls create_ticket → TicketServiceA2A]

    "I've created support ticket TKT-20260623-001 (High priority, Networking).
     The ticket includes a summary of what we already tried:
     - Toggled WiFi off/on
     - Forgot and reconnected to CorpNet-5G
     An IT technician will follow up within 2 hours."
```

**Same `sessionId` across all turns. The Memory Conversation Store keeps context — no repeated questions, seamless escalation.**

---

## Architecture

```
 Employee (WebSocket client — Postman, websocat, etc.)
      |
      |  ws://localhost:9200/helpdesk?sessionId=wifi-issue-001
      v
 +--------------------------------------------------------------------+
 |  ITHelpDeskAdvisor (port 9200)                                     |
 |                                                                     |
 |  WebSocket Trigger --> HelpDeskFlow                                 |
 |                                                                     |
 |  +----------------------------------------------------------+      |
 |  | HelpDeskLLMClient (LLM Client Activity)                  |      |
 |  |                                                          |      |
 |  |  conversationStoreType = "Memory"                        |      |
 |  |       memoryMaxSize = 20                                 |      |
 |  |       conversationId = sessionId from query param        |      |
 |  |                                                          |      |
 |  |  mcpServerConfigs (input-level)                          |------+----> KnowledgeBaseMCPServer
 |  |         name: from App Property                          |      |      (MCP on port 9201/mcp)
 |  |         serverUrl: from App Property                     |      |      +- search_kb_articles
 |  |                                                          |      |      +- get_troubleshooting_steps
 |  |  a2aServerConfigs (input-level)                          |      |
 |  |         name: from App Property                          |------+----> TicketServiceA2A
 |  |         serverUrl: localhost:9202                         |      |      (A2A on port 9202)
 |  |                                                          |      |      +- create_ticket
 |  |  LLM: OpenAI gpt-4o (dynamic config)                    |      |      +- get_ticket_status
 |  +-----------------------------+----------------------------+      |
 |                                |                                    |
 |                    $activity[HelpDeskLLMClient].response            |
 |                                |                                    |
 |  +-----------------------------v----------------------------+      |
 |  | WebSocket Write Data                                     |      |
 |  |   Sends LLM response back to WebSocket client            |      |
 |  +----------------------------------------------------------+      |
 +--------------------------------------------------------------------+
```

---

## Apps in This Sample

| Project Folder | Description |
|---|---|
| `ITHelpDeskAdvisor` | **Orchestrator** — WebSocket server on port 9200 with LLM Client Activity using Memory Conversation Store (`memoryMaxSize: 20`) and dynamic `mcpServerConfigs` / `a2aServerConfigs` input mappings. |
| `KnowledgeBaseMCPServer` | **MCP Server** — Stateless MCP Server on port 9201. Exposes two read-only tools (`search_kb_articles`, `get_troubleshooting_steps`) with mock KB article data. |
| `TicketServiceA2A` | **A2A Server** — IT ticket management agent on port 9202. Exposes two tools (`create_ticket`, `get_ticket_status`) with mock ticket data. |

Each project folder contains an `app.fgmd` file (the Flogo 3 app module) and an `app.fgprops` file (its App Properties).

---

## Memory Conversation Store — How It Works

The **Memory Conversation Store** in the TIBCO Flogo® 3 LLM Client Activity gives it multi-turn conversation memory without any external database — messages are stored in the Flogo app's memory.

### Configuration

```json
{
  "ref": "#llmclientactivity",
  "settings": {
    "conversationStoreType": "Memory",
    "memoryMaxSize": 20
  },
  "input": {
    "conversationId": "=coerce.toString($flow.queryParams.sessionId)"
  }
}
```

| Setting | Purpose |
|---|---|
| `conversationStoreType` | `"Memory"` — use in-memory conversation store (default: none) |
| `memoryMaxSize` | Maximum number of messages to retain per conversation (oldest messages are evicted when the limit is reached) |
| `conversationId` | Groups messages into sessions — messages with the same ID share conversation history. In this sample, it comes from the `sessionId` query parameter in the WebSocket URL |

### How It Enables Multi-Turn Conversations

1. **Turn 1**: User connects via `ws://localhost:9200/helpdesk?sessionId=wifi-issue-001` and sends "My laptop can't connect to WiFi". The LLM responds with troubleshooting Step 1. Both the user message and LLM response are stored in memory under `wifi-issue-001`.

2. **Turn 2**: User sends "I tried that but it still doesn't work" on the same WebSocket connection. The Memory Conversation Store loads the previous messages, so the LLM sees the full conversation history and knows the user already tried Step 1 — it suggests Step 2 without re-asking the problem.

3. **Turn 3**: User reports failure again. The LLM has context from all prior turns, decides troubleshooting is exhausted, and escalates to the A2A ticket service — including a summary of what was already attempted.

### Different Sessions Are Independent

Connections with different `sessionId` values maintain completely separate conversation histories:

```
# Session A — WiFi issue
ws://localhost:9200/helpdesk?sessionId=wifi-issue-001

# Session B — VPN issue (independent conversation)
ws://localhost:9200/helpdesk?sessionId=vpn-issue-042
```

### Comparison: Before vs After

| Feature | Before (InsuranceClaimsProcessor) | After (This Sample) |
|---|---|---|
| Conversation memory | None — stateless, one-shot | Memory store with `memoryMaxSize: 20` |
| Multi-turn support | No — each request starts fresh | Yes — same `conversationId` shares history |
| Use case fit | Single-request pipelines | Ongoing conversations (help desk, chat) |

---

## Dynamic MCP/A2A Configuration — How It Works

In TIBCO Flogo® 3, the LLM Client Activity supports **input-level** MCP and A2A server configuration via `mcpServerConfigs` and `a2aServerConfigs` input mappings. This is an alternative to configuring servers at the **connection level** in settings.

### Input-Level Configuration (This Sample)

MCP and A2A servers are configured as **activity inputs**, which means:
- Server URLs can come from **App Properties** and be changed at deploy time
- Different environments (dev, staging, prod) can point to different servers without modifying the flow
- No MCP or A2A Connection resource is needed

```json
{
  "input": {
    "mcpServerConfigs": {
      "mapping": [
        {
          "name": "=$property[\"LLMClient.MCP.KB.Server_Name\"]",
          "serverType": "http",
          "serverUrl": "=$property[\"LLMClient.MCP.KB.Server_URL\"]",
          "httpTransportType": "streamable",
          "authType": "None",
          "authToken": ""
        }
      ]
    },
    "a2aServerConfigs": {
      "mapping": [
        {
          "name": "=$property[\"LLMClient.A2A.Ticket.Server_Name\"]",
          "serverUrl": "=$property[\"LLMClient.A2A.Ticket.Server_URL\"]",
          "authType": "None",
          "authToken": ""
        }
      ]
    }
  }
}
```

### Connection-Level Configuration (Alternative Approach)

In the [InsuranceClaimsProcessor](../InsuranceClaimsProcessor/) sample, MCP and A2A servers are configured via **connection resources** referenced by ID:

```json
{
  "settings": {
    "mcpServers": ["conn://488cd44d-..."],
    "remoteAgents": ["conn://a2a12345-..."]
  }
}
```

### Comparison

| Aspect | Connection-Level | Input-Level Dynamic (This Sample) |
|---|---|---|
| Configuration location | `settings.mcpServers` / `settings.remoteAgents` | `input.mcpServerConfigs` / `input.a2aServerConfigs` |
| Server URL source | Fixed in connection resource | App Property, flow variable, or literal |
| Change server at deploy time | Requires editing connection resource | Change App Property value |
| Connection resource needed | Yes | No |
| Multiple environments | One connection per environment | One property per environment |
| Auth configuration | In connection resource | In the mapping (`authType`, `authToken`) |

---

## Tool Reference

### MCP Server Tools (KnowledgeBaseMCPServer — port 9201)

| Tool | Parameters | Returns |
|---|---|---|
| `search_kb_articles` | `query` (required) — keyword or topic | List of matching KB articles with article_id, title, summary, category, last_updated |
| `get_troubleshooting_steps` | `article_id` (required) — e.g. "KB-1001" | Step-by-step troubleshooting instructions with estimated time and difficulty |

### A2A Server Tools (TicketServiceA2A — port 9202)

| Tool | Parameters | Returns |
|---|---|---|
| `create_ticket` | `issue_summary`, `priority`, `category` (required), `steps_tried` | Ticket ID, status, priority, category, estimated response time, assigned team |
| `get_ticket_status` | `ticket_id` (required) — e.g. "TKT-20260623-001" | Ticket details: status, priority, category, assigned technician, last update, resolution ETA |

---

## Sample Data

### KB Articles

| Article ID | Title | Category |
|---|---|---|
| KB-1001 | WiFi Connection Troubleshooting Guide | Networking |
| KB-1002 | VPN Connection Setup and Troubleshooting | Networking |
| KB-1003 | Password Reset and Account Lockout Recovery | Security |

### Support Ticket (Mock)

| Field | Value |
|---|---|
| Ticket ID | TKT-20260623-001 |
| Status | Open |
| Priority | High |
| Category | Networking |
| Assigned Team | Network Operations |
| Assigned To | Mike Rodriguez |
| Estimated Response | 2 hours |

---

## Prerequisites

- **TIBCO Flogo® 3.0.0 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or swap for Anthropic, Gemini, Ollama, or vLLM in the LLM configuration properties)
- A WebSocket client for testing: [Flogo Chatbot](../../Chatbot/) (included in this repo) or [websocat](https://github.com/vi/websocat)

---

## Setup & Run

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `KnowledgeBaseMCPServer`, `TicketServiceA2A`, `ITHelpDeskAdvisor`.
2. Open each app's `.fgprops` file and set the App Properties for your environment (see [App Properties](#app-properties) below) — LLM provider/API key, MCP/A2A URLs, auth tokens, ports.
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select an app module → right-click → **Run As Executable**. The native binary is produced in that app's `bin/` folder and logs stream to the integrated terminal. Start the MCP + A2A servers first, then the advisor:
   - Run **`KnowledgeBaseMCPServer`** first — the MCP Server starts at `http://localhost:9201/mcp` (port from `FlogoMcpServer.PORT`).
   - Run **`TicketServiceA2A`** next — the A2A Server agent starts on port **9202** (from `A2A.port`).
   - Run **`ITHelpDeskAdvisor`** last — the WebSocket server starts on port **9200** (from `WebSocket_Port`).
5. Invoke and verify:

   **Verify the A2A Server is running:**
   ```bash
   curl http://localhost:9202/.well-known/agent.json
   ```

   **Connect and chat** using any WebSocket client. Two options:

   **Flogo Chatbot** (browser UI — included in this repo):
   ```bash
   cd ../../Chatbot
   npm install
   npm start
   ```
   Open **http://localhost:3000**. Update the WebSocket URL to `ws://localhost:9200/helpdesk?sessionId=wifi-issue-001` and click the refresh icon to apply. Click **Connect** and start chatting.

   **websocat** (command line):
   ```bash
   websocat "ws://localhost:9200/helpdesk?sessionId=wifi-issue-001"
   ```

   The `sessionId` query parameter becomes the `conversationId` for the Memory Conversation Store. All messages sent on the same `sessionId` share conversation history.

   **Example multi-turn conversation:**
   ```
   > My laptop cannot connect to the office WiFi network
   < I found a relevant article: WiFi Connection Troubleshooting Guide (KB-1001).
     Let's start with Step 1: Open Settings > Network & Internet > WiFi,
     toggle WiFi OFF, wait 10 seconds, then toggle back ON.
     Did that help?

   > I tried toggling WiFi off and on but it still does not work
   < OK, let's try Step 2: Forget the corporate network (CorpNet-5G)
     and reconnect using your Active Directory credentials.
     Let me know if that resolves it.

   > None of the steps worked. Can you create a support ticket?
   < I've created support ticket TKT-20260623-001 (High priority, Networking).
     The ticket includes a summary of what we already tried.
     An IT technician will follow up within 2 hours.
   ```

   Notice how the system remembers what was discussed and what was already tried — it never re-asks the problem and includes prior context when creating the ticket.

   **Start a separate session** (different `sessionId` = independent conversation):
   ```bash
   websocat "ws://localhost:9200/helpdesk?sessionId=vpn-issue-042"
   ```

---

## App Properties

Set these in each app's `app.fgprops` file (`data.profiles.default`) before running.

### ITHelpDeskAdvisor

| Property | Default | Description |
|---|---|---|
| `LLMClient.LLM_Provider` | `OpenAI` | LLM provider name |
| `LLMClient.API_Key` | *(encrypted — set your key)* | LLM provider API key |
| `LLMClient.LLM_Model` | `gpt-4o` | LLM model name |
| `LLMClient.SystemPrompt` | *(IT help desk advisor instructions)* | System prompt for the LLM |
| `LLMClient.MCP.KB.Server_Name` | `KnowledgeBase` | Display name for the Knowledge Base MCP Server |
| `LLMClient.MCP.KB.Server_URL` | `http://localhost:9201/mcp` | Knowledge Base MCP Server endpoint |
| `LLMClient.A2A.Ticket.Server_Name` | `TicketService` | Display name for the Ticket Service A2A Server |
| `LLMClient.A2A.Ticket.Server_URL` | `http://localhost:9202` | Ticket Service A2A Server endpoint |
| `WebSocket_Port` | `9200` | WebSocket server listening port |

### KnowledgeBaseMCPServer

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9201` | MCP Server listening port |

### TicketServiceA2A

| Property | Default | Description |
|---|---|---|
| `AgenticAI.openai.LLM_Provider` | `OpenAI` | LLM provider for the A2A agent |
| `AgenticAI.openai.API_Key` | *(encrypted — set your key)* | OpenAI API key for the A2A agent's LLM |
| `AgenticAI.openai.LLM_Base_URL` | *(empty)* | Custom LLM base URL (leave empty for the default provider endpoint) |
| `Trigger_Settings.AgentName` | `TicketServiceAgent` | A2A agent name |
| `Trigger_Settings.AgentDescription` | `IT support ticket management agent. Creates and tracks support tickets via A2A protocol.` | A2A agent description |
| `Trigger_Settings.LLM_Model` | `gpt-4o` | LLM model name |
| `Trigger_Settings.Token_Limit` | `4096` | Max tokens per response |
| `Trigger_Settings.Rate_Limit` | `25` | Request rate limit |
| `Trigger_Settings.LLM_temperature` | `0.3` | LLM sampling temperature |
| `A2A.AgentUrl` | `http://localhost:9202` | Advertised agent URL |
| `A2A.port` | `9202` | A2A Server listening port |
| `A2A.AuthMode` | `None` | Authentication mode (`None`, `Static Token`) |

---

## What to Customize

| Customization | Where | How |
|---|---|---|
| Connect to a real KB system | `SearchKBArticlesFlow` in `KnowledgeBaseMCPServer` | Replace `actreturn` with a REST call to your knowledge base API (Confluence, ServiceNow KB, etc.) |
| Real ticket creation | `create_ticket_flow` in `TicketServiceA2A` | Replace `actreturn` with a call to your ITSM system (ServiceNow, Jira Service Management, Zendesk) |
| Add auth to MCP/A2A connections | `mcpServerConfigs` / `a2aServerConfigs` mappings | Change `authType` to `"Token"` and set `authToken` to a property reference |
| Use Anthropic Claude | App properties | Change `LLMClient.LLM_Provider` to `Anthropic` and `LLMClient.LLM_Model` to `claude-sonnet-4-5` |
| Use a local model | App properties | Change `LLMClient.LLM_Provider` to `Ollama` and set the provider base URL to your Ollama endpoint |
| Increase conversation memory | LLM Client Activity settings | Raise `memoryMaxSize` from 20 to a higher value (trades memory for context length) |
| Add more MCP servers | `mcpServerConfigs` input mapping | Add another entry to the mapping array — e.g., a second MCP server for asset management |
| Persist conversations to a database | LLM Client Activity | Switch to the AI Agent Trigger with a Custom Conversation Store handler for durable persistence |
