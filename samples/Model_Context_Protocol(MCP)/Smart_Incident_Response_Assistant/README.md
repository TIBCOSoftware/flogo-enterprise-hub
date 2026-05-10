# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® Model Context Protocol(MCP) Showcase Sample — Smart Incident Response Assistant

## Overview

This sample demonstrates three advanced MCP features of the **TIBCO Flogo® Connector for Model Context Protocol (MCP)** working together in a single, realistic workflow: **MCP Elicitation**, **MCP Logging**, and **MCP Sampling**.

The app exposes a single MCP tool — `incident_response` — that guides an engineer through a structured incident triage. The tool interactively collects incident details via a form, emits structured log messages at each stage for full audit visibility, delegates root-cause analysis to the LLM using MCP Sampling, and returns a complete triage report with AI-generated remediation steps.

## ✨ Key Features

- 📋 **MCP Elicitation — Interactive incident intake form**  
  Collects structured incident details from the engineer at runtime via a native MCP client form

- 📡 **MCP Logging — Real-time audit trail**  
  Emits structured `info` and `warning` log messages to the MCP client at each stage of the triage workflow

- 🧠 **MCP Sampling — AI-powered root-cause analysis**  
  Delegates diagnosis to the LLM mid-flow — the server sends a prompt, the client's LLM reasons about the incident, and the result is incorporated into the final report

- 🤖 **Works with any MCP-capable client**  
  Compatible with GitHub Copilot in VS Code and other MCP clients that support Elicitation, Logging, and Sampling

- 🧩 **Three MCP features in one flow**  
  A complete end-to-end example showcasing the breadth of the Flogo MCP connector

## 🚀 Getting Started

### Prerequisites

- TIBCO Flogo® Extension for Visual Studio Code **2.26.1** or later
- Flogo MCP connector **1.0.1** or later
- An MCP client that supports MCP Elicitation, Logging, and Sampling (e.g. GitHub Copilot in VS Code)
- **VS Code 1.112.0 or later** 

## Import the sample app in the Workspace

Import `Smart_Incident_Response_Assistant_MCPServer.flogo` into VS Code.

## Understanding the configuration

The `Smart_Incident_Response_Assistant_MCPServer.flogo` app is a Flogo MCP server (HTTP) that exposes the `incident_response` tool to AI agents. When the tool is called, the flow runs the following sequence:

### Flow

```
MCP Client calls incident_response
        │
        ▼
  [StartActivity]          ── NoOp, flow entry point
        │
        ▼
  [ElicitIncidentDetails]  ── MCP Elicitation: renders incident intake form to engineer
        │
        ▼
  [LogIntakeComplete]      ── MCP Logging (info): logs intake summary to MCP client
        │
        ▼
  [SampleRootCause]        ── MCP Sampling: asks LLM to analyse root causes
        │
        ▼
  [LogAnalysisComplete]    ── MCP Logging (info): logs LLM analysis result to MCP client
        │
        ▼
  [Return]                 ── Returns full incident triage report
```

### Elicitation Schema

The `incident_response` tool collects the following fields from the engineer:

| Field | Type | Required | Notes |
|---|---|---|---|
| `reported_by` | string (email) | Yes | Reporter's email address |
| `affected_system` | enum | Yes | Payment API, Auth Service, Order Service, Inventory Service, Notification Service, Other |
| `environment` | enum | Yes | Production, Staging, DR |
| `severity` | enum | Yes | P1 - Critical, P2 - High, P3 - Medium, P4 - Low |
| `error_message` | string | Yes | Error message or observed symptom |
| `started_at` | string | No | Approximate incident start time |
| `already_tried` | string | No | Steps already attempted before raising the incident |

### MCP Logging Messages

| Activity | Level | Example Message |
|---|---|---|
| `LogIntakeComplete` | `info` | `Incident intake complete. Reporter: jane@example.com \| System: Payment API \| Severity: P1 - Critical \| Environment: Production` |
| `LogAnalysisComplete` | `info` | `LLM root-cause analysis complete for Payment API. Analysis: 1. DB connection pool exhaustion...` |

### MCP Sampling Prompt

The `SampleRootCause` activity sends the following system prompt to the LLM:

```
You are an expert SRE (Site Reliability Engineer). Given the following production incident details, provide:
1. Top 3 most likely root causes (ranked by probability)
2. Immediate remediation steps for each cause
3. A recommended escalation action if not resolved within 15 minutes
Keep the response concise and actionable. Plain text only, no markdown.
```

The user message is built from the elicited incident fields (system, environment, severity, error message, start time, already tried).

### App Properties

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9092` | HTTP port the MCP server listens on |

## Run the application

- Run `Smart_Incident_Response_Assistant_MCPServer.flogo` from VS Code. This will start the Flogo MCP Server over HTTP at `http://localhost:9092/mcp`.
- Configure this MCP server URL with your MCP client (GitHub Copilot in VS Code).
- Ask the agent to start an incident triage. Try one of the prompts below:

  > _"Our payment system is down, please help me triage this incident"_

  > _"Users are reporting login failures, can you run an incident response for me?"_

  > _"Help me file an incident, our inventory data seems out of sync"_

- The MCP client will render an elicitation form. Fill in the incident details and submit.
- You will see log messages appear in the MCP client as the flow progresses.
- You will receive a full triage report like:

  ```
  === INCIDENT TRIAGE REPORT ===
  Reporter:    jane@example.com
  System:      Payment API
  Severity:    P1 - Critical
  Environment: Production
  Error:       Connection timeout after 30s — upstream DB not responding

  --- AI Root-Cause Analysis ---
  1. Primary DB instance outage or severe saturation...
  2. Network path failure between Payment API pods and DB...
  3. Application-side DB connection pool exhaustion...

  --- Next Step ---
  Please acknowledge this incident and follow the remediation steps above.
  ```

> **Note:** To configure this MCP server in **VS Code**, add the following to your `mcp.json`:

```json
{
  "servers": {
    "Smart_Incident_Response_Assistant": {
      "type": "http",
      "url": "http://localhost:9092/mcp"
    }
  }
}
```

> **Note:** When the flow reaches the `SampleRootCause` activity, VS Code will prompt you to **allow the LLM sampling request**. This is expected — MCP Sampling requires explicit client approval before the server can invoke an LLM completion on behalf of the flow.

## 💡 Extending This Sample

Some ideas to build on this sample:

- **POST to an incident management API** — Add a REST Invoke activity to automatically create an incident in PagerDuty, OpsGenie, or ServiceNow using the elicited details
- **Severity-based routing** — Add conditional branches after `LogAnalysisComplete` to send a `warning` log and trigger a different return message for P1/P2 vs P3/P4 incidents
- **Multi-tool showcase** — Add a second tool (e.g. `submit_ticket` from the MCPElicitation sample) to the same MCP server to demonstrate multiple tools in one Flogo app
- **Escalation notification** — Add an email or messaging activity (e.g. TIBCO EMS, Slack webhook) to notify the on-call team automatically for P1 incidents

## Related Resources

- [MCP Specification — Elicitation](https://spec.modelcontextprotocol.io/specification/client/elicitation/)
- [MCP Specification — Logging](https://spec.modelcontextprotocol.io/specification/server/utilities/logging/)
- [MCP Specification — Sampling](https://spec.modelcontextprotocol.io/specification/client/sampling/)
- [TIBCO Flogo® MCP Connector Documentation](https://docs.tibco.com)
- [Model Context Protocol](https://modelcontextprotocol.io)
