> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# `_rebuild/`: regenerate and test the Hospital Post-Discharge Care apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI (`fda`) and the
tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

## What's in this folder

| File | What it does |
|---|---|
| `SPEC.md` | The design spec the apps were built from: apps, ports and names, identity and ward/team scope, which steps are deterministic, agent or human, the clinical-operations rules, every rule and reason code, the two-step booking, case routing and the reviewer loop, the MCP tools, the A2A agents, the demo staff and patients and the test scope. |
| `tool_spec.py` | **Single source of truth** for the 18 MCP tools (14 coordinator + 4 reviewer): each tool's name, description, arguments and SQL (a guarded write and/or a read), plus the columns no coordinator tool and no reviewer tool may ever return. It also holds `AGENT_REF_TOOLS`: the three A2A agents' reference tools (name, description, the one `term` argument and the fixed `SELECT * FROM ref_<topic>(CAST(?lookup AS text))`). `build_mcp.py`, `build_agents.py`, `test_rules.py`, `mcp_smoke.py`, `a2a_smoke.py` and `chat_e2e.py` import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `HospitalCareMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the conditional email step for `email_patient_summary` (the email is sent only when the SQL says `SEND_OK`). Supports a chunked build (`BUILD_TO` / `RESUME_FROM`). |
| `build_agents.py` | Generates `HospitalCareAgents.flogo`: three read-only A2A agents, `discharge_instructions_agent`, `med_reconciliation_agent` and `followup_slot_agent`, each with one read-only reference tool: `#act_postgresql_query` → `#actreturn`, reading `ref_plain_language`, `ref_med_rec` or `ref_slot_guide` (reference tables only, no patient data) over the app's own PostgreSQL connection. The model can supply only the optional lookup `term`. |
| `build_orchestrator.py` | Generates `HospitalCareAIOrchestrator.flogo`: WebSocket trigger → AI Agent (the MCP tools + the three A2A agents) → WebSocket reply, with one conversation per browser connection and two staff personas (coordinator and reviewer). Checks its own output before it finishes. |
| `orchestrator_prompt.txt` | The orchestrator's system prompt, read by `build_orchestrator.py`. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule, including the full reviewer loop. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime. |
| `a2a_smoke.py` | Test step 3b. Sends each A2A agent one small, identity-free request over A2A and checks in the Agents app's DEBUG log that its reference tool flow ran and its PostgreSQL query completed without error and returned rows. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator (coordinators and a pharmacist, on separate connections) and checks the results in the database. Writes `chat_e2e_transcript.md`. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, ward scope, follow-up, medicine, bed and reviewer rules are enforced) and demo data. |
| `seed_data.sql` | Demo data, with every volatile date relative to today. Included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant and the reviewers wrote and reloads the demo data. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the `hospital_governed`
  database loaded (see the main README, step 1).
- For step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.example.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required by `build_mcp.py` and the test scripts |
| Database name | `PG_DB` | — | `hospital_governed` |
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
`BUILD_TO=9 … build_mcp.py`, then `RESUME_FROM=9 … build_mcp.py`. Compare the result with the shipped apps, then delete
`rebuilt/`; don't commit it.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.** Regenerating creates
> new connection IDs and drops the credentials you entered. Rebuild into a new folder and compare instead.

> ⚠️ **The generated apps contain your real credentials** (PostgreSQL password, LLM key, email addresses), written as
> app properties. Replace them with placeholders before you commit or share the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL: identity and ward scope, the two-step booking, medicine orders and high-alert parking, bed turnover, cases and the full reviewer loop (team, days'-supply limit, note, amount, the parked dispense or bed turnover, audit), and the agents' `ref_*` reference functions (lookup filtering, unknown input → 0 rows, no personal data, SELECT-only, nothing from the old static text lost). Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. Also run `fda cm -f <app>.flogo` for each app. | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM. Reloads `reset_data.sql` before and after; this step tries to send one real email (John's plan) to the `EMAIL_TO` inbox. | MCP server running |
| 3b | `A2A_LOG=<agents log> python _rebuild/a2a_smoke.py` | Each A2A agent answers over A2A, calls its reference tool, and the tool's PostgreSQL query runs without error (from the Agents app's DEBUG log). Uses the LLM (3 calls); writes nothing. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG`, LLM key |
| 4 | `python _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database: coordinators, a pharmacist on a separate connection, blocked actions, a prompt-injection attempt and the reviewer loop. Resets the data before and after, and may send a real patient email to the `EMAIL_TO` inbox. | All three apps running, LLM key |

Start the apps for steps 3 and 4 as in the main README, step 3 (MCP Server → Agents → Orchestrator). Build the
executables in a folder **outside the repo** (the copies hold real credentials) with a relative `-f`.

Optional overrides:

- `MCP_URL` for step 3 (default `http://localhost:9922/hospitalcaremcp`).
- `WS_URL` (default `ws://localhost:9920/hospitalcare`) and `REPLY_TIMEOUT` (seconds per reply, default 180) for step 4.
- `A2A_LOG=<file the Agents app logs to>` for step 4. Start the Agents app with `FLOGO_LOG_LEVEL=DEBUG` and send its
  output to that file; the agent checks need the DEBUG log. Step 4 then also confirms that
  `discharge_instructions_agent`, `med_reconciliation_agent` and `followup_slot_agent` each really ran, that no
  patient name, MRN, bed, staff or case ID, email address or session token reached any of them, and (full run only)
  that each agent's reference tool queried PostgreSQL without error, at most once per agent call, with no identity in
  its lookup term. Without `A2A_LOG` these checks are skipped.
- `--only john,margaret,pharmacist,rachel_status,daniel,wrong_code` for step 4 runs only some of the scenarios
  (`pharmacist` and `rachel_status` follow on from `margaret`). Pair it with `--transcript <file>` so the full
  `chat_e2e_transcript.md` is not overwritten.

## This sample's values

| | Value |
|---|---|
| Database | `hospital_governed` |
| Orchestrator | WebSocket `9920`, path `/hospitalcare` |
| MCP server | `9922`, path `/hospitalcaremcp`, 18 tools. Coordinator (14): `verify_coordinator`, `get_ward_discharges`, `get_discharge_summary`, `get_patient_appointments`, `get_followup_slots`, `get_pharmacy_orders`, `get_ward_beds`, `propose_followup`, `confirm_action`, `order_discharge_meds`, `request_bed_turnover`, `open_service_case`, `get_my_cases`, `email_patient_summary`. Reviewer (4): `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `discharge_instructions_agent` on `9923`, `med_reconciliation_agent` on `9924`, `followup_slot_agent` on `9925` |
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
