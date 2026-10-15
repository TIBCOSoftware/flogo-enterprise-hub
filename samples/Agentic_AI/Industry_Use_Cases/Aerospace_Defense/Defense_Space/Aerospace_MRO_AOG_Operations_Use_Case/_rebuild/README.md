> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# `_rebuild/`: regenerate and test the Aerospace MRO AOG Operations apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI (`fda`) and the
tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

## What's in this folder

| File | What it does |
|---|---|
| `SPEC.md` | The design spec the apps were built from: apps, ports and names, identity and base/team scope, which steps are deterministic, agent or human, the maintenance-control rules, every rule and reason code, the two-step part order and dispatch, case routing and the reviewer loop, the MCP tools, the A2A agents, the demo staff and aircraft and the test scope. |
| `tool_spec.py` | **Single source of truth** for the 19 MCP tools (15 controller + 4 reviewer): each tool's name, description, arguments and SQL (a guarded write and/or a read), plus the columns no controller tool and no reviewer tool may ever return. `build_mcp.py`, `test_rules.py` and `mcp_smoke.py` all import it, so the SQL that is tested is the SQL that ships. It also holds `AGENT_REF_TOOLS`, the three A2A agents' reference tools (name, description, `ref_*` SQL), used by `build_agents.py`, `test_rules.py`, `a2a_smoke.py` and `chat_e2e.py`. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `AerospaceMROMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the conditional email step for `email_ops_summary` (the email is sent only when the SQL says `SEND_OK`). Supports a chunked build (`BUILD_TO` / `RESUME_FROM`). |
| `build_agents.py` | Generates `AerospaceMROAgents.flogo`: three read-only A2A agents, `fault_triage_agent`, `repeat_defect_agent` and `shift_handover_agent`, each with one read-only reference tool (`get_ata_chapter_guide`, `get_repeat_defect_guide`, `get_handover_format_guide`). Each tool flow is `#act_postgresql_query SELECT * FROM ref_<topic>(CAST(?lookup AS text))` → `#actreturn` against the `PostgresConn` connection; the model can supply only the optional lookup `term`. Names, descriptions and SQL come from `tool_spec.AGENT_REF_TOOLS`. One part of each agent's reply needs text that only the table holds (the chapter's certification and triage note, the flag's standard reliability note, the status words and the closing line). |
| `build_orchestrator.py` | Generates `AerospaceMROAIOrchestrator.flogo`: WebSocket trigger → AI Agent (the MCP tools + the three A2A agents) → WebSocket reply, with one conversation per browser connection and two staff personas (MRO controller and reviewer). Checks its own output before it finishes. |
| `orchestrator_prompt.txt` | The orchestrator's system prompt, read by `build_orchestrator.py`. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule, including the full reviewer loop, plus the agents' `ref_*` reference functions (rows, lookup filter, unknown term = 0 rows, no personal or equipment records, SELECT-only, nothing lost from the old static text, part families read from `parts`, who decides from `case_routing`). No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime. |
| `a2a_smoke.py` | Test step 3b. Sends each A2A agent one small identity-free request over A2A JSON-RPC (no orchestrator) and proves from the Agents DEBUG log that its reference tool flow ran, the PostgreSQL query ran without error and returned rows, and that the reply used table-only text. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator (controllers and a maintenance manager, on separate connections) and checks the results in the database. Writes `chat_e2e_transcript.md`. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, base scope, part-order, spend, dispatch, return-to-service and reviewer rules are enforced), the agents' reference tables (`ata_chapter_guide`, `repeat_defect_guide`, `handover_guide`) with their `ref_*` functions, and demo data. |
| `seed_data.sql` | Demo data, with every volatile date relative to today. Included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant and the reviewers wrote and reloads the demo data. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the `aerospace_mro_governed`
  database loaded (see the main README, step 1).
- For step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required by `build_mcp.py` and the test scripts |
| Database name | `PG_DB` | — | `aerospace_mro_governed` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM API key | `LLM_API_KEY` | `API_Key` | required by `build_agents.py` and `build_orchestrator.py` |
| LLM model | `LLM_MODEL` | — (see below) | `gpt-5.5` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| Email sender (MCP server only) | `EMAIL_USERNAME` | `Username` | required by `build_mcp.py` |
| Email recipient (MCP server only) | `EMAIL_TO` or `TO_EMAIL` | — | the sender address |
| Email password (MCP server only) | `EMAIL_PASSWORD` | — | see below |
| SMTP host / port (MCP server only) | `SMTP_HOST` / `SMTP_PORT` | `Server` / `Port` | `smtp.gmail.com` / `465` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` (used only when no extension is found) | newest installed Flogo VS Code extension |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |
| Output folder for the build scripts | `OUT_DIR` | — | the use-case folder (refused if the `.flogo` already exists) |

**LLM model.** `build_agents.py` and `build_orchestrator.py` set `LLM_MODEL` to `gpt-5.5` unless the `LLM_MODEL`
environment variable is already set. The `LLM_Model` key in `config.md` is not used by them. To build with another
model, set `LLM_MODEL=<model>` when you run them. (`build_mcp.py` writes no model into its app, but it still stops
unless `LLM_MODEL` or `config.md`'s `LLM_Model` is set to some value.)

**Email password.** `fda` cannot encrypt a password, and the designer only accepts the email password as an encrypted
`SECRET:` value. So `build_mcp.py` uses `EMAIL_PASSWORD` only if it already starts with `SECRET:`; otherwise it writes
a portable dummy `SECRET:` value. Re-enter your app password in the designer's **App Properties** to send real email.
The plain-text password is never written into the app; the script prints which source it used, never the value.

The test scripts take the PostgreSQL host, port, user and database from environment variables only (same defaults as
above); the password and `psql` path come from the environment or `config.md`.

## Regenerate the apps

The scripts **refuse to overwrite** an existing `.flogo`, so build into an empty folder:

```bash
mkdir -p rebuilt
OUT_DIR=rebuilt python _rebuild/build_mcp.py
OUT_DIR=rebuilt python _rebuild/build_agents.py
OUT_DIR=rebuilt python _rebuild/build_orchestrator.py
```

On Windows Git Bash, prefix each command with `MSYS_NO_PATHCONV=1`. `build_mcp.py` connects to the database to read
each query's result columns; the other two don't. To keep each run short, build the MCP server in two parts:
`BUILD_TO=8 … build_mcp.py`, then `RESUME_FROM=8 … build_mcp.py`. Compare the result with the shipped apps, then delete
`rebuilt/`; don't commit it.

If a build stops with `UNKNOWN: unknown error, open '…\AerospaceMROMCPServer.flogo'`, another program (for example
the Flogo extension of a VS Code window that has this folder open) touched the file mid-build. Delete the partial
`.flogo` and build again into an `OUT_DIR` outside the open workspace, then copy the result in.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.** Regenerating creates
> new connection IDs and drops the credentials you entered. Rebuild into a new folder and compare instead.

> ⚠️ **The generated apps contain your real credentials** (PostgreSQL password, LLM key, email addresses), written as
> app properties. Replace them with placeholders before you commit or share the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL: identity and base scope, the two-step part order (incl. spend above the limit → manager case) and dispatch (certification, base, availability), cases and the full reviewer loop (team, spend authority, note, quantity, the parked part order or return to service, audit), the guarded email. Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. Also run `fda cm -f <app>.flogo` for each app. | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM. Reloads `reset_data.sql` before and after; this step tries to send one real email (N042NV's ops summary) to the `EMAIL_TO` inbox. | MCP server running |
| 3b | `A2A_LOG=<agents log> python _rebuild/a2a_smoke.py` | Each A2A agent answers over A2A, its reference tool runs `SELECT * FROM ref_<topic>(…)` without error and returns rows, and the reply uses table-only text. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG`; LLM key |
| 4 | `python _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database: controllers, a maintenance manager on a separate connection, blocked actions, a prompt-injection attempt and the reviewer loop. Resets the data before and after, and may send a real ops email to the `EMAIL_TO` inbox. | All three apps running, LLM key |

Start the apps for steps 3 and 4 as in the main README, step 3 (MCP Server → Agents → Orchestrator). Build the
executables in a folder **outside the repo** (the copies hold real credentials) with a relative `-f`.

Optional overrides:

- `MCP_URL` for step 3 (default `http://localhost:9812/aerospacemromcp`).
- `WS_URL` (default `ws://localhost:9810/aerospacemro`) and `REPLY_TIMEOUT` (seconds per reply, default 180) for step 4.
- `A2A_LOG=<file the Agents app logs to>` for step 4. Start the Agents app with `FLOGO_LOG_LEVEL=DEBUG` and send its
  output to that file; the agent checks need the DEBUG log. Step 4 then also confirms that
  `fault_triage_agent`, `repeat_defect_agent` and `shift_handover_agent` each really ran, and that no
  staff or technician name or ID, case ID, email address, phone number or session token reached any of them, and that each
  agent's reference tool queried PostgreSQL (at most once per agent call, no identity in the lookup term). Without `A2A_LOG`
  these checks are skipped.
- `--only teresa_aog,injection,gloria,teresa_status,kenji,wrong_code` for step 4 runs only some of the scenarios
  (`injection`, `gloria` and `teresa_status` follow on from `teresa_aog`). Pair it with `--transcript <file>` so the full
  `chat_e2e_transcript.md` is not overwritten.

## This sample's values

| | Value |
|---|---|
| Database | `aerospace_mro_governed` |
| Orchestrator | WebSocket `9810`, path `/aerospacemro` |
| MCP server | `9812`, path `/aerospacemromcp`, 19 tools. Controller (15): `verify_controller`, `get_base_fleet`, `get_work_orders`, `get_tail_history`, `get_parts`, `get_part_orders`, `get_technicians`, `get_aog_incidents`, `get_base_handover`, `propose_part_order`, `propose_dispatch`, `confirm_action`, `open_service_case`, `get_my_cases`, `email_ops_summary`. Reviewer (4): `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `fault_triage_agent` on `9813`, `repeat_defect_agent` on `9814`, `shift_handover_agent` on `9815`; reference tools `get_ata_chapter_guide` → `ref_ata_chapters()`, `get_repeat_defect_guide` → `ref_repeat_defect_criteria()`, `get_handover_format_guide` → `ref_handover_guide()` |
| Runtime model | `gpt-5.5` (app property `LLM_Model`) |

The ports and URLs are set in the build scripts (`PORT` and `ENDPOINT` in `build_mcp.py`, each agent's `port` in
`build_agents.py`, `WS_PORT`, `WS_PATH`, `MCP_URL` and `AGENTS` in `build_orchestrator.py`). To change them, edit the
scripts and the matching defaults in `mcp_smoke.py` / `chat_e2e.py` (or set `MCP_URL` / `WS_URL`), or set the app
properties and orchestrator URL properties as described in the main README.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py` (keep `SPEC.md` in
   step).
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
