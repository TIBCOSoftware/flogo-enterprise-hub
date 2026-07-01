# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" /> TIBCO Flogo® MCP JWT Scope-Based Access Control — Healthcare Patient Records Sample

## Overview

This sample demonstrates how to configure **JWT scope-based access control** and use **enhanced tokenInfo claims** (iss, sub, aud, name, email) in a TIBCO Flogo® MCP Server trigger using a realistic **healthcare patient records** scenario.

Each MCP tool is protected by a different JWT scope, enforcing least-privilege access. When a client connects with a JWT token, the MCP server checks the token's `scp` or `scope` claim against the handler's required scope — if the scope is missing, the tool is hidden from that client entirely.

The enhanced `tokenInfo` object provides identity claims (issuer, subject, audience, name, email) that flows can use for **audit logging**, **attribution**, and **tenant validation**.

> **New in Flogo 2.26.5:** The `scope` handler setting and enhanced `tokenInfo` claims (iss, sub, aud, name, email) are new MCP connector features.

---

## Key Features

- **Scope-Based Access Control** — each tool requires a specific JWT scope; tools without matching scope are invisible to the caller
- **Enhanced TokenInfo Claims** — flows receive `iss`, `sub`, `aud`, `name`, and `email` from the JWT alongside existing `scopes` and `expiration`
- **Audit Logging** — sensitive operations log the caller's identity (`tokenInfo.sub`, `tokenInfo.email`) for compliance
- **Identity Attribution** — write operations attribute changes to the authenticated caller via `tokenInfo.sub`

---

## How JWT Scope Access Control Works

```
Client sends JWT token with scopes: ["patient:read", "records:read"]
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

- Scope matching is **exact** and **case-sensitive** (e.g. `patient:read` does not match `Patient:Read`)
- The JWT `scp` or `scope` claim can be a space-delimited string or a JSON array
- If a handler has no `scope` set, it is accessible to all authenticated clients

---

## Sample — Healthcare Patient Records MCP Server

The `HealthcarePatientRecordsMCPServer.flogo` app exposes **four tools**, each protected by a different scope and demonstrating different tokenInfo usage patterns:

### Tool & Scope Matrix

| MCP Tool | Required Scope | TokenInfo Usage | Description |
|---|---|---|---|
| `get_patient_summary` | `patient:read` | Logs `sub` + `email` | Read-only patient demographics (name, DOB, contact, insurance) |
| `get_medical_records` | `records:read` | Audit logs `sub` + `email` + `iss` | Sensitive medical history — diagnoses, medications, allergies |
| `update_patient_contact` | `patient:write` | Attributes update to `sub` + `name` | Update patient phone, email, or address |
| `get_token_info` | `token:inspect` | Returns full `tokenInfo` object | Debug tool — inspect decoded JWT claims and scopes |

### Role-to-Scope Mapping (Example)

| Role | Scopes | Accessible Tools |
|---|---|---|
| Receptionist | `patient:read` | `get_patient_summary` |
| Doctor | `patient:read`, `records:read` | `get_patient_summary`, `get_medical_records` |
| Admin | `patient:read`, `patient:write`, `records:read`, `token:inspect` | All tools |

---

### Tool Details

#### 1. `get_patient_summary` — Scope: `patient:read`

Retrieves patient demographics including name, date of birth, gender, contact information, and insurance details. This is the most permissive read scope — even a receptionist can access basic patient information.

The flow logs the caller's `tokenInfo.sub` and `tokenInfo.email` for access tracking.

---

#### 2. `get_medical_records` — Scope: `records:read`

Retrieves sensitive medical history including diagnoses (ICD codes), current medications, and allergies. This tool requires a separate `records:read` scope because medical records are subject to stricter access policies (e.g. HIPAA).

The flow performs **audit logging** with full caller identity:
```
[AUDIT] Medical records accessed by sub=dr.smith@hospital.org email=dr.smith@hospital.org iss=https://auth.hospital.org for patient=PAT-10042
```

---

#### 3. `update_patient_contact` — Scope: `patient:write`

Updates patient contact information (phone, email, address). The response attributes the change to the authenticated caller using `tokenInfo.sub` and `tokenInfo.name`:

```json
{
  "status": "updated",
  "patient_id": "PAT-10042",
  "updated_by": "dr.smith@hospital.org",
  "updated_by_name": "Dr. Sarah Smith"
}
```

---

#### 4. `get_token_info` — Scope: `token:inspect`

A diagnostic tool that returns the complete decoded JWT token information. Useful for debugging scope issues and verifying token claims.

Returns all enhanced tokenInfo fields:
- `scopes` — array of granted scopes
- `expiration` — token expiry timestamp
- `iss` — issuer (e.g. `https://auth.hospital.org`)
- `sub` — subject (e.g. `dr.smith@hospital.org`)
- `aud` — audience array
- `name` — human-readable name
- `email` — email address

---

## Flogo Handler Configuration

### Scope Setting

The `scope` field is configured in the handler settings of each MCP tool:

```json
{
  "settings": {
    "handlerType": "Tool",
    "handlerName": "get_medical_records",
    "handlerDescription": "Retrieve sensitive medical history ...",
    "scope": "records:read"
  }
}
```

### TokenInfo in Flow Input

Each handler passes `tokenInfo` to the flow via the action input mapping:

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

The flow can then access `$flow.tokenInfo.sub`, `$flow.tokenInfo.email`, `$flow.tokenInfo.name`, etc.

---

## Getting Started

### Prerequisites

- TIBCO Flogo® **2.26.5** or later
- An MCP-capable client (e.g. GitHub Copilot in VS Code, Claude Desktop)
- A JWT token with appropriate scopes (see JWT Token Setup below)

### Import the App

Import `HealthcarePatientRecordsMCPServer.flogo` into VS Code using the Flogo extension.

### Run the App

Run `HealthcarePatientRecordsMCPServer.flogo` from VS Code. The MCP Server will start at:

```
http://localhost:9096/mcp
```

### JWT Token Setup

The server requires a JWT token with scopes in the `scp` or `scope` claim. You can generate a test token at [jwt.io](https://jwt.io).

Example JWT payload for a "Doctor" role (access to `get_patient_summary` and `get_medical_records`):
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

Example JWT payload for an "Admin" role (access to all tools):
```json
{
  "iss": "https://auth.hospital.org",
  "sub": "admin@hospital.org",
  "aud": ["healthcare-api"],
  "name": "System Admin",
  "email": "admin@hospital.org",
  "scp": ["patient:read", "patient:write", "records:read", "token:inspect"],
  "exp": 1893456000
}
```

### Configure Your MCP Client

**VS Code (`mcp.json`):**
```json
{
  "servers": {
    "HealthcarePatientRecordsMCPServer": {
      "type": "http",
      "url": "http://localhost:9096/mcp",
      "headers": {
        "Authorization": "Bearer <your-jwt-token>"
      }
    }
  }
}
```

**Claude Desktop (`claude_desktop_config.json`):**
```json
{
  "mcpServers": {
    "HealthcarePatientRecordsMCPServer": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "http://localhost:9096/mcp",
        "--header",
        "Authorization: Bearer <your-jwt-token>"
      ]
    }
  }
}
```

### Try It — Example Prompts

Once connected with a token that has the `patient:read` and `records:read` scopes:

```
"Look up patient PAT-10042 and show me their demographics"
```
→ Invokes `get_patient_summary` (requires `patient:read`)

```
"What medications is patient PAT-10042 currently taking?"
```
→ Invokes `get_medical_records` (requires `records:read`)

```
"Update the phone number for patient PAT-10042 to +1-555-0199"
```
→ Invokes `update_patient_contact` (requires `patient:write` — will fail if scope is missing)

```
"What scopes does my current token have?"
```
→ Invokes `get_token_info` (requires `token:inspect`)

---

## Adapting This Sample for Production

The flows use `noop` + `actreturn` activities with mock data. To make this production-ready:

| Tool | Replace with |
|---|---|
| `get_patient_summary` | REST Invoke → patient demographics API (e.g. FHIR Patient resource) |
| `get_medical_records` | REST Invoke → EHR system API (e.g. FHIR Condition, MedicationRequest, AllergyIntolerance) |
| `update_patient_contact` | REST Invoke → patient management service (PUT/PATCH endpoint) |
| `get_token_info` | Keep as-is — useful for debugging in all environments |

---

## App Properties

| Property | Default | Description |
|---|---|---|
| `FlogoMcpServer.PORT` | `9096` | HTTP port the MCP server listens on |
| `FlogoMcpServer.JWT_TOKEN_SECRET` | `my-test-secret-key-for-healthcare-sample` | JWT token secret used to validate incoming Bearer tokens |

---

## Related Resources

- [MCP Specification — Tools](https://modelcontextprotocol.io/specification/2025-03-26/server/tools/)
- [TIBCO Flogo® MCP Connector Documentation](https://docs.tibco.com)
- [Model Context Protocol](https://modelcontextprotocol.io)
- [Customer360 MCP Sample](../Customer360/README.md) — basic Flogo MCP server example
- [Customer360 With Auth](../Customer360WithAuth/README.md) — TLS and JWT authentication
- [MCP Tool Annotations](../MCP_Tool_Annotations/README.md) — tool safety annotations
