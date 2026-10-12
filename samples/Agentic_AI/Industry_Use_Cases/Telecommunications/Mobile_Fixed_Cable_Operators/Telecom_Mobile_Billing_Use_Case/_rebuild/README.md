# `_rebuild/`: regenerate and test the Mobile Billing apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI
(`fda`) and the tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

## What's in this folder

| File | What it does |
|---|---|
| `SPEC.md` | The design spec the apps were built from: apps, ports and names, identity and scope, which steps are deterministic, agent or human, the plan catalogue, every rule and reason code, the two-step actions, case routing, the MCP tools, the A2A agents, the demo customers and the test scope. |
| `tool_spec.py` | **Single source of truth** for the 13 MCP tools: each tool's name, description, arguments and SQL (a guarded write and/or a read), plus the columns no tool may ever return. `build_mcp.py` and `test_rules.py` both import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `MobileBillingMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the conditional email step for `email_action_confirmation` (the email is sent only when the SQL says `SEND_OK`). |
| `build_agents.py` | Generates `MobileBillingAgents.flogo`: three read-only A2A agents, `PlanRecommender`, `ChargeClassifier` and `BillExplainer`, each with one tool that returns static reference text. This app has no database connection. |
| `build_orchestrator.py` | Generates `MobileBillingAIOrchestrator.flogo`: WebSocket trigger → AI Agent (the MCP tools + the three A2A agents) → WebSocket reply, with one conversation per browser connection. Checks its own output before it finishes. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator and checks the results in the database. Writes `chat_e2e_transcript.md`. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, scoping and business rules are enforced) and demo data. |
| `seed_data.sql` | Demo data, with every date relative to today. Included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant wrote and reloads the demo data. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the
  `mobile_billing` database loaded (see the main README, step 1).
- For step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required by `build_mcp.py` and the test scripts |
| Database name | `PG_DB` | — | `mobile_billing` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM API key | `LLM_API_KEY` | `API_Key` | required by `build_agents.py` and `build_orchestrator.py` |
| LLM model | `LLM_MODEL` | — (see below) | `gpt-5.5` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| Email sender (MCP server only) | `EMAIL_USERNAME` | `Username` | required by `build_mcp.py` |
| Email recipient (MCP server only) | `EMAIL_TO` or `TO_EMAIL` | — | the sender address |
| Email password (MCP server only) | `EMAIL_PASSWORD` | `Password` | see below |
| SMTP host / port (MCP server only) | `SMTP_HOST` / `SMTP_PORT` | `Server` / `Port` | `smtp.gmail.com` / `465` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` (used only when no extension is found) | newest installed Flogo VS Code extension |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

**LLM model.** `build_agents.py` and `build_orchestrator.py` set `LLM_MODEL` to `gpt-5.5` unless the
`LLM_MODEL` environment variable is already set, so the apps they generate use `gpt-5.5` by default.
The `LLM_Model` key in `config.md` is not used by them. To build with another model, set
`LLM_MODEL=<model>` when you run them. (`build_mcp.py` writes no model into its app, but it still stops
unless `LLM_MODEL` or `config.md`'s `LLM_Model` is set to some value.)

**Email password.** `fda` cannot encrypt a password, and the designer only accepts the email password as
an encrypted `SECRET:` value. So `build_mcp.py` picks the `Email_App_Password` value in this order:

1. your `EMAIL_PASSWORD` / `Password` value, if it already starts with `SECRET:`;
2. otherwise, an existing `SECRET:` value for `Email_App_Password` copied from another `.flogo` under
   `samples/Agentic_AI` whose password has the same length as yours (it assumes that is the same mailbox);
3. otherwise, a dummy `SECRET:` value. Re-enter your app password in the designer's **App Properties**.

The plain-text password is never written into the app. It prints which source it used, never the value.

The test scripts take the PostgreSQL host, port, user and database from environment variables only
(same defaults as above); the password and `psql` path come from the environment or `config.md`.

## Regenerate the apps

The scripts **refuse to overwrite** an existing `.flogo`, so build into an empty folder:

```bash
mkdir -p rebuilt
OUT_DIR=rebuilt python _rebuild/build_mcp.py
OUT_DIR=rebuilt python _rebuild/build_agents.py
OUT_DIR=rebuilt python _rebuild/build_orchestrator.py
```

`build_mcp.py` connects to the database to read each query's result columns; the other two don't.
Compare the result with the shipped apps, then delete `rebuilt/`; don't commit it.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.**
> Regenerating creates new connection IDs and drops the credentials you entered. Rebuild into a new
> folder and compare instead.

> ⚠️ **The generated apps contain your real credentials** (PostgreSQL password, LLM key, email
> addresses, and an email password `SECRET:` value that may have been copied from another sample),
> written as app properties. Replace them with placeholders before you commit or share the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL. Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM. Reloads `reset_data.sql` before and after; this step sends one real email to the `EMAIL_TO` inbox. | MCP server running |
| 4 | `python _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database. Resets the data before and after, and sends real confirmation emails to the `EMAIL_TO` inbox. | All three apps running, LLM key |

Start the apps for steps 3 and 4 as in the main README, step 3 (MCP Server → Agents → Orchestrator).

Optional overrides:

- `MCP_URL` for step 3.
- `WS_URL` and `REPLY_TIMEOUT` (seconds per reply, default 180) for step 4.
- `A2A_LOG=<file the Agents app logs to>` for step 4. Start the Agents app with `FLOGO_LOG_LEVEL=DEBUG`
  and send its output to that file. Step 4 then also confirms that `BillExplainer`, `ChargeClassifier`
  and `PlanRecommender` each really ran, and that no name, mobile number, account ID, email address or
  session token reached any of them. Without `A2A_LOG` these checks are skipped.
- `--only maria,james,priya,wrong_otp` for step 4 runs only some of the scenarios. Pair it with
  `--transcript <file>` so the full `chat_e2e_transcript.md` is not overwritten.

## This sample's values

| | Value |
|---|---|
| Database | `mobile_billing` |
| Orchestrator | WebSocket `9900`, path `/mobilebilling` |
| MCP server | `9902`, path `/mobilebillingmcpserver`, 13 tools: `verify_customer`, `get_my_account`, `get_my_bills`, `get_bill_detail`, `get_bill_comparison`, `get_my_usage`, `get_my_subscriptions`, `get_my_payments`, `get_eligible_plans`, `propose_action`, `confirm_action`, `open_service_case`, `email_action_confirmation` |
| A2A agents | `PlanRecommender` on `9903`, `ChargeClassifier` on `9904`, `BillExplainer` on `9905` |

The ports and URLs are set in the build scripts (`PORT` and `ENDPOINT` in `build_mcp.py`, each agent's
`port` in `build_agents.py`, `WS_PORT`, `WS_PATH`, `MCP_URL` and `AGENTS` in `build_orchestrator.py`).
To change them, edit the scripts and the matching defaults in `mcp_smoke.py` / `chat_e2e.py` (or set
`MCP_URL` / `WS_URL`), or set the app properties and orchestrator URL properties as described in the
main README.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py`
   (keep `SPEC.md` in step).
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
