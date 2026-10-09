# FDA build recipes — construct all 3 agentic apps with `fda` only

Exact `flogodesign-cli` (`fda`) command sequences to build the MCP Server, A2A Agents, and AI Orchestrator **from scratch, without hand-editing any `.flogo` JSON**. Verified end-to-end (build + live run: WebSocket chat → LLM → MCP tool → real PostgreSQL → reply written back over WS).

## Conventions & placeholders

Replace every `<…>` with the user's domain values. **Nothing here is domain-specific** — the examples use placeholders on purpose.

| Placeholder | Meaning | Example value (yours will differ) |
|---|---|---|
| `<UseCase>` / `<Prefix>` | Use-case name / app-name prefix | (from Phase 2) |
| `<db>`, `<pk>`, `<table>` | DB name / table primary key / table | (from `database.sql`) |
| `<Tool>`, `<toolDesc>`, `<SQL>` | MCP tool name / description / query | — |
| `<Agent>`, `<agentDesc>`, `<sysPrompt>` | A2A agent id / description / system prompt | — |
| `<*_PORT>`, `<*_URL>` | ports / URLs (always app properties) | — |
| `$FDA`, `$FLB` | resolved `fda` / `flogobuild` paths | from `config.md` (Phase 0) |

**Ground rules**
- Read all hosts, ports, creds, API key, model, base URL, SMTP creds, and CLI paths from `config.md` at build time (Phase 0). Never hardcode.
- Print `$FDA version` and `$FLB version` before running commands.
- On Windows/Git-Bash, prefix each `fda`/`flogobuild` call with `MSYS_NO_PATHCONV=1`, **or** drive `fda.exe` from a Python `subprocess` (which sidesteps MSYS path-mangling entirely — recommended for the A2A/orchestrator loops).
- Every `fda` call takes `-f <app>.flogo`. Detect failure by scanning combined stdout/stderr for `(ERROR)`.
- Secrets: load into variables from `config.md`; pass as `cap` values; never echo them. Prefer `SECRET:`-encoded values where the field supports it.

A tiny Python driver keeps long builds repeatable. **Keep it** (never delete): save one per app in `<UseCaseDir>/_rebuild/` (`build_mcp.py`, `build_a2a.py`, `build_orchestrator.py`) — secrets read at run time from env vars / config.md (never hardcoded), and it refuses to overwrite an existing `.flogo` (replay into a new/empty folder; never "fix" a designer-opened app with it — SKILL Hard rule #2):

```python
# Rebuilds <Prefix>MCPServer.flogo for this use case only (e.g. after an FDA upgrade / demo reset).
# Run:  FDA=<path-to-fda> OPENAI_API_KEY=... PG_PASSWORD=... python build_mcp.py <empty-target-dir>
# Secrets come from env vars / config.md at run time; refuses to overwrite an existing .flogo.
import subprocess, os, sys, json
FDA = os.environ["FDA"]                 # resolved from config.md
FILE = os.path.join(sys.argv[1] if len(sys.argv) > 1 else ".", "<Prefix>MCPServer.flogo")
if os.path.exists(FILE):
    sys.exit(f"REFUSING: {FILE} exists — replay into a new/empty folder (Hard rule #2)")
def fda(*args, allow_fail=False):
    r = subprocess.run([FDA, *map(str, args), "-f", FILE],
                       capture_output=True, text=True)
    out = (r.stdout or "") + (r.stderr or "")
    if "(ERROR)" in out and not allow_fail:
        print("FAILED:", " ".join(map(str, args))); print(out[-1000:]); sys.exit(1)
    return out

def conn_uuid(name):                 # a connection's conn:// ref (orchestrator arrays, readback checks)
    conns = json.load(open(FILE, encoding="utf-8"))["connections"]
    items = list(conns.values()) if isinstance(conns, dict) else conns
    return "conn://" + next(c["id"] for c in items if c["name"] == name)

def assert_conn(flow, task, name):   # SKILL gotcha 10: `ca -C <name>` binds; PROVE it by reading it back
    d = json.load(open(FILE, encoding="utf-8"))
    t = next(t for r in d["resources"] if r["id"] == "flow:" + flow
             for t in r["data"]["tasks"] if t["id"] == task)
    got = (t["activity"].get("input") or {}).get("Connection")
    if got != conn_uuid(name):
        print(f"FAILED: {flow}.{task} input.Connection={got!r}, expected {name} = {conn_uuid(name)}"); sys.exit(1)

def cap_empty(name):                 # gotcha 4c: TRULY empty string property (FDA-only, verified 0.9.3)
    fda("cap", name, "string", "placeholder")   # `cap … ""` would write the literal "New_value"
    idx = [p["name"] for p in json.load(open(FILE, encoding="utf-8"))["properties"]].index(name)
    fda("sa", "any", f"properties.{idx}.value", "--jsonValue", '""')   # NOT `sa property <dotted.name>.value` (ambiguous)
```

---

## § MCP Server (`<Prefix>MCPServer.flogo`)

Read-only tools, one per lookup. Trigger `tr_mcpserver`; each tool flow = `act_postgresql_query → act_default_actreturn`.

### 1. Project, properties, PostgreSQL connection

```bash
$FDA cp <Prefix>MCPServer "<UseCase> MCP Server" -f "$FILE"

# App properties (values from config.md; Password ideally SECRET:)
$FDA cap PostgreSQL.PostgresConn.Host          string <host>   -f "$FILE"
$FDA cap PostgreSQL.PostgresConn.Port          number <port>   -f "$FILE"   # DB connection Port field is NUMERIC — gotcha 8
$FDA cap PostgreSQL.PostgresConn.Database_Name string <db>     -f "$FILE"
$FDA cap PostgreSQL.PostgresConn.User          string <user>   -f "$FILE"
$FDA cap PostgreSQL.PostgresConn.Password      string <pwd>    -f "$FILE"
$FDA cap MCP_SERVER_PORT                        string <mcpPort> -f "$FILE"  # tr_mcpserver "HTTP Server Port" field is STRING — gotcha 8

# PostgreSQL connection, settings bound to the properties above
$FDA cc PostgresConn con_postgresql -f "$FILE"
# Every PostgreSQL activity below is bound by `ca … -C PostgresConn` alone (SKILL gotcha 10).
$FDA sa connection PostgresConn.settings.databaseType PostgreSQL -f "$FILE"
$FDA sa connection PostgresConn.settings.host         PostgreSQL.PostgresConn.Host          -C app-property -f "$FILE"
$FDA sa connection PostgresConn.settings.port         PostgreSQL.PostgresConn.Port          -C app-property -f "$FILE"
$FDA sa connection PostgresConn.settings.databaseName PostgreSQL.PostgresConn.Database_Name -C app-property -f "$FILE"
$FDA sa connection PostgresConn.settings.user         PostgreSQL.PostgresConn.User          -C app-property -f "$FILE"
$FDA sa connection PostgresConn.settings.password     PostgreSQL.PostgresConn.Password      -C app-property -f "$FILE"
```

### 2. Trigger

```bash
$FDA ct <Prefix>MCPServer tr_mcpserver "<UseCase> MCP server" -f "$FILE"
$FDA sa trigger <Prefix>MCPServer.settings.serverType         HTTP  -f "$FILE"
$FDA sa trigger <Prefix>MCPServer.settings.serverPort         MCP_SERVER_PORT -C app-property -f "$FILE"
$FDA sa trigger <Prefix>MCPServer.settings.serverEndpointPath /<usecase>mcpserver -f "$FILE"
$FDA sa trigger <Prefix>MCPServer.settings.serverName         <UseCase> -f "$FILE"
$FDA sa trigger <Prefix>MCPServer.settings.serverVersion      1.0.0 -f "$FILE"
```

### 3. Shared tool schemas (create ONCE, reused by every tool) — **gotcha 1**

```bash
$FDA cs EmptyArgs   '{"type":"object","properties":{}}' -f "$FILE"
$FDA cs ToolResponse '{"type":"object","properties":{"data":{"type":"string"},"error":{"type":"string"}}}' -f "$FILE"
```

### 4. Per tool (repeat for each lookup)

`<flow>` = a unique flow name (e.g. `get<Table>`). `<Tool>` = the LLM-visible tool name.

```bash
$FDA cf <flow> "<toolDesc>" -f "$FILE"
$FDA ca <flow> PostgreSQLQuery act_postgresql_query "PostgreSQL Query" -C PostgresConn -f "$FILE"
$FDA ca <flow> Return          act_default_actreturn "Simple Return"    -f "$FILE"   # ca auto-links in creation order

# SKILL gotcha 10: the `ca … -C PostgresConn` above IS the connection binding. NEVER set
#   input.Connection again with `sa activity` — fda 0.9.3 rebinds it to the FIRST connection in the
#   file (literal conn://, name + `-C connection`, `--force` and `--jsonValue` all do it). Harmless
#   here only because PostgresConn is this app's sole connection; in the A2A app OpenAIConn is first.
#   Driver: assert_conn("<flow>", "PostgreSQLQuery", "PostgresConn") right after the `ca`.
$FDA sa activity <flow>.PostgreSQLQuery.input.Query  "SELECT * FROM public.<table> ORDER BY <pk> ASC;" -f "$FILE"
$FDA sa activity <flow>.PostgreSQLQuery.input.Schema public -f "$FILE"

# Handler = one MCP tool
$FDA cth <flow> <Prefix>MCPServer "<toolDesc>" \
    --mcpHandlerType Tool --mcpHandlerName <Tool> --mcpHandlerDescription "<toolDesc>" -f "$FILE"
$FDA wth <flow> <Prefix>MCPServer.<flow> --force -f "$FILE"

# gotcha 1: attach input + output schemas or the MCP runtime panics
$FDA sa handler <Prefix>MCPServer.<flow>.schemas.output.arguments EmptyArgs   -C schema --force -f "$FILE"
$FDA sa handler <Prefix>MCPServer.<flow>.schemas.reply.response   ToolResponse -C schema --force -f "$FILE"

# gotcha 2: actreturn mapping uses the .mapping node
$FDA mm <flow>.Return.input.mappings.response.mapping.data '=coerce.toString($activity[PostgreSQLQuery].Output)' -f "$FILE"
```

> **Parameterized reads:** for a `WHERE <col> = ?p` query, set `input.Query` with a `?`-placeholder whose name does NOT equal a column name, then map values under **`input.input.mapping.parameters`** (e.g. `$FDA mm <flow>.PostgreSQLQuery.input.input.mapping.parameters.<p> '=$flow.<field>'`). See the sibling `postgres-activity-patterns.md`. Simple demos use `SELECT *` and let the LLM filter.
>
> ⚠️ **A placeholder must be followed by a space or one of `; ) , < > + - * % /`** — the connector only substitutes `?name` then, at design time *and* at runtime. **Never `?p::date`** (designer: `syntax error at or near "$5p5"`; runtime: the param is never bound) — write `CAST(?p AS date)`, or cast an enclosing expression (`NULLIF(?p,'')::date` is fine). Same for `?a||?b` → `?a || ?b`. `validate_flogo_apps.py` (Phase 5) flags it.
>
> ⚠️ **`mm` selector is DOUBLE-input — `input.input.mapping.parameters`, NOT `input.mapping.parameters`.** The `mm` selector path is `<activity>.input` + the field path inside the input object, and the postgres param object is itself named `input`. The single-input form `input.mapping.parameters` is design-time valid (`fda cm` passes) but lands the params in the WRONG slot `activity.input.mapping` — which the runtime does **not** read, so the query runs with unbound `?p` placeholders and silently returns nothing / errors. Empirically verified: `mm --help` and the reference JSON both use the double-input path, and a built file with the correct selector has params at `activity.input.input.mapping.parameters` (confirmed with the Aerospace MRO A2A build). Applies to every parameterized `act_postgresql_query` **and** `act_postgresql_insert` (INSERT/UPDATE) mapping below.

Rich `handlerDescription`s matter — the orchestrator LLM chooses tools from them.

---

## § A2A Agents (`<Prefix>Agents.flogo`)

One `tr_agent` trigger per action agent. **By default each agent's flow writes DIRECTLY to PostgreSQL** (`act_postgresql_query` to validate → `act_postgresql_insert` for the INSERT/UPDATE) **or sends email** (`act_general_sendmail`), and returns a result string. This is the pattern used by all the customer-facing reference use cases (Airline, Life & Pensions, Power Distribution, Retail Banking, Telecom). **Do NOT use `act_general_rest` / create a separate REST backend app unless the user explicitly asked for one** — the REST steps below are clearly marked *opt-in*. Because the loop is repetitive, drive it from Python `subprocess` (see driver above; point `FILE` at the A2A file).

### 1. Project, properties, LLM connection

```bash
$FDA cp <Prefix>Agents "<UseCase> A2A Agents"
# LLM properties (from config.md)
$FDA cap AgenticAI.OpenAIConn.LLM_Provider string <provider>            # e.g. OpenAI
$FDA cap AgenticAI.OpenAIConn.API_Key      string <apiKey>              # SECRET where supported
# gotcha 4c — base URL: EMPTY for OpenAI (connector default). `cap … string ""` writes the literal
#   "New_value" → posts to /New_value/chat/completions. Truly empty via FDA only (= driver's cap_empty()):
$FDA cap AgenticAI.OpenAIConn.LLM_Base_URL string placeholder
#   idx = [p['name'] for p in json.load(open(FILE,encoding='utf-8'))['properties']].index('AgenticAI.OpenAIConn.LLM_Base_URL')
$FDA sa any properties.<idx>.value --jsonValue '""'    # `sa property <dotted.name>.value` does NOT work (ambiguous)
#   config.md gives a non-empty URL (Azure OpenAI / gateway / non-OpenAI provider only)? just:
#   $FDA cap AgenticAI.OpenAIConn.LLM_Base_URL string <baseUrl>
$FDA cap LLM_Model                         string <model>             # config.md; fallback gpt-5-nano
# One PORT + URL property per agent, plus SMTP/recipient properties:
$FDA cap <Agent>_PORT string <port>          # tr_agent "A2A Server Port" field is STRING — keep string (gotcha 8)
$FDA cap <Agent>_URL  string http://localhost:<port>
#   Email agent: $FDA cap Email_Username string <user> ; Email_App_Password string <pwd> ; To_Email string <addr>
#   Opt-in REST agents ONLY (if the user explicitly asked): $FDA cap <Backend>_URL string <url-with-{pathParams}>

$FDA cc OpenAIConn con_llmprovider
$FDA sa connection OpenAIConn.settings.llmProvider    AgenticAI.OpenAIConn.LLM_Provider -C app-property
$FDA sa connection OpenAIConn.settings.apiKey         AgenticAI.OpenAIConn.API_Key      -C app-property
$FDA sa connection OpenAIConn.settings.llmProviderUrl AgenticAI.OpenAIConn.LLM_Base_URL -C app-property
# DEFAULT: action agents write to the DB, so create a PostgresConn here (same as MCP § 1).
#   OpenAIConn is FIRST in this file, so an `sa activity …input.Connection` re-set would silently rebind
#   every PostgreSQL activity to OpenAIConn — bind with `ca … -C PostgresConn` only (SKILL gotcha 10).
```

### 2. Per agent (repeat)

```bash
$FDA ct <Agent> tr_agent "<agentDesc>"
$FDA sa trigger <Agent>.settings.llmProviderConnection OpenAIConn -C connection
$FDA sa trigger <Agent>.settings.agentName           <Agent>
$FDA sa trigger <Agent>.settings.agentDescription    "<agentDesc>"
$FDA sa trigger <Agent>.settings.agentType           "A2A Server"
$FDA sa trigger <Agent>.settings.agentPort           <Agent>_PORT -C app-property
$FDA sa trigger <Agent>.settings.agentUrl            <Agent>_URL  -C app-property
$FDA sa trigger <Agent>.settings.model               LLM_Model    -C app-property
$FDA sa trigger <Agent>.settings.temperature         0    --type number   # gpt-5 reasoning models ignore it (connector sends 1.0); 0 = deterministic otherwise
$FDA sa trigger <Agent>.settings.enableGuardrails    true --type boolean
$FDA sa trigger <Agent>.settings.redactSensitiveData true --type boolean
$FDA sa trigger <Agent>.settings.conversationStoreType Memory
$FDA sa trigger <Agent>.settings.memoryMaxSize       100  --type number
$FDA sa trigger <Agent>.settings.systemPrompt        "<sysPrompt>"

# --- flow: noop is created by cf; add the action activities in order (ca auto-links) ---
$FDA cf <Agent>_flow "<agentDesc>"
$FDA ca <Agent>_flow LogMessage act_general_log "Log" 
$FDA mm <Agent>_flow.LogMessage.input.message '=string.concat("Agent Invocation started:",$flowctx["FlowName"])'

# choose the action for this agent — (a) DB write and (b) email are the DEFAULTS:
#
#   (a) DEFAULT — DB write (direct to PostgreSQL). Optionally validate with a SELECT first,
#       then INSERT/UPDATE. This is the canonical pattern for all customer-facing use cases.
$FDA ca <Agent>_flow ValidateQuery act_postgresql_query  "PostgreSQL Query"  -C PostgresConn   # optional pre-check
#       driver: assert_conn("<Agent>_flow", "ValidateQuery", "PostgresConn") — NO `sa …input.Connection` (SKILL gotcha 10)
$FDA sa activity <Agent>_flow.ValidateQuery.input.Query  "SELECT ... FROM public.<table> WHERE <col> = ?id;"
$FDA sa activity <Agent>_flow.ValidateQuery.input.Schema public
$FDA mm <Agent>_flow.ValidateQuery.input.input.mapping.parameters.id '=$flow.toolParams.<field>'   # DOUBLE-input: input.input.mapping (see ⚠️ note in § MCP parameterized reads)
$FDA ca <Agent>_flow WriteRow act_postgresql_insert  "PostgreSQL Insert"  -C PostgresConn
#       driver: assert_conn("<Agent>_flow", "WriteRow", "PostgresConn") — NO `sa …input.Connection` (SKILL gotcha 10)
$FDA sa activity <Agent>_flow.WriteRow.input.Query  "INSERT INTO public.<table> (<cols>) VALUES (?p1, ?p2);"
#       (act_postgresql_insert runs UPDATE too — e.g. "UPDATE public.cards SET status='BLOCKED' WHERE card_id=?p1;")
#       typed column? VALUES (?p1, CAST(?p2 AS date)) — NEVER ?p2::date (not substituted; see ⚠️ in § MCP parameterized reads)
$FDA sa activity <Agent>_flow.WriteRow.input.Schema public
$FDA mm <Agent>_flow.WriteRow.input.input.mapping.parameters.p1 '=$flow.toolParams.<field1>'   # DOUBLE-input (see ⚠️ note in § MCP parameterized reads)
$FDA mm <Agent>_flow.WriteRow.input.input.mapping.parameters.p2 '=$flow.toolParams.<field2>'
#
#   (b) DEFAULT — Email (the dedicated send_confirmation_email agent):
$FDA ca <Agent>_flow SendMail act_general_sendmail "Send Mail"
$FDA sa activity <Agent>_flow.SendMail.input.Server smtp.gmail.com
$FDA sa activity <Agent>_flow.SendMail.input.Port 465
#       Connection Security SSL; Username/Password/recipients from app properties; map subject/body from toolParams.
#
#   (c) OPT-IN — REST call to a backend. *** Use ONLY if the user explicitly asked for a REST
#       backend app. *** Default agents do (a)/(b) and never touch this.
# $FDA ca <Agent>_flow InvokeRESTService act_general_rest "Invoke REST"
# $FDA sa activity <Agent>_flow.InvokeRESTService.input.Method GET
# $FDA sa activity <Agent>_flow.InvokeRESTService.input.Uri <Backend>_URL -C app-property
# #   dynamic path/body: $FDA mm <Agent>_flow.InvokeRESTService.input.pathParams.mapping.<p> '=$flow.toolParams.<p>'
# #   ⚠️ REQUIRED — declare the response BODY output schema, or downstream mappings can't
# #     resolve `$activity[InvokeRESTService].responseBody`. The `#rest` activity ALWAYS
# #     exposes statusCode/responseTimeInMillis/headers, but `responseBody` only exists when
# #     you set schemas.output.responseBody. `ca`/`ct` do NOT create it → the Return mapper
# #     shows a red ✗ ("Map Outputs" invalid). Write the expected response shape (a
# #     draft-04 object schema of the fields the backend returns) to a file, then:
# $FDA sa activity <Agent>_flow.InvokeRESTService.schemas.output.responseBody --jsonFile <resp_schema.json> --force
# #     where <resp_schema.json> = {"type":"json","value":"<stringified draft-04 schema>","fe_metadata":"<sample JSON>"}
# #     (If the mapping only does coerce.toString(responseBody), the exact fields don't affect
# #      runtime — but the field must EXIST in schemas.output or the designer rejects the map.)

$FDA ca <Agent>_flow Return act_default_actreturn "Simple Return"
# DEFAULT return (DB write): map a confirmation string / the write output.
$FDA mm <Agent>_flow.Return.input.mappings.response.mapping.data '=coerce.toString($activity[WriteRow].Output)'
#   (email agent: map a "sent" confirmation; opt-in REST agent: coerce.toString($activity[InvokeRESTService].responseBody))

# --- handler = the agent's tool card ---
$FDA cth <Agent>_flow <Agent> "<agentToolDesc>"
$FDA sa handler <Agent>.<Agent>_flow.settings.agentToolName        <Agent>
$FDA sa handler <Agent>.<Agent>_flow.settings.agentToolDescription "<agentToolDesc>"
$FDA wth <Agent>_flow <Agent>.<Agent>_flow --force --input toolParams:object --output response:object   # tr_agent has no default wiring
# toolParams (input) + response (reply) schemas — describe the fields the orchestrator must pass.
# ⚠️ Set them INLINE (--jsonValue), NOT as a schema:// reference (-C schema). The AI Agent Trigger reads
#    toolParams only inline: a reference silently gives the LLM a tool with NO parameters, so it calls the tool
#    with {} or guessed names (FGAI-155). The MCP Server trigger resolves references; tr_agent does not.
TP='{"type":"object","properties":{ "<field>":{"type":"string","description":"<what to pass>"} },"required":["<field>"]}'
$FDA sa handler <Agent>.<Agent>_flow.schemas.output.toolParams --jsonValue "$(python -c 'import json,sys; v=sys.argv[1]; print(json.dumps({"type":"json","value":v,"fe_metadata":v}))' "$TP")" --force
RS='{"type":"object","properties":{"response":{"type":"string"}}}'
$FDA sa handler <Agent>.<Agent>_flow.schemas.reply.response   --jsonValue "$(python -c 'import json,sys; v=sys.argv[1]; print(json.dumps({"type":"json","value":v,"fe_metadata":v}))' "$RS")" --force

# gotcha 5 — the FLOW input needs the SAME toolParams schema as the handler, or the
#   designer's mapper can't resolve $flow.toolParams.<field>: the flow's Input tab shows
#   a red ✗ on every toolParams mapping (subject/body/email/…) and the app fails
#   validation. `wth --input toolParams:object` writes only a BARE object to
#   flow.metadata.input (no sub-schema). Reuse the tool schema on the flow input — write
#   [{"name":"toolParams","type":"object","schema":{"type":"json","value":"<same JSON string as $TP>"}}]
#   to a file, then:
$FDA sa flow <Agent>_flow.metadata.input --jsonFile <toolparams_flowinput.json>
#   ⚠️ CAVEAT — `metadata.input` alone is NOT durable in the designer. The designer treats
#   `metadata.fe_metadata.input` (a stringified draft-04 JSON schema — its cached "view") as
#   the SOURCE OF TRUTH and REGENERATES `metadata.input` FROM IT on the next Save. So a flow
#   whose fe_metadata is still empty gets your CLI-written schema WIPED back to a bare object
#   the first time the user saves the app. (Verified: two A2A flows we set via `sa flow` were
#   bare again after the user opened+saved the app in the designer.)
#   Two ways to make it stick — do ONE:
#   (a) SANCTIONED / always-correct: the user clicks "Sync" once on each trigger. Sync reads
#       the handler tool schema and writes BOTH metadata.input AND fe_metadata correctly.
#       This is the documented "Manual Sync for Non-OpenAPI Triggers" limitation
#       (tr_mcpserver/tr_agent/tr_wsserver are all non-OpenAPI) — keep it as the fallback
#       manual-config-gap step regardless.
#   (b) NO-SYNC bake (optional, for a clean first-open): also write fe_metadata to EXACTLY the
#       shape the designer produces after a Sync, so metadata.input survives regeneration and
#       the fields render with no Sync. Mirror this format per flow (fields = your
#       $TP properties):
#         metadata.input[toolParams].schema = {"type":"json",
#           "value":"{\"<f1>\":{\"type\":\"string\"},\"<f2>\":{\"type\":\"string\"}}"}
#         metadata.fe_metadata.input (stringified) =
#           {"type":"object","title":"<Agent>_trigger","properties":{"toolParams":
#             {"$schema":"http://json-schema.org/draft-04/schema#","type":"object",
#              "properties":{"<f1>":{"type":"string"},"<f2>":{"type":"string"}}}}}
#       (Do the same for output: metadata.output[response].schema value
#         {\"data\":{\"type\":\"string\"},\"error\":{\"type\":\"string\"}} and the matching
#        fe_metadata.output with title "Inputs".) Copy the exact format from a flow the user
#       has already Synced — it's the designer's own output, so it's the safest template.
#   (Flow input/output config is itself a documented FDA limitation — see fda-limitations.md.)

# gotcha 6 — email agents: the #sendmail `Password` field is type `password`. FDA `cap`
#   can only make a `string` property (no password type: `cap … password` errors
#   "Unknown Flogo Property Type") AND writes the value as PLAINTEXT (FDA can't
#   SECRET-encrypt). A `password` field only binds cleanly to a SECRET-valued property,
#   so a plaintext string one makes the designer flag:
#     Type of field "Password" (password) differs from bound app property (string).
#   *** DO NOT set the property's type to `password` to "fix" this. *** That type is
#   invalid; the designer DROPS the property on the next save, turning the warning into a
#   HARD error:  "Password" is bound to app property "..." which does not exist.
#   Correct fix (manual-config-gap): keep type=string; the user re-enters the value once in
#   the designer's App Properties panel so it is stored as SECRET:… (clears the ✗). It
#   builds and runs as a plaintext string either way.
```

---

## § AI Orchestrator (`<Prefix>AIOrchestrator.flogo`)

WebSocket trigger `tr_wsserver` → `act_agenticai_agentactivity` → `act_websocket_wswritedata`. This is where the three wsserver gotchas live.

### 1. Project, properties, connections (LLM + MCP + one A2A per agent)

```bash
$FDA cp <Prefix>AIOrchestrator "<UseCase> AI Orchestrator"
$FDA cap AgenticAI.OpenAIConn.LLM_Provider string <provider>
$FDA cap AgenticAI.OpenAIConn.API_Key      string <apiKey>
$FDA cap AgenticAI.OpenAIConn.LLM_Base_URL string placeholder # gotcha 4c: then make it truly empty exactly as
#   in § A2A step 1 (sa any properties.<idx>.value --jsonValue '""'); cap a real URL only for Azure/gateway/other
$FDA cap LLM_Model                         string <model>             # config.md; fallback gpt-5-nano
$FDA cap WebSocket_PORT                     number <wsPort>   # tr_wsserver "port" field is NUMERIC (unlike mcp/agent ports) — gotcha 8

$FDA cc OpenAIConn con_llmprovider
$FDA sa connection OpenAIConn.settings.llmProvider    AgenticAI.OpenAIConn.LLM_Provider -C app-property
$FDA sa connection OpenAIConn.settings.apiKey         AgenticAI.OpenAIConn.API_Key      -C app-property
$FDA sa connection OpenAIConn.settings.llmProviderUrl AgenticAI.OpenAIConn.LLM_Base_URL -C app-property

$FDA cc <Prefix>MCPServer con_mcpserverconfig
$FDA sa connection <Prefix>MCPServer.settings.serverType        http
$FDA sa connection <Prefix>MCPServer.settings.serverUrl         http://localhost:<mcpPort>/<usecase>mcpserver
$FDA sa connection <Prefix>MCPServer.settings.httpTransportType streamable

# one a2aserverconnection per A2A agent:
$FDA cc <Agent>A2AServer con_a2aserverconnection
$FDA sa connection <Agent>A2AServer.settings.serverUrl http://localhost:<agentPort>
```

### 2. Read `conn://` UUIDs back, then set the arrays — **gotcha 3**

```python
import json
d = json.load(open(FILE))
conns = d["connections"]
items = list(conns.values()) if isinstance(conns, dict) else conns
cid = {c["name"]: c["id"] for c in items}
MCP_REF  = f"conn://{cid['<Prefix>MCPServer']}"
A2A_REFS = [f"conn://{cid[name]}" for name in ["<Agent1>A2AServer", "<Agent2>A2AServer", ...]]
```

### 3. Trigger, flow, agent activity

```bash
$FDA ct WebsocketServer tr_wsserver "WebSocket server"
$FDA sa trigger WebsocketServer.settings.port WebSocket_PORT -C app-property

$FDA cf Orchestrator_Flow "<UseCase> orchestrator flow"
$FDA ca Orchestrator_Flow AIAgent            act_agenticai_agentactivity "AI Agent"
$FDA ca Orchestrator_Flow WebsocketWriteData act_websocket_wswritedata   "Write to websocket"

# AIAgent settings
$FDA sa activity Orchestrator_Flow.AIAgent.settings.llmProviderConnection OpenAIConn -C connection
$FDA sa activity Orchestrator_Flow.AIAgent.settings.model                LLM_Model  -C app-property
$FDA sa activity Orchestrator_Flow.AIAgent.settings.temperature          0    --type number
$FDA sa activity Orchestrator_Flow.AIAgent.settings.enableGuardrails     true --type boolean
$FDA sa activity Orchestrator_Flow.AIAgent.settings.redactSensitiveData  true --type boolean
$FDA sa activity Orchestrator_Flow.AIAgent.settings.responseType         Text
$FDA sa activity Orchestrator_Flow.AIAgent.settings.conversationStoreType Memory
$FDA sa activity Orchestrator_Flow.AIAgent.settings.memoryMaxSize        100 --type number
$FDA sa activity Orchestrator_Flow.AIAgent.settings.systemPrompt         "<routing sysPrompt>"

# gotcha 3: the conn:// arrays (read back in step 2)
$FDA sa activity Orchestrator_Flow.AIAgent.settings.mcpServers   --jsonValue '["'"$MCP_REF"'"]'
$FDA sa activity Orchestrator_Flow.AIAgent.settings.remoteAgents --jsonValue '<json array of A2A_REFS>'

# inputs
$FDA mm Orchestrator_Flow.AIAgent.input.userPrompt '=coerce.toString($flow.content)'
$FDA mm Orchestrator_Flow.WebsocketWriteData.input.message      '=$activity[AIAgent].response'
$FDA mm Orchestrator_Flow.WebsocketWriteData.input.wsconnection '=$flow.wsconnection'
```

### 4. Handler + wiring + the two remaining wsserver fixes — **gotcha 4a/4b**

```bash
$FDA cth Orchestrator_Flow WebsocketServer "<UseCase> orchestrator handler"
$FDA sa handler WebsocketServer.Orchestrator_Flow.settings.path   /<usecase>
$FDA sa handler WebsocketServer.Orchestrator_Flow.settings.mode   Data
$FDA sa handler WebsocketServer.Orchestrator_Flow.settings.format String
# wth: params survives; content/wsconnection come back as object and are fixed below
$FDA wth Orchestrator_Flow WebsocketServer.Orchestrator_Flow --force \
    --input content:any,wsconnection:any,pathParams:params,queryParams:params,headers:object --inputs-only

# gotcha 4a: wsserver handler needs schemas.output present or it nil-panics on first request
$FDA cs OrcWsHeaders '{"type":"object","properties":{"Accept":{"type":"string","visible":false},"Accept-Charset":{"type":"string","visible":false},"Accept-Encoding":{"type":"string","visible":false},"Content-Type":{"type":"string","visible":false},"Content-Length":{"type":"string","visible":false},"Connection":{"type":"string","visible":false},"Cookie":{"type":"string","visible":false},"Pragma":{"type":"string","visible":false},"Sec-Websocket-Key":{"type":"string","visible":false},"Sec-Websocket-Version":{"type":"string","visible":false},"Upgrade":{"type":"string","visible":false}},"required":[]}'
$FDA sa handler WebsocketServer.Orchestrator_Flow.schemas.output.headers OrcWsHeaders -C schema --force

# gotcha 4b: force wsconnection + content back to `any` (wth downgraded them to object).
#   write this array to a file, then apply it:
#   [{"name":"pathParams","type":"params"},{"name":"queryParams","type":"params"},
#    {"name":"headers","type":"object"},{"name":"content","type":"any"},{"name":"wsconnection","type":"any"}]
$FDA sa flow Orchestrator_Flow.metadata.input --jsonFile <meta_input.json>
```

---

## Build + verify

```bash
$FLB version                                   # print path+version first (Phase 0)
$FLB build-exe -f "<app>.flogo" -c <context>   # per app; <context> from config.md/flogobuild skill
# Note: build-exe exits 1 with a cosmetic path error ("…\engine\C:\…\X.exe: syntax is incorrect")
#       but the .exe IS produced next to the .flogo — verify by `ls -la --time-style=full-iso <app>.exe`.
$FDA cm -f "<app>.flogo"                        # check-mappings: refs, imports, scopes
grep -l New_value <UseCaseDir>/*.flogo          # must print NOTHING (gotcha 4c)
grep -o '"temperature": *"\?[0-9.]*"\?' <UseCaseDir>/*.flogo   # every hit 0 or "0" (FDA writes the string "0")
python validate_flogo_apps.py <UseCaseDir>/*.flogo   # PG mapping + ?placeholder gate (co-located in this references/ folder)
# Every PostgreSQL activity's input.Connection must resolve to the connection NAMED PostgresConn —
#   not just to *some* id in the file (SKILL gotcha 10: a stray `sa` re-set points it at the first one):
python -c "import json,sys
for f in sys.argv[1:]:
    d=json.load(open(f,encoding='utf-8')); c=d['connections']; c=c.values() if isinstance(c,dict) else c
    names={'conn://'+x['id']:x['name'] for x in c}
    for r in d['resources']:
        for t in r['data'].get('tasks',[]):
            i=t['activity'].get('input') or {}
            if 'Query' in i and 'Connection' in i and names.get(i['Connection'])!='PostgresConn':
                print('WRONG CONNECTION', f, r['id'], t['id'], '->', names.get(i['Connection'], 'dangling'))" <UseCaseDir>/*.flogo
```

### Live run (order matters: MCP → A2A → Orchestrator)

```bash
./<Prefix>MCPServer.exe      &   # listens on <mcpPort>
./<Prefix>Agents.exe         &   # listens on each <agentPort>; discovers MCP tools
./<Prefix>AIOrchestrator.exe &   # WS on <wsPort>; connects to MCP + all A2A on startup
```
On startup the orchestrator log should show it discovered the MCP tool list and connected to every A2A agent card. Then connect a WebSocket client to `ws://localhost:<wsPort>/<usecase>` and send a natural-language prompt; a healthy run logs `Executing tool[toolName:<Tool>]`, `Agent execution completed … used_tools:[<Tool>]`, `Flow Instance … completed`, and returns the answer as a WS frame.

Minimal Python WS client (needs `pip install websocket-client`):

```python
import sys, websocket
ws = websocket.create_connection(f"ws://localhost:{sys.argv[1]}/{sys.argv[2]}", timeout=90)
ws.send(sys.argv[3]); print(ws.recv()); ws.close()
```

If the LLM call fails with `unsupported protocol scheme` or a `/New_value/...` URL → the base URL holds the literal `New_value` from `cap … ""` (gotcha 4c) — make it truly empty (OpenAI) or a real URL (Azure/gateway/other); a truly empty value is correct for OpenAI. In a RAG app, the vector extension's `OPENAI_API_ENDPOINT_URL` must stay `https://api.openai.com/v1` (it rejects empty). If `Configured connection is not a WebSocket Connection` → `wsconnection` isn't typed `any` (gotcha 4b). If the trigger nil-panics on connect → the handler is missing `schemas.output` (gotcha 4a). If the MCP server panics on start with `missing input schema` → a tool handler lacks its schemas (gotcha 1).
