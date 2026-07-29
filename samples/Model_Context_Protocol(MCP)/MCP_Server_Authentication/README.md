# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® MCP Server — Authentication Guide

## Overview

The **TIBCO Flogo® Connector for Model Context Protocol (MCP)** provides built-in authentication to secure your MCP servers. When configuring an MCP Server trigger, you can select one of **four authentication types** — ranging from no authentication for local development, to full OAuth 2.0 integration with external identity providers for production deployments.

| Authentication Type | Best For | Scope Enforcement | tokenInfo Claims |
|---|---|---|---|
| **None** | Local development, prototyping | No | No |
| **API Key** | Simple server-to-server, internal services | No | No |
| **JWT Token** | Service mesh, multi-tenant, role-based access | Yes | Yes |
| **OAuth 2.0** | Production, external IdP integration (Keycloak, Auth0, Azure AD) | Yes (+ server-level scopes) | Yes |

---

## Authentication Types at a Glance

```
                        ┌──────────────────────────────────────┐
                        │     Flogo MCP Server Trigger          │
                        │                                       │
                        │   authType: [None | API Key |         │
                        │              JWT Token | OAuth 2.0]   │
                        └──────────────────────────────────────┘
                                         │
         ┌───────────────┬───────────────┼───────────────┐
         ▼               ▼               ▼               ▼
   ┌───────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐
   │   None    │  │  API Key   │  │ JWT Token  │  │  OAuth 2.0 │
   │           │  │            │  │            │  │            │
   │ No auth   │  │ Static key │  │ HMAC-signed│  │ JWKS-based │
   │ required  │  │ validation │  │ JWT + scope│  │ JWT + IdP  │
   └───────────┘  └────────────┘  └────────────┘  └────────────┘
```

---

## 1. None — No Authentication

### When to Use

- Local development and prototyping
- Internal networks with no external exposure
- Quick demos and proof-of-concept

### How It Works

No authentication is performed. Any client can connect to the MCP server without providing credentials. All tools, prompts, and resources are accessible to everyone.

### Configuration

| Setting | Value |
|---|---|
| `authType` | `None` |
| `authToken` | _(empty)_ |

```json
{
  "settings": {
    "serverName": "MyMCPServer",
    "serverPort": "9090",
    "serverEndpointPath": "/mcp",
    "authType": "None",
    "authToken": ""
  }
}
```

### Behavior

- No `Authorization` header required
- The `scope` field on handlers is **ignored** — all handlers are accessible
- No `tokenInfo` is populated for flows

> **Note:** Even if a handler has a `scope` value configured, it has no effect when `authType` is `None`.

---

## 2. API Key — Static Key Validation

### When to Use

- Simple server-to-server authentication
- Internal services where a shared secret is sufficient
- Environments where JWT infrastructure is not available

### How It Works

Clients must send the API key in the `Authorization: Bearer <api-key>` HTTP header. The server compares the provided key against the configured `authToken` value. If the key does not match or is missing, the server returns **HTTP 401 Unauthorized**.

### Configuration

| Setting | Value |
|---|---|
| `authType` | `API Key` |
| `authToken` | The API key value (stored encrypted) |

```json
{
  "settings": {
    "serverName": "MyMCPServer",
    "serverPort": "9090",
    "serverEndpointPath": "/mcp",
    "authType": "API Key",
    "authToken": "=$property[\"FlogoMcpServer.APIKEY\"]"
  }
}
```

The API key is stored as an encrypted app property:

```json
{
  "name": "FlogoMcpServer.APIKEY",
  "type": "string",
  "value": "SECRET:O75FH18oIPKOWA/vvSVubcSZjQ6mrNb76yCbWycvXPpq/iAVqXs+9gGP2Ko="
}
```

### Client Usage

```bash
curl -X POST https://localhost:9090/mcp \
  -H "Authorization: Bearer my-api-key" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```

### Behavior

- Authentication is binary — valid key or not
- The `scope` field on handlers is **ignored** — all authenticated clients can access all handlers
- No `tokenInfo` is populated for flows

---

## 3. JWT Token — Scope-Based Access Control

### When to Use

- Multi-tenant environments requiring role-based access
- Services where different clients need different levels of tool access
- Scenarios requiring audit logging with caller identity
- Microservice architectures with service-to-service JWT propagation

### How It Works

Clients must send a JWT token in the `Authorization: Bearer <jwt-token>` header. The server validates the token using an HMAC (HS256) shared secret, checks expiration, and enforces **per-handler scope-based access control**.

### Configuration

| Setting | Value |
|---|---|
| `authType` | `JWT Token` |
| `authToken` | Shared secret for HS256 signature verification (stored encrypted) |

```json
{
  "settings": {
    "serverName": "MyMCPServer",
    "serverPort": "9090",
    "serverEndpointPath": "/mcp",
    "authType": "JWT Token",
    "authToken": "=$property[\"FlogoMcpServer.JWT_TOKEN_SECRET\"]"
  }
}
```

### Scope-Based Access Control

Each handler (tool, prompt, or resource) can define a **Required Scope** that restricts which clients can access it:

```json
{
  "settings": {
    "handlerType": "Tool",
    "handlerName": "get_medical_records",
    "handlerDescription": "Retrieve sensitive medical history",
    "scope": "records:read"
  }
}
```

**How scope enforcement works:**

```
Client JWT token contains: scp: ["patient:read", "records:read"]
                    │
                    ▼
        ┌─────────────────────┐
        │  MCP Server checks  │
        │  token's scp/scope  │
        │  claim per handler  │
        └─────────────────────┘
                    │
    ┌───────────────┼───────────────────┐
    │               │                   │
    ▼               ▼                   ▼
┌─────────┐   ┌───────────┐   ┌──────────────┐
│ patient: │   │ records:  │   │ patient:write│
│  read    │   │   read    │   │              │
│ VISIBLE  │   │ VISIBLE   │   │   HIDDEN     │
└─────────┘   └───────────┘   └──────────────┘
```

**Scope matching rules:**

| Rule | Example |
|---|---|
| Exact match, case-sensitive | `patient:read` does NOT match `Patient:Read` |
| No prefix matching | `orders` does NOT match `orders:read` |
| No implicit parent scopes | `orders:read:sensitive` does NOT match `orders:read` |
| Empty scope = no restriction | Handler with `scope: ""` is accessible to all authenticated clients |

**Supported JWT scope claim formats:**

| Claim Name | Format | Example |
|---|---|---|
| `scp` | JSON array | `"scp": ["patient:read", "records:read"]` |
| `scope` | Space-delimited string | `"scope": "patient:read records:read"` |

**Enforcement behavior:**

- **`tools/list`** — Tools whose required scope is not in the client's token are **filtered out** (hidden). The client never sees them.
- **`tools/call`** — If a client directly calls a scoped tool without the required scope, the server returns an **access denied** error.
- **Applies to all MCP primitives** — Tools, Prompts, and Resources all support the `scope` handler setting.

### Enhanced tokenInfo Claims

When JWT Token authentication is active, the server decodes the JWT and exposes a `tokenInfo` object to flows. This enables audit logging, identity attribution, and tenant validation.

**tokenInfo schema:**

| Field | Type | Description |
|---|---|---|
| `scopes` | string[] | Array of granted scopes |
| `expiration` | number | Token expiry (Unix timestamp) |
| `iss` | string | Issuer (e.g. `https://auth.hospital.org`) |
| `sub` | string | Subject / user identifier (e.g. `dr.smith@hospital.org`) |
| `aud` | string[] | Audience |
| `name` | string | Human-readable display name |
| `email` | string | Email address |
| `given_name` | string | First name |
| `family_name` | string | Last name |
| `preferred_username` | string | Preferred username |

**Accessing tokenInfo in flows:**

Map `tokenInfo` from the handler output to the flow input:

```json
{
  "action": {
    "input": {
      "arguments": "=$.arguments",
      "httpHeaders": "=$.httpHeaders",
      "tokenInfo": "=$.tokenInfo"
    }
  }
}
```

Then use expressions like `$flow.tokenInfo.sub`, `$flow.tokenInfo.email`, `$flow.tokenInfo.name` within your flow activities.

### Example JWT Payload

```json
{
  "iss": "https://auth.hospital.org",
  "sub": "dr.smith@hospital.org",
  "aud": ["healthcare-api"],
  "name": "Dr. Sarah Smith",
  "email": "dr.smith@hospital.org",
  "scp": ["patient:read", "records:read"],
  "exp": 1893456000
}
```

### Example: Role-Based Tool Access

| Role | Scopes | Accessible Tools |
|---|---|---|
| Receptionist | `patient:read` | `get_patient_summary` |
| Doctor | `patient:read`, `records:read` | `get_patient_summary`, `get_medical_records` |
| Admin | `patient:read`, `patient:write`, `records:read`, `token:inspect` | All tools |

---

## 4. OAuth 2.0 — External Identity Provider Integration

### When to Use

- Production deployments with enterprise identity providers (Keycloak, Auth0, Azure AD, Okta)
- Environments requiring asymmetric key validation (RS256) via JWKS
- Organizations with existing OAuth 2.0 / OpenID Connect infrastructure
- Scenarios requiring issuer, audience, and server-level scope validation

### How It Works

OAuth 2.0 mode integrates with external OAuth 2.0 / OpenID Connect providers. Instead of validating tokens with a shared HMAC secret, the server fetches signing keys from a **JWKS (JSON Web Key Set)** endpoint, enabling **RS256** and other asymmetric algorithms. The server also validates the token's `iss` (issuer) and `aud` (audience) claims, and can enforce **server-level required scopes** in addition to per-handler scopes.

> **New in Flogo 2.26.6.** For a complete, runnable end-to-end example — including a Keycloak setup script, demo users, and MCP Inspector testing — see the [**MCP OAuth 2.0 Access Control**](../MCP_OAuth2_Access_Control/) sample.

### Configuration

| Setting | Description |
|---|---|
| `authType` | `OAuth 2.0` |
| `authToken` | JWT validation secret (stored encrypted) |
| `oauthIssuer` | Expected token issuer (`iss` claim) |
| `oauthJWKSURL` | JWKS endpoint URL for public key discovery |
| `oauthAudience` | Expected audience (`aud` claim) |
| `oauthAuthorizationServers` | Authorized servers (comma-separated) |
| `oauthRequiredScopes` | Server-level required scopes (minimum scopes for any request) |
| `oauthResourceURL` | Resource URL identifier |

```json
{
  "settings": {
    "serverName": "HealthcarePatientRecordsMCPServer",
    "serverPort": "8000",
    "serverType": "HTTP",
    "serverEndpointPath": "/",
    "enableTLS": true,
    "authType": "OAuth 2.0",
    "authToken": "=$property[\"FlogoMcpServer.JWT_TOKEN_SECRET\"]",
    "oauthIssuer": "https://auth.example.com/realms/demo",
    "oauthJWKSURL": "https://auth.example.com/realms/demo/protocol/openid-connect/certs",
    "oauthAudience": "http://localhost:8000",
    "oauthAuthorizationServers": "",
    "oauthRequiredScopes": "mcp:tools",
    "oauthResourceURL": "http://localhost:8000"
  }
}
```

### Two Layers of Scope Enforcement

OAuth 2.0 mode provides **two levels of scope enforcement**:

**1. Server-Level Scopes (`oauthRequiredScopes`)**

A minimum set of scopes required for **any** request to the server. If the token does not contain these scopes, the request is rejected before reaching any handler.

```
oauthRequiredScopes: "mcp:tools"
→ Every client must have at least the "mcp:tools" scope
```

**2. Handler-Level Scopes (`scope` on each handler)**

Per-tool, per-prompt, and per-resource scopes — identical to JWT Token mode. A common convention in OAuth 2.0 mode is to use a hierarchical prefix:

| Handler | Required Scope |
|---|---|
| `get_patient_summary` | `mcp:tools:patient:read` |
| `get_medical_records` | `mcp:tools:records:read` |
| `update_patient_contact` | `mcp:tools:patient:write` |
| `get_token_info` | `mcp:tools:token:inspect` |

### JWKS-Based Key Validation

Unlike JWT Token mode (which uses a shared HMAC secret), OAuth 2.0 mode fetches signing keys from the identity provider's JWKS endpoint. This supports:

- **RS256** and other asymmetric algorithms
- **Automatic key rotation** — the server discovers new keys via JWKS
- **No shared secrets** — the MCP server never needs the private signing key

```
                    Client                    Identity Provider (Keycloak/Auth0)
                      │                              │
                      │  1. Obtain token             │
                      │─────────────────────────────>│
                      │  (client_credentials /       │
                      │   authorization_code)        │
                      │<─────────────────────────────│
                      │  JWT signed with RS256       │
                      │                              │
                      │                       Flogo MCP Server
                      │                              │
                      │  2. Call tool with token      │
                      │─────────────────────────────>│
                      │                              │
                      │                 3. Fetch JWKS from oauthJWKSURL
                      │                              │──────────> IdP JWKS endpoint
                      │                              │<──────────
                      │                 4. Verify signature (RS256)
                      │                 5. Validate iss, aud, scopes
                      │                 6. Enforce handler scope
                      │                              │
                      │  Tool result                 │
                      │<─────────────────────────────│
```

### tokenInfo in OAuth 2.0

The `tokenInfo` object is populated identically to JWT Token mode, with all enhanced claims available for flows:

- `scopes`, `expiration`, `iss`, `sub`, `aud`, `name`, `email`, `given_name`, `family_name`, `preferred_username`

---

## Combining Authentication with TLS

All four authentication types can be combined with **TLS encryption** for secure transport. Enable TLS in the trigger settings:

| Setting | Description |
|---|---|
| `enableTLS` | `true` to enable HTTPS |
| `serverCertificate` | TLS certificate — file URI (`file:///path/to/cert.pem`) or base64-encoded value |
| `serverPrivateKey` | TLS private key — file URI (`file:///path/to/key.pem`) or base64-encoded value |

```json
{
  "settings": {
    "enableTLS": true,
    "serverCertificate": "=$property[\"FlogoMcpServer.SERVER_CERT\"]",
    "serverPrivateKey": "=$property[\"FlogoMcpServer.SERVER_PRIVATE_KEY\"]",
    "authType": "JWT Token",
    "authToken": "=$property[\"FlogoMcpServer.JWT_TOKEN_SECRET\"]"
  }
}
```

> **Recommendation:** Always enable TLS when using any authentication type in production to protect tokens in transit.

---

## Feature Comparison Matrix

| Feature | None | API Key | JWT Token | OAuth 2.0 |
|---|---|---|---|---|
| Authorization header required | No | Yes | Yes | Yes |
| Header format | — | `Bearer <key>` | `Bearer <jwt>` | `Bearer <oauth-jwt>` |
| Validation method | — | String comparison | HMAC (HS256) | JWKS (RS256+) |
| Handler scope enforcement | No | No | Yes | Yes |
| Server-level scope enforcement | No | No | No | Yes |
| tokenInfo available to flows | No | No | Yes | Yes |
| Token expiration check | — | — | Yes | Yes |
| External IdP integration | — | — | — | Yes (JWKS) |
| Issuer/Audience validation | — | — | — | Yes |
| Supports TLS | Yes | Yes | Yes | Yes |

---

## Choosing the Right Authentication Type

```
                        Start
                          │
                          ▼
                  ┌──────────────┐
                  │ Is this for  │──── Yes ──── Use: None
                  │ local dev /  │
                  │ prototyping? │
                  └──────┬───────┘
                         │ No
                         ▼
                  ┌──────────────┐
                  │ Do you need  │──── No ───── Use: API Key
                  │ role-based   │
                  │ access or    │
                  │ per-tool     │
                  │ scopes?      │
                  └──────┬───────┘
                         │ Yes
                         ▼
                  ┌──────────────┐
                  │ Using an     │──── Yes ──── Use: OAuth 2.0
                  │ external IdP │
                  │ (Keycloak,   │
                  │ Auth0, etc)? │
                  └──────┬───────┘
                         │ No
                         ▼
                    Use: JWT Token
```

---

## Connecting MCP Clients

### VS Code (`mcp.json`)

```json
{
  "servers": {
    "MyMCPServer": {
      "type": "http",
      "url": "https://localhost:9090/mcp",
      "headers": {
        "Authorization": "Bearer <your-token>"
      }
    }
  }
}
```

### Claude Desktop (`claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "MyMCPServer": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "https://localhost:9090/mcp",
        "--header",
        "Authorization: Bearer <your-token>"
      ]
    }
  }
}
```

> Replace `<your-token>` with your API key, JWT token, or OAuth 2.0 access token depending on the authentication type configured on the server.

---

## Related Samples

| Sample | Authentication Demonstrated |
|---|---|
| [Customer 360](../Customer360/) | No auth (basic MCP server) |
| [Customer 360 with Auth](../Customer360WithAuth/) | TLS + JWT Token / API Key |
| [MCP JWT Scope Access Control](../MCP_JWT_Scope_Access_Control/) | JWT Token with per-tool scope enforcement and tokenInfo claims |
| [MCP OAuth 2.0 Access Control](../MCP_OAuth2_Access_Control/) | **Runnable OAuth 2.0 sample** — external IdP (Keycloak), JWKS/RS256, issuer/audience validation, server-level + per-handler scopes |

---

## Related Resources

- [MCP Specification](https://modelcontextprotocol.io)
- [MCP Authorization — RFC 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
- [TIBCO Flogo® MCP Connector Documentation](https://docs.tibco.com)

---

<!-- SEO Keywords: MCP Server Authentication, MCP OAuth 2.0, MCP JWT Token, MCP API Key, MCP Scope Access Control, MCP tokenInfo, Flogo MCP Server Security, MCP Authorization, JWT Scopes MCP, OAuth2 MCP Server, TIBCO Flogo MCP Authentication -->

**Topics:** `MCP Authentication` · `JWT Scopes` · `OAuth 2.0` · `API Key` · `Access Control` · `TIBCO Flogo`
