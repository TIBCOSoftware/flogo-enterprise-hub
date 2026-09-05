# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® 3 MCP Customer 360 — TLS with Authentication Sample

## Overview

This sample demonstrates how to run the **TIBCO Flogo® 3 MCP Customer 360 Server** over **HTTPS (TLS)** with **JWT Token authentication**. It exposes **Customer 360 data** — including **customers**, **products**, and **sales** — as MCP tools, secured with TLS encryption and token-based authentication.

This is the secure variant of the [Customer360](../Customer360/README.md) MCP Server sample. Use this when:
- Your AI agent client requires a **secure (HTTPS) transport**, or
- You want to **restrict access** to the MCP server using **JWT Token** or **API Key** authentication.

This MCP server calls the **`CustomersProductsSalesAPI`** REST API backend from the [Customer360](../Customer360/README.md) sample, so you will run that backend from the sibling sample and only the TLS MCP server (`Customer360MCPServerTls`) from this folder.

## ✨ Key Features

- 🔐 **HTTPS (TLS) transport**  
  All MCP traffic is encrypted using TLS — configure with a certificate and private key

- 🛡️ **JWT Token / API Key authentication**  
  Only clients presenting a valid token can invoke MCP tools

- 🧩 **Expose business data as MCP tools**  
  Provides access to customer, product, and sales data via three tools: `GetCustomers`, `GetProducts`, `GetSales`

- 🤖 **NLP-ready interface for AI agents**  
  Seamless integration with AI Agents like Claude Desktop or GitHub Copilot in VS Code

- 🔁 **Automatic orchestration**  
  No need to write or manage orchestration logic — **Flogo MCP Server** handles it for you

## 🚀 Getting Started

### Prerequisites

- TIBCO Flogo® 3.0.0 or later
- Any AI agent client capable of interacting with MCP Servers (Claude Desktop, GitHub Copilot, etc.)
- A TLS certificate and private key (self-signed is fine for local testing)

## The sample apps in the Workspace

This sample folder contains one Flogo 3 project — a folder containing `app.fgmd`:

- `Customer360MCPServerTls` — a Flogo MCP Server app that exposes customers, products, and sales as MCP tools over **HTTPS** with **JWT Token authentication**.

It depends on the REST API backend from the sibling sample:

- `CustomersProductsSalesAPI` — a REST API server that returns dummy customers, products, and sales data. This lives in the [Customer360](../Customer360/README.md) sample and must be running before you start the TLS MCP server.

## Setup & Run

Start the REST API backend app (`CustomersProductsSalesAPI`, from the [Customer360](../Customer360/README.md) sample) first, then the TLS MCP server app (`Customer360MCPServerTls`) from this folder.

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `Customer360MCPServerTls`. (This MCP server calls the `CustomersProductsSalesAPI` REST backend from the [Customer360](../Customer360/README.md) sample — start that first.)
2. Open the app's `.fgprops` file and set the App Properties for your environment (see [App Properties](#app-properties) below) — the REST backend URLs (`CustInvokeRESTServiceURL` / `ProdInvokeRESTServiceURL` / `SaleInvokeRESTServiceURL`), the TLS keystore/cert paths (`MCPServer.SERVER_CERT` / `MCPServer.SERVER_PRIVATE_KEY`), the JWT settings (`MCPServer.AUTH_JWT_Token` / `MCPServer.SECRET`), and the MCP server port (`MCPServer.PORT`).
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. The native binary is produced in the app's `bin/` folder and logs stream to the integrated terminal.
   - Run `CustomersProductsSalesAPI` (from the [Customer360](../Customer360/README.md) sample) first. This starts the REST API backend at:
     - `http://localhost:18080/customers`
     - `http://localhost:18080/products`
     - `http://localhost:18080/sales`
   - Then run `Customer360MCPServerTls` from this folder. The Flogo MCP Server starts over **HTTPS** at:
     ```
     https://localhost:9091/mcp
     ```
5. Configure this MCP Server URL in your AI agent client (Claude Desktop or GitHub Copilot in VS Code), include your **JWT token** in the authorization header, and send queries in natural language (see [Connect with AI Agents](#connect-with-ai-agents) below for the `claude_desktop_config.json` snippet and the client-side TLS trust steps).

## App Properties

Set these in the `Customer360MCPServerTls` app's `.fgprops` file before running:

| Property | Default Value | Description |
|---|---|---|
| `MCPServer.PORT` | `9091` | Port for the MCP Server |
| `CustInvokeRESTServiceURL` | `http://localhost:18080/customers` | Backend customers endpoint (served by `CustomersProductsSalesAPI`) |
| `ProdInvokeRESTServiceURL` | `http://localhost:18080/products` | Backend products endpoint (served by `CustomersProductsSalesAPI`) |
| `SaleInvokeRESTServiceURL` | `http://localhost:18080/sales` | Backend sales endpoint (served by `CustomersProductsSalesAPI`) |
| `MCPServer.SERVER_CERT` | `your_server_certificate` | TLS server certificate (file URI or base64) |
| `MCPServer.SERVER_PRIVATE_KEY` | `your_server_private_key` | TLS private key (file URI or base64) |
| `MCPServer.AUTH_JWT_Token` | `JWT Token` | Authentication type (`None`, `API Key`, `JWT Token`) |
| `MCPServer.SECRET` | _(encrypted)_ | Shared secret for token validation |

Make sure to check and update the `CustInvokeRESTServiceURL`, `ProdInvokeRESTServiceURL`, and `SaleInvokeRESTServiceURL` app properties to point to the URL where your `CustomersProductsSalesAPI` app (from the [Customer360](../Customer360/README.md) sample) is running.

## 🔐 Configure TLS (HTTPS)

TLS is enabled on the MCP Server trigger for this sample. Provide the certificate and private key via the `MCPServer.SERVER_CERT` and `MCPServer.SERVER_PRIVATE_KEY` app properties, using one of the following forms:

- **Server Certificate** (`MCPServer.SERVER_CERT`) — one of:
  - **File path (URI)** prefixed with `file://`  
    Example: `file:///path/to/cert.pem`
  - **Base64-encoded certificate value**  
    Example: `MIIDXTCCAkWgAwIBAgIJALa...`

- **Server Private Key** (`MCPServer.SERVER_PRIVATE_KEY`) — one of:
  - **File path (URI)** prefixed with `file://`  
    Example: `file:///path/to/privatekey.pem`
  - **Base64-encoded private key value**  
    Example: `MIIEvQIBADANBgkqhkiG9w0BAQE...`

> **Notes**
> - The `file://` form should point to a readable file on the machine where the MCP Server is running.
> - For the base64 form, use the base64-encoded contents of the certificate/key file.
> - **Never commit real private keys to public GitHub repos.** For demos/tests, use disposable keys and rotate them frequently.

Once TLS is enabled, your MCP endpoint will be:

```
https://localhost:9091/mcp
```

## 🛡️ Configure Authentication (JWT Token / API Key)

Set the **Authentication Type** and **Secret** via the app properties:

- **Authentication Type** (`MCPServer.AUTH_JWT_Token`): `None` | `API Key` | `JWT Token`
- **Secret** (`MCPServer.SECRET`): the shared secret used to validate the API key or to verify JWT signatures (e.g., HS256)

### JWT Token requirements (recommended defaults)

When using JWT, generate tokens that include:

- `exp` (expiration) — required for safe testing
- `iat` (issued-at)
- scopes — either:
  - `scope` as a space-delimited string: `"read write"`, or
  - `scopes` as an array: `["read", "write"]`

## Connect with AI Agents

### Claude Desktop

Add the following to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "FLOGO:CustomerProductSalesData": {
      "command": "npx",
      "args": ["mcp-remote", "https://localhost:9091/mcp", "--header", "Authorization: Bearer YOUR_JWT_TOKEN"]
    }
  }
}
```

> You will need npm and the `mcp-remote` package installed for Claude Desktop to connect to the MCP server.

### GitHub Copilot (VS Code)

Configure the MCP Server URL `https://localhost:9091/mcp` in your VS Code MCP settings and include your JWT token in the authorization header.

### Client-side TLS trust

When using a self-signed or privately issued certificate, your AI agent client must be able to **trust** it. If the client fails with a generic network error (e.g., `fetch failed`), the most common cause is TLS trust validation.

Typical fixes:
- Import the issuing CA / server certificate into your OS trust store (recommended), or
- Configure your client to use the server certificate/CA explicitly (if supported by that client).

## Example Queries

Once connected, you can ask your AI agent questions like:

- _"Show me sales for Q1 2025"_
- _"List customer names who have purchased more than 2 products and their details"_
- _"What are the top-selling products?"_

The Flogo MCP Server will automatically orchestrate calls across the `GetCustomers`, `GetProducts`, and `GetSales` tools — no manual business logic required.
