# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® MCP OAuth 2.0 Access Control — Healthcare Patient Records Sample

## Overview

This sample secures a TIBCO Flogo® MCP Server with **OAuth 2.0**, integrating with an external identity provider (**Keycloak**) instead of a shared secret. It is the production-grade counterpart of the [MCP JWT Scope Access Control](../MCP_JWT_Scope_Access_Control/README.md) sample — same healthcare patient-records scenario and the same four tools, but tokens are now issued by an IdP and validated against its **JWKS** endpoint.

Instead of validating a token with an HMAC (HS256) shared secret, the trigger fetches the IdP's public signing keys from a **JWKS URL** (supporting **RS256** and key rotation), and additionally validates the token's **issuer** (`iss`) and **audience** (`aud`, an RFC 8707 Resource Indicator). On top of the existing per-handler `scope` enforcement, OAuth 2.0 mode adds a **server-level required scope** that every request must satisfy.

> **New in Flogo 2.26.6:** `OAuth 2.0` is a new `authType` on the MCP Server trigger, adding JWKS-based validation, issuer/audience checks, server-level required scopes, and protected-resource metadata discovery at `/.well-known/oauth-protected-resource`.

---

## Key Features

- **External IdP integration** — validate tokens issued by Keycloak, Auth0, Azure AD, Okta, or any OpenID Connect provider
- **JWKS / RS256 validation** — no shared secret; the trigger discovers signing keys from the IdP and follows key rotation automatically
- **Issuer & audience validation** — tokens must carry the expected `iss` and the resource URL in `aud` (RFC 8707)
- **Two layers of scope enforcement** — a server-level `oauthRequiredScopes` gate plus per-handler `scope` checks
- **Enhanced tokenInfo claims** — flows receive `iss`, `sub`, `aud`, `name`, `email`, `given_name`, `family_name`, `preferred_username`, `scopes`, `expiration` for audit logging and attribution
- **Protected-resource discovery** — the server advertises its authorization servers and resource at `/.well-known/oauth-protected-resource`

---

## How OAuth 2.0 Validation Works

```
        Client                         Identity Provider (Keycloak)
          │                                     │
          │  1. Obtain token (password /        │
          │     client_credentials / authcode)  │
          │────────────────────────────────────>│
          │<────────────────────────────────────│
          │     JWT signed with RS256            │
          │                                     │
          │                          Flogo MCP Server (OAuth 2.0)
          │  2. Call tool with Bearer token      │
          │────────────────────────────────────>│
          │                     3. Fetch JWKS ───┼──> IdP JWKS endpoint
          │                     4. Verify RS256 signature
          │                     5. Validate iss + aud
          │                     6. Enforce oauthRequiredScopes (server level)
          │                     7. Enforce handler scope (per tool)
          │<────────────────────────────────────│
          │     Tool result / 401 + WWW-Authenticate
```

### Two layers of scope enforcement

| Layer | Setting | Behavior |
|---|---|---|
| **Server-level** | `oauthRequiredScopes` (trigger) = `mcp:tools` | Every request must carry this scope, or it is rejected before reaching any handler |
| **Handler-level** | `scope` (per handler) = `patient:read`, `records:read`, … | Tools whose scope the caller lacks are hidden from `tools/list` and denied on `tools/call` |

In this sample every caller must have `mcp:tools` to talk to the server at all, and then each tool additionally requires its own scope.

---

## Sample — Healthcare Patient Records MCP Server

`HealthcarePatientRecordsOAuth2MCPServer.flogo` exposes **four tools**, each protected by a per-handler scope on top of the server-level `mcp:tools` gate:

### Tool & Scope Matrix

| MCP Tool | Server Scope | Handler Scope | TokenInfo Usage | Description |
|---|---|---|---|---|
| `get_patient_summary` | `mcp:tools` | `patient:read` | Logs `sub` + `email` | Read-only patient demographics |
| `get_medical_records` | `mcp:tools` | `records:read` | Audit logs `sub` + `email` + `iss` | Sensitive medical history |
| `update_patient_contact` | `mcp:tools` | `patient:write` | Attributes update to `sub` + `name` | Update patient contact info |
| `get_token_info` | `mcp:tools` | `token:inspect` | Returns full `tokenInfo` | Debug — inspect decoded token claims |

### Demo Users (created by `setup-keycloak.sh`)

| User | Granted scopes | Effective access |
|---|---|---|
| `receptionist` | `mcp:tools`, `patient:read` | `get_patient_summary` |
| `doctor` | `mcp:tools`, `patient:read`, `records:read` | `get_patient_summary`, `get_medical_records` |
| `admin` | `mcp:tools`, `patient:read`, `records:read`, `patient:write`, `token:inspect` | All tools |
| `guest` | `patient:read` *(no `mcp:tools`)* | **Rejected** — fails the server-level gate |

---

## Trigger Configuration

The MCP Server trigger is configured with `authType: OAuth 2.0` and the OAuth fields:

```json
{
  "settings": {
    "serverName": "HealthcarePatientRecordsOAuth2MCPServer",
    "serverType": "HTTP",
    "serverPort": "=$property[\"FlogoMcpServer.PORT\"]",
    "serverEndpointPath": "/mcp",
    "authType": "OAuth 2.0",
    "oauthIssuer": "=$property[\"FlogoMcpServer.OAUTH_ISSUER\"]",
    "oauthJWKSURL": "=$property[\"FlogoMcpServer.OAUTH_JWKS_URL\"]",
    "oauthAudience": "=$property[\"FlogoMcpServer.OAUTH_AUDIENCE\"]",
    "oauthResourceURL": "=$property[\"FlogoMcpServer.OAUTH_AUDIENCE\"]",
    "oauthRequiredScopes": "=$property[\"FlogoMcpServer.OAUTH_REQUIRED_SCOPES\"]",
    "oauthAuthorizationServers": ""
  }
}
```

| Setting | Purpose |
|---|---|
| `oauthIssuer` | Expected `iss` claim — must match the token issuer (the realm URL) |
| `oauthJWKSURL` | IdP JWKS endpoint; the trigger fetches RS256 public keys from here |
| `oauthAudience` | Expected `aud` value (RFC 8707 Resource Indicator) — the MCP server resource URL |
| `oauthResourceURL` | Canonical resource URL advertised in protected-resource metadata (defaults to the public server URL) |
| `oauthRequiredScopes` | Space-separated scopes required on **every** request (server-level gate) |
| `oauthAuthorizationServers` | Optional comma-separated issuer list advertised at `/.well-known/oauth-protected-resource` (defaults to `oauthIssuer`) |

> Unlike JWT Token mode, **no `authToken` shared secret is needed** — validation is done entirely against the IdP's public keys.

---

## Getting Started

### Prerequisites

- TIBCO Flogo® **2.26.6** or later
- **Docker** (to run Keycloak) and `curl` + `python3` (used by the setup script)
- An MCP-capable client (GitHub Copilot in VS Code, Claude Desktop) or the [MCP Inspector](https://github.com/modelcontextprotocol/inspector)

### 1. Start Keycloak

```bash
docker run -d --name keycloak -p 9098:8080 \
  -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \
  quay.io/keycloak/keycloak:26.6.3 start-dev
```

### 2. Provision the realm, client, scopes, and users

```bash
./setup-keycloak.sh
```

This creates the `flogo-mcp` realm, a confidential client (`flogo-mcp-server`), client scopes and roles, an audience mapper (`aud` = the MCP resource URL), a per-user `scopes` array mapper, and the four demo users. It prints the **issuer**, **JWKS URL**, **audience**, and **client secret** to use next. Override defaults with env vars, e.g. `KC_URL=http://localhost:9098 REALM=flogo-mcp ./setup-keycloak.sh`.

### 3. Set the app properties

The defaults already match the script defaults. Adjust in the Flogo app if you changed anything:

| Property | Default |
|---|---|
| `FlogoMcpServer.PORT` | `9097` |
| `FlogoMcpServer.OAUTH_ISSUER` | `http://localhost:9098/realms/flogo-mcp` |
| `FlogoMcpServer.OAUTH_JWKS_URL` | `http://localhost:9098/realms/flogo-mcp/protocol/openid-connect/certs` |
| `FlogoMcpServer.OAUTH_AUDIENCE` | `http://localhost:9097/mcp` |
| `FlogoMcpServer.OAUTH_REQUIRED_SCOPES` | `mcp:tools` |

### 4. Run the app

Run `HealthcarePatientRecordsOAuth2MCPServer.flogo` from VS Code. The MCP server starts at:

```
http://localhost:9097/mcp
```

Confirm the protected-resource metadata is advertised:

```bash
curl -s http://localhost:9097/.well-known/oauth-protected-resource | python3 -m json.tool
```

---

## Getting a Token

**Resource Owner Password grant** (simplest for testing) — for the `doctor` user:

```bash
curl -s -X POST "http://localhost:9098/realms/flogo-mcp/protocol/openid-connect/token" \
  -d grant_type=password \
  -d client_id=flogo-mcp-server \
  -d client_secret=<CLIENT_SECRET> \
  -d username=doctor -d password='Password123!' \
  -d scope='openid mcp:tools patient:read records:read' | python3 -m json.tool
```

**Client Credentials grant** (service-to-service, no user) also works and avoids refresh-token expiry:

```bash
curl -s -X POST "http://localhost:9098/realms/flogo-mcp/protocol/openid-connect/token" \
  -d grant_type=client_credentials \
  -d client_id=flogo-mcp-server -d client_secret=<CLIENT_SECRET> \
  -d scope='mcp:tools patient:read' | python3 -m json.tool
```

**Decode** the `access_token` to verify `iss`, `aud`, `scope`, and the per-user `scopes` array. The simplest way is to fetch and decode in one shot (no copy-paste of the token):

```bash
curl -s -X POST "http://localhost:9098/realms/flogo-mcp/protocol/openid-connect/token" \
  -d grant_type=password \
  -d client_id=flogo-mcp-server -d client_secret=<CLIENT_SECRET> \
  -d username=doctor -d password='Password123!' \
  -d scope='openid mcp:tools patient:read records:read' \
| python3 -c "import sys,json,base64; t=json.load(sys.stdin)['access_token']; \
  p=t.split('.')[1]; p+='='*(-len(p)%4); \
  print(json.dumps(json.loads(base64.urlsafe_b64decode(p)),indent=2))"
```

Or decode a token you already have on the clipboard — **replace `<access_token>` with your real token** (keep the surrounding double quotes, and make sure it's a single unbroken line):

```bash
echo "eyJhbGciOiJSUzI1NiIsInR5cCI6...<your real token>...abc123" | python3 -c "import sys,json,base64; \
  p=sys.stdin.read().strip().split('.')[1]; p+='='*(-len(p)%4); \
  print(json.dumps(json.loads(base64.urlsafe_b64decode(p)),indent=2))"
```

> Paste the **real** token in place of `<access_token>` (a single unbroken line, no surrounding quotes or spaces). The `-d scope=...` list is what you request; the token's per-user `scopes` array reflects what the user is actually granted.

---

## Testing

### MCP Inspector

```bash
npx @modelcontextprotocol/inspector
```

- Transport: **Streamable HTTP**, URL: `http://localhost:9097/mcp`
- Header: `Authorization` = `Bearer <access_token>`

Verify the two-layer enforcement:

- **`doctor`** → sees `get_patient_summary` and `get_medical_records`; not the write/inspect tools.
- **`admin`** → sees all four tools.
- **`guest`** (no `mcp:tools`) → request rejected at the server level with `401` and a `WWW-Authenticate` challenge.

### MCP Client Configuration

**VS Code (`mcp.json`):**
```json
{
  "servers": {
    "HealthcarePatientRecordsOAuth2MCPServer": {
      "type": "http",
      "url": "http://localhost:9097/mcp",
      "headers": { "Authorization": "Bearer <access_token>" }
    }
  }
}
```

**Claude Desktop (`claude_desktop_config.json`):**
```json
{
  "mcpServers": {
    "HealthcarePatientRecordsOAuth2MCPServer": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:9097/mcp",
               "--header", "Authorization: Bearer <access_token>"]
    }
  }
}
```

---

## JWT Token vs OAuth 2.0

| Aspect | JWT Token ([sample](../MCP_JWT_Scope_Access_Control/README.md)) | OAuth 2.0 (this sample) |
|---|---|---|
| Signature validation | HMAC (HS256) shared secret | JWKS (RS256+) from the IdP |
| Key management | Secret stored in the app | Public keys discovered + rotated automatically |
| Issuer / audience checks | No | Yes (`oauthIssuer`, `oauthAudience`) |
| Server-level scope gate | No | Yes (`oauthRequiredScopes`) |
| Token source | Hand-crafted / any signer | External IdP (Keycloak, Auth0, Azure AD, Okta) |
| Discovery endpoint | No | `/.well-known/oauth-protected-resource` |

---

## Notes & Troubleshooting

- **Access tokens expire quickly** (Keycloak default 5 min). Re-fetch when the Inspector/client returns `401`.
- **`invalid_grant` / "Token is not active" at runtime** with the Authorization Code grant means the stored refresh token expired between design-time login and runtime. Prefer **Client Credentials** for unattended runtime, or increase the Keycloak SSO Session Idle/Max, or add the `offline_access` scope.
- **Token rejected with audience error** — ensure the audience mapper set `aud` to the resource URL that matches `oauthAudience` (the script does this automatically).
- **Tool not visible** — the caller's token is missing the handler scope; check the decoded `scopes` array and the user's role assignments.
- **All requests rejected** — the token lacks the server-level `mcp:tools` scope.

---

## Adapting This Sample for Production

The flows use `noop` + `actreturn` with mock data. Replace each with a real backend call:

| Tool | Replace with |
|---|---|
| `get_patient_summary` | REST Invoke → patient demographics API (e.g. FHIR Patient) |
| `get_medical_records` | REST Invoke → EHR API (FHIR Condition, MedicationRequest, AllergyIntolerance) |
| `update_patient_contact` | REST Invoke → patient management service (PUT/PATCH) |
| `get_token_info` | Keep — useful for debugging in all environments |

Enable **TLS** on the trigger (`enableTLS`, `serverCertificate`, `serverPrivateKey`) so Bearer tokens are protected in transit.

---

## Related Resources

- [MCP Authorization — 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
- [RFC 8707 — Resource Indicators for OAuth 2.0](https://www.rfc-editor.org/rfc/rfc8707)
- [MCP Server Authentication Guide](../MCP_Server_Authentication/README.md) — all four auth types compared
- [MCP JWT Scope Access Control](../MCP_JWT_Scope_Access_Control/README.md) — the shared-secret counterpart
- [TIBCO Flogo® MCP Connector Documentation](https://docs.tibco.com)

<!-- SEO Keywords: MCP OAuth 2.0, MCP Server OAuth, Flogo MCP OAuth, JWKS RS256, Keycloak MCP, OAuth2 scopes, RFC 8707, protected resource metadata, MCP authorization, tokenInfo, TIBCO Flogo MCP -->

**Topics:** `MCP OAuth 2.0` · `Keycloak` · `JWKS` · `OAuth Scopes` · `Access Control` · `TIBCO Flogo`
