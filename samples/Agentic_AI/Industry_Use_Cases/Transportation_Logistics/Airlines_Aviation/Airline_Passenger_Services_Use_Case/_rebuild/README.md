> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# `_rebuild/`: regenerate and test the Passenger Services apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI
(`fda`) and the tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

## What's in this folder

| File | What it does |
|---|---|
| `SPEC.md` | The use-case spec: personas, the decision-framework classification, rules with reason codes, the reviewer loop, the agents and their reference tables. |
| `tool_spec.py` | **Single source of truth.** Every MCP tool's name, description, arguments and SQL (a guarded write and/or a read), plus each A2A agent's reference tool (`AGENT_REF_TOOLS`). The build scripts and the tests all import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `PassengerServicesMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the conditional email step for `email_my_confirmation`. |
| `build_agents.py` | Generates `PassengerServicesAgents.flogo`: three A2A agents (`rebooking_options_agent`, `baggage_claim_agent`, `special_assistance_agent`), each with one read-only PostgreSQL reference tool, and a self-check. |
| `build_orchestrator.py` | Generates `PassengerServicesAIOrchestrator.flogo`: WebSocket trigger → AI Agent (MCP tools + the three A2A agents) → WebSocket reply, with one conversation per browser connection. |
| `orchestrator_prompt.txt` | The orchestrator's system prompt (travellers and staff reviewers), read by `build_orchestrator.py`. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule: identity, rebooking, compensation parking, baggage-claim and assistance validation, every reviewer reason code, the email guard, the audit trail and the agents' reference functions. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime, including the reviewer tools (happy path + one blocked call each). |
| `a2a_smoke.py` | Test step 3b. Sends each A2A agent one identity-free request and checks in the Agents app's DEBUG log that its reference tool ran the PostgreSQL query, and that the answer carries text only the reference table holds. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator - travellers, a staff reviewer on a separate connection, prompt-injection turns - and checks the results in the database. Writes `chat_e2e_transcript.md`. `--only` runs a subset. |

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
  `airline_governed` database loaded (see the main README, step 1).
- For step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required |
| Database name | `PG_DB` | — | `airline_governed` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM model | `LLM_MODEL` | `LLM_Model` | required by every build script (checked at start) |
| LLM API key | `LLM_API_KEY` | `API_Key` | required by `build_agents.py` and `build_orchestrator.py` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| Email (MCP server only) | `EMAIL_USERNAME` / `EMAIL_PASSWORD` | `Username` / — | username required by `build_mcp.py`; the password is used only if `EMAIL_PASSWORD` holds a `SECRET:` value, otherwise a portable dummy `SECRET:` is written (re-enter the app password in App Properties) |
| Email recipient, SMTP server | `TO_EMAIL`, `SMTP_HOST`, `SMTP_PORT` | — | recipient = sender; `smtp.gmail.com` / `465` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` | newest installed Flogo VS Code extension |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

The test scripts take the PostgreSQL host and user from environment variables only, and use psql's
default port.

## Regenerate the apps

The scripts **refuse to overwrite** an existing `.flogo`, so build into an empty folder:

```bash
mkdir -p rebuilt
OUT_DIR=rebuilt python _rebuild/build_mcp.py          # chunked if you like: BUILD_TO=8, then RESUME_FROM=8
OUT_DIR=rebuilt python _rebuild/build_agents.py
OUT_DIR=rebuilt python _rebuild/build_orchestrator.py
```

`build_mcp.py` and `build_agents.py` connect to the database to read each query's result columns.
Compare the result with the shipped apps, then delete `rebuilt/`; don't commit it.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.**
> Regenerating creates new connection IDs and drops the credentials you entered. Rebuild into a new
> folder and compare instead.

> ⚠️ **The generated apps contain your real credentials** (PostgreSQL password, LLM key), written as app
> properties. Replace them with placeholders before you commit or share
> the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL. Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM. Resets the data before and after. Attempts two real emails; with the dummy email password the send fails and the SQL guard (`email_log`) is checked instead. | MCP server running |
| 3b | `A2A_LOG=<agents log> python _rebuild/a2a_smoke.py` | Each agent answers, its reference tool queried PostgreSQL without error, and the answer uses the table. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG`, its output in a file; LLM key |
| 4 | `python _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database. Resets the data before and after. | All three apps running, LLM key |

Start the apps for steps 3 and 4 as in the main README, step 3.

Optional overrides:

- `MCP_URL` for step 3.
- `WS_URL` and `REPLY_TIMEOUT` (seconds, default 180) for step 4; run it with `python -u` (it takes about 10 minutes).
- `A2A_LOG=<file the Agents app logs to>` for step 4, which also confirms each agent ran, that its reference tool
  queried PostgreSQL and that no identity reached it (start the Agents app with `FLOGO_LOG_LEVEL=DEBUG`).

## This sample's values

| | Value |
|---|---|
| Database | `airline_governed` |
| Orchestrator | WebSocket `9850`, path `/passengerservices` |
| MCP server | `9852`, path `/passenger-services-gov-mcp`, 16 tools: `verify_traveller`, `get_my_itinerary`, `get_flight_status`, `get_my_loyalty`, `check_connection_risk`, `propose_rebook`, `confirm_rebook`, `email_my_confirmation`, `open_service_case`, `get_my_cases`, `record_baggage_claim`, `request_assistance`, `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `rebooking_options_agent` `9853` (`search_alternatives`), `baggage_claim_agent` `9854` (`ref_baggage_guide`), `special_assistance_agent` `9855` (`ref_assistance_codes`) |
| Staff reviewers | `MER-7001` Dana Brooks (Baggage Services, $250), `MER-7002` Victor Hale (Baggage Services, $2,000), `MER-7003` Marcus Lee (Accessibility Desk), `MER-7004` Elena Ruiz (Customer Care, $500), `MER-7005` Nadia Karim (Customer Relations, $500), `MER-7006` Owen Price (Ticketing) |

The ports and URLs are set in the build scripts (`PORT`, `WS_PORT`, `WS_PATH`, `MCP_URL`, `AGENTS`, and each agent's `port`).
To change them, edit the scripts and the matching values in `mcp_smoke.py` / `a2a_smoke.py` / `chat_e2e.py`, or set
the app properties and orchestrator URL properties as described in the main README.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py`.
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
