> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# `_rebuild/`: regenerate and test the Electric Outage & Billing apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI
(`fda`) and the tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

## What's in this folder

| File | What it does |
|---|---|
| `SPEC.md` | The design spec the apps were built from: apps, ports and names, identity and scope (customers and staff reviewers), which steps are deterministic, agent or human, the rate plan catalogue, every rule and reason code, the two-step actions, case routing and the reviewer loop, the guarded email, the MCP tools, the A2A agents, the demo customers and the test scope. |
| `tool_spec.py` | **Single source of truth** for the 22 MCP tools: each tool's name, description, arguments and SQL (a guarded write and/or a read), the MCP hints, plus the columns no tool may ever return. Also `AGENT_REF_TOOLS`: the A2A agents' three reference tools (name, description, `SELECT * FROM ref_<topic>(CAST(?lookup AS text))`). `build_mcp.py`, `build_agents.py`, `test_rules.py`, `mcp_smoke.py` and `a2a_smoke.py` all import it, so the SQL that is tested is the SQL that ships. |
| `orchestrator_prompt.txt` | The system prompt of Sage, the orchestrator's AI Agent. `build_orchestrator.py` reads it. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `PowerUtilityMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the conditional email step for `email_confirmation` (the email is sent only when the SQL says `SEND_OK`). The build is long (22 tools), so it can run in chunks: `BUILD_TO=<n>` stops after tool `n-1`, and `RESUME_FROM=<n>` continues the **same** file at tool `n` (only for a file this script is still building). `EMAIL_SECRET_FROM_FLOGO=<path to a .flogo>` adds one more file to search for a reusable `Email_App_Password` `SECRET:` value (see below). |
| `build_agents.py` | Generates `PowerUtilityAgents.flogo`: three read-only A2A agents, `bill_explainer_agent`, `outage_triage_agent` and `rate_plan_agent`, each with one read-only tool that reads a reference table from PostgreSQL (`ref_bill_glossary`, `ref_outage_triage`, `ref_rate_plans`; the model can only pass an optional lookup word). The app has its own PostgreSQL connection for those reference tables only. |
| `build_orchestrator.py` | Generates `PowerUtilityAIOrchestrator.flogo`: WebSocket trigger → AI Agent (the MCP tools + the three A2A agents) → WebSocket reply, with one conversation per browser connection. Checks its own output before it finishes. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule, including the reviewer guard, and the agents' `ref_*` functions (filtering, unknown input, no personal data, SELECT-only). No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules, including the reviewer loop, hold in the Flogo runtime. |
| `a2a_smoke.py` | Test step 3b. Sends each A2A agent one small, identity-free request (JSON-RPC `message/send`) and checks in the Agents app's DEBUG log that its reference tool ran and its PostgreSQL query completed without error. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator, including the customer → reviewer → customer loop across separate connections, and checks the results in the database. Writes `chat_e2e_transcript.md`. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, scoping, business rules and the reviewer guard are enforced) and triggers; loads the demo data at the end. |
| `seed_data.sql` | Demo data, with every date relative to today. Included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant and the reviewers wrote and reloads the demo data. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the
  `power_distribution_governed` database loaded (see the main README, step 1).
- For the local builds in the test ladder: **`flogobuild`** with a build context, and **Go**.
- For step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.example.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required by `build_mcp.py` and the test scripts |
| Database name | `PG_DB` | — | `power_distribution_governed` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM API key | `LLM_API_KEY` | `API_Key` | required by `build_agents.py` and `build_orchestrator.py` |
| LLM model | `LLM_MODEL` | `LLM_Model` (see below) | `gpt-5.5` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| Email sender (MCP server only) | `EMAIL_USERNAME` | `Username` | required by `build_mcp.py` |
| Email recipient (MCP server only) | `EMAIL_TO` or `TO_EMAIL` | — | the sender address |
| Email password (MCP server only) | `EMAIL_PASSWORD` | `Password` | see below |
| SMTP host / port (MCP server only) | `SMTP_HOST` / `SMTP_PORT` | `Server` / `Port` | `smtp.gmail.com` / `465` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` (used only when no extension is found) | newest installed Flogo VS Code extension |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

**LLM model.** `build_agents.py` and `build_orchestrator.py` set `LLM_MODEL` to `gpt-5.5` unless the
`LLM_MODEL` environment variable is already set, so the apps they generate use `gpt-5.5` by default and
`config.md`'s `LLM_Model` is not used by them. To build with another model, set `LLM_MODEL=<model>` when you run
them. (`build_mcp.py` writes no model into its app, but it still stops unless `LLM_MODEL` or `config.md`'s
`LLM_Model` is set to some value.)

**Email password.** `fda` cannot encrypt a password, and the designer only accepts the email password as
an encrypted `SECRET:` value. So `build_mcp.py` picks the `Email_App_Password` value in this order:

1. your `EMAIL_PASSWORD` / `Password` value, if it already starts with `SECRET:`;
2. otherwise, an existing `SECRET:` value for `Email_App_Password` whose password has the same length as yours (it
   assumes that is the same mailbox), searched first in the file named by `EMAIL_SECRET_FROM_FLOGO` and then in
   every `.flogo` under `samples/Agentic_AI`;
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

To build the MCP server in two chunks (for example to stay within a session time limit):

```bash
OUT_DIR=rebuilt BUILD_TO=11 python _rebuild/build_mcp.py
OUT_DIR=rebuilt RESUME_FROM=11 python _rebuild/build_mcp.py
```

If a build fails for any other reason, delete only the half-built `.flogo` in `rebuilt/` and run that script again.
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
| 1 | `python _rebuild/test_rules.py` | Every SQL rule and reason code, using the exact tool SQL: scoping, the two-step actions and expiry, the reviewer guard (team, authority limit, note, amount), trigger effects, the verify throttle, the email guard and the hidden columns; plus the agents' reference functions (every guide returns rows, the lookup filters, unknown words give 0 rows, no customer or staff data, SELECT-only). Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. | Nothing running |
| 2b | `fda cm -f PowerUtilityMCPServer.flogo` (and the same for `PowerUtilityAgents.flogo` and `PowerUtilityAIOrchestrator.flogo`) | Mapping references and functions resolve in each app. | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM, including the reviewer tools. Reloads `reset_data.sql` before and after; this step sends one real email to the `EMAIL_TO` inbox. | MCP server running |
| 3b | `A2A_LOG=<agents log> python _rebuild/a2a_smoke.py` | Each A2A agent answers a small request and its reference tool reads PostgreSQL (`Executing handler [<tool>_flow]`, `Prepared Query Statement is : SELECT * FROM ref_<topic>(CAST($1 AS text));`, `ReadReference` completed, no error). Uses the LLM. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG` |
| 4 | `python _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database: the happy path, the blocked reconnection, prompt injection, scope, the reviewer loop across separate connections, a new connection that must verify again and a wrong code. Resets the data before and after, and sends real confirmation emails to the `EMAIL_TO` inbox. | All three apps running, LLM key |

**Running the apps for steps 3 and 4.** Build local executables in a scratch folder **outside the repo**
(the copies hold credentials), with a **relative** `-f` (an absolute `-f` drops the exe next to the source,
inside the repo). Use a context name from `flogobuild list-context`:

```bash
flogobuild list-context
mkdir -p "$HOME/power_utility_run" && cp *.flogo "$HOME/power_utility_run/"
cd "$HOME/power_utility_run"
flogobuild build-exe -f PowerUtilityMCPServer.flogo -c <context>
flogobuild build-exe -f PowerUtilityAgents.flogo -c <context>
flogobuild build-exe -f PowerUtilityAIOrchestrator.flogo -c <context>
```

Start them in order (MCP Server → Agents → Orchestrator), as in the main README, step 3. On Windows, stop them
by port: `netstat -ano | grep :<port>`, then `taskkill //PID <pid> //F` (bash `kill` doesn't stop them).

Optional overrides:

- `MCP_URL` for step 3 (default `http://localhost:9942/powerutilitymcp`).
- `WS_URL` (default `ws://localhost:9940/powerutility`) and `REPLY_TIMEOUT` (seconds per reply, default 180) for
  step 4.
- `A2A_LOG=<file the Agents app logs to>` for step 4. Start the Agents app with `FLOGO_LOG_LEVEL=DEBUG`
  and send its output to that file. Step 4 then also confirms that `bill_explainer_agent`,
  `outage_triage_agent` and `rate_plan_agent` each really ran, that each one's reference tool queried
  PostgreSQL without error (at most once per run of the agent, with no identity in the lookup word), and that no
  name, account number, address, email address or session token reached any of them. Without `A2A_LOG` these
  checks are skipped.

  ```bash
  # in the scratch folder
  FLOGO_LOG_LEVEL=DEBUG ./PowerUtilityAgents > "$HOME/power_utility_run/a2a_run.log" 2>&1 &
  # back in the use-case folder
  A2A_LOG="$HOME/power_utility_run/a2a_run.log" python _rebuild/chat_e2e.py
  ```
- `--only laura,henry,grace,reviewer,grace_status,wrong_code` for step 4 runs only some of the scenarios
  (`reviewer` and `grace_status` follow on from `grace`). Pair it with `--transcript <file>` so the full
  `chat_e2e_transcript.md` is not overwritten.

## This sample's values

| | Value |
|---|---|
| Database | `power_distribution_governed` |
| Orchestrator | `PowerUtilityAIOrchestrator`, WebSocket `9940`, path `/powerutility` |
| MCP server | `PowerUtilityMCPServer`, `9942`, path `/powerutilitymcp`, 22 tools. Customer: `verify_customer`, `get_my_account`, `get_my_bills`, `get_bill_detail`, `get_bill_comparison`, `get_my_usage`, `get_my_payments`, `get_plan_options`, `get_area_outages`, `get_my_service_activity`, `get_appointment_slots`, `propose_action`, `confirm_action`, `book_appointment`, `request_reconnect`, `open_service_case`, `get_my_cases`, `email_confirmation`. Reviewer: `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `PowerUtilityAgents`: `bill_explainer_agent` on `9943`, `outage_triage_agent` on `9944`, `rate_plan_agent` on `9945` |
| Model | `gpt-5.5` (app property `LLM_Model`) |
| Case teams | Billing Review (`billing_dispute`), Credit & Collections (`payment_arrangement`), Customer Care (`medical_baseline`), Emergency Dispatch (`hazardous_condition`) |
| Demo reviewers | `RPL-S-201` Avery Collins (Billing Review, limit $200), `RPL-S-305` Jordan Lee (Credit & Collections, limit $100) |

The ports and URLs are set in the build scripts (`PORT` and `ENDPOINT` in `build_mcp.py`, each agent's
`port` in `build_agents.py`, `WS_PORT`, `WS_PATH`, `MCP_URL` and `AGENTS` in `build_orchestrator.py`).
To change them, edit the scripts and the matching defaults in `mcp_smoke.py` / `chat_e2e.py` (or set
`MCP_URL` / `WS_URL`), or set the app properties and orchestrator URL properties as described in the
main README.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py`
   (keep `SPEC.md` and `orchestrator_prompt.txt` in step).
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
