# `_rebuild/`: regenerate and test the Agent Privilege IDs apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the two base `.flogo` apps with the Flogo Design CLI (`fda`),
the token minter, and the tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the agents, tools or rules and check the privileges still hold.

The [orchestrated](../orchestrated/_rebuild/README.md) and [no-MCP](../no-mcp/_rebuild/README.md) variants reuse
`fda_common.py`, `tool_spec.py` and `mint_agent_tokens.py` from this folder (see [Other variants](#other-variants)).

## What's in this folder

| File | What it does |
|---|---|
| `tool_spec.py` | **Single source of truth.** Every MCP tool's name, description, required scope, arguments and SQL (an audited guarded write plus a read of the outcome), and the agents (privilege IDs) with the scopes their tokens carry. The build scripts and `test_rules.py` both import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `mint_agent_tokens.py` | Issues one HS256 JWT per agent (the stand-in for your identity provider). Used on its own to mint tokens for the shipped apps, and imported by the build and test scripts. |
| `build_mcp.py` | Generates `BankOpsMCPServer.flogo`: the MCP Server trigger with `JWT Token` auth, and one flow per tool in `tool_spec.py`, each with its required scope. |
| `build_agents.py` | Generates `BankOpsAgents.flogo`: one WebSocket server with two AI Agents (`/insight` and `/servicing`), each with its own MCP connection carrying its own token, and one conversation per browser connection. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every privilege and approval rule. No Flogo needed. |
| `mcp_smoke.py` | Test step 2. Calls the running MCP server with real, forged and expired tokens (no LLM) to check both the token layer and the agent registry hold in the Flogo runtime. |
| `chat_e2e.py` | Test step 3. Holds scripted chats with both agents and checks the results in the database. Writes `chat_e2e_transcript.md`. |

Related files in the sample folder:

| File | What it does |
|---|---|
| `database.sql` | Schema and the **rule functions** (where identity, entitlement, approval and audit are enforced), including those the orchestrated and no-MCP variants use. Loads `reset_data.sql` for the data. |
| `reset_data.sql` | The demo data: agent identities and entitlements (the registry), human approvers, accounts, cards and transactions. Run it on its own to clear everything the agents wrote and reload the data. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the `bankops_agents`
  database loaded (see the main README, step 1).
- For step 3 only: `pip install websocket-client`.
- Run every command below **from the sample folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../skills-library/.claude/skills/config.example.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required by every script that uses PostgreSQL |
| Database name | `PG_DB` | — | `bankops_agents` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM model | `LLM_MODEL` | `LLM_Model` | required by **every** build script (read when `fda_common.py` loads) |
| LLM API key | `LLM_API_KEY` | `API_Key` | required by `build_agents.py` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` | newest installed Flogo VS Code extension; the `config.md` value is used only if none is found |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

The test scripts read the PostgreSQL password and `psql` path the same way, but take the host and user from
environment variables only and use psql's default port. `test_rules.py` honours `PG_DB`; `mcp_smoke.py` and
`chat_e2e.py` always use `bankops_agents`.

**Secrets.** These come from environment variables only, never from `config.md`:

| Variable | Needed by | What it is |
|---|---|---|
| `JWT_SECRET` | `build_mcp.py`, `mint_agent_tokens.py`, `mcp_smoke.py`; `build_agents.py` unless both tokens below are set | The HS256 secret the agent tokens are signed with. The MCP server verifies tokens with it, so every script must use the same value. |
| `INSIGHT_TOKEN` / `SERVICING_TOKEN` | `build_agents.py` (optional) | Ready-made tokens for `agt-insight-01` / `agt-servicing-01`. If unset, the script mints them from `JWT_SECRET`, valid for 30 days. |
| `SPECIALISTS_JWT_SECRET` | `mint_agent_tokens.py` (optional) | Only for the orchestrated variant: without it, `agt-orchestrator-01` is skipped. |

To pick a secret: `export JWT_SECRET="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"`.

**Minting tokens.** `mint_agent_tokens.py` takes an optional number of days (default `30`) followed by optional agent
IDs (default: every agent in `tool_spec.py`), and prints `<agent_id> <TAB> <token>`:

```bash
python _rebuild/mint_agent_tokens.py                    # every agent, 30 days
python _rebuild/mint_agent_tokens.py 7 agt-insight-01   # one agent, 7 days
```

The token's `sub` is the privilege ID and `scp` its scopes from `tool_spec.AGENTS`. In production the tokens come from
your identity provider instead.

## Regenerate the apps

The scripts **refuse to overwrite** an existing `.flogo`, and by default they write into the sample folder, where the
shipped apps already are. Build into an empty folder:

```bash
mkdir -p rebuilt
OUT_DIR=rebuilt python _rebuild/build_mcp.py
OUT_DIR=rebuilt python _rebuild/build_agents.py
```

`build_mcp.py` connects to the database to read each query's result columns. Compare the result with the shipped
apps, then delete `rebuilt/`; don't commit it.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.**
> Regenerating creates new connection IDs and drops the credentials you entered. Rebuild into a new
> folder and compare instead.

> ⚠️ **The generated apps contain your real credentials**, written as app properties: the PostgreSQL password and
> `MCP.JWT_Secret` in `BankOpsMCPServer.flogo`; the LLM API key and both agent tokens (`InsightAgent.MCP_Token`,
> `ServicingAgent.MCP_Token`) in `BankOpsAgents.flogo`. Replace them with placeholders before you commit or share
> the files.

The agent tokens built into `BankOpsAgents.flogo` expire (30 days when minted by the script). Mint new ones and paste
them on the agents' MCP connections, or rebuild with `INSIGHT_TOKEN` / `SERVICING_TOKEN` set.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every registry, entitlement, approval and audit rule, using the exact tool SQL with the agent ID bound as the token would bind it. Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python _rebuild/mcp_smoke.py` | At the MCP edge, without an LLM: missing, forged and expired tokens are rejected; each token sees only the tools its scopes allow; suspended or unregistered agents are refused even with a valid token; every call that reaches a flow is audited. Resets the data before and after. | MCP server running, `JWT_SECRET` |
| 3 | `python _rebuild/chat_e2e.py` | The whole system through real chats with both agents, including prompt injection, a human approval and the kill switch, with checks on the database. Resets the data before and after. | Both apps running, LLM key in the agents app |

Start the apps for steps 2 and 3 as in the main README, steps 3 and 4.

Optional overrides:

- `MCP_URL` for step 2 (default `http://localhost:9871/bankops-mcp`).
- `WS_BASE` (default `ws://localhost:9870`), `REPLY_TIMEOUT` (seconds, default 150) and `TRANSCRIPT` (output file,
  default `chat_e2e_transcript.md` in the current folder) for step 3.

## This sample's values

| | Value |
|---|---|
| Database | `bankops_agents` |
| Agents app | WebSocket `9870`, paths `/insight` (`agt-insight-01`) and `/servicing` (`agt-servicing-01`) |
| MCP server | `9871`, path `/bankops-mcp`, 6 tools: `whoami`, `get_account_summary`, `list_recent_transactions`, `block_card`, `request_limit_increase`, `get_request_status` |
| Privilege IDs | `agt-insight-01`, `agt-servicing-01`, `agt-legacy-07` (suspended); `agt-orchestrator-01` for the orchestrated variant |
| Token claims | issuer `harbor-bank-agent-registry`, audience `bankops-mcp` (in `mint_agent_tokens.py`) |

The ports and URLs are set in the build scripts (`PORT` and `ENDPOINT` in `build_mcp.py`; `WS_PORT` and `MCP_URL` in
`build_agents.py`). To change them, edit the scripts and the matching defaults in `mcp_smoke.py` / `chat_e2e.py`
(or use the overrides above), or set the app properties and connection URLs in the designer.

## Changing the use case

1. Change the rule functions in `database.sql`, the registry and data in `reset_data.sql`, and the tools or agents in
   `tool_spec.py` (`TOOLS`, `AGENTS`). A new tool needs a scope in `tool_spec.py` **and** an entitlement row for
   each agent that may use it in `reset_data.sql`.
2. Reload the database, then run `test_rules.py` until it passes. Its checks name this sample's agents, accounts and
   cards, so update them to match your data.
3. Regenerate the apps into an empty folder, then run steps 2 and 3, updating their expectations the same way. If you
   changed an agent's scopes, mint new tokens.

The variants import `tool_spec.py` too, so a change here also reaches them on their next rebuild (see below).

## Other variants

Each variant has its own `_rebuild/` folder with its build scripts and tests, and reuses this folder's shared
settings and helpers:

- [`no-mcp/_rebuild/`](../no-mcp/_rebuild/README.md): the agents call the bank API through a Flogo API gateway with
  their own OAuth 2.0 client credentials. Rebuilds `BankAPIGateway.flogo` and `BankOpsAgentsNoMCP.flogo`. A new tool
  in `tool_spec.py` also needs an entry in the `HTTP` table of both its build scripts.
- [`orchestrated/_rebuild/`](../orchestrated/_rebuild/README.md): a front-door orchestrator that delegates to the two
  agents, exposed as JWT-protected MCP tools. Rebuilds `BankOpsSpecialists.flogo` and `BankOpsOrchestrator.flogo`, and
  uses `BankOpsMCPServer.flogo` from this folder's build.
