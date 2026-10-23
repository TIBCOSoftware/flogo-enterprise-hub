> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# `_rebuild/`: regenerate and test the Retail Banking (JWT Auth) apps from code

**You don't need this folder to run the demo** — except `mint_user_tokens.py`, which mints the demo users' tokens.
The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI
(`fda`) and the tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules (and the token checks) still hold.

## What's in this folder

| File | What it does |
|---|---|
| `tool_spec.py` | **Single source of truth.** Every MCP tool's name, description, required **scope**, arguments and SQL (a guarded write and/or a read) — 14 customer tools, `whoami`, `find_branch` and 3 reviewer tools; every SQL parameter bound to the caller has the source `SUB` and is mapped to the verified `$flow.tokenInfo.sub`. Also the demo **`PERSONAS`** (`sub`, name, scopes), the scope sets, and `AGENT_REF_TOOLS`, the one read-only PostgreSQL reference tool of each A2A agent (`lookup_merchant`, `get_scam_signal_guide`, `get_hardship_guide`). The build scripts and the tests import it, so the SQL that is tested is the SQL that ships. |
| `mint_user_tokens.py` | The stand-in for the bank's identity provider. Signs one HS256 JWT per persona in `tool_spec.PERSONAS` with `JWT_SECRET` (claims `iss`, `aud`, `sub`, `name`, `scp`, `iat`, `exp`). `[hours]` sets the lifetime (default 8); `--json`, `--expired` and `--wrong-secret` for scripts and negative tests. Standard library only; `mint()` is imported by the smoke tests. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `RetailBankingSecureMCPServer.flogo`: the MCP trigger with `JWT Token` authentication (`MCP.JWT_Secret`), one flow per tool with its `scope`, `tokenInfo` handed to each flow, and the conditional email step for `email_my_confirmation` (it logs and sends only when the SQL returns `send_status = SEND`). Can run in chunks (`BUILD_TO=10`, then `RESUME_FROM=10`) or add single tools to an existing app (`ADD_TOOLS=… APP_FILE=…`). |
| `build_agents.py` | Generates `RetailBankingSecureAgents.flogo`: the three A2A agents `dispute_triage_agent` (9973), `scam_signal_agent` (9974) and `hardship_intake_agent` (9975), each with `Static Token` authentication (`A2A.<agent>.AuthToken`, shipped as `SET_YOUR_A2A_TOKEN`), one read-only PostgreSQL reference tool and a self-check of the query, connection and parameter mapping. |
| `build_orchestrator.py` | Generates `RetailBankingSecureOrchestrator.flogo`: WebSocket trigger (9970 `/retailbanking`) → guard on the `Authorization: Bearer` header → **LLM Client** activity (per-call LLM settings; MCP with `authType: Token` = the caller's JWT; three A2A agents with `Static Token`) → WebSocket reply, plus the fixed sign-in / sign-in-expired / service-error replies. One conversation per connection (`Sec-Websocket-Key`). |
| `orchestrator_prompt.txt` | The orchestrator's system prompt (signed-in customers and staff reviewers; `whoami` first; the dispute, card, payment, hardship and reviewer flows). `build_orchestrator.py` stores it in the `LLMClient.SystemPrompt` app property. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL, binding each persona's `sub` the way the MCP flows do, and checks every business rule: identity from the subject (customers, active reviewers, unknown subjects, `whoami`), scoping, the two-step actions, the scam bands, case parking, every reviewer reason code and the actions a decision executes, hidden columns, and the agents' reference tables. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server with real JWTs, no LLM: no / forged / expired / not-yet-valid / malformed token → HTTP 401; the tool list per scope set (16 / 8 / 5 tools); hidden tools refused; identity arguments ignored; `UNKNOWN_CALLER` / `NOT_REVIEWER` in SQL; then the business rules end to end (card block, dispute, payment incl. a HIGH scam hold, guarded email, a routed case, the reviewer loop, audit). |
| `a2a_smoke.py` | Test step 3b. Per agent: the agent card is public; no token, a wrong token and another agent's token are all rejected (a failed A2A task; no tool, no LLM call); the agent's own token gets an answer whose reference tool ran the PostgreSQL query and whose text only the reference table holds. Changes no data. |
| `ws_smoke.py` | Test step 3. The orchestrator's sign-in guard: no header and a `?token=` query parameter both get the fixed sign-in reply with no LLM call; a valid token gets an answer that says it is an AI; an expired token gets the "sign in again" reply. `--no-auth-only` runs just the guard checks (orchestrator alone). Changes no data. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator — sign-in edge cases (no header, `?token=` only, expired, forged, unknown subject), then customers, prompt injections, a scam hold, a hardship case, a view-only sign-in and a staff reviewer deciding on a separate connection — and checks the results in the database and the Agents log. Writes `chat_e2e_transcript.md` to the use-case folder. `--only` runs a subset. Set `MCP_LOG=<MCP app log>` to add tool-level checks (no write tool ran for the view-only token, no cross-role tool ran, `whoami` ran first, no identity in tool arguments). |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (`caller_customer(sub)`, `caller_reviewer(sub)`, `whoami(sub)` and the business rules) and demo data. |
| `seed_data.sql` | Demo data, included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant wrote and reloads the demo data. |
| `prompts.md` | Demo prompts per persona token, including ones that show the rules and the scopes holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |
| `auth.spec.md` | The identity design: token, claims, scopes per persona and tool, what each layer checks, and how Flogo 2.26.7 behaves on a rejected request. |
| `banking.spec.md` | The business design the apps were built from: which steps are agent, deterministic or human, the rules and reason codes, the tools, the A2A agents and the reviewer loop. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the
  `banking_jwt_auth` database loaded (see the main README, step 1).
- For `ws_smoke.py` and step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.example.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required |
| Database name | `PG_DB` | — | `banking_jwt_auth` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| JWT signing secret (= the MCP app's `MCP.JWT_Secret`) | `JWT_SECRET` | — | required for `mint_user_tokens.py`, `mcp_smoke.py`, `ws_smoke.py` (checks 3–4) and step 4; optional for `build_mcp.py` (else the placeholder `SET_YOUR_JWT_SECRET`) |
| A2A agent tokens (= `A2A.dispute_triage_agent.AuthToken` / `A2A.scam_signal_agent.AuthToken` / `A2A.hardship_intake_agent.AuthToken`) | `A2A_TOKEN_DISPUTE` / `A2A_TOKEN_SCAM` / `A2A_TOKEN_HARDSHIP` | — | required for `a2a_smoke.py`; the build scripts always write the placeholder `SET_YOUR_A2A_TOKEN` |
| LLM model | `LLM_MODEL` | `LLM_Model` | `gpt-5.5` |
| LLM API key | `LLM_API_KEY` | `API_Key` | required for `build_agents.py` (the orchestrator always gets the placeholder `sk-REPLACE-WITH-YOUR-OPENAI-KEY`) |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| Email sender (MCP server only) | `EMAIL_USERNAME` | `Username` | required for `build_mcp.py` |
| Email password (MCP server only) | `EMAIL_PASSWORD` | — | placeholder (see below) |
| Email recipient / SMTP server (MCP server only) | `TO_EMAIL` / `SMTP_HOST` / `SMTP_PORT` | — | recipient = sender; `smtp.gmail.com` / `465` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` | newest installed Flogo VS Code extension (`config.md` is used only if none is found) |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

The test scripts take the PostgreSQL host, port, user and database name from environment variables only
(same defaults as above); they take the password and the `psql` path from `config.md` too. No script prints a
secret or a token.

**Email password.** `build_mcp.py` writes your email password into the app's `Email_App_Password`
property only if `EMAIL_PASSWORD` already starts with `SECRET:` (an encrypted value copied from the Flogo
designer). Otherwise the app gets a placeholder `SECRET:` value, because a plain string makes the build fail. In
that case enter your real App Password in `Email_App_Password` (designer App Properties, or at run time — below)
before the email tool can send.

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

> ⚠️ **A generated app can contain real credentials**: the PostgreSQL password and LLM key, `JWT_SECRET` if it
> was set during `build_mcp.py`, and the email address. Replace them with placeholders before you commit or
> share the files. Never leave `A2A.<agent>.AuthToken` empty: an empty token turns the agent's check off.

## Run the apps with runtime secrets

The tests below need the apps running with real secrets. The simplest way is to leave the `.flogo` files
untouched and give each executable a JSON file of app properties with `FLOGO_APP_PROPS_JSON` (a **path** to the
file, not inline JSON). Keep these files outside the repository:

| File (example) | Properties |
|---|---|
| `kestrel-mcp.json` | `MCP.JWT_Secret` (= `JWT_SECRET`), `PostgreSQL.PostgresConn.Password`, optionally `Email_App_Password` |
| `kestrel-agents.json` | `A2A.dispute_triage_agent.AuthToken`, `A2A.scam_signal_agent.AuthToken`, `A2A.hardship_intake_agent.AuthToken`, `AgenticAI.OpenAIConn.API_Key`, `PostgreSQL.PostgresConn.Password` |
| `kestrel-orchestrator.json` | `LLMClient.API_Key`, the same three `A2A.<agent>.AuthToken` values |

```bash
FLOGO_APP_PROPS_JSON=$HOME/kestrel-secrets/kestrel-mcp.json ./bin/RetailBankingSecureMCPServer > mcp.log 2>&1
FLOGO_LOG_LEVEL=DEBUG FLOGO_APP_PROPS_JSON=$HOME/kestrel-secrets/kestrel-agents.json ./bin/RetailBankingSecureAgents > agents.log 2>&1
FLOGO_APP_PROPS_JSON=$HOME/kestrel-secrets/kestrel-orchestrator.json ./bin/RetailBankingSecureOrchestrator > orchestrator.log 2>&1
```

(One terminal each, in this order; on Windows the executables end in `.exe`.) `FLOGO_APP_PROPS_ENV=auto` is the
alternative: one environment variable per property, dots replaced by underscores (`MCP_JWT_Secret`,
`A2A_scam_signal_agent_AuthToken`, `LLMClient_API_Key`, …). Build the executables as in
[Running the Industry Use-Case samples](../../../../RUNNING_THE_SAMPLES.md#start-the-apps).

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL with each persona's `sub`. Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, connections, secrets. See the note below on G11, G3, G4 and G7. Add `--local` for a build that still holds real credentials. | Nothing running |
| 2 | `fda cm -f <App>.flogo` (each app) | Every mapping resolves (the Agents app shows about 7 mappings per agent). | Nothing running |
| 3 | `JWT_SECRET=… python _rebuild/mcp_smoke.py` | The token checks at the MCP edge (401s, tool list per scope, hidden tools refused, identity from the token only, `UNKNOWN_CALLER` / `NOT_REVIEWER`) and the business rules in the Flogo runtime, without an LLM. Reloads `reset_data.sql` before and after; it attempts one real confirmation email to `To_Email` (the SQL guard is checked either way). | MCP server running |
| 3b | `A2A_LOG=agents.log A2A_TOKEN_DISPUTE=… A2A_TOKEN_SCAM=… A2A_TOKEN_HARDSHIP=… python _rebuild/a2a_smoke.py` | Public agent cards; missing, wrong and cross-agent tokens rejected before the agent runs; each agent answers with its own token, its reference tool queried PostgreSQL and its answer carries text only the reference table holds. Changes no data. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG`, LLM key |
| 3 | `python _rebuild/ws_smoke.py --no-auth-only`, then `JWT_SECRET=… python _rebuild/ws_smoke.py` | The orchestrator's sign-in guard (no header, `?token=` only), then a signed-in turn and an expired token. Changes no data. | Orchestrator (guard only); all three apps + LLM key for the full run |
| 4 | `JWT_SECRET=… A2A_LOG=agents.log python -u _rebuild/chat_e2e.py` | The whole system through real signed-in chats, with checks on the database (decisions, executed actions, audit) and on the Agents log (each agent's reference tool ran; no identity reached an agent). Resets the data before and after. About 5 minutes. | All three apps running, LLM key |

**Validator notes for this variant.** `validate_governed_apps.py` was written for the session-token design:

- **G11** reports *"decide_review_case without ['verify_reviewer']"*. That error is **not applicable** here: there is
  no `verify_reviewer` tool by design. The reviewer's identity comes from the JWT (`reviews:*` scopes at the MCP
  trigger, `caller_reviewer(sub)` in SQL on every call); `mcp_smoke.py` and `test_rules.py` cover it.
- **G3** (prompt rules), **G4** (temperature) and G7's `conversationId` check look for a `systemPrompt` in an
  activity's **settings**, the AI Agent's shape. The LLM Client activity takes its prompt, temperature and
  `conversationId` as **inputs**, so those checks skip the orchestrator. Review them by hand: the prompt is
  `orchestrator_prompt.txt` (stored in `LLMClient.SystemPrompt`), temperature is `0`, and `conversationId` is
  `$flow.headers["Sec-Websocket-Key"]` (declared in the handler's header schema).

Optional overrides:

- `MCP_URL` for `mcp_smoke.py` (default `http://localhost:9972/retail-banking-mcp`).
- `A2A_HOST` (default `http://localhost`) and `REPLY_TIMEOUT` (seconds, default 240) for `a2a_smoke.py`.
- `WS_URL` (default `ws://localhost:9970/retailbanking`) and `REPLY_TIMEOUT` (seconds; 150 for `ws_smoke.py`, 180
  for step 4).
- `A2A_LOG=<file the Agents app logs to>` for steps 3b and 4 (start the Agents app with `FLOGO_LOG_LEVEL=DEBUG`).

## This sample's values

| | Value |
|---|---|
| Database | `banking_jwt_auth` |
| Orchestrator | `RetailBankingSecureOrchestrator`, WebSocket `9970`, path `/retailbanking`; token from the `Authorization: Bearer` header only |
| MCP server | `RetailBankingSecureMCPServer`, `9972`, path `/retail-banking-mcp`, `JWT Token` auth (HS256, `MCP.JWT_Secret`), 19 tools: `whoami`, `get_my_accounts`, `get_my_transactions`, `get_my_cards`, `get_my_loans`, `find_branch`, `propose_card_block`, `confirm_card_block`, `propose_dispute`, `confirm_dispute`, `open_service_case`, `get_my_cases`, `email_my_confirmation`, `get_my_payees`, `propose_payment`, `confirm_payment`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `RetailBankingSecureAgents`, `Static Token` each: `dispute_triage_agent` `9973` (`lookup_merchant` → `lookup_merchant()`), `scam_signal_agent` `9974` (`get_scam_signal_guide` → `ref_scam_signals()`), `hardship_intake_agent` `9975` (`get_hardship_guide` → `ref_hardship_guide()`) |
| Reference tables (agents only) | `merchant_directory`, `scam_signal_guide`, `hardship_guide` (+ WHO_DECIDES rows read from `service_teams`) — no customer data |
| JWT claims | `iss` `kestrel-bank-idp`, `aud` `["retail-banking-mcp"]`, `sub`, `name`, `scp` (array), `iat`, `exp` |
| Personas (`mint_user_tokens.py`) | customers `james` `olivia` `william` `sophia` `benjamin` `emma` `michael` `patricia` (`CUST-2026-00101`…`00108`, full scopes), `james_view` (`CUST-2026-00101`, read scopes only); reviewers `maya` `KST-7001` (Customer Care, $25), `daniel` `KST-7002` (Financial Support, $5,000), `priya` `KST-7003` (Fraud Operations, $20,000) |
| Browser client | `samples/Agentic_AI/Chatbot_Secure`, port `3001` |

The ports and URLs are set in the build scripts (`PORT` and `ENDPOINT` in `build_mcp.py`, each agent's `port` in
`build_agents.py`, `WS_PORT`, `WS_PATH`, `MCP_URL` and `AGENTS` in `build_orchestrator.py`). To change
them, edit the scripts and pass the new URLs to the test scripts (`MCP_URL`, `A2A_HOST`, `WS_URL`), or set
the app properties as described in the main README, step 4.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools, scopes or personas in `tool_spec.py`.
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
