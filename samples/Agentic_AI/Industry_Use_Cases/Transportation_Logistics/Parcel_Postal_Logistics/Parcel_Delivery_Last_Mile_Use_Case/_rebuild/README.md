# `_rebuild/`: regenerate and test the Parcel Delivery apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI
(`fda`) and the tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

## What's in this folder

| File | What it does |
|---|---|
| `tool_spec.py` | **Single source of truth.** Every MCP tool's name, description, arguments and SQL (a guarded write and/or a read), plus the A2A agent's tool (`search_delivery_options`). The build scripts and `test_rules.py` both import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `ParcelDeliveryMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the email step for `email_confirmation`. The email goes to the `To_Email` inbox; the SQL decides its subject, body and reported outcome, so an unauthorised call carries no parcel details. |
| `build_agents.py` | Generates `ParcelDeliveryAgents.flogo`: the A2A agent `delivery_options_agent` and its one read-only tool. |
| `build_orchestrator.py` | Generates `ParcelDeliveryAIOrchestrator.flogo`: WebSocket trigger → AI Agent (MCP tools + the A2A agent) → WebSocket reply, with one conversation per browser connection. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator and checks the results in the database. Writes `chat_e2e_transcript.md` to the folder you run it from. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, scoping and business rules are enforced) and demo data. |
| `seed_data.sql` | Demo data, included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant wrote and reloads the demo data. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the
  `parcel_delivery` database loaded (see the main README, step 1).
- For step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required |
| Database name | `PG_DB` | — | `parcel_delivery` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM model | `LLM_MODEL` | `LLM_Model` | required for every build script |
| LLM API key | `LLM_API_KEY` | `API_Key` | required for `build_agents.py` and `build_orchestrator.py` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| Email (MCP server only) | `EMAIL_USERNAME`, `EMAIL_PASSWORD`, `TO_EMAIL`, `SMTP_HOST`, `SMTP_PORT` | `Username`, `Password` | `TO_EMAIL` = the sender; `smtp.gmail.com` / `465` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` | newest installed Flogo VS Code extension |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

The test scripts take the PostgreSQL host, user and database name (`PG_HOST`, `PG_USER`, `PG_DB`) from
environment variables only, and use psql's default port. They read the password and `psql` path from
the environment or `config.md`.

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

> ⚠️ **The generated apps contain your real credentials** (PostgreSQL password, LLM key, email
> password), written as app properties. Replace them with placeholders before you commit or share
> the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL. Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM. Load `reset_data.sql` before and after; this step leaves one executed reschedule and one service case behind, and sends one real email to the `To_Email` inbox. | MCP server running |
| 4 | `python _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database. Resets the data before and after. | All three apps running, LLM key |

Start the apps for steps 3 and 4 as in the main README, step 3 (MCP Server → Agents → Orchestrator).

Optional overrides:

- `MCP_URL` for step 3.
- `WS_URL` and `REPLY_TIMEOUT` (seconds, default 150) for step 4.
- `A2A_LOG=<file the Agents app logs to>` for step 4, which also confirms `delivery_options_agent` ran.

## This sample's values

| | Value |
|---|---|
| Database | `parcel_delivery` |
| Orchestrator | WebSocket `9890`, path `/parceldelivery` |
| MCP server | `9892`, path `/parcel-delivery-mcp`, 11 tools: `verify_recipient`, `get_my_parcels`, `get_parcel_detail`, `get_tracking_history`, `propose_reschedule`, `confirm_reschedule`, `propose_redirect`, `confirm_redirect`, `email_confirmation`, `open_service_case`, `get_my_cases` |
| A2A agent | `delivery_options_agent` on `9893` |

The ports and URLs are set in the build scripts (`PORT`, `ENDPOINT`, `WS_PORT`, `WS_PATH`, `MCP_URL`,
`A2A_URL`). To change them, edit the scripts and the matching values in `mcp_smoke.py` / `chat_e2e.py`,
or set the app properties and orchestrator connection URLs as described in the main README.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py`.
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
