# `orchestrated/_rebuild/`: regenerate and test the orchestrated variant from code

**You don't need this folder to run the demo.** The variant [README](../README.md) covers that.

This folder holds the Python scripts that generated the orchestrated variant's two `.flogo` apps with the Flogo Design
CLI (`fda`), and the tests that check agent-to-agent delegation. It covers only what is specific to this variant; the
shared settings, helpers and base tests are described in the base [`_rebuild/README.md`](../../_rebuild/README.md).

## What's in this folder

| File | What it does |
|---|---|
| `orch_common.py` | Shared settings for this variant: the ports, paths and URLs, the two specialist tools (scope, connection, prompt) and the orchestrator's prompt. It puts the base `_rebuild/` folder on `sys.path`, so the scripts here import `fda_common.py`, `mint_agent_tokens.py` and `tool_spec.py` from there. Not run on its own. |
| `build_specialists.py` | Generates `BankOpsSpecialists.flogo`: an MCP Server trigger with `JWT Token` auth and one tool per specialist, each with its own scope. Each tool flow audits the delegation under the caller's ID, lets the registry decide, then runs the specialist AI Agent with its own bank token, or returns `DELEGATION_REFUSED`. |
| `build_orchestrator.py` | Generates `BankOpsOrchestrator.flogo`: WebSocket trigger → LLM Client activity → WebSocket reply. The LLM settings and its only MCP server (the specialists, with the orchestrator's own token) are runtime inputs fed from app properties. One conversation per browser connection. |
| `test_delegation.py` | Test step 1. Runs the delegation SQL the specialist tools use against PostgreSQL. No Flogo, no LLM. |
| `mcp_smoke_orchestrated.py` | Test step 2. Calls the specialists server (and the bank server) directly, without the orchestrator, to check the token boundaries, per-specialist scopes and the registry gate, then makes real delegations. |
| `chat_e2e_orchestrated.py` | Test step 3. Holds scripted chats with the running orchestrator and checks the results in the database. Writes `chat_e2e_transcript.md`. |

The variant also needs `BankOpsMCPServer.flogo` (the bank tools), which is built by the base `_rebuild/build_mcp.py`.

Related files in the variant folder:

| File | What it does |
|---|---|
| `README.md` | How to configure and run this variant. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e_orchestrated.py` run. |

The database (`../database.sql`, `../reset_data.sql`) is the base sample's; it already holds the orchestrator
identity and the delegation functions.

## Before you start

- Everything in the base [`_rebuild/README.md`](../../_rebuild/README.md#before-you-start): Python 3.9+, the Flogo VS
  Code extension, `psql` with `bankops_agents` loaded, and the same settings from
  [`config.md`](../../../../../../skills-library/.claude/skills/config.md) or environment variables (PostgreSQL,
  `LLM_MODEL`, `LLM_API_KEY`, `LLM_PROVIDER`, `LLM_BASE_URL`, `FDA`, `PG_DB`, `CONFIG_MD`).
- For step 3 only: `pip install websocket-client`.
- Run every command below **from the variant folder** (`orchestrated/`).

**Secrets.** There are two signing secrets on purpose, so the orchestrator's token is rejected by the bank server and
a specialist's bank token is rejected by the specialists server. They come from environment variables only:

| Variable | Needed by | What it is |
|---|---|---|
| `JWT_SECRET` | `build_specialists.py` (always), `mcp_smoke_orchestrated.py` | The base sample's bank secret. The specialists' bank tokens are minted from it; it must match `MCP.JWT_Secret` in the running `BankOpsMCPServer`. |
| `SPECIALISTS_JWT_SECRET` | `build_specialists.py`, `mcp_smoke_orchestrated.py`; `build_orchestrator.py` unless `ORCHESTRATOR_TOKEN` is set | The secret the specialists server verifies tokens with. The orchestrator's token is minted from it. |
| `INSIGHTAGENT_MCP_TOKEN` / `SERVICINGAGENT_MCP_TOKEN` | `build_specialists.py` (optional) | Ready-made bank tokens for `agt-insight-01` / `agt-servicing-01`. If unset, they are minted from `JWT_SECRET`, valid for 30 days. |
| `ORCHESTRATOR_TOKEN` | `build_orchestrator.py` (optional) | A ready-made token for `agt-orchestrator-01`. If unset, it is minted from `SPECIALISTS_JWT_SECRET`, valid for 30 days. |

To mint the tokens yourself (for the shipped apps), set both secrets and run
`python ../_rebuild/mint_agent_tokens.py 30`; see the base README for its arguments.

## Regenerate the apps

The scripts **refuse to overwrite** an existing `.flogo`, and by default they write into `orchestrated/`, where the
shipped apps already are. Build into an empty folder:

```bash
mkdir -p rebuilt
OUT_DIR=rebuilt python _rebuild/build_specialists.py
OUT_DIR=rebuilt python _rebuild/build_orchestrator.py
```

`build_specialists.py` connects to the database to read each query's result columns, and checks that both AI Agents
are bound to the LLM connection. Build `BankOpsMCPServer.flogo` with the base scripts if you need it too. Compare the
result with the shipped apps, then delete `rebuilt/`; don't commit it.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.**
> Regenerating creates new connection IDs and drops the credentials you entered. Rebuild into a new
> folder and compare instead.

> ⚠️ **The generated apps contain your real credentials**, written as app properties: the PostgreSQL password, LLM
> API key, `MCP.JWT_Secret` and both specialists' bank tokens (`InsightAgent.MCP_Token`, `ServicingAgent.MCP_Token`)
> in `BankOpsSpecialists.flogo`; the LLM API key (`LLMClient.API_Key`) and `Orchestrator.MCP_Token` in
> `BankOpsOrchestrator.flogo`. Replace them with placeholders before you commit or share the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python ../_rebuild/test_rules.py`, then `python _rebuild/test_delegation.py` | The base sample's rules, then the delegation rules: the orchestrator is a registered identity that may only delegate and has no direct bank privilege; specialists and unknown callers can't delegate; the kill switch; every attempt is audited with the request text. Each resets the data before and after. | Database only |
| 2 | `python ../_rebuild/mcp_smoke.py`, then `python _rebuild/mcp_smoke_orchestrated.py` | The bank server's edge (see the base README), then: each server accepts only tokens signed with its own secret; the orchestrator sees only the specialists its scopes allow; an unknown or suspended orchestrator is refused before any specialist runs; a delegated request still runs under the specialist's own ID. The last checks call real specialist agents. Resets the data before and after. | `BankOpsMCPServer` and `BankOpsSpecialists` running, both secrets, LLM key in the specialists app |
| 3 | `python _rebuild/chat_e2e_orchestrated.py` | The whole chain through real chats with the orchestrator, with checks on the database. Resets the data before and after. | All three apps running, LLM keys |

Start the apps for steps 2 and 3 as in the variant README, step 4.

Optional overrides for step 3: `WS_URL` (default `ws://localhost:9880/bankops`), `REPLY_TIMEOUT` (seconds, default
240) and `TRANSCRIPT` (output file, default `chat_e2e_transcript.md` in the current folder). Step 2 takes its URLs
from `orch_common.py`. The tests in this folder always use the `bankops_agents` database.

## This variant's values

| | Value |
|---|---|
| Database | `bankops_agents` (the base sample's) |
| Orchestrator | WebSocket `9880`, path `/bankops`, privilege ID `agt-orchestrator-01` (scopes `agent:insight`, `agent:servicing`) |
| Specialists server | MCP `9872`, path `/bankops-specialists-mcp`, 2 tools: `ask_insight_agent` (scope `agent:insight`), `ask_servicing_agent` (scope `agent:servicing`) |
| Bank MCP server | `9871`, path `/bankops-mcp` (the base sample's) |

The ports and URLs are set in `orch_common.py` (`BANK_MCP_URL`, `SPECIALISTS_PORT`, `SPECIALISTS_PATH`,
`ORCH_WS_PORT`, `ORCH_WS_PATH`), which both the build scripts and the tests read. To change them, edit that file, or
set the app properties and connection URLs in the designer.

## Changing the use case

1. Change the delegation functions in `../database.sql`, or the orchestrator's identity and entitlements in
   `../reset_data.sql`, and run `test_delegation.py` until it passes. Its checks name this sample's agents, so update
   them to match.
2. Change the specialists (tool, scope, prompt) or the orchestrator's prompt in `orch_common.py`. A new specialist
   also needs its scope on `agt-orchestrator-01` in `../_rebuild/tool_spec.py` (`AGENTS`), an entitlement row for
   `agt-orchestrator-01` in `../reset_data.sql`, and new orchestrator tokens.
3. Regenerate the apps into an empty folder, then run steps 2 and 3, updating their expectations the same way.
