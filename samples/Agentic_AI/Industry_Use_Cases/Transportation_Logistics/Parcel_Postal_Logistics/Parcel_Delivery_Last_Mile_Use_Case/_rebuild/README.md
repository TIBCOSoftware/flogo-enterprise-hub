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
| `tool_spec.py` | **Single source of truth.** Every MCP tool's name, description, arguments and SQL (a guarded write and/or a read) - 14 recipient tools + 4 reviewer tools - plus the three agents' PostgreSQL reference tools (`AGENT_REF_TOOLS`: `search_delivery_options`, `get_claim_guide`, `get_delivery_instructions_guide`). The build scripts and the tests import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `ParcelDeliveryMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the guarded email branch for `email_confirmation` (the request is logged in `email_log` and the email is sent only when the SQL says `SEND_OK`; it goes to the `To_Email` inbox). Chunked: `BUILD_TO=<n>` / `RESUME_FROM=<n>`. |
| `build_agents.py` | Generates `ParcelDeliveryAgents.flogo`: the three A2A agents (`delivery_options_agent` 9893, `damage_claim_agent` 9894, `delivery_instructions_agent` 9896), each with one read-only PostgreSQL reference tool, plus a self-check. |
| `build_orchestrator.py` | Generates `ParcelDeliveryAIOrchestrator.flogo`: WebSocket trigger → AI Agent (18 MCP tools + the three A2A agents) → WebSocket reply, with one conversation per browser connection. The system prompt is `orchestrator_prompt.txt`. |
| `orchestrator_prompt.txt` | The orchestrator's system prompt (two personas: recipients and staff reviewers). |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule: identity, scoping, the two-step changes, claims, delivery instructions, every reviewer reason code and the reference tools. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime, including the reviewer tools (happy path + one blocked call each). Resets the data before and after. |
| `a2a_smoke.py` | Test step 3b. Sends each A2A agent one identity-free request and proves from the Agents DEBUG log that its reference tool queried PostgreSQL and that the answer carries text only its table holds. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator - including the reviewer loop across separate connections and prompt-injection turns - and checks the results in the database. Writes `chat_e2e_transcript.md` to the use-case folder. `--only` runs a subset. |
| `SPEC.md` | The use-case spec: decisions, identity, tools, agents, the reviewer loop and the data. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, scoping and business rules are enforced) and demo data. |
| `seed_data.sql` | Demo data, included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant and the reviewers wrote and reloads the demo data. |
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
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM, including the reviewer tools. Resets the data before and after; attempts one real email to the `To_Email` inbox (the `email_log` guard row is asserted, SMTP delivery is not). | MCP server running |
| 3b | `A2A_LOG=<agents log> python _rebuild/a2a_smoke.py` | Each agent answers, calls its reference tool, the PostgreSQL query runs, and the answer carries table-only text. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG`, LLM key |
| 4 | `A2A_LOG=<agents log> python -u _rebuild/chat_e2e.py` | The whole system through real chats (about 12 minutes), with checks on the database, agent-input minimisation and the reference-tool evidence. Resets the data before and after. | All three apps running, LLM key |

Start the apps for steps 3 and 4 as in the main README, step 3 (MCP Server → Agents → Orchestrator).

Optional overrides:

- `MCP_URL` for step 3.
- `WS_URL` and `REPLY_TIMEOUT` (seconds, default 180) for step 4.
- `A2A_LOG=<file the Agents app logs to>` for steps 3b and 4: start the Agents exe with `FLOGO_LOG_LEVEL=DEBUG` and its
  output in a file.

## This sample's values

| | Value |
|---|---|
| Database | `parcel_delivery` |
| Orchestrator | WebSocket `9890`, path `/parceldelivery` |
| MCP server | `9892`, path `/parcel-delivery-mcp`, 18 tools: `verify_recipient`, `get_my_parcels`, `get_parcel_detail`, `get_tracking_history`, `propose_reschedule`, `confirm_reschedule`, `propose_redirect`, `confirm_redirect`, `email_confirmation`, `open_service_case`, `get_my_cases`, `open_damage_claim`, `propose_delivery_instructions`, `confirm_delivery_instructions`, `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `delivery_options_agent` on `9893` (`search_delivery_options`), `damage_claim_agent` on `9894` (`ref_claim_guide`), `delivery_instructions_agent` on `9896` (`ref_delivery_instructions`). 9895 is skipped: another sample uses it. |
| Reference tables (agents) | `delivery_slots` + `pickup_points` (options), `claim_guide` (+ the claim teams from `service_teams`), `safe_places` + `instruction_risk_flags` + `instruction_guide` |

The ports and URLs are set in the build scripts (`PORT`, `ENDPOINT`, `WS_PORT`, `WS_PATH`, `MCP_URL`,
`AGENTS`). To change them, edit the scripts and the matching values in `mcp_smoke.py` / `chat_e2e.py`,
or set the app properties and orchestrator connection URLs as described in the main README.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py`.
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
