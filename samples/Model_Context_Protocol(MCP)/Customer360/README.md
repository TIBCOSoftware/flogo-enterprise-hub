# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® Model Context Protocol(MCP) Customer 360 Sample

## Overview

This sample demonstrates how to use **TIBCO Flogo® Connector for Model Context Protocol (MCP)** to expose **Customer 360 data** — including **customers**, **products**, and **sales** — using the **Model Context Protocol (MCP)**. Once deployed, the Flogo MCP Server acts as an intelligent data orchestrator, enabling **AI agents** to query the data using **natural language (NLP)** without requiring any manual orchestration logic from the user.

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

- TIBCO Flogo® Extension for Visual Studio Code 1.3.2 and above
- Any AI agent client capable of interacting with MCP Servers like Claude Desktop, GitHub Copilot etc


## Import the sample apps in the Workspace
  Import `CustProdSaleAPI.flogo` and `Customer360MCPServer.flogo` apps in VS Code.

  If you want to run the MCP Server over **HTTPS (TLS)**, import `Customer360MCPServerTls.flogo` instead of (or in addition to) `Customer360MCPServer.flogo`.
   
## Understanding the configuration
  - CustProdSaleAPI.flogo app is a REST API server which will return dummy customers, products, sales data.
  - Customer360MCPServer.flogo app is a FLOGO MCP server app (HTTP) which will expose these customers, products, sales data as MCP server tools to AI Agents.
  - Customer360MCPServerTls.flogo app is the TLS/HTTPS variant of the MCP server.
   
<img width="1377" height="577" alt="Screenshot 2025-08-01 at 12 48 56 AM" src="https://github.com/user-attachments/assets/43c03f72-d890-4bf0-a3a7-816c719f9336" />

<img width="1322" height="588" alt="Screenshot 2025-08-01 at 12 49 20 AM" src="https://github.com/user-attachments/assets/2885b657-0b45-49ab-b3e3-465894eece6d" />

## Run the application
  - Run CustProdSaleAPI.flogo app from VsCode which will start the API server and you can access these endpoints - http://localhost:18080/products, http://localhost:18080/customers, http://localhost:18080/sales
  - Make sure to check and update the app property CustInvokeRESTServiceURL, ProdInvokeRESTServiceURL, SaleInvokeRESTServiceURL in the MCP server app you are running (`Customer360MCPServer.flogo` or `Customer360MCPServerTls.flogo`) to point to url where your CustProdSaleAPI flogo app is running.
  - Run `Customer360MCPServer.flogo` app from VsCode which will start FLOGO MCP Server over HTTP at http://localhost:9091/mcp.
  - If you want to run the MCP server over HTTPS (TLS), run `Customer360MCPServerTls.flogo` instead. When TLS is enabled, the MCP endpoint will be https://localhost:9091/mcp.
  - You can configure this MCP Server url with Claude Desktop or GitHub Copilot in VS Code and send querries in natural language and get the response as shown below.
  - You can send a query like "Show me sales for Q1 2025" or "List customer names who have purchased more than 2 products and their details" and you will get the result in AI Agent as shown below.
  - As you can see, you dont need to write any specific business logic to query data which spans across different tools like customer, product, sales

## 🔐 TLS (HTTPS) support for Agentic AI

By default, `Customer360MCPServer.flogo` runs the Flogo MCP Server over **HTTP**.

If you want to run the MCP Server over **HTTPS (TLS)** (recommended when using authentication, or when your AI agent client requires secure transport), use `Customer360MCPServerTls.flogo` and configure the MCP Server with a certificate + private key.

### Configure TLS certificate and private key

In your Flogo MCP Server app configuration (Trigger/Settings), provide:

- **Server Certificate** (one of the following):
  - **File path (URI)** prefixed with `file://`
    - Example: `file:///path/to/cert.pem`
  - **Base64-encoded certificate value**
    - Example: `MIIDXTCCAkWgAwIBAgIJALa...` (base64-encoded value)
- **Server Private Key** (one of the following):
  - **File path (URI)** prefixed with `file://`
    - Example: `file:///path/to/privatekey.pem`
  - **Base64-encoded private key value**
    - Example: `MIIEvQIBADANBgkqhkiG9w0BAQE...` (base64-encoded value)

> Notes
> - The `file://` form should point to a readable file on the machine where the MCP Server is running.
> - For the base64 form, use the base64-encoded file contents of the certificate/key you would otherwise provide via `file://`.
> - **Never commit real private keys to public GitHub repos.** For demos/tests, use disposable keys and rotate them frequently.

Once TLS is enabled, your MCP endpoint will be:

- `https://localhost:9091/mcp`

### Authentication (API Key / JWT)

If **Authentication Type** is set to **API Key** or **JWT Token**, you must also provide an **authentication secret**.

- **Authentication Type**: `None` | `API Key` | `JWT Token`
- **Secret**: a shared secret used to validate the API key or to verify JWT signatures (for example, HS256)

#### JWT token requirements (recommended defaults)

When using JWT, generate tokens that include:

- `exp` (expiration) — required for safe testing
- `iat` (issued-at)
- scopes (either `scope` as a space-delimited string like `"read write"` or `scopes` as an array like `["read","write"]`, depending on your validation rules)

### Client-side note (VS Code / Claude Desktop)

When you use a self-signed or privately issued certificate, your agent client must be able to **trust** it. If your client fails with a generic network error (for example, `fetch failed`), the most common cause is TLS trust validation.

Typical fixes include:

- Import the issuing CA / server certificate into your OS trust store (recommended), or
- Configure your client to use the server certificate/CA explicitly (if supported by that client).

<img width="1663" height="846" alt="Screenshot 2025-08-01 at 12 43 04 AM" src="https://github.com/user-attachments/assets/7b3d6c5b-8956-4dfb-bb31-f3df865c300a" />

  - 
<img width="1623" height="845" alt="Screenshot 2025-08-01 at 12 40 43 AM" src="https://github.com/user-attachments/assets/196f5119-b69e-4a80-87d8-f99101950e53" />

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

> If you are running the TLS sample (`Customer360MCPServerTls.flogo`), update the MCP URL to `https://localhost:9091/mcp`.

> You would also need to install npm and mcp-remote package in order for Claude Desktop to connect to MCP server.
