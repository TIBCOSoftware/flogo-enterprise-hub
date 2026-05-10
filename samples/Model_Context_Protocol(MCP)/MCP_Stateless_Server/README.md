# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® MCP Stateless Server — Product Catalog Sample

## Overview

This sample demonstrates how to configure a **stateless Flogo MCP server** (`statelessServer = true`) using a realistic **e-commerce product catalog** scenario.

A stateless MCP server does **not** issue or track an `Mcp-Session-Id`. Every HTTP request from the MCP client is completely independent — the server holds no per-client context between calls. This makes stateless servers ideal for read-only data lookups, horizontally scalable deployments, serverless hosting, and any workflow where each tool call is fully self-contained.

---

## Stateless vs Stateful — Quick Reference

| Feature | Stateless (`statelessServer: true`) | Stateful (`statelessServer: false`) |
|---|---|---|
| `Mcp-Session-Id` issued | ❌ No | ✅ Yes |
| Client must send session header | ❌ No | ✅ Yes (on all subsequent requests) |
| Per-client context tracked server-side | ❌ No | ✅ Yes |
| Safe for horizontal scaling / load balancers | ✅ Yes | ⚠️ Only with sticky sessions or external state store |
| Required for MCP Elicitation | ❌ No | ✅ Yes |
| Required for MCP Sampling | ❌ No | ✅ Yes |
| Required for MCP Logging streams | ❌ No | ✅ Yes |
| Best for | Read-only lookups, shared data APIs, high-volume tools | Multi-step wizards, conversation context, user-specific sessions |

---

## The `statelessServer` Setting in Flogo

In the Flogo MCP server trigger, the `statelessServer` field is set at the **server level** (not per-handler):

```json
"settings": {
  "serverName": "ProductCatalogMCPServer",
  "serverType": "HTTP",
  "serverPort": "9094",
  "statelessServer": true,
  "serverEndpointPath": "/mcp"
}
```

- **`statelessServer: true`** — The server skips session management entirely. No `Mcp-Session-Id` is generated or sent during initialization. The MCP client sends each request as a plain HTTP POST with no session header required.
- **`statelessServer: false`** — The server assigns a cryptographically unique `Mcp-Session-Id` during the `InitializeResult` response. The client must include `Mcp-Session-Id` in the header of every subsequent request. Requests missing the session header are rejected with `HTTP 400 Bad Request`.

---

## Why Stateless for Product Catalog?

A product catalog has exactly the properties that make stateless ideal:

- **Every tool call is self-contained** — searching for products, getting details, checking stock, and looking up promotions each require only the inputs provided in that single request.
- **No user context accumulates** — there is nothing to remember between tool calls. An AI agent can call these tools in any order, from any session.
- **High-volume, multi-client** — many AI agents (or users) can query the catalog simultaneously. With no session state on the server, any instance in a load-balanced pool can handle any request.
- **Horizontally scalable** — because there is no server-side session to synchronise, additional server instances can be added freely.
- **Serverless friendly** — stateless tools are compatible with serverless or ephemeral deployments where the server process may be recycled between requests.

---

## Sample — Product Catalog MCP Server

`ProductCatalogMCPServer.flogo` exposes four product catalog tools, all read-only and stateless:

### Tool Summary

| Tool | readOnly | openWorld | Description |
|---|:---:|:---:|---|
| `search_products` | ✅ | ❌ | Full-text search with optional category and price filters |
| `get_product_details` | ✅ | ❌ | Full product details by product ID |
| `check_stock` | ✅ | ❌ | Live stock availability across warehouse regions |
| `get_active_promotions` | ✅ | ❌ | Active discounts, coupon codes, and promotional offers |

All four tools are `readOnlyToolHint: true` — the Flogo MCP server publishes this hint so MCP clients know they are safe to invoke automatically without user confirmation.

### Session Flow Comparison

**Stateless (this sample):**
```
Client                         Server
  │── POST /mcp (Initialize) ──▶│  (no Mcp-Session-Id issued)
  │◀─ InitializeResult ─────────│
  │
  │── POST /mcp (search_products) ──▶│  (independent, no session header)
  │◀─ tool result ───────────────────│
  │
  │── POST /mcp (get_product_details) ──▶│  (independent, no session header)
  │◀─ tool result ──────────────────────│
```

**Stateful (see MCP_Stateful_Server sample):**
```
Client                           Server
  │── POST /mcp (Initialize) ──▶│
  │◀─ InitializeResult ─────────│  Mcp-Session-Id: abc123 issued
  │
  │── POST /mcp (step 1) Mcp-Session-Id: abc123 ──▶│  session state written
  │◀─ tool result ───────────────────────────────────│
  │
  │── POST /mcp (step 2) Mcp-Session-Id: abc123 ──▶│  reads session state from step 1
  │◀─ tool result ───────────────────────────────────│
```

---

## Getting Started

### Prerequisites

- TIBCO Flogo® **2.26.3** or later
- An MCP-capable client (e.g. GitHub Copilot in VS Code, Claude Desktop)

### Import the App

Import `ProductCatalogMCPServer.flogo` into VS Code using the Flogo extension.

### Run the App

Run `ProductCatalogMCPServer.flogo` from VS Code. The server starts at:

```
http://localhost:9094/mcp
```

### Configure Your MCP Client

**VS Code (`mcp.json`):**
```json
{
  "servers": {
    "ProductCatalogMCPServer": {
      "type": "http",
      "url": "http://localhost:9094/mcp"
    }
  }
}
```

**Claude Desktop (`claude_desktop_config.json`):**
```json
{
  "mcpServers": {
    "ProductCatalogMCPServer": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:9094/mcp"]
    }
  }
}
```

### Try It — Example Prompts

```
"Search for laptops under $1500 that are in stock"
```
→ Invokes `search_products` — fully self-contained, no session needed

```
"Give me the full specifications for product PROD-4421"
```
→ Invokes `get_product_details` — stateless, no session needed

```
"Is PROD-4421 available in the EU warehouse?"
```
→ Invokes `check_stock` — stateless, no session needed

```
"What promotions are currently available for Electronics?"
```
→ Invokes `get_active_promotions` — stateless, no session needed

Notice that the AI agent can call these tools in **any order**, from **any session**, and the results are always correct with no dependency on previous calls.

---

## Adapting for Production

The flows use `noop` + `actreturn` activities with mock data. To make this production-ready:

| Tool | Replace with |
|---|---|
| `search_products` | REST Invoke → product search API (Elasticsearch, Solr, or your catalog service) |
| `get_product_details` | REST Invoke → product management service (GET /products/{id}) |
| `check_stock` | REST Invoke → warehouse management system (WMS) |
| `get_active_promotions` | REST Invoke → promotions engine or marketing platform |

Since the server is stateless, all of these can be behind a **load balancer** with no sticky session requirement.

---

## When to Use Stateless — Decision Guide

Use `statelessServer: true` when **all** of the following are true:

- ✅ Each tool call produces a complete result from its inputs alone
- ✅ No information needs to be remembered between tool calls for the same user
- ✅ The same tool can be called by multiple different AI agents simultaneously
- ✅ You want to scale horizontally behind a load balancer
- ✅ You are not using MCP Elicitation, Sampling, or server-initiated Logging streams

Use `statelessServer: false` (see [MCP_Stateful_Server](../MCP_Stateful_Server/README.md)) when:

- The workflow has multiple steps that must share accumulated context
- You need MCP Elicitation (server-to-client interactive forms)
- You need MCP Sampling (server-to-client LLM completions)
- You need persistent server-to-client SSE notification streams

---

## App Properties

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9094` | HTTP port the MCP server listens on |

---

## Related Resources

- [MCP Specification — Transports (Session Management)](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports#session-management)
- [MCP Stateful Server Sample](../MCP_Stateful_Server/README.md) — Multi-step loan application wizard with `statelessServer: false`
- [Customer360 MCP Sample](../Customer360/README.md) — Basic Flogo MCP server (no statelessServer field — defaults to stateful)
- [Smart Incident Response Assistant](../Smart_Incident_Response_Assistant/README.md) — MCP Elicitation, Logging, and Sampling (requires stateful server)
- [MCP Tool Annotations Sample](../MCP_Tool_Annotations/README.md) — All four tool annotation hints demonstrated
