# Auth design spec — Retail Banking Assistant (JWT Auth variant)

Variant of [`Retail_Banking_Assistant_Use_Case`](../Retail_Banking_Assistant_Use_Case/) (Kestrel Bank). The business
rules, data and the three A2A agents are unchanged ([`banking.spec.md`](banking.spec.md)). What changes is **where
identity and authorization are enforced**: no passcodes, no session tokens, no `verify_*` tools. The user arrives
already signed in with a **JWT**, and the transport layers enforce it. This spec describes the apps as built and the
Flogo 2.26.7 runtime behaviour they were tested against.

## Apps, ports, database

| App | Port / path | Auth |
|---|---|---|
| `RetailBankingSecureOrchestrator.flogo` | WebSocket `9970` `/retailbanking` | Reads `Authorization: Bearer <jwt>` from the WS handshake **only**. Missing / malformed → fixed "please sign in" reply, no LLM call. Holds no JWT secret: it forwards the caller's token, it never validates it. |
| `RetailBankingSecureMCPServer.flogo` | MCP `9972` `/retail-banking-mcp` | MCP Server trigger `authType: "JWT Token"`, `authToken = $property["MCP.JWT_Secret"]` (HS256 shared secret); **per-tool `scope`**; every tool flow receives `$flow.tokenInfo` and binds `tokenInfo.sub` to every SQL parameter whose source is `SUB`. |
| `RetailBankingSecureAgents.flogo` | A2A `9973` dispute_triage_agent, `9974` scam_signal_agent, `9975` hardship_intake_agent | Agent trigger `agentAuthMode: "Static Token"`, `agentToken = $property["A2A.<agent>.AuthToken"]`, one token per agent. Service-to-service credential (Flogo 2.26.7 A2A supports only None / Static Token). Agents never receive identity. |
| `samples/Agentic_AI/Chatbot_Secure` | HTTP `3001` | Copy of the shared Chatbot with a server-side **proxy**: the browser POSTs the JWT once (`POST /auth/session`) → HttpOnly SameSite=Strict session cookie → browser opens a WS to the Node server (`/proxy`) → Node opens the upstream WS **with `Authorization: Bearer`**. The token never appears in a URL or in browser JS after sign-in. Upstream targets are allow-listed (`ALLOWED_UPSTREAMS`). The proxy only decodes the token (display, session expiry); it refuses an already-expired token and does not verify signatures. |
| PostgreSQL `banking_jwt_auth` | `5432` | Business rules + row scoping by the verified `sub`. No sessions, passcodes or throttles. |

### App properties (names as shipped; values are placeholders)

| App | Auth-related properties | Other properties |
|---|---|---|
| Orchestrator | `A2A.dispute_triage_agent.AuthToken`, `A2A.scam_signal_agent.AuthToken`, `A2A.hardship_intake_agent.AuthToken` (`SET_YOUR_A2A_TOKEN`) | `WebSocket_PORT`, `LLMClient.LLM_Provider`, `LLMClient.API_Key` (`sk-REPLACE-WITH-YOUR-OPENAI-KEY`), `LLMClient.LLM_Model`, `LLMClient.LLM_Base_URL`, `LLMClient.SystemPrompt`, `MCP.URL`, `A2A.<agent>.URL` |
| MCP server | `MCP.JWT_Secret` (`SET_YOUR_JWT_SECRET`) | `MCP_SERVER_PORT`, `PostgreSQL.PostgresConn.*`, `Email_Username`, `Email_App_Password`, `To_Email` |
| Agents | `A2A.<agent>.AuthToken` ×3 (`SET_YOUR_A2A_TOKEN`) | `AgenticAI.OpenAIConn.*`, `LLM_Model`, `PostgreSQL.PostgresConn.*`, `<agent>_PORT`, `<agent>_URL` |

Real values are supplied at run time — designer **App Properties**, or `FLOGO_APP_PROPS_JSON=<path to a JSON file>`
(a path, not inline JSON), or `FLOGO_APP_PROPS_ENV=auto` (one env var per property, `.` → `_`). The placeholders
must never be empty: an empty `agentToken` disables the A2A check.

## Orchestrator: LLM Client activity (not AI Agent)

Flow `Orchestrator_Flow`:

```
StartActivity --[Signed in (Bearer token)]--> LLMClient --> WriteResponse
StartActivity --[otherwise]-----------------> SignInRequired                         (fixed reply, no LLM call)
LLMClient ==[error]==> LogLLMClientError --[MCP server rejected the sign-in]--> SignInExpired
                                         --[otherwise]---------------------> ServiceUnavailable
```

- Guard: `json.exists($flow.headers, "Authorization") && string.startsWith(coerce.toString($flow.headers["Authorization"]), "Bearer ") && string.length(...) > 7`.
  The header name is declared in the handler's inline headers schema; the wsserver trigger looks it up
  case-insensitively, so `authorization:` also matches. The **scheme is case-sensitive**: `bearer <jwt>` and
  `Basic …` take the "not signed in" branch. Query parameters (`?token=`) are never read.
- LLM Client inputs (all per-call, no connection resources):
  - `llmConfiguration`: `provider` / `apiKey` / `model` / `providerBaseUrl` from `LLMClient.*`, `temperature` 0.
  - `mcpServerConfigs[0]`: `serverUrl = $property["MCP.URL"]`, `httpTransportType: streamable`, `authType: "Token"`,
    **`authToken = string.trimPrefix(coerce.toString($flow.headers["Authorization"]), "Bearer ")`** → the caller's own JWT.
  - `a2aServerConfigs[0..2]`: `authType: "Static Token"`, `authToken = $property["A2A.<agent>.AuthToken"]`,
    `serverUrl = $property["A2A.<agent>.URL"]`.
  - `conversationStoreType: Memory` (`memoryMaxSize` 60), `conversationId` = `Sec-Websocket-Key` + `:` + the last 16
    characters of the caller's JWT (one conversation per WS connection and user; another user's token never joins it,
    and the full token is not the key). The guard requires `Authorization: Bearer <token>` longer than 50 characters.
  - `systemPrompt = $property["LLMClient.SystemPrompt"]` (= `_rebuild/orchestrator_prompt.txt`).
- The LLM never sees the JWT (a transport input, not prompt text) and no tool takes an identity argument.

Fixed replies:

| Branch | Reply |
|---|---|
| `SignInRequired` | "Please sign in to Kestrel Bank to use the assistant. This chat did not receive your sign-in, so nothing has been looked up or changed. Sign in, then start a new chat." |
| `SignInExpired` | "Your sign-in is not valid or has expired. Please sign in to Kestrel Bank again, then start a new chat." |
| `ServiceUnavailable` | "Sorry, the assistant ran into a problem and could not finish your request. Please try again in a few minutes, or call Kestrel Bank." |

`LogLLMClientError` logs `[RetailBankingSecureOrchestrator] LLM Client failed: <error>` at ERROR. The sign-in branch
fires only when the error comes from the MCP server and is an authentication failure — with
`ERR = string.toLower(coerce.toString($error[LLMClient].message))`:
`string.contains(ERR, "mcp server") && (string.contains(ERR, "authentication_error") || string.contains(ERR, "unauthorized"))`.
An LLM provider 401 (bad `LLMClient.API_Key`) therefore gets `ServiceUnavailable`, not a misleading "sign in again".

**LLM Client vs AI Agent (2.26.7).** The LLM Client is used because its MCP / A2A settings are per-call inputs, so
each turn can carry the caller's own token (an AI Agent's MCP connection holds one static token for every user).
What it lacks compared with the AI Agent: `rateLimit`, `tokenLimit`, guardrails, sensitive-data redaction and
handoffs. It opens a **new MCP session and fetches all A2A agent cards on every turn** — if any A2A agent is down,
the turn fails (`ServiceUnavailable`). Tool iterations (50) and retries (3) per turn are fixed. Limits belong at a
gateway in front of it.

## JWT

HS256, signed with `JWT_SECRET` (= `MCP.JWT_Secret`). Claims: `iss: kestrel-bank-idp`, `aud: ["retail-banking-mcp"]`,
`sub` (customer id or staff id), `name`, `scp` (array of scopes), `iat`, `exp`. Minted by
`_rebuild/mint_user_tokens.py` (stdlib only; `--expired`, `--wrong-secret` for negative tests) — the stand-in for the
bank's identity provider. Production: OAuth 2.0 / OIDC with JWKS on the MCP trigger (`authType: "OAuth 2.0"`,
`oauthIssuer`, `oauthJWKSURL`, `oauthAudience`).

### What the MCP Server trigger's `JWT Token` mode checks (Flogo 2.26.7, verified)

| Check | Behaviour |
|---|---|
| Signature | HS256 with the shared secret; wrong secret → 401. `alg: none` rejected. |
| `exp` | Expired → 401. **Optional**: a token without `exp` never expires, so the issuer must always set it. |
| `nbf` | Not yet valid → 401. |
| `aud`, `iss` | **Not checked.** Use OAuth 2.0 mode or validate them upstream. |
| Scopes | Read from `scp` (JSON array of strings) or `scope` (one space-separated string). `scopes` is ignored. `scp` as a string → 401 (malformed). |
| Rejection shape | HTTP 401, plain-text body, no `WWW-Authenticate` header. |
| Tool outside the token's scopes | Not in `tools/list`. Calling it anyway → HTTP 200 with a JSON-RPC error `access denied: token missing required scope '<scope>' for tool '<tool>'`; the tool's flow never runs. |
| Claims to the flow | `$flow.tokenInfo` (`sub`, `scopes`, `expiration`, `iss`, `aud`, `name`, `email`) next to `$flow.arguments`. |

## Scopes

| Persona token (`tool_spec.PERSONAS`) | `sub` | Scopes |
|---|---|---|
| Customer, full app (`james` … `patricia`) | `CUST-2026-001NN` | `profile:read accounts:read transactions:read cards:read loans:read payees:read cases:read branches:read cards:block disputes:write payments:write cases:write email:send` |
| Customer, view-only channel (`james_view`) | `CUST-2026-00101` | `profile:read accounts:read transactions:read cards:read loans:read payees:read cases:read branches:read` |
| Staff reviewer (`maya`, `daniel`, `priya`) | `KST-700N` | `profile:read reviews:read reviews:decide branches:read` |

Resulting tool lists: full customer 16 tools, view-only 8, reviewer 5.

| MCP tool | Scope | Args (no token/session/identity args anywhere) |
|---|---|---|
| `whoami` | `profile:read` | — → `role` (CUSTOMER / REVIEWER / UNKNOWN), `subject`, `display_name`, `team` + `approval_limit` (reviewers only), `reason` |
| `get_my_accounts` | `accounts:read` | — |
| `get_my_transactions` | `transactions:read` | `search` |
| `get_my_cards` | `cards:read` | — |
| `get_my_loans` | `loans:read` | — |
| `get_my_payees` | `payees:read` | — |
| `get_my_cases` | `cases:read` | — |
| `find_branch` | `branches:read` | `city` |
| `propose_card_block` / `confirm_card_block` | `cards:block` | `card`, `reason` / `action_id` |
| `propose_dispute` / `confirm_dispute` | `disputes:write` | `transaction_id`, `reason_code`, `customer_statement` / `action_id` |
| `propose_payment` / `confirm_payment` | `payments:write` | `from_account`, `payee`, `amount`, `customer_story`, `scam_indicators`, `narrative_score`, `agent_notes` / `payment_id`, `acknowledge_warning` |
| `open_service_case` | `cases:write` | `request_type`, `customer_statement`, `brief`, `reference_id` |
| `email_my_confirmation` | `email:send` | `reference_id` |
| `get_review_queue` / `get_review_case` | `reviews:read` | — / `case_id` |
| `decide_review_case` | `reviews:decide` | `case_id`, `decision`, `amount`, `internal_note`, `customer_message` |

Removed: `verify_customer`, `verify_reviewer`.

## A2A Static Token (Flogo 2.26.7, verified)

- The agent card `/.well-known/agent-card.json` is **public** (no token needed); it advertises the Bearer scheme.
- `message/send` (and `message/stream`) with no token or a wrong token: **HTTP 200** with an A2A task whose state is
  `failed` and whose message is "no authentication token provided in the request" / "authentication token provided in
  the request is incorrect" — not 401/403. The agent, its tool and its LLM never run. The Agents log shows
  `A2A executor: agent completed with error`.
- One token per agent: another agent's token is rejected.
- An **empty** `agentToken` disables the check.

## Database changes (from the original `database.sql`)

- Dropped `customer_sessions`, `verify_attempts`, `reviewer_verify_attempts`, `customers.passcode_hash`,
  `reviewers.one_time_code`, `passcode_hash()`, the `verify_*` / `*_locked_until` functions and the session audit trigger.
- `session_customer(p_token)` → `caller_customer(p_sub)`; `session_reviewer(p_token)` → `caller_reviewer(p_sub)`:
  same always-one-row plpgsql contract, matching the subject exactly against `customers` / **active** `reviewers`.
- New `whoami(p_sub)` → `role`, `subject`, `display_name`, `team`, `approval_limit`, `reason`.
- Every rule function's `p_token` parameter is now `p_sub` (the verified `tokenInfo.sub`, never model input).
- Read results: column `session_status` renamed **`caller_status`**. Reason code `SESSION_INVALID` → **`UNKNOWN_CALLER`**;
  `NOT_REVIEWER` keeps its meaning (the subject is not an active reviewer).
- Everything else (rules, reason codes, two-step confirms, scam bands, HITL, audit triggers) unchanged. `agent_audit`
  no longer has sign-in rows; `actor` holds the reviewer's `sub` on `CASE_DECIDED`.

## Defense in depth

1. Chat proxy: the token stays server-side; allow-listed upstreams; expired tokens can't sign in.
2. Orchestrator: no `Authorization: Bearer` header → fixed reply, no LLM call.
3. MCP trigger: invalid signature / expired / not yet valid / malformed → 401; tool outside the token's scopes → not
   listed, not callable.
4. Tool flows: the caller comes from `tokenInfo.sub` only; no tool has an identity argument.
5. SQL: caller resolved from `sub`; customer tools need a customer, reviewer tools an active reviewer; rows scoped to
   the caller; all business rules in SQL.
6. A2A: static token per agent; agents receive no identity and read reference tables only.

## Not covered (production)

OAuth 2.0 / OIDC with JWKS instead of a shared secret; `aud` / `iss` validation; short-lived tokens and revocation;
TLS (`wss://`, HTTPS + `Secure` cookie, TLS on MCP / A2A); secret storage and rotation for the A2A tokens; rate and
token limits for the LLM Client (gateway); a shared session store for the chat proxy.
