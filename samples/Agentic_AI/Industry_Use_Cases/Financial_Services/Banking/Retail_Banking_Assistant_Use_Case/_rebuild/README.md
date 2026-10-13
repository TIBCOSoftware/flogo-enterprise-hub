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
| `tool_spec.py` | **Single source of truth.** Every MCP tool's name, description, arguments and SQL (a guarded write and/or a read) — 16 customer tools and 4 reviewer tools — plus `AGENT_REF_TOOLS`, the one read-only PostgreSQL reference tool of each A2A agent (`lookup_merchant`, `get_scam_signal_guide`, `get_hardship_guide`). The build scripts and the tests import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `RetailBankingMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the conditional email step for `email_my_confirmation` (it logs and sends only when the SQL returns `send_status = SEND`). Can run in chunks (`BUILD_TO=10`, then `RESUME_FROM=10`). |
| `build_agents.py` | Generates `RetailBankingAgents.flogo` (from the skill's `templates/_rebuild/build_agents.py`): the three A2A agents `dispute_triage_agent` (9863), `scam_signal_agent` (9864) and `hardship_intake_agent` (9865), each with one read-only PostgreSQL reference tool, and a self-check of the query, connection and parameter mapping. |
| `build_orchestrator.py` | Generates `RetailBankingAIOrchestrator.flogo`: WebSocket trigger → AI Agent (20 MCP tools + the 3 A2A agents) → WebSocket reply, with one conversation per browser connection. |
| `orchestrator_prompt.txt` | The orchestrator's system prompt (customer and staff-reviewer personas; the dispute, card, payment, hardship and reviewer flows). `build_orchestrator.py` reads it. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule: identity and roles, scoping, the two-step actions, the scam bands, case parking, every reviewer reason code and the actions a decision executes, hidden columns, and the agents' reference tables. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime, including a payment hold and the reviewer tools. |
| `a2a_smoke.py` | Test step 3b. Sends each agent one small, identity-free request over A2A and checks, from the Agents app's DEBUG log, that its reference tool ran the PostgreSQL query and that the answer uses text only the reference table holds. Changes no data. |
| `ws_smoke.py` | Test step 3. A quick WebSocket check of the running orchestrator: connects, sends one message and checks that a reply comes back and says it is an AI. Changes no data. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator — customers, prompt injections, a scam hold, a hardship case and a staff reviewer deciding it on a separate connection — and checks the results in the database and the Agents log. Writes `chat_e2e_transcript.md` to the use-case folder. `--only` runs a subset. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, scoping and business rules are enforced) and demo data. |
| `seed_data.sql` | Demo data, included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant wrote and reloads the demo data. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |
| `banking.spec.md` | The design spec the apps were built from: apps and ports, which steps are agent, deterministic or human, the rules and reason codes, the tools, the A2A agents and the reviewer loop. |

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
| Email password (MCP server only) | `EMAIL_PASSWORD` | — | placeholder (see below) |
| Email recipient / SMTP server (MCP server only) | `TO_EMAIL` / `SMTP_HOST` / `SMTP_PORT` | — | recipient = sender; `smtp.gmail.com` / `465` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` | newest installed Flogo VS Code extension (`config.md` is used only if none is found) |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

The test scripts take the PostgreSQL host, port, user and database name from environment variables only
(same defaults as above); they take the password and the `psql` path from `config.md` too.

**Email password.** `build_mcp.py` writes your email password into the app's `Email_App_Password`
property only if `EMAIL_PASSWORD` already starts with `SECRET:` (an encrypted value copied from the Flogo
designer). Otherwise the app gets a placeholder `SECRET:` value, because a plain string makes the build fail. In that case open
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
| 2 | `fda cm -f <App>.flogo` (each app) | Every mapping resolves (the Agents app shows about 7 mappings per agent). | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM (incl. a payment hold and the reviewer tools). Reloads `reset_data.sql` before and after; it attempts one real confirmation email to `To_Email` (the SQL guard is checked either way). | MCP server running |
| 3b | `A2A_LOG=<agents log> python _rebuild/a2a_smoke.py` | Each agent answers on its own port, its reference tool queried PostgreSQL, and its answer carries text only the reference table holds. Changes no data. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG`, LLM key |
| 3 | `python _rebuild/ws_smoke.py` | The orchestrator accepts a WebSocket connection and replies. Changes no data. | All three apps running, LLM key |
| 4 | `A2A_LOG=<agents log> python -u _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database (decisions, executed actions, audit) and on the Agents log (each agent's reference tool ran; no identity reached an agent). Resets the data before and after. About 10 minutes. | All three apps running, LLM key |

Start the apps for steps 3 and 4 as in the main README, step 3.

Optional overrides:

- `MCP_URL` for `mcp_smoke.py`.
- `A2A_HOST` and `REPLY_TIMEOUT` (seconds, default 240) for `a2a_smoke.py`.
- `WS_URL` and `REPLY_TIMEOUT` (seconds; 150 for `ws_smoke.py`, 180 for step 4).
- `A2A_LOG=<file the Agents app logs to>` for steps 3b and 4 (start the Agents app with `FLOGO_LOG_LEVEL=DEBUG`).

## This sample's values

| | Value |
|---|---|
| Database | `banking_governed` |
| Orchestrator | WebSocket `9860`, path `/retailbanking` |
| MCP server | `9862`, path `/retail-banking-mcp`, 20 tools: `verify_customer`, `get_my_accounts`, `get_my_transactions`, `get_my_cards`, `get_my_loans`, `find_branch`, `propose_card_block`, `confirm_card_block`, `propose_dispute`, `confirm_dispute`, `open_service_case`, `get_my_cases`, `email_my_confirmation`, `get_my_payees`, `propose_payment`, `confirm_payment`, `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `dispute_triage_agent` `9863` (`lookup_merchant` → `lookup_merchant()`), `scam_signal_agent` `9864` (`get_scam_signal_guide` → `ref_scam_signals()`), `hardship_intake_agent` `9865` (`get_hardship_guide` → `ref_hardship_guide()`) |
| Reference tables (agents only) | `merchant_directory`, `scam_signal_guide`, `hardship_guide` (+ WHO_DECIDES rows read from `service_teams`) — no customer data |
| Demo staff | `KST-7001` / `246810` (Customer Care, $25), `KST-7002` / `135790` (Financial Support, $5,000), `KST-7003` / `864209` (Fraud Operations, $20,000) |

The ports and URLs are set in the build scripts (`PORT` and `ENDPOINT` in `build_mcp.py`, each agent's `port` in
`build_agents.py`, `WS_PORT`, `WS_PATH`, `MCP_URL` and `AGENTS` in `build_orchestrator.py`). To change
them, edit the scripts and pass the new URLs to the test scripts (`MCP_URL`, `A2A_HOST`, `WS_URL`), or set
the app properties as described in the main README, step 2.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py`.
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
