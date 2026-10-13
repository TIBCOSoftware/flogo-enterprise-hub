# `_rebuild/`: regenerate and test the Auto Policy & Claims (RAG) apps from code

**You don't need this folder to run the demo.** The main [README](../README.md) covers that.

This folder holds the Python scripts that generated the four `.flogo` apps and the tests that check them. Use it
to:

- see exactly how each app was built;
- rebuild the apps the same way every time (no AI assistant needed);
- change the use case and check the rules still hold.

**Build method: hybrid clone.** The three governed apps (MCP Server, Agents, Orchestrator) are built with the Flogo
Design CLI (`fda`). `fda` has no recipe for user-extension activities, so the `extensions/openAI` `vectorSearch`
task, its import and its `contrib` entry are then **transplanted verbatim** from the original (non-governed) MCP
app into the `search_policy_wording` flow. The ingestion app is a surgical clone of the original
`AutoInsuranceRAGIngestion.flogo`. The donors live in
[`Industry_Use_Cases_old/Auto_Insurance_Assistant_RAG_Use_Case`](../../../../../Industry_Use_Cases_old/Auto_Insurance_Assistant_RAG_Use_Case/).

## What's in this folder

| File | What it does |
|---|---|
| `SPEC.md` | The design spec the apps were built from: apps, ports and names, identity and scope for policyholders and staff reviewers, which steps are deterministic, agent, RAG or human, the product rules, the claim signals and risk band, every rule and reason code, two-step claim filing, case routing and the reviewer loop, the MCP tools, the A2A agents, the demo personas and the test scope. |
| `tool_spec.py` | **Single source of truth** for the 16 MCP tools (12 customer + 4 reviewer): each tool's name, description, arguments and SQL (a guarded write and/or a read), the `rag=True` flag on `search_policy_wording`, plus the columns and strings no customer tool and no reviewer tool may ever return. `build_mcp.py`, `test_rules.py` and `mcp_smoke.py` all import it, so the SQL that is tested is the SQL that ships. It also holds `AGENT_REF_TOOLS`, the three A2A agents' reference tools (name, description, `ref_*` SQL), used by `build_agents.py`, `test_rules.py`, `a2a_smoke.py` and `chat_e2e.py`. |
| `fda_common.py` | Shared helpers. Finds `config.md` and the `fda` binary, reads settings (environment variables first, then `config.md`) and wraps `fda` calls, the PostgreSQL and LLM connections, and PostgreSQL activities. Not run on its own. |
| `build_mcp.py` | Generates `AutoInsuranceMCPServer.flogo` (**hybrid clone**). `fda` builds the MCP trigger, one flow per tool in `tool_spec.py` and the conditional email step (sent only when the SQL says `SEND_OK`); `search_policy_wording` is built as `ReadOutcome (SELECT * FROM latest_vector_store()) → Return`, then the `vectorSearch` task, import and `contrib` entry are transplanted from the original MCP app, re-pointed at `ReadOutcome` (flow: `ReadOutcome → PolicySearch → Return`). Checks that `contrib` holds `openAI`, `PostgreSQL` and `MCP` before it finishes. |
| `build_agents.py` | Generates `AutoInsuranceAgents.flogo` with `fda` only: three read-only A2A agents, `fnol_intake_agent`, `coverage_interpreter_agent` and `fraud_signal_agent`, each with one read-only reference tool (`get_fnol_checklist`, `get_coverage_clause_index`, `get_claim_indicator_guide`). Each tool flow is `#act_postgresql_query SELECT * FROM ref_<topic>(CAST(?lookup AS text))` → `#actreturn` against the `PostgresConn` connection; the model can supply only the optional lookup `term`. Names, descriptions and SQL come from `tool_spec.AGENT_REF_TOOLS`. One part of each agent's reply needs text that only the table holds (`adjuster_follow_ups`, `clause_ref`, the indicator names). |
| `build_orchestrator.py` | Generates `AutoInsuranceAIOrchestrator.flogo` with `fda` only: WebSocket trigger → AI Agent (the 16 MCP tools + the three A2A agents) → WebSocket reply, with one conversation per browser connection and two personas (policyholder and staff reviewer). Checks its own output before it finishes. |
| `orchestrator_prompt.txt` | Riley's system prompt (identity, facts vs wording, the claim-filing order, internal details stay internal, the reviewer flow), read by `build_orchestrator.py`. |
| `build_ingestion.py` | Generates `AutoInsuranceRAGIngestion.flogo` by cloning the original ingestion app and swapping fields: port `9919`, database, store name `CopperleafAutoPolicyKB`, `POLICY_DOCS_DIR`, the four PDF names, a fresh PostgreSQL connection id, and the guarded `INSERT … SELECT * FROM record_vector_store(…)` in place of the original literal insert. The `contrib` blob, imports and the openAI tasks are carried verbatim. |
| `test_rules.py` | Test step 1. Runs the exact SQL from `tool_spec.py` against PostgreSQL and checks every business rule: verification and lockout, scoping, the claim rules, the claim signals and band, routing, cases and the full reviewer loop, plus the agents' `ref_*` reference functions (rows, lookup filter, unknown term = 0 rows, no personal data, SELECT-only, nothing lost from the old static text). No Flogo needed. |
| `mcp_smoke.py` | Test step 3. Calls the running MCP server's tools directly (no LLM) to check the rules hold in the Flogo runtime, including a `search_policy_wording` call against the ingested vector store. |
| `a2a_smoke.py` | Test step 3b. Sends each A2A agent one small identity-free request over A2A JSON-RPC (no orchestrator) and proves from the Agents DEBUG log that its reference tool flow ran, the PostgreSQL query ran without error and returned rows, and that the reply used table-only text. |
| `chat_e2e.py` | Test step 4. Holds scripted chats with the running orchestrator (policyholders, an injection attempt and the reviewers, on separate connections) and checks the results in the database. Writes `chat_e2e_transcript.md`. |

Related files in the use-case folder:

| File | What it does |
|---|---|
| `database.sql` | Schema, **rule functions** (where identity, scoping, the claim rules, the claim signals, the band, routing and the reviewer checks are enforced), the agents' reference tables (`fnol_intake_guide`, `coverage_clause_index`, `claim_indicator_guide`) with their `ref_*` functions, and demo data. Never drops `document_index` or the two RAG handoff functions (`record_vector_store`, `latest_vector_store`). |
| `seed_data.sql` | Demo data, with every volatile date relative to today. Included by `database.sql` and `reset_data.sql`. Don't load it on its own. |
| `reset_data.sql` | Clears everything the assistant and the reviewers wrote and reloads the demo data. Never truncates `document_index`, so the ingested vector store id survives. |
| `generate_policy_pdfs.py` | Generates the four fictional policy-wording PDFs in `policy_docs/` (the RAG corpus) with `fpdf2`. Deterministic output. They already exist; re-run only if you change the wording, then re-run the ingestion. |
| `prompts.md` | Demo prompts, including ones that show the rules holding. |
| `chat_e2e_transcript.md` | The transcript from the last `chat_e2e.py` run. |

## Before you start

- **Python 3.9+**, the **TIBCO Flogo VS Code extension** (it ships `fda`) and **`psql`** with the
  `auto_insurance_governed` database loaded (see the main README, step 1).
- The original sample in `samples/Agentic_AI/Industry_Use_Cases_old/Auto_Insurance_Assistant_RAG_Use_Case/` (the
  donor for `build_mcp.py` and `build_ingestion.py`).
- For `generate_policy_pdfs.py` only: `pip install fpdf2`.
- For step 4 only: `pip install websocket-client`.
- Run every command below **from the use-case folder** (the parent of `_rebuild/`).

**Settings.** Nothing secret is stored in these scripts. They read
[`skills-library/.claude/skills/config.md`](../../../../../../../skills-library/.claude/skills/config.md)
(copy `config.example.md` if you don't have one), and any environment variable overrides it:

| Setting | Environment variable | `config.md` key | Default |
|---|---|---|---|
| PostgreSQL host / port / user | `PG_HOST` / `PG_PORT` / `PG_USER` | `PG_HOST` / `PG_PORT` / `PG_USER` | `localhost` / `5432` / `postgres` |
| PostgreSQL password | `PG_PWD` or `PG_PASSWORD` | `PG_PASSWORD` | required by `build_mcp.py`, `build_ingestion.py` and the test scripts |
| Database name | `PG_DB` | — | `auto_insurance_governed` |
| `psql` path | `PSQL` | `PSQL_PATH` | `psql` on `PATH` |
| LLM / OpenAI API key | `LLM_API_KEY` | `API_Key` | required by every build script (the MCP and ingestion apps use it as `OPENAI_API_KEY` for the vector store) |
| LLM model | `LLM_MODEL` | — (see below) | `gpt-5.5` |
| LLM provider / base URL | `LLM_PROVIDER` / `LLM_BASE_URL` | `LLM_Provider` / `LLM_Base_URL` | `OpenAI` / empty |
| Email sender (MCP server only) | `EMAIL_USERNAME` | `Username` | required by `build_mcp.py` |
| Email recipient (MCP server only) | `EMAIL_TO` or `TO_EMAIL` | — | the sender address |
| Email password (MCP server only) | `EMAIL_PASSWORD` | — | see below |
| SMTP host / port (MCP server only) | `SMTP_HOST` / `SMTP_PORT` | `Server` / `Port` | `smtp.gmail.com` / `465` |
| vectorSearch donor app | `LEGACY_MCP` | — | the original sample's `AutoInsuranceMCPServer.flogo` |
| `fda` path | `FDA` | `FLOGODESIGN_CLI_PATH` (used only when no extension is found) | newest installed Flogo VS Code extension |
| Another `config.md` | `CONFIG_MD` | — | nearest `skills-library/.claude/skills/config.md` |
| Output folder (`fda` build scripts) | `OUT_DIR` | — | the use-case folder (refused if the `.flogo` already exists) |

**LLM model.** `build_agents.py` and `build_orchestrator.py` set `LLM_MODEL` to `gpt-5.5` unless the
`LLM_MODEL` environment variable is already set. To build with another model, set `LLM_MODEL=<model>` when you run
them.

**Email password.** `fda` cannot encrypt a password, and the designer only accepts the email password as an
encrypted `SECRET:` value. So `build_mcp.py` uses your `EMAIL_PASSWORD` only if it already starts with `SECRET:`;
otherwise it writes a portable dummy `SECRET:` value. Re-enter your app password in the designer's **App
Properties**. It prints which source it used, never the value.

**OpenAI endpoint.** The `extensions/openAI` activities reject an empty endpoint, so `build_mcp.py` and
`build_ingestion.py` write `OPENAI_API_ENDPOINT_URL` = `https://api.openai.com/v1`.

## Regenerate the apps

The `fda` scripts **refuse to overwrite** an existing `.flogo`, so build into an empty folder. `build_ingestion.py`
takes `--out` instead of `OUT_DIR` (and `--force` to overwrite):

```bash
mkdir -p rebuilt
OUT_DIR=rebuilt python _rebuild/build_mcp.py
OUT_DIR=rebuilt python _rebuild/build_agents.py
OUT_DIR=rebuilt python _rebuild/build_orchestrator.py
python _rebuild/build_ingestion.py --out rebuilt/AutoInsuranceRAGIngestion.flogo
```

`build_mcp.py` connects to the database to read each query's result columns; the others don't.
`build_ingestion.py` always points `POLICY_DOCS_DIR` at this sample's own `policy_docs/` folder (absolute path),
whatever `--out` is. Compare the result with the shipped apps, then delete `rebuilt/`; don't commit it. If
`build_mcp.py` fails midway, delete only the partial `AutoInsuranceMCPServer.flogo` and re-run.

> ⚠️ **Any later `fda sa` on the MCP app drops the vectorSearch contrib entry.** `fda` re-derives the app's
> `contrib` blob on every `set-attribute`, and it doesn't know the user-extension `openAI` entry, so the entry is
> silently removed and the app no longer builds or opens cleanly. After any `fda` edit to
> `AutoInsuranceMCPServer.flogo`, re-run the transplant (rebuild with `build_mcp.py`) or restore the `openAI`
> entry in `contrib` from the original app.

> ⚠️ **Never use these scripts to "fix" a `.flogo` you have opened and saved in the designer.**
> Regenerating creates new connection IDs and drops the credentials you entered. Rebuild into a new
> folder and compare instead.

> ⚠️ **The generated apps contain your real credentials** (PostgreSQL password, the OpenAI key in
> `OPENAI_API_KEY` and `AgenticAI.OpenAIConn.API_Key`, email addresses, a local `POLICY_DOCS_DIR` path), written
> as app properties. Replace them with placeholders before you commit or share the files.

## Build context (only to build executables)

Running the apps from VS Code needs only `flogo.extensions.local` → `<repo>/extensions`. To build executables with
`flogobuild`, the build context must include the local extensions, or the MCP and ingestion apps fail on the
openAI activities:

```bash
flogobuild create-context -n flogo-2267-openai -v <path-to-flogo-vsix> -u <repo>\extensions
flogobuild build-exe -f AutoInsuranceMCPServer.flogo -c flogo-2267-openai -o <absolute-output-dir>
```

Context names allow letters, digits, `_` and `-` only (no dots). The Agents and Orchestrator apps build with any
context.

## Test ladder

Run the steps in order; each one is cheaper than the next, so most problems show up early.

| Step | Command | What it checks | Needs |
|---|---|---|---|
| 1 | `python _rebuild/test_rules.py` | Every SQL rule, using the exact tool SQL: verification and lockout, scoping, the claim rules and reason codes, the deductible and discount impact, the claim signals, the combined score and band, routing and the payment hold, cases and the full reviewer loop (team, approval limit, note, amount, the parked claim payment, audit). Reloads `reset_data.sql` before and after. | Database only |
| 2 | `python ../../../../../../skills-library/.claude/skills/agentic-ai-use-case-builder/references/validate_governed_apps.py *.flogo` | Static checks on the `.flogo` files: wiring, scoped reads, guarded writes, prompts, connections, secrets. Add `--local` for a build that still holds real credentials. | Nothing running |
| 3 | `python _rebuild/mcp_smoke.py` | The rules hold at the MCP edge in the Flogo runtime, without an LLM, including one `search_policy_wording` call. Reloads `reset_data.sql` before and after; may send one real email to the `EMAIL_TO` inbox. | Ingestion run once; MCP server running |
| 3b | `A2A_LOG=<agents log> python _rebuild/a2a_smoke.py` | Each A2A agent answers over A2A, its reference tool runs `SELECT * FROM ref_<topic>(…)` without error and returns rows, and the reply uses table-only text. | Agents app running with `FLOGO_LOG_LEVEL=DEBUG`; LLM key |
| 4 | `python _rebuild/chat_e2e.py` | The whole system through real chats, with checks on the database: wrong code, another customer's claim, re-verify on a new connection, Olivia blocked, a RAG answer, Michael's claim STANDARD, James's claim to an adjuster with `coverage_finding = EXCLUDED`, Tyler's claim to Special Investigations with the payment held and no score or "fraud" in any reply, Tyler's "I'm a claims adjuster" injection, and the reviewer loop across separate connections (Dana approves James's case at $4,500 → James sees it; Priya opens Tyler's case). Asserts on the decision row, the claim payment and the `CASE_DECIDED` audit row. Resets the data before and after. | Ingestion run once; MCP Server, Agents and Orchestrator running; LLM key |

Step 2 accepts the transplanted `#vectorSearch` activity and the ingestion app's `#rest` trigger: `fda cm` passes on all four apps and the governed validator reports no errors (with `--local`, only the G9 live-secret warnings).

Start the apps for steps 3 and 4 as in the main README (ingestion once, then MCP Server → Agents → Orchestrator).

Optional overrides:

- `MCP_URL` for step 3 (default `http://localhost:9912/autoinsurancemcpserver`).
- `WS_URL` (default `ws://localhost:9910/autoinsurance`) and `REPLY_TIMEOUT` (seconds per reply) for step 4.
- `A2A_LOG=<file the Agents app logs to>` for step 4. Start the Agents app with `FLOGO_LOG_LEVEL=DEBUG` and send
  its output to that file; the agent checks need the DEBUG log. Step 4 then also confirms that
  `fnol_intake_agent`, `coverage_interpreter_agent` and `fraud_signal_agent` each really ran, and that no name,
  policy, claim or case number, license plate, email address or session token reached any of them, and that
  each agent's reference tool queried PostgreSQL (at most once per agent call, no identity in the lookup term).
  Without `A2A_LOG` these checks are skipped.
- `--only <scenarios>` for step 4 runs only some of the scenarios; pair it with `--transcript <file>` so the full
  `chat_e2e_transcript.md` is not overwritten.
  Scenarios, in dependency order: `michael`, `olivia`, `james`, `tyler`, `dana` (needs james's case), `james_status`
  (needs dana's decision), `priya` (needs tyler's case). `--keep` keeps the data after a full run so a dependent
  scenario can be re-run with `--only <names> --no-reset`. `ORCH_LOG=<orchestrator log>` adds the tool-call checks
  (e.g. `search_policy_wording` ran). `REPLY_TIMEOUT` defaults to 300 seconds.

## Last verified run

| Step | Result |
|---|---|
| 1 `test_rules.py` | 244/244 (164 rules + 80 reference-tool checks) |
| 2 `validate_governed_apps.py --local` + `fda cm` | 0 errors (G9 live-secret warnings only); mappings MCP 164, Agents 21, Orchestrator 5, Ingestion 13 |
| 3 `mcp_smoke.py` + `a2a_smoke.py` | 80/80 (live SMTP not exercised: dummy email password) + 21/21 |
| 4 `chat_e2e.py` | 77/77 on gpt-5.5, 2026-10-13, incl. the reference-tool PostgreSQL checks |

## This sample's values

| | Value |
|---|---|
| Database | `auto_insurance_governed` (the original sample keeps its own `auto_insurance` database) |
| Orchestrator | WebSocket `9910`, path `/autoinsurance` |
| MCP server | `9912`, path `/autoinsurancemcpserver`, 16 tools. Customer (12): `verify_policyholder`, `get_my_policy`, `get_my_coverages`, `get_my_claims`, `get_my_payments`, `get_my_cases`, `search_policy_wording` (RAG), `propose_claim`, `record_claim_assessment`, `confirm_claim`, `open_service_case`, `email_confirmation`. Reviewer (4): `verify_reviewer`, `get_review_queue`, `get_review_case`, `decide_review_case` |
| A2A agents | `fnol_intake_agent` on `9913`, `coverage_interpreter_agent` on `9914`, `fraud_signal_agent` on `9915`; reference tools `get_fnol_checklist` → `ref_fnol_checklist()`, `get_coverage_clause_index` → `ref_coverage_clauses()`, `get_claim_indicator_guide` → `ref_claim_indicators()` |
| RAG ingestion | `POST http://localhost:9919/ingest`; vector store `CopperleafAutoPolicyKB`; id recorded in `document_index` via `record_vector_store()`, read by `latest_vector_store()` |
| Runtime model | `gpt-5.5` (app property `LLM_Model`) |

The ports and URLs are set in the build scripts (`PORT` and `ENDPOINT` in `build_mcp.py`, each agent's port in
`build_agents.py`, `WS_PORT`, `WS_PATH`, `MCP_URL` and `AGENTS` in `build_orchestrator.py`, `PORT` in
`build_ingestion.py`). To change them, edit the scripts and the matching defaults in `mcp_smoke.py` /
`chat_e2e.py` (or set `MCP_URL` / `WS_URL`), or set the app properties and orchestrator URL properties as
described in the main README.

## Changing the use case

1. Change the rules or data in `database.sql` / `seed_data.sql`, and the tools in `tool_spec.py`
   (keep `SPEC.md` in step).
2. Reload the database, then run `test_rules.py` until it passes.
3. If you change the policy wording, edit `generate_policy_pdfs.py`, regenerate the PDFs and re-run the
   ingestion (a new vector store; the MCP tool picks up the newest).
4. Regenerate the apps into an empty folder, then run steps 2–4.
