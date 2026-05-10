# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® MCP Tool Annotations — Banking Operations Sample

## Overview

This sample demonstrates how to configure all four **MCP Tool Annotation hints** in a **TIBCO Flogo® MCP Server** trigger using a realistic **banking operations** scenario.

MCP Tool Annotations are optional hints attached to each MCP tool that tell the AI client (and the LLM) about the **safety, reversibility, and scope** of a tool's operations. AI clients use these hints to decide whether to prompt the user for confirmation before invoking a tool, and to make smarter choices when planning multi-step agentic workflows.

> **Important:** Tool annotations are *hints* — they are not enforced by the MCP protocol. Clients **MUST** treat annotations from untrusted servers as advisory only.

---

## The Four MCP Tool Annotation Hints

| Hint | Flogo Field | Default | Meaning |
|---|---|---|---|
| `readOnlyHint` | `readOnlyToolHint` | `false` | If `true`, the tool **never modifies** its environment. Safe to call without side effects. |
| `destructiveHint` | `destructiveToolHint` | `true` | If `true`, the tool **may permanently destroy or overwrite** data. Only meaningful when `readOnlyHint = false`. |
| `idempotentHint` | `idempotentToolHint` | `false` | If `true`, calling the tool **repeatedly with the same arguments** produces the same result — no extra side effects accumulate. Only meaningful when `readOnlyHint = false`. |
| `openWorldHint` | `openWorldToolHint` | `true` | If `true`, the tool **interacts with an open world** of external entities (e.g. third-party APIs, internet). If `false`, the domain is closed (e.g. the tool only touches internal databases). |

These hints map directly to the [MCP specification — ToolAnnotations](https://spec.modelcontextprotocol.io/specification/2025-03-26/server/tools/#tool-annotations).

---

## Annotation Combinations — Decision Guide

```
Is the tool read-only?
  YES → readOnlyToolHint = true
       Does it call external APIs / internet resources?
         YES → openWorldToolHint = true   (e.g. get_forex_rate)
         NO  → openWorldToolHint = false  (e.g. get_account_balance)

  NO  → readOnlyToolHint = false
       Can the operation be undone? Is data permanently lost?
         YES (permanent loss) → destructiveToolHint = true
         NO                  → destructiveToolHint = false

       Does calling it twice with the same args have extra effects?
         YES (two different results) → idempotentToolHint = false
         NO  (same result each time) → idempotentToolHint = true

       Does it reach external systems outside your closed domain?
         YES → openWorldToolHint = true
         NO  → openWorldToolHint = false
```

---

## Sample — Banking Operations MCP Server

The `BankingOperationsMCPServer.flogo` app exposes **six banking tools**, each representing a different annotation combination:

### Tool Annotation Matrix

| MCP Tool | `readOnly` | `destructive` | `idempotent` | `openWorld` | Why |
|---|:---:|:---:|:---:|:---:|---|
| `get_account_balance` | ✅ `true` | ❌ `false` | — | ❌ `false` | Pure read from internal ledger |
| `get_forex_rate` | ✅ `true` | ❌ `false` | — | ✅ `true` | Reads live rate from external forex API |
| `set_daily_spending_limit` | ❌ `false` | ❌ `false` | ✅ `true` | ❌ `false` | Setting same limit twice = same state |
| `transfer_funds` | ❌ `false` | ❌ `false` | ❌ `false` | ❌ `false` | Each call creates a new unique transaction |
| `close_account` | ❌ `false` | ✅ `true` | ✅ `true` | ❌ `false` | Permanent destruction; closing a closed account = same result |
| `send_fraud_alert` | ❌ `false` | ❌ `false` | ❌ `false` | ✅ `true` | Each call sends a new external notification |

> **Note on `idempotentHint` for read-only tools:** The MCP specification states that `idempotentHint` is only meaningful when `readOnlyHint = false`. For read-only tools, the field has no semantic impact.

---

### Tool Details

#### 1. `get_account_balance` — Read-Only, Closed Domain
```
readOnlyToolHint   = true    ← never modifies any data
destructiveToolHint = false
idempotentToolHint  = false
openWorldToolHint  = false   ← only queries internal bank ledger
```
Retrieves the current balance and account status from the bank's internal ledger. An AI agent can call this tool freely and repeatedly without any risk — it will never change the state of any account.

---

#### 2. `get_forex_rate` — Read-Only, Open World
```
readOnlyToolHint   = true    ← never modifies any data
destructiveToolHint = false
idempotentToolHint  = false
openWorldToolHint  = true    ← calls external forex market data API
```
Fetches the live mid-market foreign exchange rate for a currency pair from an external market data provider. Although it is read-only, it is **open-world** because it reaches outside the bank's systems to query a third-party API. The AI client should be aware that the response depends on an external entity it cannot control.

---

#### 3. `set_daily_spending_limit` — Idempotent Write, Closed Domain
```
readOnlyToolHint    = false
destructiveToolHint = false  ← not destructive; the old limit can be restored
idempotentToolHint  = true   ← setting the same limit twice = same state
openWorldToolHint   = false  ← updates internal account management only
```
Sets the daily spending cap for an account. This is **idempotent**: if an AI agent retries the call (e.g. due to a network timeout) with the same arguments, the resulting account state is identical to calling it once. The previous limit can always be restored by calling this tool again with a different value, so it is **not destructive**.

---

#### 4. `transfer_funds` — Non-Idempotent Write, Closed Domain
```
readOnlyToolHint    = false
destructiveToolHint = false  ← no data is permanently deleted
idempotentToolHint  = false  ← each call creates a NEW transaction record
openWorldToolHint   = false  ← internal payment processing only
```
Initiates a funds transfer between two accounts. This is the most important annotation to get right: the tool is **NOT idempotent**. Calling it twice with identical arguments will produce **two separate transfers** and debit the source account twice. AI clients that understand this hint will warn the user before retrying a failed call instead of blindly re-invoking the tool.

---

#### 5. `close_account` — Destructive, Idempotent, Closed Domain
```
readOnlyToolHint    = false
destructiveToolHint = true   ← permanently closes the account; irreversible
idempotentToolHint  = true   ← closing an already-closed account = same state
openWorldToolHint   = false  ← internal account lifecycle service only
```
Permanently closes a bank account and archives its data. **Destructive** — the action cannot be reversed without manual intervention by bank operations staff; a human-in-the-loop confirmation (`confirm: true`) is required. **Idempotent** — if the tool is called on an account that is already closed, it returns the same closed-state result without any additional side effects.

> MCP clients that respect `destructiveHint = true` will present a confirmation dialog to the user before invoking this tool.

---

#### 6. `send_fraud_alert` — Non-Idempotent Write, Open World
```
readOnlyToolHint    = false
destructiveToolHint = false  ← no data is destroyed
idempotentToolHint  = false  ← each call dispatches a NEW notification
openWorldToolHint   = true   ← calls external SMS, email, and push APIs
```
Dispatches a fraud alert to the account holder and the bank's fraud prevention team through external notification services (SMS gateway, email relay, push notification provider). **Open-world** because it reaches external APIs. **Not idempotent** — each call sends a new notification, so a retry delivers a duplicate alert to the customer.

---

## Flogo Handler Configuration

In Flogo the annotation hints are configured directly in the **handler settings** of the MCP server trigger. Here is an example from `BankingOperationsMCPServer.flogo`:

```json
{
  "settings": {
    "handlerType": "Tool",
    "handlerName": "close_account",
    "handlerDescription": "Permanently closes a bank account ...",
    "readOnlyToolHint":    false,
    "destructiveToolHint": true,
    "idempotentToolHint":  true,
    "openWorldToolHint":   false
  }
}
```

These settings are transmitted to the MCP client as part of the `tools/list` response, inside the `annotations` object of each `Tool` definition, following the [MCP 2025-03-26 schema](https://spec.modelcontextprotocol.io/specification/2025-03-26/server/tools/).

---

## Getting Started

### Prerequisites

- TIBCO Flogo® **2.26.3** or later
- An MCP-capable client (e.g. GitHub Copilot in VS Code, Claude Desktop)

### Import the App

Import `BankingOperationsMCPServer.flogo` into VS Code using the Flogo extension.

### Run the App

Run `BankingOperationsMCPServer.flogo` from VS Code. The Flogo MCP Server will start over HTTP at:

```
http://localhost:9093/mcp
```

### Configure Your MCP Client

**VS Code (`mcp.json`):**
```json
{
  "servers": {
    "BankingOperationsMCPServer": {
      "type": "http",
      "url": "http://localhost:9093/mcp"
    }
  }
}
```

**Claude Desktop (`claude_desktop_config.json`):**
```json
{
  "mcpServers": {
    "BankingOperationsMCPServer": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:9093/mcp"]
    }
  }
}
```

> You will need Node.js and the `mcp-remote` package installed for Claude Desktop.

### Try It — Example Prompts

Once connected, ask your AI agent:

```
"What is the current balance for account ACC-100042?"
```
→ Invokes `get_account_balance` (readOnly=true — no confirmation needed)

```
"What is today's USD to EUR exchange rate?"
```
→ Invokes `get_forex_rate` (readOnly=true, openWorld=true — reads from external API)

```
"Set the daily spending limit for account ACC-100042 to 500 USD"
```
→ Invokes `set_daily_spending_limit` (idempotent=true — safe to retry)

```
"Transfer 250 USD from account ACC-100042 to ACC-200099 with reference Invoice-5501"
```
→ Invokes `transfer_funds` (idempotent=false — client should warn before retry)

```
"Close account ACC-100042 — the customer has requested this"
```
→ Invokes `close_account` (destructive=true — MCP client should prompt for confirmation)

```
"Send a fraud alert for account ACC-100042, transaction TXN-987654, type SUSPICIOUS_TRANSACTION"
```
→ Invokes `send_fraud_alert` (idempotent=false, openWorld=true — each call sends a new notification via external APIs)

---

## Adapting This Sample for Production

The flows in this sample use `noop` + `actreturn` activities with mock responses to keep the focus on annotation configuration. To make this production-ready:

| Tool | Replace with |
|---|---|
| `get_account_balance` | REST Invoke → internal account ledger API |
| `get_forex_rate` | REST Invoke → external forex provider (e.g. Open Exchange Rates, Fixer.io, treasury system) |
| `set_daily_spending_limit` | REST Invoke → account management service (PUT/PATCH endpoint) |
| `transfer_funds` | REST Invoke → payment processing service (POST endpoint) |
| `close_account` | REST Invoke → account lifecycle service (DELETE/POST /close endpoint) |
| `send_fraud_alert` | REST Invoke → notification gateway (SMS, email, push APIs) |

---

## App Properties

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9093` | HTTP port the MCP server listens on |

---

## How AI Clients Use Tool Annotations

When an MCP client receives the tool list, it uses annotations to make informed decisions:

| Annotation Combination | Typical Client Behaviour |
|---|---|
| `readOnly=true` | Call freely with no confirmation; safe to retry |
| `readOnly=false, destructive=true` | Show confirmation dialog before invoking |
| `readOnly=false, idempotent=false` | Warn user before retrying a failed call |
| `openWorld=true` | Indicate that the tool will contact external services |
| `readOnly=false, destructive=true, idempotent=true` | Confirm once; safe to retry after confirmation |

> Client behaviour is implementation-specific — different MCP clients may handle annotations differently. Always design tools with appropriate safeguards (e.g. the `confirm` parameter on `close_account`) regardless of client-side annotation handling.

---

## Related Resources

- [MCP Specification — Tools](https://modelcontextprotocol.io/specification/2025-03-26/server/tools/)
- [MCP TypeScript Schema — ToolAnnotations](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-03-26/schema.ts)
- [TIBCO Flogo® MCP Connector Documentation](https://docs.tibco.com)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [Customer360 MCP Sample](../Customer360/README.md) — basic Flogo MCP server example
- [Smart Incident Response Assistant](../Smart_Incident_Response_Assistant/README.md) — MCP Elicitation, Logging, and Sampling
