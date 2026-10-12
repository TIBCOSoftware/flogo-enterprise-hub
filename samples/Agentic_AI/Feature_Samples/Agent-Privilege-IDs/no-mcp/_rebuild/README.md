# `no-mcp/_rebuild/`: regenerate and test the no-MCP variant from code

**You don't need this folder to run the demo.** The variant [README](../README.md) covers that.

This folder holds the Python scripts that generated the no-MCP variant's two `.flogo` apps with the Flogo Design CLI
(`fda`), and the test that checks the gateway. It covers only what is specific to this variant; the shared settings,
helpers and base tests are described in the base [`_rebuild/README.md`](../../_rebuild/README.md).

## What's in this folder

| File | What it does |
|---|---|
| `build_gateway.py` | Generates `BankAPIGateway.flogo`, the Flogo stand-in for the bank's identity provider and API gateway: a REST trigger with `POST /oauth/token` (client credentials, signs a short-lived JWT) and one `/api/...` endpoint per tool (verifies the token, checks issuer, audience and the endpoint's scope, then runs the same guarded tool SQL as the base sample). |
| `build_agents_nomcp.py` | Generates `BankOpsAgentsNoMCP.flogo`: two AI Agent Triggers with custom tools (one Flogo flow per tool, each a REST Invoke to the gateway with that agent's own OAuth 2.0 client-credentials connection), and a WebSocket front door with one conversation per browser connection. |
| `gateway_smoke.py` | Test step 2. Calls the running gateway directly (no LLM, no MCP) with the same client-credentials flow the agents use, and checks the token, scope, registry and audit controls. |

Both build scripts put the base `_rebuild/` folder on `sys.path` and import `fda_common.py` (settings, `fda`,
connections) and `tool_spec.py` (tool descriptions, scopes and SQL) from it. Each also has its own `HTTP` table that
maps every tool to its method and path.

Related files in the variant folder:

| File | What it does |
|---|---|
| `README.md` | How to configure and run this variant. |
| `chat_e2e_transcript.md` | A recorded chat with these apps. |

The database (`../database.sql`, `../reset_data.sql`) is the base sample's; it already holds this variant's OAuth
client table and token and gateway rule functions.

## Before you start

- Everything in the base [`_rebuild/README.md`](../../_rebuild/README.md#before-you-start): Python 3.9+, the Flogo VS
  Code extension, `psql` with `bankops_agents` loaded, and the same settings from
  [`config.md`](../../../../../../skills-library/.claude/skills/config.md) or environment variables (PostgreSQL,
  `LLM_MODEL`, `LLM_API_KEY`, `FDA`, `PG_DB`, `CONFIG_MD`).
- Run every command below **from the variant folder** (`no-mcp/`).

**Client secrets.** Each agent is an OAuth client of the gateway. Register the clients in PostgreSQL; each call
prints the new secret **once** (only its hash is stored) and rotates it if the client already exists:

```bash
psql -U postgres -d bankops_agents -At \
  -c "SELECT * FROM register_agent_client('agt-insight-01',   'accounts:read txns:read')" \
  -c "SELECT * FROM register_agent_client('agt-servicing-01', 'accounts:read txns:read cards:block limits:request')" \
  -c "SELECT * FROM register_agent_client('agt-legacy-07',    'accounts:read')" > idp_clients.txt
export GATEWAY_CLIENTS_FILE=idp_clients.txt
```

Each line of `idp_clients.txt` is `client_id|secret|scopes`, the format both `build_agents_nomcp.py` and `gateway_smoke.py` read. `agt-legacy-07` is
needed only by `gateway_smoke.py` (it checks that a suspended agent is refused). `reset_data.sql` keeps the
registrations. If you register a client again, its old secret stops working, so update the agents app too. Delete
`idp_clients.txt` when you're done; don't commit it.

**Secrets.** These come from environment variables only:

| Variable | Needed by | What it is |
|---|---|---|
| `GATEWAY_SIGNING_KEY` | `build_gateway.py`, `gateway_smoke.py` | The HS256 key the gateway signs and verifies access tokens with. Any long random string; the test must use the same value as the running gateway. |
| `GATEWAY_CLIENTS_FILE` | `build_agents_nomcp.py`, `gateway_smoke.py` | The `idp_clients.txt` file from the step above. `build_agents_nomcp.py` reads the `agt-insight-01` / `agt-servicing-01` secrets from it; `gateway_smoke.py` needs all three clients. |
| `INSIGHT_CLIENT_SECRET` / `SERVICING_CLIENT_SECRET` | `build_agents_nomcp.py` (optional) | Override the secret read from `GATEWAY_CLIENTS_FILE` for that agent. |

`BANK_GATEWAY_URL` changes the gateway address: in `build_agents_nomcp.py` (token URL and every tool's URL, default
`http://localhost:9895`) and in `gateway_smoke.py` (default `http://127.0.0.1:9895`). `gateway_smoke.py` always uses
the `bankops_agents` database.

## Regenerate the apps

The scripts **refuse to overwrite** an existing `.flogo`, and by default they write into `no-mcp/`, where the shipped
apps already are. Build into an empty folder:

```bash
mkdir -p rebuilt
OUT_DIR=rebuilt python _rebuild/build_gateway.py
OUT_DIR=rebuilt python _rebuild/build_agents_nomcp.py
```

`build_gateway.py` connects to the database to read each query's result columns. `build_agents_nomcp.py` checks every
connection binding at the end. Compare the result with the shipped apps, then delete `rebuilt/`; don't commit it.

The rebuilt agents app seeds a placeholder OAuth token so it can run without the designer: its first call gets a
`401` from the gateway, and the connection then fetches a real token. In the designer, start the gateway and click
**Login** on both OAuth connections, as in the variant README.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.**
> Regenerating creates new connection IDs and drops the credentials you entered. Rebuild into a new
> folder and compare instead.

> ⚠️ **The generated apps contain your real credentials**, written as app properties: the PostgreSQL password and
> `Gateway.Signing_Key` in `BankAPIGateway.flogo`; the LLM API key and both client secrets
> (`InsightAgentOAuth.Client_Secret`, `ServicingAgentOAuth.Client_Secret`) in `BankOpsAgentsNoMCP.flogo`. Replace
> them with placeholders before you commit or share the files.

## Test ladder

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python ../_rebuild/test_rules.py` | The base sample's rules, using the exact tool SQL the gateway also runs. See the base README. | Database only |
| 2 | `python _rebuild/gateway_smoke.py` | At the gateway, without an LLM: each agent gets a token with only its scopes; wrong or unknown clients are refused; missing, forged, expired and wrong-audience tokens get `401`; a missing scope gets `403` and is audited; a suspended agent is refused even with a valid token; the servicing agent can block a card while a limit increase waits for a person. Resets the data before and after. | Gateway running, `GATEWAY_SIGNING_KEY`, `GATEWAY_CLIENTS_FILE` |
| 3 | Chat by hand | The whole system: connect the shared Chatbot to `ws://localhost:9890/insight` or `/servicing` and follow the demo script in the variant README. There is no scripted chat test for this variant. | Both apps running, LLM key in the agents app |

## This variant's values

| | Value |
|---|---|
| Database | `bankops_agents` (the base sample's) |
| Agents app | WebSocket `9890`, paths `/insight` (`agt-insight-01`, 3 tools) and `/servicing` (`agt-servicing-01`, 6 tools) |
| Gateway | REST `9895`: `POST /oauth/token` and the `/api/...` endpoints listed in the variant README; token lifetime `Gateway.Token_TTL_Seconds` = `600` |
| Token claims | issuer `harbor-bank-idp`, audience `harbor-bank-api` (set in `database.sql`) |

The ports are set in the build scripts (`WS_PORT` and `BANK_GATEWAY_URL` in `build_agents_nomcp.py`; the
`Gateway.Port` property in `build_gateway.py`). To change them, edit the scripts and use the `BANK_GATEWAY_URL`
override for the test, or set the app properties in the designer.

## Changing the use case

1. Change the rules in `../database.sql`, the data in `../reset_data.sql` and the tools in
   `../_rebuild/tool_spec.py`, and run the base `test_rules.py` until it passes.
2. For a new or renamed tool, add it to the `HTTP` table in **both** `build_gateway.py` and `build_agents_nomcp.py`,
   and to the agent's `tools` list in `build_agents_nomcp.py` if it should have it. For a new scope, register the
   client again with it.
3. Regenerate the apps into an empty folder, then run `gateway_smoke.py`, updating its expectations to match.
