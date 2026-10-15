> **Disclaimer**
>
> This sample is provided for demonstration and educational purposes only, on an
> "as-is" basis and without warranty of any kind. It is not a supported product and
> is not intended for production use. All company names, data, and scenarios are
> fictional; any resemblance to real entities is coincidental. You are responsible
> for reviewing, securing, and testing it before any use.

# `_rebuild/`: regenerate and test the Author Services apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the three `.flogo` apps with the Flogo Design CLI
(`fda`) and the tests that check them. Use it to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

## What's in this folder

| File | What it does |
|---|---|
| `SPEC.md` | The design: personas, what the agents / the database / people own, tools, rules, reviewer loop and test plan. |
| `tool_spec.py` | **Single source of truth.** Every MCP tool's name, description, arguments and SQL (a guarded write and/or a read), plus the three A2A agents' reference tools (`AGENT_REF_TOOLS`). The build scripts and the tests import it, so the SQL that is tested is the SQL that ships. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `AuthorServicesMCPServer.flogo`: the MCP trigger and one flow per tool in `tool_spec.py` (guarded write, then the outcome read). 14 tools: 10 author tools + 4 reviewer tools. Can build in chunks (`BUILD_TO` / `RESUME_FROM`). |
| `build_agents.py` | Generates `AuthorServicesAgents.flogo`: three A2A agents (`journal_match_agent` 9843, `review_summary_agent` 9844, `submission_check_agent` 9845), each with ONE read-only PostgreSQL reference tool (`search_journals`, `get_review_guide`, `get_journal_policy`). The agents never get the author's identity. Ends with a self-check of ports, prompts, queries and parameter mappings. |
| `build_orchestrator.py` | Generates `AuthorServicesAIOrchestrator.flogo`: WebSocket trigger → AI Agent (MCP tools + the three A2A agents) → WebSocket reply, with one conversation per browser connection. URLs are app properties. |
| `orchestrator_prompt.txt` | The orchestrator's system prompt (two personas: authors and staff reviewers). |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule, the reviewer loop (every reason code) and the agents' reference functions. No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime, including the reviewer tools. |
| `a2a_smoke.py` | Test step 3b. Sends each A2A agent one identity-free request and checks from the Agents log that its reference tool queried PostgreSQL and that the answer carries text only the reference table holds. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator (authors, a staff reviewer on a separate connection, injection turns) and checks the results in the database. Writes `chat_e2e_transcript.md`. `--only` runs a subset. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, scoping and business rules are enforced) and the agents' reference functions; loads `seed_data.sql`. |
| `seed_data.sql` | Demo data (authors, staff reviewers, journals and their statement policies, manuscripts, reviewer comments, the peer-review guide, open cases), with dates relative to today. |
| `reset_data.sql` | Clears everything the assistant and the reviewers wrote and reloads `seed_data.sql`. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the
  `author_services` database loaded (see the main README, step 1).
- For steps 3b and 4: the **Flogo App Build CLI** (`flogobuild`) to build the executables, and an LLM key.
- For step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required |
| Database name | `PG_DB` | — | `author_services` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM model | `LLM_MODEL` | `LLM_Model` | `gpt-5.5` in `build_agents.py` / `build_orchestrator.py` |
| LLM API key | `LLM_API_KEY` | `API_Key` | required for `build_agents.py` and `build_orchestrator.py` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` | newest installed Flogo VS Code extension |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |

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

> ⚠️ **The generated apps contain your real credentials** (PostgreSQL password and LLM key), written as
> app properties. Replace them with placeholders before you commit or share the files.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule using the exact tool SQL: identity, scoping, the statements gate, transfers, routing and parking, the reviewer loop (every reason code, the parked APC reduction and statements exception, audit), and the agents' reference functions (rows, lookups, no identity, SELECT-only). Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` (and `validate_flogo_apps.py *.flogo`) | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, reference tools, secrets. Add `--local` for a build that still holds real credentials. | Nothing running |
| 2 | `fda cm -f <App>.flogo` (each app) | Every mapping resolves (the Agents app shows about 7 mappings per agent). | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM, including the reviewer tools. Resets the data before and after. | MCP server running |
| 3b | `A2A_LOG=<agents log> python _rebuild/a2a_smoke.py` | Each agent answers, its reference tool queried PostgreSQL without error, and the answer carries table-only text. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG`, output in a file; LLM key |
| 4 | `A2A_LOG=<agents log> python -u _rebuild/chat_e2e.py` | The whole system through real chats (authors, a reviewer on a separate connection, prompt injection), with checks on the database and on the agents' inputs (no identity). Resets the data before and after. Takes about 10 minutes. | All three apps running, LLM key |

Start the apps for steps 3–4 as in the main README, step 3 (the Agents app with `FLOGO_LOG_LEVEL=DEBUG` for 3b
and 4). Optional overrides: `MCP_URL` (step 3), `A2A_HOST` / `REPLY_TIMEOUT` (step 3b), `WS_URL` and
`REPLY_TIMEOUT` (seconds, default 180) for step 4.

## This sample's values

| | Value |
|---|---|
| Database | `author_services` |
| Orchestrator | WebSocket `9840`, path `/authorservices` |
| MCP server | `9842`, path `/author-services-mcp`, 14 tools: `verify_author`, `get_my_manuscripts`, `get_manuscript`, `get_review_comments`, `check_apc_coverage`, `record_submission_check`, `propose_transfer`, `confirm_transfer`, `open_review_case`, `get_my_cases`, `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `journal_match_agent` `9843` (`search_journals`), `review_summary_agent` `9844` (`get_review_guide` → `ref_review_guide`), `submission_check_agent` `9845` (`get_journal_policy` → `ref_journal_policy`) |
| Agent reference tables | `journals` (catalogue), `review_guide` (+ the appeal row from `review_teams`), `submission_policies` |

The ports and URLs are set in the build scripts (`PORT`, `WS_PORT`, `WS_PATH`, `MCP_URL`, `AGENTS`). To change them,
edit the scripts and the matching values in `mcp_smoke.py` / `a2a_smoke.py` / `chat_e2e.py`, or set the app
properties as described in the main README.

## Changing the use case

1. Change the rules in `database.sql`, the demo data in `seed_data.sql`, and the tools in `tool_spec.py`.
2. Reload the database, then run `test_rules.py` until it passes.
3. Regenerate the apps into an empty folder, then run steps 2–4.
