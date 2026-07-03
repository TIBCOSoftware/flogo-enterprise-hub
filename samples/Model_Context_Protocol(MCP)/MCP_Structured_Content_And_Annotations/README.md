# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® MCP Structured Content & Annotations — E-Commerce Orders Sample

## Overview

This sample demonstrates how to configure **Structured Content** (Tool Output Schema + `structuredContent` mapping) and **Content Annotations** (`audience` + `priority`) in a TIBCO Flogo® MCP Server trigger using a realistic **e-commerce order management** scenario.

**Structured Content** allows a tool to return typed JSON alongside (or instead of) plain text — enabling MCP clients to programmatically consume tool results without parsing text. **Content Annotations** control who sees the response (`audience`) and how important it is (`priority`).

> **New in Flogo 2.26.5:** Tool Output Schema (`reply.outputSchema`), `structuredContent` output mapping, and content annotations (`audience`/`priority` on `response`) are new MCP connector features.

---

## Key Features

- **Tool Output Schema** — declare the shape of structured output using JSON Schema in `reply.outputSchema`; MCP clients can use this schema for validation and auto-completion
- **Structured Content Mapping** — return typed JSON values (integers, numbers, booleans, arrays) via `structuredContent` alongside human-readable text in `response.data`
- **Audience Annotations** — control whether content is shown to the user (`["user"]`), the LLM (`["assistant"]`), or both (`["user","assistant"]`)
- **Priority Annotations** — signal importance from `0.0` (lowest) to `1.0` (highest/urgent)

---

## How Structured Content Works

```
Tool returns BOTH:
  ┌──────────────────────────────────┐
  │  response.data (text)            │  ← Human-readable summary
  │  "Order ORD-2026-78901: Status   │
  │   SHIPPED. 3 items, $247.95..."  │
  └──────────────────────────────────┘
  ┌──────────────────────────────────┐
  │  structuredContent (typed JSON)  │  ← Machine-readable data
  │  {                               │
  │    "order_id": "ORD-2026-78901", │
  │    "status": "shipped",          │
  │    "item_count": 3,              │  ← integer, not string
  │    "total_usd": 247.95           │  ← number, not string
  │  }                               │
  └──────────────────────────────────┘
```

The MCP client receives **both** and chooses which to use. Text-only clients show `response.data`; programmatic clients consume `structuredContent`.

---

## How Content Annotations Work

| Annotation | Values | Effect |
|---|---|---|
| `audience` | `["user"]` | Content shown **only to the human** — LLM does not see it |
| `audience` | `["assistant"]` | Content sent **only to the LLM** — hidden from the human user |
| `audience` | `["user","assistant"]` | Content visible to **both** human and LLM (default) |
| `priority` | `0.0` – `1.0` | Importance hint. `1.0` = urgent, `0.0` = background context |

---

## Sample — E-Commerce Orders MCP Server

The `ECommerceOrdersMCPServer.flogo` app exposes **three tools**, each demonstrating a different combination of structured content and annotations:

### Tool Matrix

| MCP Tool | audience | priority | Structured Content? | Description |
|---|:---:|:---:|:---:|---|
| `get_order_status` | `["user","assistant"]` | `0.9` | Yes | Order lookup with both text summary AND typed JSON |
| `get_order_analytics` | `["assistant"]` | `0.3` | No | Internal analytics for LLM reasoning — hidden from user |
| `get_shipping_alerts` | `["user"]` | `1.0` | No | Urgent alerts shown directly to human — LLM does not process |

---

### Tool Details

#### 1. `get_order_status` — Structured Content + Dual Audience

This tool demonstrates the **full structured content pattern**: it returns a human-readable text summary in `response.data` AND a typed JSON object in `structuredContent`.

**Output Schema** (declared in `reply.outputSchema`):
```json
{
  "type": "object",
  "properties": {
    "order_id": { "type": "string" },
    "status": { "type": "string" },
    "item_count": { "type": "integer" },
    "total_usd": { "type": "number" },
    "estimated_delivery": { "type": "string" },
    "shipping_carrier": { "type": "string" },
    "tracking_number": { "type": "string" }
  },
  "required": ["order_id", "status", "item_count", "total_usd"]
}
```

**Text response** (`response.data`):
```
Order ORD-2026-78901: Status SHIPPED. 3 items totaling $247.95.
Shipped via FedEx (tracking: FX-9876543210). Estimated delivery: 2026-06-28.
```

**Structured response** (`structuredContent`):
```json
{
  "order_id": "ORD-2026-78901",
  "status": "shipped",
  "item_count": 3,
  "total_usd": 247.95,
  "estimated_delivery": "2026-06-28",
  "shipping_carrier": "FedEx",
  "tracking_number": "FX-9876543210"
}
```

With `audience=["user","assistant"]` and `priority=0.9`, both the human and LLM receive this content at normal importance.

---

#### 2. `get_order_analytics` — Assistant-Only, Low Priority

Returns internal order analytics (revenue, fulfillment rate, return rate, cart abandonment, etc.) that the **LLM uses for reasoning** but is **not shown to the human user**.

- `audience=["assistant"]` — the MCP client should hide this from the UI
- `priority=0.3` — low importance; background context for the LLM to reference when answering order-related questions

This pattern is useful for feeding the AI with context data that would clutter the user's view.

---

#### 3. `get_shipping_alerts` — User-Only, Urgent Priority

Returns critical shipping alerts (customs delays, failed deliveries, weather delays) that are **shown directly to the human user** but **not fed to the LLM** for further processing.

- `audience=["user"]` — displayed in the UI but not consumed by the LLM
- `priority=1.0` — highest urgency; MCP clients may render this more prominently

This pattern is useful for time-sensitive notifications that need human attention, not AI reasoning.

---

## Flogo Handler Configuration

### Structured Content (get_order_status)

1. **Output Schema** — set `reply.outputSchema` to a JSON Schema string describing the structured output:

```json
{
  "reply": {
    "outputSchema": "{ \"type\": \"object\", \"properties\": { ... } }"
  }
}
```

2. **Action Output Mapping** — map both `response` and `structuredContent` from the flow:

```json
{
  "action": {
    "output": {
      "response": "=$.response",
      "structuredContent": "=$.structuredContent"
    }
  }
}
```

3. **Activity Return** — in the `actreturn` activity, provide mappings for both:

```json
{
  "mappings": {
    "response": {
      "mapping": {
        "data": "Human-readable text summary...",
        "audience": ["user", "assistant"],
        "priority": 0.9
      }
    },
    "structuredContent": {
      "mapping": {
        "order_id": "ORD-2026-78901",
        "status": "shipped",
        "item_count": 3,
        "total_usd": 247.95
      }
    }
  }
}
```

### Content Annotations Only (get_order_analytics, get_shipping_alerts)

For tools without structured content, just set `audience` and `priority` on the response mapping:

```json
{
  "mappings": {
    "response": {
      "mapping": {
        "data": "Analytics text...",
        "audience": ["assistant"],
        "priority": 0.3
      }
    }
  }
}
```

---

## Getting Started

### Prerequisites

- TIBCO Flogo® **2.26.5** or later
- An MCP-capable client (e.g. GitHub Copilot in VS Code, Claude Desktop)

### Import the App

Import `ECommerceOrdersMCPServer.flogo` into VS Code using the Flogo extension.

### Run the App

Run `ECommerceOrdersMCPServer.flogo` from VS Code. The MCP Server will start at:

```
http://localhost:9097/mcp
```

### Configure Your MCP Client

**VS Code (`mcp.json`):**
```json
{
  "servers": {
    "ECommerceOrdersMCPServer": {
      "type": "http",
      "url": "http://localhost:9097/mcp"
    }
  }
}
```

**Claude Desktop (`claude_desktop_config.json`):**
```json
{
  "mcpServers": {
    "ECommerceOrdersMCPServer": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:9097/mcp"]
    }
  }
}
```

### Try It — Example Prompts

```
"What is the status of order ORD-2026-78901?"
```
→ Invokes `get_order_status` — returns text summary + structured JSON with typed fields

```
"Give me an overview of our order performance"
```
→ Invokes `get_order_analytics` — analytics sent to LLM only (hidden from user)

```
"Are there any shipping problems I should know about?"
```
→ Invokes `get_shipping_alerts` — urgent alerts shown to user only (LLM does not process)

---

## Adapting This Sample for Production

The flows use `noop` + `actreturn` activities with mock data. To make this production-ready:

| Tool | Replace with |
|---|---|
| `get_order_status` | REST Invoke → order management system API (e.g. Shopify, SAP Commerce) |
| `get_order_analytics` | REST Invoke → analytics/BI API (e.g. Looker, Tableau, internal data warehouse) |
| `get_shipping_alerts` | REST Invoke → shipping provider APIs (e.g. FedEx, UPS, ShipStation) |

---

## App Properties

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9097` | HTTP port the MCP server listens on |

---

## Related Resources

- [MCP Specification — Tools](https://modelcontextprotocol.io/specification/2025-03-26/server/tools/)
- [TIBCO Flogo® MCP Connector Documentation](https://docs.tibco.com)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [MCP Tool Annotations](../MCP_Tool_Annotations/README.md) — tool safety annotations
- [Customer360 MCP Sample](../Customer360/README.md) — basic Flogo MCP server example
- [MCP JWT Scope Access Control](../MCP_JWT_Scope_Access_Control/README.md) — scope-based access and tokenInfo
