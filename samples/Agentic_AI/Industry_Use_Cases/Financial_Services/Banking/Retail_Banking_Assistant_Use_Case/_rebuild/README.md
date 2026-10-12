# `_rebuild/`: regenerate and test the Retail Banking apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI
(`fda`) and the tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

## What's in this folder

| File | What it does |
|---|---|
| `tool_spec.py` | **Single source of truth.** Every MCP tool's name, description, arguments and SQL (a guarded write and/or a read), plus the SQL for the A2A agent's `lookup_merchant` tool. The build scripts and `test_rules.py` both import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `RetailBankingMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the conditional email step for `email_my_confirmation` (it sends only when the SQL returns `send_status = SEND`). |
| `build_agents.py` | Generates `RetailBankingAgents.flogo`: the A2A agent `dispute_triage_agent` and its one read-only tool, `lookup_merchant`. |
| `build_orchestrator.py` | Generates `RetailBankingAIOrchestrator.flogo`: WebSocket trigger → AI Agent (MCP tools + the A2A agent) → WebSocket reply, with one conversation per browser connection. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime. |
| `a2a_smoke.py` | Test step 3. Calls the running Agents app directly (no orchestrator): fetches the agent card and checks that `dispute_triage_agent` decodes a cryptic descriptor and suggests a reason code. Changes no data. |
| `ws_smoke.py` | Test step 3. A quick WebSocket check of the running orchestrator: connects, sends one message and checks that a reply comes back and says it is an AI. Changes no data. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator and checks the results in the database. Writes `chat_e2e_transcript.md` to the current folder. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, scoping and business rules are enforced) and demo data. |
| `seed_data.sql` | Demo data, included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant wrote and reloads the demo data. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |
| `banking.spec.md` | The design spec the apps were built from: apps and ports, which steps are agent, deterministic or human, the rules and reason codes, the tools and the A2A agent. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the
  `banking_governed` database loaded (see the main README, step 1).
- For `ws_smoke.py` and step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required |
| Database name | `PG_DB` | — | `banking_governed` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM model | `LLM_MODEL` | `LLM_Model` | required for every build script |
| LLM API key | `LLM_API_KEY` | `API_Key` | required for `build_agents.py` and `build_orchestrator.py` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| Email sender (MCP server only) | `EMAIL_USERNAME` | `Username` | required for `build_mcp.py` |
| Email password (MCP server only) | `EMAIL_PASSWORD` | `Password` | placeholder (see below) |
| Email recipient / SMTP server (MCP server only) | `TO_EMAIL` / `SMTP_HOST` / `SMTP_PORT` | — | recipient = sender; `smtp.gmail.com` / `465` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` | newest installed Flogo VS Code extension (`config.md` is used only if none is found) |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

The test scripts take the PostgreSQL host, port, user and database name from environment variables only
(same defaults as above); they take the password and the `psql` path from `config.md` too.

**Email password.** `build_mcp.py` writes your email password into the app's `Email_App_Password`
property only if it already starts with `SECRET:` (an encrypted value copied from the Flogo designer).
If you give a plain password, such as a Gmail App Password as you typed it, or give none, the app gets a
placeholder `SECRET:` value instead, because a plain string makes the build fail. In that case open
`RetailBankingMCPServer.flogo` in the designer and enter your real App Password in `Email_App_Password`
(App Properties) before the email tool can send.

## Regenerate the apps

The scripts **refuse to overwrite** an existing `.flogo`, so build into an empty folder:

```bash
mkdir -p rebuilt
OUT_DIR=rebuilt python _rebuild/build_mcp.py
OUT_DIR=rebuilt python _rebuild/build_agents.py
OUT_DIR=rebuilt python _rebuild/build_orchestrator.py
```

`build_mcp.py` and `build_agents.py` connect to the database to read each query's result columns.
Compare the result with the shipped apps, then delete `rebuilt/`; don't commit it.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.**
> Regenerating creates new connection IDs and drops the credentials you entered. Rebuild into a new
> folder and compare instead.

> ⚠️ **The generated apps contain your real credentials** (PostgreSQL password, LLM key, email address
> and, if you supplied a `SECRET:` value, the email password), written as app properties. Replace them
> with placeholders before you commit or share the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL. Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM. Reloads `reset_data.sql` before and after; this step sends one real confirmation email to the MCP server's `To_Email`, so its email properties must be set. | MCP server running |
| 3 | `python _rebuild/a2a_smoke.py` | `dispute_triage_agent` answers on its own: agent card served, descriptor decoded, reason code suggested. Changes no data. | Agents app running, LLM key |
| 3 | `python _rebuild/ws_smoke.py` | The orchestrator accepts a WebSocket connection and replies. Changes no data. | All three apps running, LLM key |
| 4 | `python _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database. Resets the data before and after; sends at most one real confirmation email. | All three apps running, LLM key |

Start the apps for steps 3 and 4 as in the main README, step 3.

Optional overrides:

- `MCP_URL` for `mcp_smoke.py`.
- `A2A_URL` and `A2A_TIMEOUT` (seconds, default 180) for `a2a_smoke.py`.
- `WS_URL` and `REPLY_TIMEOUT` (seconds, default 150) for `ws_smoke.py` and step 4.
- `A2A_LOG=<file the Agents app logs to>` for step 4, which also confirms `dispute_triage_agent` ran.

## This sample's values

| | Value |
|---|---|
| Database | `banking_governed` |
| Orchestrator | WebSocket `9860`, path `/retailbanking` |
| MCP server | `9862`, path `/retail-banking-mcp`, 13 tools: `verify_customer`, `get_my_accounts`, `get_my_transactions`, `get_my_cards`, `get_my_loans`, `find_branch`, `propose_card_block`, `confirm_card_block`, `propose_dispute`, `confirm_dispute`, `open_service_case`, `get_my_cases`, `email_my_confirmation` |
| A2A agent | `dispute_triage_agent` on `9863`, with the read-only tool `lookup_merchant` |

The ports and URLs are set in the build scripts (`PORT` and `ENDPOINT` in `build_mcp.py`, `PORT` in
`build_agents.py`, `WS_PORT`, `WS_PATH`, `MCP_URL` and `A2A_URL` in `build_orchestrator.py`). To change
them, edit the scripts and pass the new URLs to the test scripts (`MCP_URL`, `A2A_URL`, `WS_URL`), or set
the app properties and orchestrator connection URLs as described in the main README, step 2.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py`.
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
