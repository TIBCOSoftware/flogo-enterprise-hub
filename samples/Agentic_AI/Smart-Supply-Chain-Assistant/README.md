# Smart Supply Chain Assistant — Agent Trigger with List of MCP Servers and Custom Tool

## Overview

This sample demonstrates two key features of the **TIBCO Flogo® Agentic AI Connector** working together:

- **List of MCP Servers** — connect a single AI Agent to **multiple MCP servers simultaneously**, unlocking cross-domain intelligence from independent data sources.
- **Agent Trigger with Custom Tool** — use the Agent Trigger (`#agent`) with `mcpServers` to combine read operations from MCP with a custom Flogo flow for write operations.

A procurement manager can type natural language questions to query live inventory and supplier data — and when gaps are found, ask the agent to create a purchase order, all in one conversation.

---

## Where the `mcpServers` Feature Lives

The `mcpServers` list is available on **both** main Agentic AI components:

| Component | mcpServers Support | Additional Capabilities |
|---|---|---|
| **Agent Activity** (`#agentactivity`) | Yes — list MCP server connection IDs | Simple embed-in-flow pattern; good for read-only Q&A |
| **Agent Trigger** (`#agent`) | Yes — same `mcpServers` list | Plus: custom Flogo tool handlers, custom guardrails, custom conversation stores, agent handoff |

This sample uses the **Agent Trigger** pattern because it adds a `CreatePurchaseOrder` custom tool alongside the two MCP servers — enabling the agent to both **read** data from MCP and **write** a purchase order through a Flogo flow in the same session.

### How it connects in `SupplyChainAgent.flogo`

```
SupplyChainAgentTrigger (#agent)
├── mcpServers:
│   ├── inventory_mcp_server  →  http://localhost:9091/mcp
│   └── supplier_mcp_server   →  http://localhost:9092/mcp
└── handlers:
    └── CreatePurchaseOrder (handlerType: Tool)
        └── flowURI: create_po_flow  (Flogo flow, runs inside the same app)
```

At runtime, the LLM sees all 7 tools as one unified toolset — 6 from MCP for querying and 1 custom Flogo tool for creating purchase orders.

---

## Real-World Scenario

**Persona**: Sarah, a procurement manager at a manufacturing company.

```
Sarah: "Show me everything I need to know about our critical stock situation."

Agent: [Calls GetStockAlerts from Inventory MCP Server]
       [Calls GetPurchaseOrders from Supplier MCP Server]
       [Calls GetSuppliers from Supplier MCP Server]
       [Calls GetSupplierCapacity from Supplier MCP Server]

Agent: "3 products need immediate attention:

| Product | Alert | Stock | Reorder | Gap |
|---|---|---|---|---|
| Safety Valve MK-7 | OUT_OF_STOCK | 0 | 200 | -200 |
| Industrial Sensor Type-B | CRITICAL | 12 | 50 | -38 |
| Hydraulic Pump HY-500 | LOW | 5 | 10 | -5 |

Good news: PO-2025-002 (300x Safety Valve MK-7) from TechParts Inc. is 
Confirmed -- expected 2025-03-27. This fully covers the gap.

Caution: PO-2025-001 (100x Industrial Sensor Type-B) from Pacific Components 
is In Transit -- arriving 2025-04-05. Supplier S002 is at 90% capacity.
Consider placing a backup order with QuickShip Supplies (2-day lead time).

Recommendation: Hydraulic Pump HY-500 has no backup order. Want me to 
create a purchase order for 20 units from QuickShip Supplies at $1,250 each?"

Sarah: "Yes, please do that."

Agent: [Calls CreatePurchaseOrder with supplier_id=S004, product_id=P005,
        quantity=20, unit_price=1250.00]

Agent: "Done! Purchase order PO-2026-5001 has been created:
  - Supplier: QuickShip Supplies (S004)
  - Product: Hydraulic Pump HY-500 (P005)
  - Quantity: 20 units at $1,250.00 each
  - Total Value: $25,000.00
  - Status: Processing
  It will be confirmed by the supplier within 1 business day."
```

This session used **5 MCP tool calls across 2 servers** for reads and **1 custom Flogo tool call** for the write — all within a single natural language conversation.

---

## Architecture

```
 User (WebSocket Client)
      │  ws://localhost:9998/supply-chain?sessionId=sarah-123
      ▼
 ┌────────────────────────────────────────────────────────────────────┐
 │  SupplyChainAgent.flogo (port 9998)                               │
 │                                                                    │
 │  WebSocket Trigger → invoke_supply_chain_flow                     │
 │                              │                                     │
 │              ┌───────────────▼──────────────────┐                 │
 │              │  InvokeAIAgentTrigger (callagent) │                 │
 │              │  agentName: "SupplyChainAgent"    │                 │
 │              └───────────────┬──────────────────┘                 │
 │                              │ dispatches to                       │
 │              ┌───────────────▼──────────────────────────┐         │
 │              │  Agent Trigger (gpt-4o)                  │         │
 │              │                                          │         │
 │              │  mcpServers: [              KEY FEATURE  │         │
 │              │    inventory_mcp_server,                 │         │
 │              │    supplier_mcp_server                   │         │
 │              │  ]                                       │         │
 │              │                                          │         │
 │              │  handlers:                               │         │
 │              │    CreatePurchaseOrder (Tool)  ←────┐    │         │
 │              │      flowURI: create_po_flow        │    │         │
 │              └──────┬───────────────────────┬──────┘    │         │
 │                     │ MCP calls             │ MCP calls  │         │
 │                     │                       │           │         │
 │              create_po_flow (Flogo flow)    │           │         │
 │              Returns PO-2026-5001 ──────────┘           │         │
 └─────────────────────│───────────────────────────────────┘         │
                        │                       │
          ┌─────────────▼──┐    ┌───────────────▼──────────┐
          │InventoryMCPSrv │    │  SupplierMCPServer        │
          │ (port 9091)    │    │  (port 9092)              │
          │                │    │                           │
          │ GetProductCatalog   │ GetSuppliers              │
          │ GetStockAlerts │    │ GetPurchaseOrders         │
          │ GetWarehouseLocations GetSupplierCapacity       │
          └────────────────┘    └───────────────────────────┘
                Both run in: SupplyChainMCPServers.flogo
```


## Files in This Sample

| File | Description |
|---|---|
| `SupplyChainMCPServers.flogo` | Single Flogo app with **two MCP server triggers** — InventoryMCPServer (port 9091) and SupplierMCPServer (port 9092) — each exposing 3 domain-specific tools with realistic mock data |
| `SupplyChainAgent.flogo` | AI Agent app using an **Agent Trigger** configured with two MCP server connections plus a `CreatePurchaseOrder` custom tool. A WebSocket trigger routes prompts to the agent via InvokeAIAgentTrigger. |

---

## MCP Tools Reference

### InventoryMCPServer (port 9091) — via MCP (read-only)

| Tool | Description | Returns |
|---|---|---|
| `GetProductCatalog` | Full product list | product_id, name, category, unit_price, current_stock, reorder_point, preferred_supplier_id |
| `GetStockAlerts` | Products at or below reorder point | Same fields + shortage quantity + alert_level (LOW / CRITICAL / OUT_OF_STOCK) |
| `GetWarehouseLocations` | Physical storage locations | product_id, warehouse_id, location_code, qty_on_hand |

### SupplierMCPServer (port 9092) — via MCP (read-only)

| Tool | Description | Returns |
|---|---|---|
| `GetSuppliers` | Supplier catalog | supplier_id, name, country, contact_email, reliability_score, average_lead_days, payment_terms, certifications |
| `GetPurchaseOrders` | Open and recent POs | po_id, supplier, product, quantity, total_value, status, order_date, expected_delivery |
| `GetSupplierCapacity` | Real-time capacity availability | supplier_id, utilization_pct, available_capacity, next_available_slot, max_order_volume |

### Custom Flogo Tool — write operation

| Tool | Handler | Description | Parameters |
|---|---|---|---|
| `CreatePurchaseOrder` | `create_po_flow` (Flogo flow) | Creates a new purchase order and returns a PO confirmation | supplier_id, product_id, quantity, unit_price |

The agent is instructed to always confirm order details with the user before calling `CreatePurchaseOrder`.

### Data Model: How the Two Servers Connect

```
product.preferred_supplier_id ──────→ supplier.supplier_id
purchase_order.product_id ──────────→ product.product_id
purchase_order.supplier_id ─────────→ supplier.supplier_id
```

The LLM understands these relationships from the system prompt and uses them to join data across servers autonomously.

---

## Sample Data

### Products (6 items)

| ID | Product | Category | Stock | Reorder | Unit Price | Preferred Supplier |
|---|---|---|---|---|---|---|
| P001 | Industrial Sensor Type-A | Electronics | 450 | 100 | $149.99 | S001 |
| P002 | Industrial Sensor Type-B | Electronics | **12** | 50 | $299.99 | S002 |
| P003 | Safety Valve MK-7 | Mechanical | **0** | 200 | $89.99 | S001 |
| P004 | Control Board X200 | Electronics | 78 | 25 | $499.99 | S003 |
| P005 | Hydraulic Pump HY-500 | Mechanical | **5** | 10 | $1,250.00 | S002 |
| P006 | Pneumatic Cylinder PC-100 | Mechanical | 340 | 75 | $220.00 | S003 |

### Suppliers (4 vendors)

| ID | Supplier | Country | Reliability | Lead Time | Capacity |
|---|---|---|---|---|---|
| S001 | TechParts Inc. | USA | ⭐ 4.8 | 5 days | High (65%) |
| S002 | Pacific Components Ltd. | Japan | ⭐ 4.5 | 14 days | **Low (90%)** |
| S003 | EuroMech GmbH | Germany | ⭐ 4.9 | 10 days | High (45%) |
| S004 | QuickShip Supplies | USA | ⭐ 3.9 | 2 days | Very High (30%) |

### Open Purchase Orders (4 POs)

| PO | Product | Supplier | Qty | Status | Expected |
|---|---|---|---|---|---|
| PO-2025-001 | Industrial Sensor Type-B | Pacific Components | 100 | In Transit | 2025-04-05 |
| PO-2025-002 | Safety Valve MK-7 | TechParts Inc. | 300 | Confirmed | 2025-03-27 |
| PO-2025-003 | Hydraulic Pump HY-500 | Pacific Components | 15 | Processing | 2025-04-18 |
| PO-2025-004 | Control Board X200 | EuroMech GmbH | 50 | Delivered | 2025-03-12 |

---

## Prerequisites

- **TIBCO Flogo® 2.26.2 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An **OpenAI API key** (or swap for Anthropic or Gemini in the LLM Provider connection)
- A WebSocket client for testing: [Postman](https://www.postman.com/) or [websocat](https://github.com/vi/websocat)

---

## Setup & Configuration

### Step 1 — Configure the LLM Provider

Open `SupplyChainAgent.flogo` in the Flogo VS Code extension. Navigate to the **Connections** tab and open the `openai` connection. Set your API key in the `AgenticAI.openai.API_Key` property (or use the Properties panel to set it as an environment variable).

> **Swap LLM**: To use Anthropic Claude or Google Gemini, change `AgenticAI.openai.LLM_Provider` and update the `llmProvider` field in the connection. Then change the `model` in the Agent Activity settings accordingly.

### Step 2 — Start the MCP Servers

Open `SupplyChainMCPServers.flogo` and run it. This starts two HTTP MCP servers:

| Server | Port | Endpoint |
|---|---|---|
| InventoryMCPServer | 9091 | `http://localhost:9091/mcp` |
| SupplierMCPServer | 9092 | `http://localhost:9092/mcp` |

### Step 3 — Verify MCP Server Connections

In `SupplyChainAgent.flogo`, the two MCP server connections are pre-configured:

- **`inventory_mcp_server`** → `http://localhost:9091/mcp`
- **`supplier_mcp_server`** → `http://localhost:9092/mcp`

### Step 4 — Start the AI Agent

Run `SupplyChainAgent.flogo`. This starts:
- The **Agent Trigger** internally on port 8080 (handles LLM orchestration)
- The **WebSocket server** on port **9998** (accepts user connections)

### Step 5 — Connect and Query

Use any WebSocket client to connect.

**Postman**: Create a new WebSocket request, set the URL to `ws://localhost:9998/supply-chain?sessionId=my-session-1`, and click Connect.

**websocat** (command line):
```bash
websocat "ws://localhost:9998/supply-chain?sessionId=my-session-1"
```

Then type any of the sample queries below.

---

## Sample Queries

These queries demonstrate the cross-MCP read intelligence and the custom write tool.

### Single-Server Queries (warm-up)

```
What products do we currently have in stock?
```
```
Show me all our active suppliers sorted by reliability score.
```
```
List all open purchase orders and their expected delivery dates.
```

### Cross-Server Queries (the real power)

```
Which products are critically low on stock and who are their preferred suppliers?
Can those suppliers deliver quickly given their current capacity?
```
```
We have 3 stock alerts right now. For each one, tell me:
1. The alert severity
2. Whether there is already a purchase order in flight
3. If not, which supplier can deliver fastest right now
```
```
Give me a full procurement risk report: which of our out-of-stock or 
critical products do NOT have an open purchase order?
```
```
Our preferred supplier for the Safety Valve MK-7 has a PO confirmed.
When will it arrive, and will it fully cover our reorder point?
```
```
Which supplier has the best combination of high reliability score 
AND fast lead time AND available capacity right now?
```
```
Compare Pacific Components Ltd. vs TechParts Inc. across reliability, 
lead time, certifications, and current capacity. 
Which should I prefer for a large urgent order?
```

### Purchase Order Creation (custom tool)

```
The Safety Valve MK-7 is out of stock. Please create a purchase order
for 300 units from TechParts Inc. at $89.99 each.
```
```
Hydraulic Pump HY-500 has no backup order. Raise a PO for 20 units 
from QuickShip Supplies at $1,250 each.
```
```
Which critical stock items could be sourced from QuickShip Supplies today?
For each one, help me create a purchase order.
```

### Multi-Turn Conversation (leverages memory)

```
Turn 1: What are our current stock alerts?
Turn 2: For the most critical one, who is the preferred supplier?
Turn 3: Do they have capacity for an urgent order of 200 units?
Turn 4: Go ahead and create the purchase order at their standard price.
```

---

## How It Works

### Agent Trigger settings (SupplyChainAgent.flogo)

```json
{
  "ref": "#agent",
  "id": "SupplyChainAgentTrigger",
  "settings": {
    "agentName": "SupplyChainAgent",
    "model": "gpt-4o",
    "mcpServers": [
      "b2c3d4e5-f6a7-8901-bcde-f12345678901",
      "c3d4e5f6-a7b8-9012-cdef-012345678902"
    ],
    "conversationStoreType": "Memory",
    "memoryMaxSize": 20
  },
  "handlers": [
    {
      "settings": {
        "handlerType": "Tool",
        "agentToolName": "CreatePurchaseOrder",
        "agentToolDescription": "Create a new purchase order after user confirmation"
      },
      "action": { "flowURI": "res://flow:create_po_flow" }
    }
  ]
}
```

Each string in `mcpServers` is a **connection ID** referencing an MCP Server connection. The Agentic AI Connector:

1. Connects to both MCP servers at startup
2. Discovers tools from each: `GetProductCatalog`, `GetStockAlerts`, `GetWarehouseLocations`, `GetSuppliers`, `GetPurchaseOrders`, `GetSupplierCapacity`
3. Combines them with the handler-defined tool `CreatePurchaseOrder` into one unified toolset for the LLM
4. Routes each tool call — transparently to the correct MCP server or Flogo flow

### InvokeAIAgentTrigger flow (invoke_supply_chain_flow)

WebSocket connections call the `callagent` (InvokeAIAgentTrigger) activity, which dispatches to the named Agent Trigger:

```json
{
  "ref": "#callagent",
  "input": {
    "agentName": "SupplyChainAgent",
    "Prompt": "=coerce.toString($flow.content)",
    "conversationId": "=coerce.toString($flow.queryParams.sessionId)"
  }
}
```

The `sessionId` URL parameter keeps conversation history separate per user session.

---

## What to Customize

| Customization | Where | How |
|---|---|---|
| Use a real ERP or WMS backend | Replace `actreturn` in each MCP tool flow | Call REST/JDBC activity instead of returning static data |
| Make CreatePurchaseOrder call a real API | `create_po_flow` | Add HTTP or JDBC activity before the return |
| Add more MCP servers | `SupplyChainAgent.flogo` Agent Trigger settings | Add a third connection ID to `mcpServers` |
| Add a spending guardrail | Agent Trigger handler | Add a `CustomGuardrail` handler that rejects orders above a threshold |
| Use a durable conversation store | Agent Trigger settings | Change `conversationStoreType` to `Custom` and add a store handler backed by a database |
| Use Anthropic Claude | LLM Provider connection | Change `llmProvider` to `Anthropic` and set model to `claude-opus-4-5` |
| Add authentication to MCP servers | MCP server connection settings | Change `authType` to `Bearer` and configure `authToken` |

---

## Why This Architecture Matters

| Traditional Integration | With Flogo Agentic AI + MCP List |
|---|---|
| Custom ETL to join inventory + supplier data | LLM joins data dynamically, zero ETL |
| Bespoke dashboard per question type | Natural language — any question, any combination |
| Adding a third data source = new code | Add one line to `mcpServers` array |
| Separate UI for creating purchase orders | Same conversation: query data, then create PO |
| One team per system = coordination overhead | Single AI Agent orchestrates all systems |

The `mcpServers` feature on the Agent Trigger gives you the enterprise integration superpower: independent MCP servers for reads, custom Flogo flows for writes, and the LLM orchestrating all of it from a single natural language interface.

---

## Extending to Production

1. **Replace static data** in each MCP tool flow's `actreturn` with live calls to your ERP (SAP, Oracle), WMS, or procurement system
2. **Connect `create_po_flow`** to your actual procurement API or message queue instead of returning mock data
3. **Add a spending guardrail** — a `CustomGuardrail` handler on the Agent Trigger that rejects or flags orders above an approval threshold before the LLM calls `CreatePurchaseOrder`
4. **Switch to a durable conversation store** for audit trails — add a `CustomConversationStore` handler backed by a database
5. **Add a third MCP server** (e.g., a Logistics MCP Server with shipment tracking) — just add its connection ID to `mcpServers`

See the [Healthcare Compliance Agent](../Healthcare-Compliance-Agent/) sample for a full demonstration of custom guardrails and durable conversation stores.
