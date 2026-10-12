# `_rebuild/`: regenerate and test the Corporate Payments apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI
(`fda`) and the tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

## What's in this folder

| File | What it does |
|---|---|
| `tool_spec.py` | **Single source of truth.** Every MCP tool's name, description, arguments and SQL (a guarded write and/or a read), plus the A2A agent's tool `lookup_reason_code`. The build scripts and `test_rules.py` all import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `CorporatePaymentsMCPServer.flogo`: the MCP trigger, one flow per tool in `tool_spec.py`, and the conditional email step for `email_my_confirmation` (the email is sent only when the SQL returns `send_status = SEND`). |
| `build_agents.py` | Generates `CorporatePaymentsAgents.flogo`: the A2A agent `payment_triage_agent` and its one read-only tool, `lookup_reason_code`. |
| `build_orchestrator.py` | Generates `CorporatePaymentsAIOrchestrator.flogo`: WebSocket trigger → AI Agent (MCP tools + the A2A agent) → WebSocket reply, with one conversation per browser connection. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime. |
| `a2a_smoke.py` | Test step 3. Calls the running Agents app directly (no orchestrator): reads the agent card, then checks that `payment_triage_agent` decodes a return/reason code and recommends a next step. Read-only. |
| `ws_smoke.py` | Test step 3. A quick WebSocket check of the running orchestrator: connects, sends one message and checks for a reply that says it is an AI. Read-only. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator and checks the results in the database. Writes `chat_e2e_transcript.md`. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, scoping and business rules are enforced) and demo data. |
| `seed_data.sql` | Demo data, included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant wrote and reloads the demo data. |
| `payments.spec.md` | The governed design spec: persona, apps and ports, and the rules each tool enforces. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the
  `payments_governed` database loaded (see the main README, step 1).
- For `ws_smoke.py` and step 4: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required |
| Database name | `PG_DB` | — | `payments_governed` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM model | `LLM_MODEL` | `LLM_Model` | required for every build script |
| LLM API key | `LLM_API_KEY` | `API_Key` | required for `build_agents.py` and `build_orchestrator.py` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| Email sender (MCP server only) | `EMAIL_USERNAME` | `Username` | required for `build_mcp.py` |
| Email password (MCP server only) | `EMAIL_PASSWORD` | `Password` | placeholder secret (see below) |
| Email recipient / SMTP (MCP server only) | `TO_EMAIL`, `SMTP_HOST`, `SMTP_PORT` | — | recipient = sender; `smtp.gmail.com` / `465` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` | newest installed Flogo VS Code extension |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

The test scripts take the PostgreSQL host, port, user and database name from environment variables only
(`PG_HOST`, `PG_PORT`, `PG_USER`, `PG_DB`, with the defaults above). They take the `psql` path and the
password from the environment or `config.md`.

**Email password.** `build_mcp.py` writes the email password into the app only if it is already a Flogo
secret, i.e. a value that starts with `SECRET:`. A plain password (such as a Gmail app password copied
into `config.md`), or no password at all, is replaced with a placeholder secret that does not work for
sending. In that case open `CorporatePaymentsMCPServer.flogo` in the designer and set `Email_App_Password`
in App Properties, as in the main README, step 2. Until you do, the email step can't send.

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
> addresses, and the email password if you supplied a `SECRET:` value), written as app properties.
> Replace them with placeholders before you commit or share the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL. Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. | Nothing running |
| 3a | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM. Reloads `reset_data.sql` before and after; this step sends one real email to `To_Email`. | MCP server running, working `Email_App_Password` |
| 3b | `python _rebuild/a2a_smoke.py` | `payment_triage_agent` answers on its own: agent card, reason-code decoding and a recommended next step. No database changes. | Agents app running, LLM key |
| 3c | `python _rebuild/ws_smoke.py` | The orchestrator accepts a WebSocket connection and replies. No database changes. | All three apps running, LLM key |
| 4 | `python _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database. Resets the data before and after; sends at most one real email. | All three apps running, LLM key |

Start the apps for steps 3 and 4 in the order given in the main README, step 3: MCP Server → Agents →
Orchestrator.

Optional overrides:

- `MCP_URL` for `mcp_smoke.py`.
- `A2A_URL` and `A2A_TIMEOUT` (seconds, default 180) for `a2a_smoke.py`.
- `WS_URL` and `REPLY_TIMEOUT` (seconds, default 150) for `ws_smoke.py` and step 4.
- `A2A_LOG=<file the Agents app logs to>` for step 4, which also confirms `payment_triage_agent` ran.

## This sample's values

| | Value |
|---|---|
| Database | `payments_governed` |
| Orchestrator | WebSocket `9870`, path `/corporatepayments` |
| MCP server | `9872`, path `/corporate-payments-mcp`, 12 tools: `verify_client`, `get_my_payments`, `get_payment_status`, `get_payment_timeline`, `check_delivery_estimate`, `propose_trace`, `confirm_trace`, `propose_recall`, `confirm_recall`, `open_review_case`, `get_my_cases`, `email_my_confirmation` |
| A2A agent | `payment_triage_agent` on `9873` |

The ports and URLs are set in the build scripts (`PORT` and `ENDPOINT` in `build_mcp.py`, `PORT` in
`build_agents.py`, `WS_PORT`, `WS_PATH`, `MCP_URL` and `A2A_URL` in `build_orchestrator.py`). To change
them, edit the scripts and the matching defaults in the test scripts (or pass `MCP_URL`, `A2A_URL` and
`WS_URL`), or set the app properties and orchestrator connection URLs as described in the main README,
step 2.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py`.
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
