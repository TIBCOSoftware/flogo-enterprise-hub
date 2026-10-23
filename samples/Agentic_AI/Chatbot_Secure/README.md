# Flogo Agentic AI Chatbot (Secure Proxy)

A copy of the shared [Chatbot](../Chatbot/) for use cases whose AI Orchestrator **requires a signed-in user**,
for example [Retail Banking Assistant (JWT Auth)](../Industry_Use_Cases/Financial_Services/Banking/Retail_Banking_Assistant_JWT_Auth_Use_Case/).
It runs on **port 3001**, so it can run alongside the original chatbot on port 3000.

## Why a proxy

A JWT-secured Flogo orchestrator reads the user's token from the WebSocket handshake header
`Authorization: Bearer <jwt>`. Browsers **cannot set an `Authorization` header** on a WebSocket, and putting
the token in the URL (`?token=...`) leaks it into server logs, proxies and browser history.

This chatbot uses the **backend-for-frontend** pattern instead:

```
Browser ──(HttpOnly session cookie)──> Chatbot_Secure :3001 ──(Authorization: Bearer <jwt>)──> Flogo orchestrator
```

1. You sign in once: the page sends the JWT to the server in a `POST /auth/session` request body and clears the field.
2. The server keeps the token in a server-side session and gives the browser an **HttpOnly, SameSite=Strict** cookie
   (plus `Secure` when served over HTTPS through a TLS-terminating reverse proxy). Page scripts cannot read the cookie or the token.
3. When you click **Connect**, the page opens a WebSocket to this server (`/proxy`). The server checks the cookie,
   the `Origin` and the target URL allow-list, then opens the upstream WebSocket **with the `Authorization` header**
   and relays messages both ways. Each browser connection gets its own upstream connection (its own conversation).

The token never appears in a URL, in browser storage, or in the server log (only the `sub` and a short session-id
prefix are logged).

## Prerequisites

- **Node.js** 16 or later (with npm)
- The use case's orchestrator running (Retail Banking JWT Auth: `ws://localhost:9970/retailbanking`)
- A user token (JWT). For the Retail Banking JWT Auth demo, mint one with the sample's
  `_rebuild/mint_user_tokens.py` (see that sample's README); in production an OIDC login would provide it.

## Run

```bash
cd samples/Agentic_AI/Chatbot_Secure
npm install
npm start
```

Open **http://localhost:3001**.

1. **Sign in:** paste your JWT into **Sign in** (left panel) and click **Sign in**. The panel shows the signed-in
   name, `sub`, token expiry and scopes.
2. **Connect:** the URL box is pre-filled with the first allowed upstream (`ws://localhost:9970/retailbanking`).
   Click **Connect**; the status turns green: **● Connected**.
3. **Chat** as usual. Each Connect starts a new conversation with the orchestrator.
4. **Sign out** ends the server session, closes open connections and clears this browser's chat history.
   To switch persona, sign out and sign in with another token.

If Connect fails, the chat shows why: not signed in / session expired (sign in again), or the orchestrator could not
be reached (check it is running and its URL is in `ALLOWED_UPSTREAMS`). If the assistant says it cannot verify you,
mint a fresh token (expired or wrongly signed tokens are refused by the MCP server) and sign in again.

## Configuration

Copy `env.example` to `.env` to change the defaults:

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `3001` | HTTP port |
| `HOST` | `127.0.0.1` | Interface to bind. Keep loopback unless it sits behind an HTTPS reverse proxy |
| `ALLOWED_UPSTREAMS` | `ws://localhost:9970/retailbanking` | Comma-separated upstream WebSocket URLs the proxy may open. **Exact match**; anything else is refused. The first one is pre-filled in the page |
| `WS_URL` | first allowed upstream | URL pre-filled in the page (must be in `ALLOWED_UPSTREAMS`) |
| `SESSION_TTL_MINUTES` | `480` | Server session lifetime (1 to 43200); never longer than the token's `exp`. A live connection is closed when its session ends |
| `MAX_SESSIONS` | `1000` | Most sessions kept in memory; when full, new sign-ins get HTTP 429 (a live session is never ended to make room) |
| `SIGNIN_PER_MINUTE` | `10` | Sign-in attempts allowed per client address per minute (HTTP 429 above it; set `TRUST_PROXY=true` behind a reverse proxy so the client address is right) |
| `COOKIE_SECURE` | `auto` | `auto` sets `Secure` when the request came over HTTPS; or `true` / `false` |
| `TRUST_PROXY` | `false` | Set `true` behind a TLS-terminating reverse proxy that sets `X-Forwarded-Proto` |
| `ALLOWED_ORIGINS` | this server's origin | Comma-separated browser origins allowed to sign in and connect (needed only behind a reverse proxy with a different host name) |
| `DIRECT_MODE` | `false` | `true` shows a **Direct** checkbox that connects the browser straight to an upstream **without any token** (for unauthenticated samples only) |

The server refuses to start, with a message naming the variable, when a value is invalid (for example a non-number,
or an `ALLOWED_UPSTREAMS` entry that isn't a `ws://` or `wss://` URL).

To use it with another JWT-secured orchestrator, add its URL to `ALLOWED_UPSTREAMS`, restart, and pick the URL in
the URL box (click ↻ to apply it).

## Endpoints

| Endpoint | Purpose |
|---|---|
| `POST /auth/session` `{"token": "<jwt>"}` | Sign in: stores the token server-side, sets the `cbs_sid` cookie. JSON only |
| `GET /auth/session` | Signed-in status and display claims (`sub`, `name`, `scp`, `exp`). Never returns the token |
| `DELETE /auth/session` | Sign out: drops the session and closes its proxied connections |
| `GET /client-config` | Allowed upstreams and whether direct mode is enabled |
| `ws://<host>:3001/proxy?target=<url-encoded upstream>` | The proxied WebSocket (session cookie + matching `Origin` required) |

The chatbot only **decodes** the token to display its claims and to end the session when it expires. It does not
verify the signature: the Flogo MCP server does that on every tool call.

## Security notes

- **Demo session store.** Sessions live in server memory: restarting the server signs everyone out, and it does
  not scale beyond one instance. Use a shared store (for example Redis) in production.
- **Use HTTPS in production.** This server speaks plain HTTP only, so put it behind a TLS-terminating reverse proxy
  and set `TRUST_PROXY=true`. The cookie is then `Secure` and the token is encrypted between the browser and this server. Use `wss://` for upstreams that are
  not on the same host.
- **Use a real login.** Pasting a JWT is a demo stand-in. In production, replace the sign-in panel with an
  OIDC authorization-code login on this server; the rest of the flow stays the same.
- **The Node server holds the token, the browser does not.** Protect this server like any other component that
  holds user credentials.
- Chat history is kept in this browser's `localStorage` until you sign out.

## Test

`npm test` runs a self-contained smoke test of the proxy against a mock upstream (no Flogo needed).

---

**A WebSocket client with a token-forwarding proxy for TIBCO Flogo® Agentic AI demos**
