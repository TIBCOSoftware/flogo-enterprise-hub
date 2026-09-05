# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® 3 MCP Client Activity — Gateway Aggregator Sample

## Overview

This sample demonstrates how to use the **MCP Client Activity** (`#mcpclient`) in a TIBCO Flogo® 3 flow to connect to remote MCP servers and invoke their tools. The app acts as an **MCP Gateway** — it is itself an MCP server that clients connect to, and internally it uses `#mcpclient` activities to call backend MCP servers and return aggregated results.

This is a common enterprise pattern: a single gateway MCP server provides a unified interface to clients (VS Code, Claude Desktop) while orchestrating calls to multiple backend microservices behind the scenes.

> **MCP Client:** The MCP Client Activity (`#mcpclient`) and MCP Client OAuth2 Configuration are MCP connector features available in TIBCO Flogo® 3.

---

## Key Features

- **MCP Client Activity** — `#mcpclient` activity allows Flogo flows to call tools on any remote MCP server
- **Gateway Pattern** — the aggregator is itself an MCP server, making it accessible from VS Code, Claude Desktop, or any MCP client
- **Streamable-HTTP Transport** — connects to remote servers using the standard MCP Streamable-HTTP transport
- **Multiple Server Endpoints** — a single app calls tools on different backend MCP servers
- **Multiple Auth Modes** — supports `None`, `Static Token`, and `OAuth2` (via connection) authentication
- **Self-Contained** — all three apps (gateway + 2 backends) are included in this sample folder

---

## Architecture

```
User (VS Code / Claude Desktop)
            │
            ▼
┌──────────────────────────────────────────────┐
│  MCPClientAggregator (port 9100)             │
│  MCP Server — http://localhost:9100/mcp      │
│                                              │
│  Tool: lookup_customer                       │
│    └─► mcpclient → CustomerService (9098)    │
│                                              │
│  Tool: lookup_inventory                      │
│    └─► mcpclient → InventoryService (9099)   │
└──────────────────────────────────────────────┘
            │                    │
            ▼                    ▼
┌────────────────────┐  ┌─────────────────────┐
│ CustomerService    │  │ InventoryService     │
│ MCP Server         │  │ MCP Server           │
│ port 9098          │  │ port 9099            │
│                    │  │                      │
│ get_customer_      │  │ get_product_         │
│   profile          │  │   inventory          │
└────────────────────┘  └─────────────────────┘
```

**How it works:**

1. User connects their MCP client (VS Code, Claude Desktop) to the **Aggregator** at `localhost:9100/mcp`
2. User asks a question like "Look up customer CUST-1001"
3. The Aggregator's `lookup_customer` tool receives the request
4. The flow uses a `#mcpclient` activity to call the **CustomerService** MCP server at `localhost:9098/mcp`
5. The backend server returns the customer profile
6. The Aggregator logs the result and returns it to the user

---

## MCP Client Activity Configuration

Each `#mcpclient` activity is configured with these key settings:

| Setting | Description | Example |
|---|---|---|
| `clientName` | Name identifying this client connection | `CustomerServiceClient` |
| `clientVersion` | Client version string | `1.0.0` |
| `transportType` | MCP transport protocol | `Streamable-HTTP` |
| `endpoint` | URL of the remote MCP server | `http://localhost:9098/mcp` |
| `authMode` | Authentication mode | `None`, `Static Token`, or `OAuth2` |
| `staticToken` | Bearer token (when authMode = Static Token) | `SECRET:...` |
| `authorizationConn` | OAuth2 connection ref (when authMode = OAuth2) | Connection name |
| `timeout` | Request timeout in seconds | `30` |
| `toolName` | Name of the tool to invoke on the remote server | `get_customer_profile` |
| `responseType` | How to parse the response | `JSON` or `Text` |

### Example Activity Configuration

```json
{
  "activity": {
    "ref": "#mcpclient",
    "settings": {
      "clientName": "CustomerServiceClient",
      "clientVersion": "1.0.0",
      "transportType": "Streamable-HTTP",
      "endpoint": "http://localhost:9098/mcp",
      "authMode": "None",
      "timeout": 30,
      "toolName": "get_customer_profile",
      "responseType": "JSON"
    },
    "input": {
      "toolArguments": {
        "mapping": {
          "customer_id": "=$flow.arguments.customer_id"
        }
      }
    }
  }
}
```

---

## Authentication Modes

### None

No authentication — used for local development or trusted network servers:

```json
{
  "authMode": "None"
}
```

### Static Token

Bearer token authentication — the token is sent in the `Authorization` header:

```json
{
  "authMode": "Static Token",
  "staticToken": "your-bearer-token-here"
}
```

### OAuth2 (via Connection)

For production environments, configure an **MCP Client OAuth2 Connection** with Client Credentials or Authorization Code grant:

```json
{
  "authMode": "OAuth2",
  "authorizationConn": "MyOAuth2Connection"
}
```

**OAuth2 Connection Settings:**

| Setting | Description |
|---|---|
| Grant Type | `Client Credentials` or `Authorization Code` |
| Token URL | OAuth2 token endpoint (e.g. `https://auth.example.com/oauth/token`) |
| Client ID | OAuth2 client identifier |
| Client Secret | OAuth2 client secret |
| Scopes | Space-separated list of requested scopes |
| Authorization URL | (Authorization Code only) Authorization endpoint |
| Redirect URL | (Authorization Code only) Callback URL |

---

## Tool Arguments & Response

### Passing Tool Arguments

Tool arguments are passed via the `toolArguments` input mapping. Arguments from the incoming MCP request are forwarded to the backend server:

```json
{
  "input": {
    "toolArguments": {
      "mapping": {
        "customer_id": "=$flow.arguments.customer_id"
      }
    }
  }
}
```

### Accessing Results

Access the MCP client activity output in downstream activities:

```
$activity[CallCustomerService].result     — the tool's JSON result
$activity[CallCustomerService].isError    — boolean indicating if the call failed
```

---

## Getting Started

### Prerequisites

- TIBCO Flogo® **3.0.0** or later
- An MCP-capable client (e.g. GitHub Copilot in VS Code, Claude Desktop)

## Setup & Run

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `CustomerServiceMCPServer`, `InventoryMCPServer`, `MCPClientAggregator`.
2. Open each app's `.fgprops` file and set the App Properties for your environment (see [App Properties](#app-properties) below) — backend MCP server URLs, MCP server ports.
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select an app module → right-click → **Run As Executable**. The native binary is produced in that app's `bin/` folder and logs stream to the integrated terminal. Start the two backend MCP servers first (`CustomerServiceMCPServer` at `http://localhost:9098/mcp`, then `InventoryMCPServer` at `http://localhost:9099/mcp`), then `MCPClientAggregator` at `http://localhost:9100/mcp`. The aggregator will connect to the backend servers when tools are invoked.
5. Invoke and verify — connect your MCP client to the **Aggregator** (port 9100), not the backend servers directly, and route requests through the gateway to the backends:

   **VS Code (`mcp.json`):**
   ```json
   {
     "servers": {
       "MCPClientAggregator": {
         "type": "http",
         "url": "http://localhost:9100/mcp"
       }
     }
   }
   ```

   **Claude Desktop (`claude_desktop_config.json`):**
   ```json
   {
     "mcpServers": {
       "MCPClientAggregator": {
         "command": "npx",
         "args": ["mcp-remote", "http://localhost:9100/mcp"]
       }
     }
   }
   ```

   **Try It — Example Prompts:**

   ```
   "Look up customer CUST-1001"
   ```
   → Invokes `lookup_customer` — the aggregator calls CustomerService via mcpclient and returns the profile

   ```
   "What is the inventory for product PROD-5001?"
   ```
   → Invokes `lookup_inventory` — the aggregator calls InventoryService via mcpclient and returns inventory details

   Check the Flogo console logs for the aggregator to see the mcpclient responses:

   ```
   [LookupCustomer] CustomerService response: { ... customer data ... }
   [LookupInventory] InventoryService response: { ... inventory data ... }
   ```

---

## Included Apps

### CustomerServiceMCPServer (port 9098)

A simple backend MCP server with one tool:

| Tool | Description |
|---|---|
| `get_customer_profile` | Returns customer profile (name, email, phone, membership tier, address) |

### InventoryMCPServer (port 9099)

A simple backend MCP server with one tool:

| Tool | Description |
|---|---|
| `get_product_inventory` | Returns product inventory (name, SKU, stock quantity, price, warehouse) |

### MCPClientAggregator (port 9100)

The gateway MCP server that clients connect to:

| Tool | Backend Call | Description |
|---|---|---|
| `lookup_customer` | mcpclient → CustomerService (9098) | Proxies customer lookup to the backend |
| `lookup_inventory` | mcpclient → InventoryService (9099) | Proxies inventory lookup to the backend |

---

## Adapting This Sample for Production

The backend servers use `noop` + `actreturn` activities with mock data. To make this production-ready:

| Change | How |
|---|---|
| Connect to real backends | Change `CustomerService.ENDPOINT` and `InventoryService.ENDPOINT` properties to point to your actual MCP servers |
| Add more backend calls | Add additional `#mcpclient` activities in the aggregator flows |
| Use OAuth2 authentication | Create an MCP Client OAuth2 Connection and set `authMode: "OAuth2"` on the mcpclient activity |
| Use Static Token auth | Set `authMode: "Static Token"` and provide the bearer token |
| Add error handling | Check `$activity[...].isError` and return appropriate error responses |
| Secure the gateway | Set `authType` on the aggregator's MCP server trigger to require JWT tokens |

---

## App Properties

Set these in each app's `.fgprops` file before running.

### MCPClientAggregator

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9100` | HTTP port the gateway MCP server listens on |
| `CustomerService.ENDPOINT` | `http://localhost:9098/mcp` | URL of the CustomerService MCP server |
| `InventoryService.ENDPOINT` | `http://localhost:9099/mcp` | URL of the InventoryService MCP server |

### CustomerServiceMCPServer

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9098` | HTTP port the customer service listens on |

### InventoryMCPServer

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9099` | HTTP port the inventory service listens on |

---

## Related Resources

- [MCP Specification — Tools](https://modelcontextprotocol.io/specification/2025-03-26/server/tools/)
- [TIBCO Flogo® MCP Connector Documentation](https://docs.tibco.com)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [MCP JWT Scope Access Control](../MCP_JWT_Scope_Access_Control/README.md) — scope-based access and tokenInfo
- [MCP Structured Content & Annotations](../MCP_Structured_Content_And_Annotations/README.md) — structured content and audience annotations
