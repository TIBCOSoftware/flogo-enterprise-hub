# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® MCP Customer 360 — TLS with Authentication Sample

## Overview

This sample demonstrates how to run the **TIBCO Flogo® MCP Customer 360 Server** over **HTTPS (TLS)** with **JWT Token authentication**. It exposes **Customer 360 data** — including **customers**, **products**, and **sales** — as MCP tools, secured with TLS encryption and token-based authentication.

This is the secure variant of the [Customer360MCPServer](../Customer360/README.md) sample. Use this when:
- Your AI agent client requires a **secure (HTTPS) transport**, or
- You want to **restrict access** to the MCP server using **JWT Token** or **API Key** authentication.

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

- TIBCO Flogo® Extension for Visual Studio Code 2.26.1 and above
- Any AI agent client capable of interacting with MCP Servers (Claude Desktop, GitHub Copilot, etc.)
- A TLS certificate and private key (self-signed is fine for local testing)

## Import the sample apps in the Workspace

Import `Customer360MCPServerWithAuth.flogo` in VS Code.

You will also need the REST API backend app — import `CustProdSaleAPI.flogo` from the [Customer360](../Customer360/) folder.

## Understanding the configuration

- **CustProdSaleAPI.flogo** — REST API server that returns dummy customers, products, and sales data.
- **Customer360MCPServerWithAuth.flogo** — Flogo MCP Server that exposes customers, products, and sales as MCP tools over **HTTPS** with **JWT Token authentication**.

### App Properties

| Property | Default Value | Description |
|---|---|---|
| `MCPServer.PORT` | `9091` | Port for the MCP Server |
| `MCPServer.SERVER_CERT` | `your_server_certificate` | TLS server certificate (file URI or base64) |
| `MCPServer.SERVER_PRIVATE_KEY` | `your_server_private_key` | TLS private key (file URI or base64) |
| `MCPServer.AUTH_JWT_Token` | `JWT Token` | Authentication type (`None`, `API Key`, `JWT Token`) |
| `MCPServer.SECRET` | _(encrypted)_ | Shared secret for token validation |
| `CustInvokeRESTServiceURL` | `http://localhost:18080/customers` | Backend customers endpoint |
| `ProdInvokeRESTServiceURL` | `http://localhost:18080/products` | Backend products endpoint |
| `SaleInvokeRESTServiceURL` | `http://localhost:18080/sales` | Backend sales endpoint |

## 🔐 Configure TLS (HTTPS)

In your Flogo MCP Server app configuration (Trigger / Settings), provide:

- **Server Certificate** — one of the following:
  - **File path (URI)** prefixed with `file://`  
    Example: `file:///path/to/cert.pem`
  - **Base64-encoded certificate value**  
    Example: `MIIDXTCCAkWgAwIBAgIJALa...`

- **Server Private Key** — one of the following:
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

Set the **Authentication Type** and **Secret** in the trigger settings (or via app properties):

- **Authentication Type**: `None` | `API Key` | `JWT Token`
- **Secret**: the shared secret used to validate the API key or to verify JWT signatures (e.g., HS256)

### JWT Token requirements (recommended defaults)

When using JWT, generate tokens that include:

- `exp` (expiration) — required for safe testing
- `iat` (issued-at)
- scopes — either:
  - `scope` as a space-delimited string: `"read write"`, or
  - `scopes` as an array: `["read", "write"]`

## Run the application

1. Run **CustProdSaleAPI.flogo** from VS Code. This starts the REST API backend at:
   - `http://localhost:18080/customers`
   - `http://localhost:18080/products`
   - `http://localhost:18080/sales`

2. Update the app properties `CustInvokeRESTServiceURL`, `ProdInvokeRESTServiceURL`, and `SaleInvokeRESTServiceURL` in **Customer360MCPServerWithAuth.flogo** to point to where your `CustProdSaleAPI` app is running.

3. Configure `MCPServer.SERVER_CERT` and `MCPServer.SERVER_PRIVATE_KEY` with your certificate and private key.

4. Configure `MCPServer.AUTH_JWT_Token` and `MCPServer.SECRET` with your preferred auth type and secret.

5. Run **Customer360MCPServerWithAuth.flogo** from VS Code. The Flogo MCP Server will start over HTTPS at:
   ```
   https://localhost:9091/mcp
   ```

6. Configure this MCP Server URL in your AI agent client (Claude Desktop or GitHub Copilot in VS Code) and send queries in natural language.

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
