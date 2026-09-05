# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® 3 Model Context Protocol(MCP) Customer 360 Sample

## Overview

This sample demonstrates how to use **TIBCO Flogo® 3 Connector for Model Context Protocol (MCP)** to expose **Customer 360 data** — including **customers**, **products**, and **sales** — using the **Model Context Protocol (MCP)**. Once deployed, the Flogo MCP Server acts as an intelligent data orchestrator, enabling **AI agents** to query the data using **natural language (NLP)** without requiring any manual orchestration logic from the user.

## ✨ Key Features

- 🧩 **Expose business data as MCP tools**  
  Provides access to customer, product, and sales data

- 🤖 **NLP-ready interface for AI agents**  
  Seamless integration with AI Agents like Claude Desktop or GitHub Copilot in VS Code to issue natural language queries

- 🔁 **Automatic orchestration**  
  No need to write or manage orchestration logic — **Flogo MCP Server** handles it for you

- 🗃️ **Prebuilt sample datasets**  
  Includes mock data for sales, customer profiles, and product purchases

- 📊 **Supports business-centric queries**, like:
  - _"Show me sales for Q1 2025"_
  - _"List customer names who have purchased more than 2 products and their details"_

## 🚀 Getting Started

### Prerequisites

- TIBCO Flogo® 3.0.0 or later
- Any AI agent client capable of interacting with MCP Servers like Claude Desktop, GitHub Copilot etc

## The sample apps in the Workspace

This sample contains two Flogo 3 projects — each is a folder containing `app.fgmd`:

- `CustomersProductsSalesAPI` — a REST API server which will return dummy customers, products, sales data.
- `Customer360MCPServer` — a FLOGO MCP server app (HTTP) which will expose these customers, products, sales data as MCP server tools to AI Agents.

If you want to run the MCP Server over **HTTPS (TLS) with Authentication**, see the [Customer360WithAuth](../Customer360WithAuth/README.md) sample.


## Setup & Run

Start the REST API backend app (`CustomersProductsSalesAPI`) first, then the MCP server app (`Customer360MCPServer`).

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `CustomersProductsSalesAPI` and `Customer360MCPServer`.
2. Open each app's `.fgprops` file and set the App Properties for your environment (see [App Properties](#app-properties)) — in the `Customer360MCPServer` app set `CustInvokeRESTServiceURL` / `ProdInvokeRESTServiceURL` / `SaleInvokeRESTServiceURL` to point at the running `CustomersProductsSalesAPI` REST API app.
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select an app module → right-click → **Run As Executable**. The native binary is produced in that app's `bin/` folder and logs stream to the integrated terminal.
   - Run `CustomersProductsSalesAPI` first. This starts the API server and exposes these endpoints:
     - `GET http://localhost:18080/customers` — returns all customers
     - `GET http://localhost:18080/products` — returns all products
     - `GET http://localhost:18080/sales` — returns all sales
     - `GET http://localhost:18080/customers/:id` — returns a single customer by ID (also used by the [Customer360WithPromptsAndResources](../Customer360WithPromptsAndResources/README.md) sample)
   - Then run `Customer360MCPServer`. This starts the FLOGO MCP Server over HTTP at `http://localhost:9091/mcp`.
5. Configure the MCP Server url `http://localhost:9091/mcp` with Claude Desktop or GitHub Copilot in VS Code and send queries in natural language (see the [Note](#note) below for the `claude_desktop_config.json` snippet). You can send a query like _"Show me sales for Q1 2025"_ or _"List customer names who have purchased more than 2 products and their details"_ and you will get the result in the AI Agent as shown below. As you can see, you don't need to write any specific business logic to query data which spans across different tools like customer, product, sales.

> For the **HTTPS (TLS) with Authentication** variant, see the [Customer360WithAuth](../Customer360WithAuth/README.md) sample.

## App Properties

Set these in each app's `.fgprops` file before running:

- **`CustomersProductsSalesAPI`**
  - `EntityAPI.HTTPPort` — the HTTP port the REST API server listens on (default `18080`).
- **`Customer360MCPServer`**
  - `MCPServer.PORT` — the port the MCP Server listens on (default `9091`).
  - `CustInvokeRESTServiceURL` — URL where the `CustomersProductsSalesAPI` app serves customers (default `http://localhost:18080/customers`).
  - `ProdInvokeRESTServiceURL` — URL where the `CustomersProductsSalesAPI` app serves products (default `http://localhost:18080/products`).
  - `SaleInvokeRESTServiceURL` — URL where the `CustomersProductsSalesAPI` app serves sales (default `http://localhost:18080/sales`).

Make sure to check and update the `CustInvokeRESTServiceURL`, `ProdInvokeRESTServiceURL`, `SaleInvokeRESTServiceURL` app properties in the `Customer360MCPServer` app to point to the url where your `CustomersProductsSalesAPI` app is running.

## 🔐 TLS (HTTPS) with Authentication

For the **HTTPS (TLS) + Authentication** variant of this sample, see the [Customer360WithAuth](../Customer360WithAuth/README.md) sample which uses the `Customer360MCPServerWithAuth` app.

<img width="1663" height="846" alt="Screenshot 2025-08-01 at 12 43 04 AM" src="https://github.com/user-attachments/assets/7b3d6c5b-8956-4dfb-bb31-f3df865c300a" />

  - 
<img width="1623" height="845" alt="Screenshot 2025-08-01 at 12 40 43 AM" src="https://github.com/user-attachments/assets/196f5119-b69e-4a80-87d8-f99101950e53" />

### Note

> **Note:** In order to run the query in Claude Desktop, you will need to configure MCP Server url in > claude_desktop_config.json like below - 

```
{
  "mcpServers": {
    "FLOGO:CustomerProductSalesData": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:9091/mcp"]
    }
  }
}
```

> You would also need to install npm and mcp-remote package in order for Claude Desktop to connect to MCP server.
