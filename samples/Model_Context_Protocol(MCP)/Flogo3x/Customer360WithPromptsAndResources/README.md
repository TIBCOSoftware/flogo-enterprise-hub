# Customer 360 MCP Server — Prompts & Resources

## Overview

This sample extends the [Customer 360](../Customer360/README.md) MCP server to demonstrate all **three MCP primitive types** — **Tools**, **Resources**, and **Prompts** — working together in a single real-world Customer 360 scenario, built with the **TIBCO Flogo® 3 Connector for Model Context Protocol (MCP)**.

While the base Customer360 sample exposes data exclusively as **Tools** (callable by the LLM on demand), this sample shows when and why you would choose **Resources** or **Prompts** instead — and what each primitive type is uniquely good at.

---

## MCP Primitive Types — What Each One Does

| Primitive | MCP Spec Role | When to Use |
|---|---|---|
| **Tool** | LLM calls it to fetch or mutate data at runtime | Dynamic, parameterised queries the LLM decides to make on demand (e.g. "fetch all sales") |
| **Resource** | AI client reads a URI-addressable data store | Reference data the AI client pre-loads as context — either static (full catalog) or dynamic (single record by ID) |
| **Prompt** | AI client retrieves a pre-packaged conversation starter | Complex analysis tasks where you want the server to inject a carefully structured instruction set into the conversation |

---

## Handlers in This Sample

| # | Name | Type | URI / Invocation | Purpose |
|---|---|---|---|---|
| 1 | `GetCustomers` | **Tool** | called by LLM | Returns all customers from the REST API |
| 2 | `GetProducts` | **Tool** | called by LLM | Returns all products from the REST API |
| 3 | `GetSales` | **Tool** | called by LLM | Returns all sales transactions from the REST API |
| 4 | `product_catalog` | **Resource (static)** | `products://catalog` | Full product catalog as `application/json` — AI client reads once as context |
| 5 | `sales_summary` | **Resource (static)** | `sales://summary` | Pre-aggregated summary (total revenue, top products, top customers) — for instant executive answers |
| 6 | `customer_profile` | **Resource (dynamic)** | `customers://{id}/profile` | Single customer record fetched live from the REST API by customer ID |
| 7 | `analyze_customer_sales` | **Prompt** | invoked by name | Injects a structured analysis instruction — the LLM performs deep customer sales analysis for a given name + period |
| 8 | `cross_sell_recommendation` | **Prompt** | invoked by name | Injects a cross-sell recommendation instruction — the LLM identifies products the customer hasn't bought and recommends complementary ones |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Customer360WithPromptsAndResources (HTTP MCP Server, port 9092) │
│                                                                   │
│  TOOLS (LLM calls on demand)                                      │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────┐   │
│  │  GetCustomers   │  │   GetProducts    │  │   GetSales     │   │
│  │  → REST GET     │  │   → REST GET     │  │   → REST GET   │   │
│  │  /customers     │  │   /products      │  │   /sales       │   │
│  └─────────────────┘  └──────────────────┘  └────────────────┘   │
│                                                                   │
│  RESOURCES (AI client reads as context)                           │
│  ┌──────────────────────────┐  ┌──────────────────────────────┐  │
│  │  products://catalog      │  │  sales://summary             │  │
│  │  Static — full catalog   │  │  Static — aggregated totals  │  │
│  │  JSON text, read once    │  │  JSON text, read once        │  │
│  └──────────────────────────┘  └──────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │  customers://{id}/profile                                │     │
│  │  Dynamic — fetches one customer record via REST GET      │     │
│  │  URI variable: id  →  /customers/{id}                    │     │
│  └──────────────────────────────────────────────────────────┘     │
│                                                                   │
│  PROMPTS (AI client invokes to get pre-composed instructions)     │
│  ┌─────────────────────────────────────────────────────────┐      │
│  │  analyze_customer_sales(customer_name, period)          │      │
│  │  Returns: description + [user message with full         │      │
│  │  analysis brief — 6 analytical requirements injected]   │      │
│  └─────────────────────────────────────────────────────────┘      │
│  ┌─────────────────────────────────────────────────────────┐      │
│  │  cross_sell_recommendation(customer_name)               │      │
│  │  Returns: description + [user message with cross-sell   │      │
│  │  instruction — compare history vs catalog, top 3 recs]  │      │
│  └─────────────────────────────────────────────────────────┘      │
└───────────────────────────────────────────────────────────────────┘
        ↕  REST API (CustomersProductsSalesAPI — port 18080)
```

---

## Why Resources Instead of Tools?

The **base Customer360 sample** exposes all data as Tools. That means every time the AI needs product or customer information, it makes a fresh tool call — even for reference data that never changes between requests.

**Static Resources** (`products://catalog`, `sales://summary`) solve this by letting the AI client **subscribe to the resource URI once** and hold the data in its context window. No repeated tool calls for catalog lookups.

**Dynamic Resources** (`customers://{id}/profile`) combine the precision of a parameterised lookup with the semantics of a resource read — the AI client says "give me `customers://3/profile`" rather than calling `GetCustomers` and filtering client-side.

---

## Why Prompts Instead of Just Sending a Message?

A **Prompt** is a reusable, server-managed instruction template. When a user in Claude Desktop selects the `analyze_customer_sales` prompt and fills in `customer_name=Bruce Wayne` and `period=Q1 2025`, the Flogo flow constructs a rich, multi-requirement analysis brief. The AI receives this as the opening `user` message — with 6 specific analytical requirements already written in — and begins its analysis immediately.

**Business value:**
- Consistent analysis quality across all users (the brief is always complete)
- No prompt engineering required from the end user
- The Flogo server controls the analysis framework — easy to update centrally

---

## Real-World Query Examples

### Using the Prompts (in Claude Desktop or GitHub Copilot)

```
Prompt: analyze_customer_sales
  customer_name: Bruce Wayne
  period: Q1 2025

→ Claude immediately performs a 6-point analysis:
   total transactions • product breakdown • average order value
   comparison • top category • purchase trends • executive summary
```

```
Prompt: cross_sell_recommendation
  customer_name: Bruce Wayne

→ Claude identifies Bruce's purchase history, compares against the catalog,
   and recommends 3 complementary products with personalised pitches
```

### Using the Resources (in any MCP client)

```
Read: products://catalog
→ Returns the full product catalog JSON in one read — no tool call needed

Read: sales://summary
→ Returns pre-aggregated totals: $593,463 revenue, top 3 products, top 3 customers

Read: customers://3/profile
→ Returns Scott Lang's full profile fetched live from the REST API
```

### Using the Tools (same as base Customer360)

```
"Show me all sales for Q1 2025"
→ LLM calls GetSales tool → filters → presents results

"List customers who bought more than 2 products"
→ LLM calls GetCustomers + GetSales tools → cross-references → presents results
```

---

## Prerequisites

- **TIBCO Flogo® 3.0.0 or later**. For more information, please refer [documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/agentic-AI/agentic-AI-overview.htm)
- An MCP-capable AI client: [Claude Desktop](https://claude.ai/download), [GitHub Copilot in VS Code](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot), or [Postman](https://www.postman.com/)

---

## Files in This Sample

| Project folder | Description |
|---|---|
| `Customer360WithPromptsAndResources` | The Flogo 3 MCP Server app (folder containing `app.fgmd`) — 8 handlers (3 Tools + 3 Resources + 2 Prompts) |
| `../Customer360/CustomersProductsSalesAPI` | **Shared** REST API data server — reuse from the base [Customer360](../Customer360/README.md) sample |

---

## Setup & Run

The MCP server depends on the REST API backend for its Tools and its dynamic `customer_profile` resource, so start the REST backend first. This sample reuses the `CustomersProductsSalesAPI` REST API app from the base [Customer360](../Customer360/README.md) sample — run it from `../Customer360/` before starting the MCP server here.

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `Customer360WithPromptsAndResources`. (Open the `../Customer360/` folder as well so the extension detects the shared `CustomersProductsSalesAPI` REST API app.)
2. Open the app's `.fgprops` file and set the App Properties for your environment (see [App Properties](#app-properties) below) — REST backend URLs, MCP server port. Point `CustInvokeRESTServiceURL` / `ProdInvokeRESTServiceURL` / `SaleInvokeRESTServiceURL` / `CustByIdInvokeRESTServiceURL` at the running `CustomersProductsSalesAPI` REST API app.
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. The native binary is produced in the app's `bin/` folder and logs stream to the integrated terminal.
   - Run `CustomersProductsSalesAPI` (from `../Customer360/`) first. This starts the data server at `http://localhost:18080` with the following endpoints:
     - `GET http://localhost:18080/customers` — returns all customers
     - `GET http://localhost:18080/products` — returns all products
     - `GET http://localhost:18080/sales` — returns all sales
     - `GET http://localhost:18080/customers/:id` — returns a single customer by ID (required by the `customer_profile` dynamic resource)
   - Then run `Customer360WithPromptsAndResources`. This starts the FLOGO MCP Server over HTTP at `http://localhost:9092/mcp`.
5. Connect your AI client to the MCP server and exercise all three primitive types (Tools, Resources, and Prompts):

   **Claude Desktop** — add to `claude_desktop_config.json`:
   ```json
   {
     "mcpServers": {
       "Customer360-Prompts-Resources": {
         "command": "npx",
         "args": ["mcp-remote", "http://localhost:9092/mcp"]
       }
     }
   }
   ```

   **GitHub Copilot in VS Code** — add to your MCP settings:
   ```json
   {
     "servers": {
       "Customer360-Prompts-Resources": {
         "url": "http://localhost:9092/mcp"
       }
     }
   }
   ```

   > You will also need to install npm and the `mcp-remote` package in order for Claude Desktop to connect to the MCP server.

   Once connected, VS Code GitHub Copilot exposes the server's resources in the MCP panel alongside its tools:

   - **Static resources** (`products://catalog`, `sales://summary`) — appear in the MCP resources list and can be read directly by selecting them in the panel
   - **Dynamic resource** (`customer_profile`) — uses the URI template `customers://{id}/profile`. To fetch a specific customer's profile, enter the full URI with the customer ID in the MCP resource input field. For example, `customers://3/profile` returns Scott Lang's full profile fetched live from the REST API.

   > **How the custom ID is passed to the flow:** When you request `customers://3/profile`, the Flogo MCP trigger extracts the `id` value (`3`) from the URI template and passes it into the `Customer_Profile_Resource` flow as `$flow.arguments.id`. The flow then calls `GET http://localhost:18080/customers/3` and returns the result.

   Use the [Real-World Query Examples](#real-world-query-examples) above to exercise the Prompts, Resources, and Tools.

---

## App Properties

Set these in the app's `.fgprops` file before running:

- **`Customer360WithPromptsAndResources`**
  - `MCPServer.PORT` — the port the MCP Server listens on (default `9092`). Different from the base Customer360 sample (`9091`) so both can run side-by-side.
  - `CustInvokeRESTServiceURL` — URL where the `CustomersProductsSalesAPI` app serves customers (default `http://localhost:18080/customers`). Used by the `GetCustomers` tool.
  - `ProdInvokeRESTServiceURL` — URL where the `CustomersProductsSalesAPI` app serves products (default `http://localhost:18080/products`). Used by the `GetProducts` tool.
  - `SaleInvokeRESTServiceURL` — URL where the `CustomersProductsSalesAPI` app serves sales (default `http://localhost:18080/sales`). Used by the `GetSales` tool.
  - `CustByIdInvokeRESTServiceURL` — URL where the `CustomersProductsSalesAPI` app serves a single customer by ID (default `http://localhost:18080/customers/{id}`). Used by the `customer_profile` dynamic resource.

Make sure to check and update `CustInvokeRESTServiceURL`, `ProdInvokeRESTServiceURL`, `SaleInvokeRESTServiceURL`, and `CustByIdInvokeRESTServiceURL` to point at the URL where your `CustomersProductsSalesAPI` app (from the base [Customer360](../Customer360/README.md) sample) is running.

---

## What Happens Under the Hood

### Resource read — `products://catalog`
1. AI client calls `resources/read` with `uri: "products://catalog"`
2. Flogo routes to `Product_Catalog_Resource` flow
3. Flow returns `textResourceContents` array with one entry: `mimeType: application/json`, `text: <full catalog JSON>`
4. AI client caches this in its context — no more tool calls needed for product lookups in this session

### Resource read — `customers://{id}/profile`
1. AI client calls `resources/read` with `uri: "customers://3/profile"`
2. Flogo MCP trigger extracts `id=3` from the URI template and passes it in `arguments`
3. `Customer_Profile_Resource` flow calls `GET http://localhost:18080/customers/3`
4. Returns the single customer record as `textResourceContents` with `uri: "customers://3/profile"`

### Prompt invocation — `analyze_customer_sales`
1. AI client calls `prompts/get` with `name: analyze_customer_sales`, `arguments: {customer_name: "Alice Johnson", period: "Q1 2025"}`
2. Flogo routes to `Analyze_Customer_Sales_Prompt` flow
3. Flow constructs a `messages` array with one `user` role entry — a 6-requirement analysis brief personalised with the customer name and period
4. Returns `{description: "Deep sales analysis for Alice Johnson — Q1 2025", messages: [...]}`
5. AI client inserts these messages as the conversation opener and begins analysis using the available tools

---

## Key Differences from Base Customer360

| | Customer360 | Customer360WithPromptsAndResources |
|---|---|---|
| **Handler types** | Tools only | Tools + Resources + Prompts |
| **Product data access** | Tool call every time | Static Resource — read once, cached |
| **Sales overview** | Tool call + LLM aggregation | Static Resource — pre-aggregated |
| **Single customer lookup** | Tool call + client-side filter | Dynamic Resource — URI-addressed |
| **Analysis tasks** | User writes prompt manually | Server-managed Prompt templates |
| **Port** | 9091 | 9092 (runs alongside base sample) |
