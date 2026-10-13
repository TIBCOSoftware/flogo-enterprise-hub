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
| `SPEC.md` | The design spec the apps were built from: apps, ports and names, identity and scope, which steps are deterministic, agent or human, the plan catalogue, every rule and reason code, the two-step actions, case routing and the reviewer loop, the MCP tools, the A2A agents and their reference tables, the demo customers and reviewers and the test scope. |
| `tool_spec.py` | **Single source of truth** for the 18 MCP tools (14 customer + 4 reviewer): each tool's name, description, arguments and SQL (a guarded write and/or a read), the columns no customer or reviewer tool may ever return, and `AGENT_REF_TOOLS` - the one read-only PostgreSQL reference tool of each A2A agent. `build_mcp.py`, `build_agents.py` and the tests all import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `MobileBillingMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the conditional email step for `email_action_confirmation` (the email is sent only when the SQL says `SEND_OK`). Can build in chunks (`BUILD_TO=<n>`, then `RESUME_FROM=<n>`). |
| `build_agents.py` | Generates `MobileBillingAgents.flogo`: three read-only A2A agents, `PlanRecommender`, `ChargeClassifier` and `BillExplainer`, each with one tool that reads its reference table from PostgreSQL (`SELECT * FROM ref_<topic>(CAST(?lookup AS text))`). Checks its own output before it finishes. |
| `build_orchestrator.py` | Generates `MobileBillingAIOrchestrator.flogo`: WebSocket trigger → AI Agent (the MCP tools + the three A2A agents) → WebSocket reply, with one conversation per browser connection. The system prompt (customers + staff reviewers) is in `orchestrator_prompt.txt`. Checks its own output before it finishes. |
| `orchestrator_prompt.txt` | The orchestrator's system prompt. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule, the reviewer loop (parked actions, every decide reason code, audit) and the agents' reference functions. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime, including the reviewer tools. |
| `a2a_smoke.py` | Test step 3b. Sends each A2A agent one identity-free request and checks from the Agents log that its reference tool ran the PostgreSQL query, and that the answer carries text only its table holds. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator - customers, a staff reviewer on a separate connection and a self-approval injection - and checks the results in the database. Writes `chat_e2e_transcript.md`. |

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
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required by `build_mcp.py`, `build_agents.py` and the test scripts |
| Database name | `PG_DB` | — | `mobile_billing` |
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

**LLM model.** `build_agents.py` and `build_orchestrator.py` set `LLM_MODEL` to `gpt-5.5` unless the
`LLM_MODEL` environment variable is already set, so the apps they generate use `gpt-5.5` by default.
The `LLM_Model` key in `config.md` is not used by them. To build with another model, set
`LLM_MODEL=<model>` when you run them. (`build_mcp.py` writes no model into its app, but it still stops
unless `LLM_MODEL` or `config.md`'s `LLM_Model` is set to some value.)

**Email password.** `fda` cannot encrypt a password, and the designer only accepts the email password as
an encrypted `SECRET:` value. So `build_mcp.py` uses your `EMAIL_PASSWORD` value if it already starts with
`SECRET:`, and otherwise a portable dummy `SECRET:` value: re-enter your app password in the designer's
**App Properties** to send real email. The plain-text password is never written into the app. It prints which
source it used, never the value.

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

`build_mcp.py` and `build_agents.py` connect to the database to read each query's result columns.
`build_mcp.py` can also run in two shorter chunks: `BUILD_TO=9 OUT_DIR=rebuilt python _rebuild/build_mcp.py`, then
`RESUME_FROM=9 OUT_DIR=rebuilt python _rebuild/build_mcp.py`.
Compare the result with the shipped apps, then delete `rebuilt/`; don't commit it.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.**
> Regenerating creates new connection IDs and drops the credentials you entered. Rebuild into a new
> folder and compare instead.

> ⚠️ **The generated apps contain your real credentials** (PostgreSQL password in the MCP Server and the
> Agents app, LLM key, email addresses), written as app properties. Replace them with placeholders before you
> commit or share the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL. Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM, including the reviewer tools. Reloads `reset_data.sql` before and after; this step tries to send real email to the `EMAIL_TO` inbox (with the shipped placeholder password the send fails and is reported as a NOTE; the SQL guard is what is checked). | MCP server running |
| 3b | `A2A_LOG=<agents log> python _rebuild/a2a_smoke.py` | Each agent answers over A2A, its reference tool runs `SELECT * FROM ref_<topic>(...)` against PostgreSQL without error, at most once, and the answer carries text only its table holds. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG`, LLM key |
| 4 | `python -u _rebuild/chat_e2e.py` | The whole system through real chats - including the reviewer loop across separate connections and a self-approval injection - with checks on the database. Resets the data before and after. Takes about 10 minutes. | All three apps running, LLM key |

Start the apps for steps 3 and 4 as in the main README, step 3 (MCP Server → Agents → Orchestrator).

Optional overrides:

- `MCP_URL` for step 3.
- `WS_URL` and `REPLY_TIMEOUT` (seconds per reply, default 180) for step 4.
- `A2A_LOG=<file the Agents app logs to>` for step 4. Start the Agents app with `FLOGO_LOG_LEVEL=DEBUG`
  and send its output to that file. Step 4 then also confirms that `BillExplainer`, `ChargeClassifier`
  and `PlanRecommender` each really ran and read its reference table from PostgreSQL, and that no name,
  mobile number, bill, case or staff ID, email address or session token reached any of them. Without `A2A_LOG`
  these checks are skipped.
- `--only maria,james,priya,wrong_otp,reviewer,priya_status` for step 4 runs only some of the scenarios
  (`reviewer` needs `priya` first). Pair it with `--transcript <file>` so the full `chat_e2e_transcript.md` is not
  overwritten.

## This sample's values

| | Value |
|---|---|
| Database | `mobile_billing` |
| Orchestrator | WebSocket `9900`, path `/mobilebilling` |
| MCP server | `9902`, path `/mobilebillingmcpserver`, 18 tools: `verify_customer`, `get_my_account`, `get_my_bills`, `get_bill_detail`, `get_bill_comparison`, `get_my_usage`, `get_my_subscriptions`, `get_my_payments`, `get_eligible_plans`, `propose_action`, `confirm_action`, `open_service_case`, `email_action_confirmation`, `get_my_cases`, `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `PlanRecommender` on `9903` (`get_plan_guide` → `ref_plan_guide`), `ChargeClassifier` on `9904` (`get_charge_taxonomy` → `ref_charge_taxonomy`), `BillExplainer` on `9905` (`get_bill_glossary` → `ref_bill_glossary`) |
| Staff reviewers | `TWS-7001` Billing Disputes ($60 limit), `TWS-7002` Fraud Team ($500), `TWS-7003` Retention, `TWS-7004` Billing Disputes (senior, no limit) |

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
