# Agent Privilege IDs: no-MCP variant (agent → API through your own gateway)

Some banks don't want MCP in the path. This variant secures **agent → API** the way they already secure every other
application: **each AI agent is an OAuth 2.0 client of the bank's identity provider, and every call goes through the
bank's API gateway.** No MCP anywhere, and everything is Flogo.

- Each agent's tools are **Flogo flows inside the agent app** ("custom tools" on the **AI Agent Trigger**). An agent
  can only do what its built-in tools do. The read-only agent has no "block card" tool at all.
- Each tool calls the bank's REST API with **REST Invoke** and that agent's own **OAuth 2.0 client-credentials**
  connection. The `client_id` is the agent's privilege ID, so every call carries the agent's own short-lived token.
- The **API gateway** checks the token (signature, expiry, issuer, audience) and the **scope each endpoint needs**,
  then the same **agent registry** as the base sample (status, expiry, entitlement, kill switch), then audits and runs
  the guarded SQL. Refusals are recorded too.

```
Staff ─WS :9890 /insight───► Customer Insight Agent (AI Agent Trigger) ── tools: whoami · account · transactions
Staff ─WS :9890 /servicing─► Card Servicing Agent  (AI Agent Trigger) ── tools: + block card · limit request · status
                                   │  each tool = a Flogo flow: REST Invoke + THIS agent's OAuth2 client credentials
                                   ▼
        BankAPIGateway.flogo :9895  (stand-in for the bank's identity provider + API gateway)
          POST /oauth/token  → client credentials checked → short-lived JWT (sub = privilege ID, scp = its scopes)
          /api/...           → JWT verified → 401 bad/expired token · 403 missing scope · registry kill switch · audit
                                   ▼
                              PostgreSQL bankops_agents
```

| App | Port | What it is |
|---|---|---|
| `BankOpsAgentsNoMCP.flogo` | WebSocket `9890` (`/insight`, `/servicing`) | Two AI Agent Triggers with custom tools, invoked from the chat flows |
| `BankAPIGateway.flogo` | REST `9895` | **Stand-in** for the bank's own identity provider and API gateway, built in Flogo (REST trigger + JWT activity + PostgreSQL). At the customer, these are their existing Entra ID / Okta / Keycloak and gateway. |
| PostgreSQL `bankops_agents` | `5432` | The base sample's database, plus OAuth client registrations (hashed secrets) and the token/gateway rule functions |

| Endpoint | Scope the gateway requires | Agent tool |
|---|---|---|
| `POST /oauth/token` | client credentials (Basic header or form fields) | *(used by the OAuth connections)* |
| `GET /api/whoami` | any valid token | `whoami` |
| `GET /api/accounts/{account_id}` | `accounts:read` | `get_account_summary` |
| `GET /api/accounts/{account_id}/transactions` | `txns:read` | `list_recent_transactions` |
| `POST /api/cards/{card_id}/block` | `cards:block` | `block_card` |
| `POST /api/accounts/{account_id}/limit-requests` | `limits:request` | `request_limit_increase` |
| `GET /api/limit-requests/{request_id}` | `limits:request` | `get_request_status` |

## Prerequisites

The base sample's prerequisites: Flogo VS Code extension 2.26.6+, PostgreSQL with `bankops_agents` loaded (reload
`../database.sql` if you created it before this variant existed), an OpenAI key, and Node.js for the Chatbot.

## Steps to run

> ⚠️ **Order matters: start `BankAPIGateway` before you click Login on the agents' OAuth connections.** The gateway
> is the token endpoint (`http://localhost:9895/oauth/token`). If it isn't running, Login on **InsightAgentOAuth** /
> **ServicingAgentOAuth** fails with "Failed to get access token", and the agents app can't call any tool. If you
> restart the gateway with a different `Gateway.Signing_Key`, click Login again on both connections.

1. **Register each agent as an OAuth client.** Each call prints the agent's client secret **once**; only its SHA-256
   hash is stored:
   ```sql
   SELECT * FROM register_agent_client('agt-insight-01',   'accounts:read txns:read');
   SELECT * FROM register_agent_client('agt-servicing-01', 'accounts:read txns:read cards:block limits:request');
   ```
   Run it again at any time to rotate a secret. `reset_data.sql` keeps the registrations.
2. **⚠️ Configure and start `BankAPIGateway.flogo`** (the shipped file carries placeholders):

   | App property | Set to |
   |---|---|
   | `PostgreSQL.PostgresConn.*` | your PostgreSQL (`Database_Name` = `bankops_agents`) |
   | `Gateway.Signing_Key` | any long random string; it signs and verifies the agents' tokens |
   | `Gateway.Token_TTL_Seconds` | token lifetime (default `600`) |

   Then **Run** it (it listens on port `9895`).
3. **⚠️ Configure `BankOpsAgentsNoMCP.flogo`:**

   | Where | Set to |
   |---|---|
   | App properties `AgenticAI.OpenAIConn.API_Key`, `LLM_Model` | your OpenAI key; `gpt-5.5` or another capable model |
   | Connection **InsightAgentOAuth** → Client Secret | the `agt-insight-01` secret from step 1 |
   | Connection **ServicingAgentOAuth** → Client Secret | the `agt-servicing-01` secret from step 1 |

   Both connections are already set to OAuth2 / Client Credentials, with the token URL
   `http://localhost:9895/oauth/token`, `client_id` = the agent's privilege ID, and its scopes.

   **Then, with the gateway from step 2 running, click Login on each of the two connections.** FDA creates connections but can't
   press a connection's Login/Connect button (documented FDA limitation "Connector Configuration"), so this is a
   manual step. Login fetches the first token. After that the connection fetches new tokens itself with the agent's
   client credentials whenever the gateway says one has expired.
4. **Start** `BankOpsAgentsNoMCP`.
5. **Chat:** open the shared [Chatbot](../../../Chatbot/), connect to `ws://localhost:9890/insight` or
   `ws://localhost:9890/servicing` and click **↻** after changing the URL.

The demo script is the same as the [base sample's](../README.md#6-demo-script-about-5-minutes). The difference is
where each control lives: tools compiled into each agent; token, scope and audit at the bank's gateway.

Reset with `psql -U postgres -d bankops_agents -f ../reset_data.sql`.

## How it maps to a bank's existing estate

| Control | Where it lives here | In production |
|---|---|---|
| Agent identity | OAuth client per agent (`client_id` = privilege ID) | A client / workload identity per agent in Entra ID, Okta or Keycloak (federated credentials or managed identity rather than secrets) |
| Short-lived credentials | 10-minute JWTs, fetched by the Flogo connection | The IdP's token lifetime; rotation needs no app change |
| Least privilege | Tools compiled into each agent, plus a scope per endpoint at the gateway | Your gateway's scope or role policies per client |
| Kill switch | `agent_identities.status` (checked every call), or rotate/remove the client | Disable the client in the IdP; tokens die within their lifetime |
| Business rules and approvals | Guarded SQL and human-only `approve_request()` | Your APIs and workflow tools |
| Audit | `agent_audit` (allowed and refused, by privilege ID) | Gateway logs and your SIEM; OpenTelemetry traces from Flogo |

## Notes

- **Click Login on both OAuth connections** (step 3). The shipped agents app also seeds a placeholder token so a
  rebuilt app can run headless in CI (the first call gets a 401 and the connection then fetches a real token). In the
  designer, just click Login.
- **Keep schemas inline.** The AI Agent Trigger reads each tool's `toolParams` schema only inline, and the REST
  trigger reads `pathParams` the same way. A `schema://` reference leaves the agent with no tool parameters, or the
  gateway with no path parameters. The designer always stores them inline; the build scripts do too.
- `fda cm` flags `TR_REST_NO_SWAGGER` on the gateway: its REST trigger has no OpenAPI document. That's a design-time
  recommendation; the gateway runs and is tested without one.

> ⚠️ Demonstration only: fictional data, a Flogo app standing in for the bank's IdP and gateway, shared-secret JWTs.
