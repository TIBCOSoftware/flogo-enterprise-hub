# Dynamic Semantic Tool Selection at Scale — Two-Step Agent with 150 MCP Tools

## Overview

This sample demonstrates **dynamic semantic tool selection at scale** using the **TIBCO Flogo® 3 Agentic AI Connector**. An IT Service Desk orchestrator handles natural-language requests across **150 tools** spread over three MCP Servers — without sending all 150 tool definitions to the executing agent.

The architecture uses a **two-step pattern**:

1. **Step 1 — Tool Selection** (`LLMClient Activity`): Has a text catalog of all 150 tool names embedded in its system prompt. Analyzes the request and returns a JSON object with a `tools` array of relevant tool names (typically 1–5). No MCP connections — pure text-based selection that bypasses API tool-count limits.
2. **Step 2 — Execution** (`AI Agent Activity`): Receives the filtered tool names via `filteredToolNames` and connects to all 3 MCP Servers, but only loads and executes the selected tools.

This keeps the execution agent's context focused and cost-efficient, even as the total tool catalog grows.

| Pattern | Component | What It Shows |
|---|---|---|
| **Two-step tool selection** | `ITServiceDeskOrchestrator` | LLMClient selects tools → Agent executes with filtered subset |
| **LLM Client + text catalog** | `ITServiceDeskOrchestrator` | LLMClient with 150 tool names in system prompt — no MCP connections, no API tool limit |
| **AI Agent + filteredToolNames** | `ITServiceDeskOrchestrator` | Agent Activity receives pre-selected tool names, only loads those tools |
| **MCP Server at scale** | 3 MCP Server apps | 50 tools each with argument schemas and mock data |

---

## Real-World Scenario

**Persona**: Alex, an IT support manager, sends a natural-language request to the service desk.

```
Alex submits:
  Employee ID: EMP-1042
  Request: "My VPN password expired and I'm locked out of Jira. Can you reset
            the password and unlock my account? Also create a ticket to track this."

Step 1 — Tool Selection (LLMClient):
  [Reads 150 tool names from text catalog in system prompt]
  → {"tools": ["reset_password", "unlock_account", "create_ticket"]}

Step 2 — Execution (AI Agent with 3 filtered tools):
  [Calls reset_password → IdentityAccessMCPServer]
  [Calls unlock_account → IdentityAccessMCPServer]
  [Calls create_ticket → TicketingMCPServer]

  "Done! Here's what I did:
   1. Password Reset: VPN password for EMP-1042 has been reset.
      Temporary password sent to your registered email.
   2. Account Unlocked: Jira account for EMP-1042 is now unlocked.
   3. Ticket Created: TKT-2026-4521 — 'VPN password reset and Jira unlock
      for EMP-1042', priority Medium, assigned to IT Support Tier 1.

   You'll need to change the temporary VPN password at next login.
   Would you also like me to check your MFA status or review your
   recent login history?"
```

**One REST call. 150 tools available. Only 3 selected and executed.**

---

## Architecture

```
 User (REST Client — Postman, curl, etc.)
      |  POST http://localhost:9195/service-request
      |  Body: { "request": "...", "employee_id": "EMP-1042" }
      v
 +------------------------------------------------------------------------+
 |  ITServiceDeskOrchestrator (port 9195)                                 |
 |                                                                         |
 |  REST Trigger --> service_request_flow                                  |
 |                                                                         |
 |  +--------------------------------------------------------------+      |
 |  | Step 1: ProcessRequest (LLM Client Activity)                  |      |
 |  |   systemPrompt: text catalog of all 150 tool names           |      |
 |  |   userPrompt: employee_id + request text                     |      |
 |  |   No MCP connections — pure text-based selection             |      |
 |  |   LLM: OpenAI gpt-4o, temp 0.3                              |      |
 |  |   Output: {"tools": ["reset_password", "unlock_account",...]} |      |
 |  +-----------------------------+--------------------------------+      |
 |                                |                                        |
 |              $activity[ProcessRequest].response.tools                  |
 |              (JSON object with tools array of tool name strings)       |
 |                                |                                        |
 |  +-----------------------------v--------------------------------+      |
 |  | Step 2: ProcessAIAgent (AI Agent Activity)                    |      |
 |  |   userPrompt: employee_id + request text                     |      |
 |  |   filteredToolNames: ← tool names from Step 1               |      |
 |  |   mcpServers: [IAM, Infra, Ticketing] — same 3 connections  |------+---> Only selected tools
 |  |   LLM: OpenAI gpt-4o, temp 0.7 (via LLM Provider Conn)     |      |     are loaded & called
 |  |   conversationStore: None                                    |      |
 |  +-----------------------------+--------------------------------+      |
 |                                |                                        |
 |  +-----------------------------v--------------------------------+      |
 |  | ReturnResult (actreturn)                                      |      |
 |  |   code: 200, data.result: ProcessAIAgent response             |      |
 |  +--------------------------------------------------------------+      |
 +------------------------------------------------------------------------+

 MCP Servers (start all 3 before the orchestrator):

 +----------------------------------+  +----------------------------------+  +----------------------------------+
 | IdentityAccessMCPServer          |  | InfraMonitoringMCPServer         |  | TicketingMCPServer               |
 | Port 9610 — 50 tools             |  | Port 9611 — 50 tools             |  | Port 9612 — 50 tools             |
 |                                  |  |                                  |  |                                  |
 | User Lifecycle (8)               |  | Server Metrics (8)               |  | Ticket CRUD (7)                  |
 | Password Management (6)          |  | Service Health (8)               |  | Assignment (5)                   |
 | Account Status (6)               |  | Alerts (8)                       |  | Status & Priority (6)            |
 | Roles & Permissions (8)          |  | Network (8)                      |  | Search & Listing (8)             |
 | Group Management (5)             |  | Database (6)                     |  | Comments & Communication (4)     |
 | MFA/Security (6)                 |  | Container & Cloud (8)            |  | Attachments (3)                  |
 | API Keys & Service Accounts (4)  |  | Monitoring & Reporting (4)       |  | SLA (4)                          |
 | Session Management (4)           |  |                                  |  | Categories & Templates (4)       |
 | Compliance & Audit (3)           |  |                                  |  | Workflow & Approvals (4)         |
 +----------------------------------+  +----------------------------------+  | Reporting (5)                    |
                                                                             +----------------------------------+
```

---

## Projects in This Sample

Each project is a Flogo 3 project folder (a folder containing `app.fgmd`).

| Project Folder | Description |
|---|---|
| `ITServiceDeskOrchestrator` | **Orchestrator (two-step)** — REST API on port 9195. LLMClient selects tool names from a text catalog of 150 tools, then AI Agent executes with only the filtered tools via `filteredToolNames`. |
| `ITServiceDeskDirect` | **Direct agent (no filtering)** — REST API on port 9197. AI Agent connects to all 3 MCP servers with no tool filtering. Included for comparison — demonstrates the 128-tool API limit that the two-step pattern solves. |
| `IdentityAccessMCPServer` | **MCP Server** — Port 9610. 50 identity & access management tools: user lifecycle, passwords, account status, roles, groups, MFA, API keys, sessions, compliance. |
| `InfraMonitoringMCPServer` | **MCP Server** — Port 9611. 50 infrastructure monitoring tools: server metrics, service health, alerts, network, databases, containers, cloud resources, capacity forecasting. |
| `TicketingMCPServer` | **MCP Server** — Port 9612. 50 IT ticketing tools: ticket CRUD, assignment, status management, search, comments, attachments, SLA tracking, templates, approvals, reporting. |

---

## Two-Step Tool Selection — How It Works

### The Problem

Sending 150 tool definitions to an LLM in every request is expensive, degrades response quality, and hits API limits (e.g., OpenAI caps at 128 tools per request). Most requests only need 1–5 tools.

### The Solution

**Step 1 — LLMClient (tool selector):** Has no MCP connections. Instead, the `LLMClient.systemPrompt` contains a plain-text catalog of all 150 tool names with one-line descriptions. The LLM reads the catalog as text and returns the relevant tool names — no tool schemas are sent in the API call, so there is no tool-count limit.

```json
{
  "ref": "#llmclientactivity",
  "settings": {
    "responseType": "JSON"
  },
  "input": {
    "systemPrompt": "You are a tool selection assistant. Below is the catalog of 150 tools...\n## Identity & Access Management\n- reset_password: Reset a user's password...\n- unlock_account: Unlock a locked user account...\n...",
    "llmConfiguration": { "mapping": { "provider": "OpenAI", "model": "gpt-4o", "temparature": 0.3 } }
  },
  "schemas": {
    "output": {
      "responseJSONSchema": {
        "type": "json",
        "value": "{\"type\":\"object\",\"properties\":{\"tools\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"tools\"],\"additionalProperties\":false}"
      }
    }
  }
}
```

The `responseType: "JSON"` with `responseJSONSchema` (under `schemas.output`) ensures the LLM returns a validated JSON object containing a `tools` array.

Output: `{"tools": ["reset_password", "unlock_account", "create_ticket"]}`

**Step 2 — AI Agent (executor):** Receives the tool names via the `filteredToolNames` input. The Agent Activity only loads and exposes those specific tools to the LLM, keeping the context small and focused.

```json
{
  "ref": "#agentactivity",
  "settings": {
    "llmProviderConnection": "conn://OpenAI",
    "mcpServers": ["conn://IAM", "conn://Infra", "conn://Ticketing"]
  },
  "input": {
    "userPrompt": "=string.concat(\"Employee ID: \", ..., \"\\nRequest: \", ...)",
    "conversationId": "=$flow.body.employee_id",
    "filteredToolNames": "=$activity[ProcessRequest].response.tools"
  }
}
```

### Why Two Steps?

| Aspect | Single-Step (150 tools) | Two-Step (select → execute) |
|---|---|---|
| API tool limits | Hits OpenAI's 128-tool cap | Step 1 uses text catalog (no limit), Step 2 sends only 1–5 tools |
| Token cost per request | High — all 150 tool schemas sent | Low — only 1–5 tool schemas sent to executor |
| Response quality | Degrades with too many tools | Focused context, better tool selection |
| Latency | Higher (large prompt) | Lower for Step 2 (small prompt) |
| Scalability | Limited by context window and API limits | Scales to hundreds or thousands of tools |

### Try It Yourself — Direct vs. Two-Step

This sample includes `ITServiceDeskDirect` (port 9197) — the same AI Agent with the same 3 MCP server connections, but **without** the LLMClient tool selection step and **without** `filteredToolNames`. It sends all 150 tools directly to the LLM.

**To compare:**

1. Start all 3 MCP servers
2. Start `ITServiceDeskOrchestrator` (port 9195) — two-step with filtering
3. Start `ITServiceDeskDirect` (port 9197) — direct, no filtering
4. Send the same request to both:

```bash
# Two-step (works — selects 3 tools, executes in 4.5s, ~1,900 tokens)
curl -X POST http://localhost:9195/service-request \
  -H "Content-Type: application/json" \
  -d '{"request": "Unlock my account and create a ticket", "employee_id": "EMP-1042"}'

# Direct (fails — OpenAI rejects 150 tools)
curl -X POST http://localhost:9197/service-request \
  -H "Content-Type: application/json" \
  -d '{"request": "Unlock my account and create a ticket", "employee_id": "EMP-1042"}'
```

**Expected result:** The direct approach fails with `400 Bad Request: "Invalid 'tools': array too long. Expected maximum length 128, got 150"`. The two-step approach succeeds because Step 1 uses a text catalog (no tool limit) and Step 2 only sends the 3 filtered tools to the API.

This demonstrates that `filteredToolNames` is not just an optimization — it is **required** when the total tool count exceeds the LLM provider's per-request limit.

---

## Tool Reference

### IdentityAccessMCPServer (port 9610 — 50 tools)

| Category | Tools |
|---|---|
| User Lifecycle (8) | `create_user`, `delete_user`, `suspend_user`, `reactivate_user`, `get_user_profile`, `update_user_profile`, `search_users`, `list_all_users` |
| Password Management (6) | `reset_password`, `set_temporary_password`, `force_password_change`, `check_password_expiry`, `get_password_policy`, `update_password_policy` |
| Account Status (6) | `check_account_status`, `lock_account`, `unlock_account`, `disable_account`, `enable_account`, `get_login_history` |
| Roles & Permissions (8) | `list_user_permissions`, `grant_permission`, `revoke_permission`, `list_roles`, `assign_role`, `remove_role`, `create_role`, `list_role_members` |
| Group Management (5) | `create_group`, `add_user_to_group`, `remove_user_from_group`, `list_groups`, `list_group_members` |
| MFA/Security (6) | `enable_mfa`, `disable_mfa`, `reset_mfa`, `get_mfa_status`, `list_mfa_methods`, `verify_mfa_setup` |
| API Keys & Service Accounts (4) | `create_api_key`, `revoke_api_key`, `list_api_keys`, `create_service_account` |
| Session Management (4) | `list_active_sessions`, `terminate_session`, `terminate_all_sessions`, `get_session_details` |
| Compliance & Audit (3) | `run_access_review`, `get_compliance_report`, `audit_permission_changes` |

### InfraMonitoringMCPServer (port 9611 — 50 tools)

| Category | Tools |
|---|---|
| Server Metrics (8) | `get_server_metrics`, `get_server_info`, `list_servers`, `get_cpu_usage`, `get_memory_usage`, `get_disk_usage`, `get_server_uptime`, `get_process_list` |
| Service Health (8) | `check_service_health`, `list_services`, `start_service`, `stop_service`, `restart_service`, `get_service_logs`, `get_service_config`, `get_service_dependencies` |
| Alerts (8) | `list_active_alerts`, `acknowledge_alert`, `resolve_alert`, `create_alert_rule`, `delete_alert_rule`, `list_alert_rules`, `get_alert_history`, `escalate_alert` |
| Network (8) | `get_network_status`, `get_network_latency`, `run_traceroute`, `check_dns_resolution`, `get_firewall_rules`, `get_load_balancer_status`, `get_ssl_certificate_status`, `check_port_availability` |
| Database (6) | `get_database_metrics`, `check_database_health`, `get_slow_queries`, `get_connection_pool_status`, `get_replication_status`, `get_database_size` |
| Container & Cloud (8) | `list_containers`, `get_container_metrics`, `get_container_logs`, `list_kubernetes_pods`, `get_pod_status`, `scale_deployment`, `get_cloud_costs`, `get_cloud_resource_usage` |
| Monitoring & Reporting (4) | `get_metric_history`, `get_sla_report`, `get_incident_timeline`, `get_capacity_forecast` |

### TicketingMCPServer (port 9612 — 50 tools)

| Category | Tools |
|---|---|
| Ticket CRUD (7) | `get_ticket_status`, `create_ticket`, `update_ticket`, `clone_ticket`, `merge_tickets`, `split_ticket`, `get_ticket_history` |
| Assignment (5) | `assign_ticket`, `reassign_ticket`, `unassign_ticket`, `auto_assign_ticket`, `get_ticket_assignee` |
| Status & Priority (6) | `update_ticket_priority`, `update_ticket_status`, `close_ticket`, `reopen_ticket`, `escalate_ticket`, `mark_as_resolved` |
| Search & Listing (8) | `list_my_tickets`, `search_tickets`, `list_all_tickets`, `list_tickets_by_status`, `list_tickets_by_priority`, `list_tickets_by_category`, `list_overdue_tickets`, `list_escalated_tickets` |
| Comments & Communication (4) | `add_comment`, `list_comments`, `add_internal_note`, `send_notification` |
| Attachments (3) | `add_attachment`, `list_attachments`, `download_attachment` |
| SLA (4) | `get_sla_status`, `check_sla_breach`, `get_sla_metrics`, `update_sla_policy` |
| Categories & Templates (4) | `list_categories`, `create_category`, `list_templates`, `create_from_template` |
| Workflow & Approvals (4) | `get_approval_status`, `approve_ticket`, `reject_ticket`, `add_watcher` |
| Reporting (5) | `get_ticket_metrics`, `get_resolution_time_report`, `get_agent_workload`, `get_satisfaction_scores`, `get_trending_issues` |

---

## Prerequisites

- **TIBCO Flogo® 3.0.0 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or swap for Anthropic, Gemini, Ollama, or vLLM in the app properties)
- A REST client for testing: [Postman](https://www.postman.com/) or curl

---

## Setup & Run

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `IdentityAccessMCPServer`, `InfraMonitoringMCPServer`, `TicketingMCPServer`, `ITServiceDeskOrchestrator`, `ITServiceDeskDirect`.
2. Open each app's `.fgprops` file and set the App Properties for your environment (see [App Properties](#app-properties) below) — LLM provider/API key, MCP server URLs, ports.
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select an app module → right-click → **Run As Executable**. The native binary is produced in that app's `bin/` folder and logs stream to the integrated terminal. Start the MCP servers first, then the orchestrator/direct apps.
5. Invoke and verify as described in [Invoke & Verify](#invoke--verify) below (curl/Postman, ports, payloads, and the semantic-tool-selection comparison between the Orchestrator and Direct apps).

### Start order

Start the three MCP server apps first, then the orchestrator/direct apps:

1. `IdentityAccessMCPServer` (port 9610)
2. `InfraMonitoringMCPServer` (port 9611)
3. `TicketingMCPServer` (port 9612)
4. `ITServiceDeskOrchestrator` (port 9195)
5. `ITServiceDeskDirect` (port 9197, optional — for the direct-vs-two-step comparison)

The MCP Servers need no API keys or special configuration — they use mock data and no authentication.

| App | Port | Endpoint |
|---|---|---|
| `IdentityAccessMCPServer` | 9610 | `/mcp` |
| `InfraMonitoringMCPServer` | 9611 | `/mcp` |
| `TicketingMCPServer` | 9612 | `/mcp` |
| `ITServiceDeskOrchestrator` | 9195 | `POST /service-request` |
| `ITServiceDeskDirect` | 9197 | `POST /service-request` |

---

## App Properties

Set these in each project's `.fgprops` file before running. Property names below are exact.

### ITServiceDeskOrchestrator

The `LLMClient.*` properties configure **Step 1** (tool selector); the `AgenticAI.*` properties configure **Step 2** (agent executor).

| Property | Default | What to set |
|---|---|---|
| `LLMClient.openai.LLM_Provider` | `OpenAI` | LLM provider for the Step 1 tool selector |
| `LLMClient.openai.LLM_Model` | `gpt-4o` | Model for the Step 1 tool selector |
| `LLMClient.openai.LLM_APIKey` | *(secret)* | Your API key for Step 1 |
| `LLMClient.systemPrompt` | *(text catalog of all 150 tool names + selection rules)* | Tune only if you want to change how tools are selected |
| `AgenticAI.OpenAI.LLM_Provider` | `OpenAI` | LLM provider for the Step 2 agent executor |
| `AgenticAI.OpenAI.LLM_Model` | `gpt-4o` | Model for the Step 2 agent executor |
| `AgenticAI.OpenAI.API_Key` | *(secret)* | Your API key for Step 2 |
| `AgenticAI.OpenAI.LLM_Base_URL` | *(empty)* | Leave empty for the OpenAI default; set for Ollama/vLLM/custom endpoints |
| `AgenticAI.systemPrompt` | *(IT Service Desk assistant prompt)* | Agent behavior rules for Step 2 |

Quick reference for the keys you will typically edit:

```
LLMClient.openai.LLM_Provider  = OpenAI
LLMClient.openai.LLM_Model     = gpt-4o
LLMClient.openai.LLM_APIKey    = sk-your-key-here

AgenticAI.OpenAI.LLM_Provider  = OpenAI
AgenticAI.OpenAI.LLM_Model     = gpt-4o
AgenticAI.OpenAI.API_Key       = sk-your-key-here
AgenticAI.OpenAI.LLM_Base_URL  = (leave empty for OpenAI default)
```

### ITServiceDeskDirect

| Property | Default | What to set |
|---|---|---|
| `AgenticAI.OpenAI.LLM_Provider` | `OpenAI` | LLM provider for the agent |
| `AgenticAI.OpenAI.LLM_Model` | `gpt-4o` | Model for the agent |
| `AgenticAI.OpenAI.API_Key` | *(secret)* | Your API key |
| `AgenticAI.OpenAI.LLM_Base_URL` | *(empty)* | Leave empty for the OpenAI default; set for Ollama/vLLM/custom endpoints |
| `AgenticAI.systemPrompt` | *(IT Service Desk assistant prompt)* | Agent behavior rules |

### IdentityAccessMCPServer / InfraMonitoringMCPServer / TicketingMCPServer

| Property | Default (per app) | What to set |
|---|---|---|
| `FlogoMcpServer.PORT` | `9610` (IdentityAccess), `9611` (InfraMonitoring), `9612` (Ticketing) | Port the MCP server listens on; change only if the default conflicts |

---

## Invoke & Verify

### Send a Request

**curl**:
```bash
curl -X POST http://localhost:9195/service-request \
  -H "Content-Type: application/json" \
  -d '{
    "request": "Reset my VPN password and create a ticket to track it",
    "employee_id": "EMP-1042"
  }'
```

**Postman**: Create a POST request to `http://localhost:9195/service-request` with the JSON body above.

### Compare Direct vs. Two-Step

Send the same request to both apps and observe the difference (see [Try It Yourself](#try-it-yourself--direct-vs-two-step) above). The two-step Orchestrator on port 9195 selects and executes only the needed tools; the Direct app on port 9197 sends all 150 tools and fails against OpenAI's 128-tool cap.

---

## Sample Queries

### Single-Domain Request (Identity)

```json
{
  "request": "What's my current MFA status and list my active sessions?",
  "employee_id": "EMP-1042"
}
```

### Cross-Domain Request (Identity + Ticketing)

```json
{
  "request": "Reset my VPN password, unlock my Jira account, and create a high-priority ticket to track this",
  "employee_id": "EMP-1042"
}
```

### Infrastructure Query

```json
{
  "request": "Check the health of the payment-service and show me any active critical alerts",
  "employee_id": "EMP-1042"
}
```

### Three-Domain Request (Identity + Infra + Ticketing)

```json
{
  "request": "My account is locked, the VPN server seems down, and I need a ticket for all of this. Can you check the server status, unlock my account, and create a ticket?",
  "employee_id": "EMP-1042"
}
```

---

## What to Customize

| Customization | Where | How |
|---|---|---|
| Connect to real identity systems | Tool flows in `IdentityAccessMCPServer` | Replace `actreturn` with calls to Active Directory, Okta, or your IAM API |
| Real infrastructure monitoring | Tool flows in `InfraMonitoringMCPServer` | Replace `actreturn` with calls to Datadog, Prometheus, Grafana, or CloudWatch APIs |
| Live ticketing system | Tool flows in `TicketingMCPServer` | Replace `actreturn` with calls to ServiceNow, Jira Service Management, or Zendesk APIs |
| Use Anthropic Claude | App properties | Change `LLM_Provider` to `Anthropic` and `LLM_Model` to `claude-sonnet-4-5` |
| Use a local model | App properties | Change `LLM_Provider` to `Ollama` and set `LLM_Base_URL` to your Ollama endpoint |
| Add more MCP servers | Orchestrator connections | Add a fourth `mcpserverconfig` connection and append it to the `mcpServers` arrays |
| Add authentication to MCP servers | MCP Server trigger settings | Change `authType` from `None` to `JWT Token` and configure the secret |
| Tune tool selection | `LLMClient.systemPrompt` property | Adjust the system prompt to change how aggressively tools are selected |
| Add guardrails | ProcessAIAgent settings | Set `enableGuardrails: true` and add PII redaction or custom guardrail handlers |

---

## Extending to Production

1. **Replace mock data** in each MCP Server's tool flows with live API calls to your enterprise systems
2. **Add authentication** to the MCP Servers — change `authType` to `JWT Token` and configure secrets
3. **Tune the tool selector prompt** — adjust `LLMClient.systemPrompt` based on observed selection accuracy
4. **Add more tool domains** — create additional MCP Servers (e.g., HR, Finance, Facilities) and add them to the orchestrator's connection list
5. **Use a cheaper model for Step 1** — tool selection is a simpler task; consider using `gpt-4o-mini` for the LLMClient step while keeping `gpt-4o` for the Agent step
6. **Add conversation memory** — change `conversationStoreType` to `Memory` on the Agent Activity and use `employee_id` as the `conversationId` to enable multi-turn follow-ups per employee

See the [Insurance Claims Processor](../InsuranceClaimsProcessor/) sample for the LLM Client Activity chaining pattern, and the [Mobile Customer Care Multi-Agent](../Mobile-Customer-Care-Multi-Agent/) sample for multi-agent handoff architecture.
