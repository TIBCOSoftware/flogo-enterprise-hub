# Flogo App Templates (3-app Agentic AI pattern)

Domain-agnostic JSON skeletons for the three apps. Placeholders are written as `<LIKE_THIS>`.
The **most reliable way to build** is to copy a same-type app from an existing use case under
`samples/Agentic_AI/Industry_Use_Cases_old/*_Use_Case/` and swap in the domain specifics; these skeletons show what to change
and what must stay. Always carry `contrib` and `SECRET:` values verbatim from the cloned app.

Common to every app: `"appModel": "1.1.1"`, and `"metadata": { "flogoVersion": "2.26.5", "endpoints": [...] }`.

LLM settings (A2A + orchestrator): `config.md` wins; otherwise `LLM_Model` = `gpt-5-nano`, `AgenticAI.OpenAIConn.LLM_Base_URL` = `""`, and `"temperature": 0` (a JSON number) on every `#agent` trigger and the `#agentactivity` — gpt-5 reasoning models ignore temperature (the connector sends 1.0); 0 makes non-reasoning models deterministic. Cloned reference apps often carry `0.7` — reset it.

---

## 1. MCP Server — `<Prefix>MCPServer.flogo`

**Imports:** flow, contrib/activity/noop, wi-postgres query, contrib/activity/actreturn, flogo-mcp trigger/mcpserver, contrib/function/coerce, wi-postgres connector/connection.

**Trigger** (one, `#mcpserver`) with one **handler per read tool**:
```json
{
  "ref": "#mcpserver",
  "settings": {
    "serverName": "<UseCaseName>", "serverVersion": "1.0.0", "serverType": "HTTP",
    "serverPort": "=$property[\"MCP_SERVER_PORT\"]",
    "serverEndpointPath": "/<usecase-bss>", "authType": "None"
  },
  "id": "<UseCase>MCPServer",
  "handlers": [
    {
      "settings": {
        "handlerType": "Tool", "handlerName": "<GetSomething>",
        "handlerDescription": "<RICH description — the LLM picks this tool from this text; list the columns returned and when to use it>",
        "readOnlyToolHint": true, "destructiveToolHint": false, "idempotentToolHint": true, "openWorldToolHint": true
      },
      "action": {
        "ref": "github.com/project-flogo/flow",
        "settings": { "flowURI": "res://flow:<getSomething>" },
        "input": { "arguments": "=$.arguments", "httpHeaders": "=$.httpHeaders" },
        "output": { "response": "=$.response" }
      },
      "name": "<getSomething>"
    }
  ]
}
```

**One flow per tool** — `#noop → #query → #actreturn`. The query is a plain `SELECT * FROM <table>` (no params; the LLM filters). Return maps `data` to the stringified output:
```json
{
  "id": "Return",
  "activity": {
    "ref": "#actreturn",
    "settings": { "mappings": { "response": { "mapping": {
      "data": "=coerce.toString($activity[PostgreSQLQuery].Output)"
    } } } }
  }
}
```
See [postgres-activity-patterns.md](postgres-activity-patterns.md) for the exact `#query` block (Fields, schema, State).

**Connections:** one PostgreSQL `#connection` named `PostgresConn`, wired to `PostgreSQL.PostgresConn.*` properties (`Database_Name` = the new DB).
**Properties:** the `PostgreSQL.PostgresConn.*` set (Host/Port/Database_Name/User/Password[SECRET]/pool settings) + `MCP_SERVER_PORT`.
**endpoints:** one entry `{ "protocol":"http", "port":"<mcpPort>", "title":"<UseCase>MCPServer", "type":"public" }`.

Design rule: **one tool per table or per meaningful join.** Rich `handlerDescription` per tool. All read-only.

---

## 2. A2A Agents — `<Prefix>Agents.flogo`

**Imports:** flow, noop, flogo-general log, wi-postgres query, actreturn, wi-postgres insert, flogo-general sendmail (if email agent), flogo-ai-agent trigger/agent, contrib/function/string, coerce, flogo-ai-agent connector/llmprovider, wi-postgres connector/connection.

**One `#agent` trigger per write agent:**
```json
{
  "ref": "#agent",
  "settings": {
    "llmProviderConnection": "conn://<openai-uuid>",
    "agentName": "<some_action_agent>",
    "agentDescription": "<what this agent does + returns>",
    "agentType": "A2A Server",
    "agentPort": "=$property[\"<Agent>_A2AServer_PORT\"]",
    "agentUrl": "=$property[\"<Agent>_A2AServer_URL\"]",
    "agentAuthMode": "None",
    "model": "=$property[\"LLM_Model\"]",
    "temperature": 0, "enableGuardrails": true, "conversationStoreType": "Memory", "memoryMaxSize": 100,
    "systemPrompt": "<role, the exact tool params to pass, the workflow steps, what to return, 'do not hand off to other agents', 3-attempt termination>"
  },
  "id": "<some_action_agent>_trigger",
  "handlers": [
    {
      "settings": {
        "handlerType": "Tool",
        "agentToolName": "<do_the_action>",
        "agentToolDescription": "<when to call + which params to provide>",
        "customGuardrailType": "BOTH", "customConversationStoreOperation": "STORE"
      },
      "action": {
        "ref": "github.com/project-flogo/flow",
        "settings": { "flowURI": "res://flow:<action_flow>" },
        "input": { "toolParams": "=$.toolParams" },
        "output": { "response": "=$.response" }
      },
      "name": "<action_flow>"
    }
  ]
}
```
The handler also carries `schemas.output.toolParams` (the JSON Schema of params the LLM must supply — this is what drives the tool signature) and the standard `reply/customGuardrailInput/customConversationStore*` schema blocks — copy those blocks verbatim from a reference A2A app; only edit the `toolParams` schema + its `fe_metadata` example.

**Write flow** — `#noop → #log → [#query validation, optional] → #insert → #log → #actreturn`:
- **Flow inputs:** the flow MUST declare `toolParams` as an input **with a schema** in
  `resource.data.metadata.input` (part #2 of the 3-part designer contract). Without it every
  `=$flow.toolParams.<field>` shows a design-time red ✗ even though the app runs fine. The reliable way to
  emit it — and the matching activity-input schema (part #3) — is to click the trigger **Sync** after
  wiring the activity `input.mapping.parameters` (part #1). See
  [postgres-activity-patterns.md](postgres-activity-patterns.md) → "The 3-part designer contract".
- `#log` uses `=string.concat("Agent Invocation started: ", $flowctx["FlowName"], " ...", $flow.toolParams.<x>)`.
- optional `#query` validates (e.g. cross-check a charge against usage) and its output is included in the return so the agent can explain findings.
- `#insert` performs the write — **follow the INSERT pattern in [postgres-activity-patterns.md](postgres-activity-patterns.md) exactly.**
  For any write into a table with a **NOT-NULL foreign key the prompt won't carry** (owner/account id),
  derive it via `INSERT … SELECT … COALESCE` from the parent row instead of mapping it from `toolParams`
  (the LLM would send null → not-null violation) — Section D of postgres-activity-patterns.md.
- `#actreturn` builds a human-readable confirmation via `string.concat(...)`.

**Email agent (optional):** flow `#noop → #sendmail → #log → #actreturn`. `#sendmail`: `Server smtp.gmail.com`, `Port 465`, `Connection Security SSL`, `Username/Password/sender/recipients` from `Email_*` / `To_Email` properties, `subject/message` from `$flow.toolParams.subject/body`. Set the agent's `enableGuardrails:false`, `conversationStoreType:"None"`. System prompt: "recipient is preconfigured; email address optional; send exactly once."

**Connections:** OpenAI `#llmprovider` (`OpenAIConn`) + PostgreSQL `#connection` (`PostgresConn`).
**Properties:** `AgenticAI.OpenAIConn.*` (incl. `API_Key` SECRET and `LLM_Base_URL`), `PostgreSQL.PostgresConn.*`, `LLM_Model`, `To_Email`/`Email_Username`/`Email_App_Password`(SECRET) if email, and a `<Agent>_A2AServer_PORT` + `<Agent>_A2AServer_URL` per agent.
**Base URL:** the `#llmprovider`'s `llmProviderUrl` = `=$property["AgenticAI.OpenAIConn.LLM_Base_URL"]`; leave that property **empty** (`""`) for OpenAI — the connector uses the OpenAI default (verified end to end). Set a real URL only for Azure OpenAI, a gateway/proxy, or a non-OpenAI provider. Write a real `""` when editing the cloned JSON — never the text `New_value` (that literal is what FDA's `cap … ""` writes, the origin of the old "must be a real URL" rule).
**endpoints:** one entry per agent (port + `name` = `<agent>_trigger`).

Design rule: **one agent per write workflow** (create/update/side-effecting). Keep reads in the MCP server.

---

## 3. AI Orchestrator — `<Prefix>AIOrchestrator.flogo`

**Imports:** flow, noop, flogo-ai-agent activity/agentactivity, websocket activity/wswritedata, websocket trigger/wsserver, coerce, flogo-ai-agent connector/llmprovider, connector/mcpserverconfig, connector/a2aserverconnection.

**Trigger** `#wsserver` (one handler):
```json
{
  "ref": "#wsserver",
  "settings": { "port": <wsPort>, "enableTLS": false },
  "id": "WebsocketServer",
  "handlers": [{
    "settings": { "method": "GET", "path": "/<ws-path>", "mode": "Data", "format": "String" },
    "action": {
      "ref": "github.com/project-flogo/flow",
      "settings": { "flowURI": "res://flow:Orchestrator_Flow" },
      "input": { "pathParams":"=$.pathParams","queryParams":"=$.queryParams","headers":"=$.headers","content":"=$.content","wsconnection":"=$.wsconnection" }
    },
    "name": "Orchestrator_Flow"
  }]
}
```
(Copy the `headers` schema block and flow `metadata.input` from a reference orchestrator verbatim.)

**Flow** `#noop → #agentactivity → #wswritedata`:
```json
{
  "id": "AIAgent",
  "activity": {
    "ref": "#agentactivity",
    "settings": {
      "llmProviderConnection": "conn://<openai-uuid>",
      "model": "=$property[\"LLM_Model\"]",
      "temperature": 0, "enableGuardrails": true, "responseType": "Text",
      "remoteAgents": [ "conn://<a2a-uuid-1>", "conn://<a2a-uuid-2>", "..." ],
      "mcpServers": [ "conn://<mcp-uuid>" ],
      "conversationStoreType": "Memory", "memoryMaxSize": 100,
      "systemPrompt": "<identify the user; INTENT ROUTING: which questions -> which MCP tools, which actions -> which A2A agent; NEVER ask for internal/FK ids (agents derive them); confirm before writes; call the email/notify agent ONLY AFTER a write succeeds; never confirm or email a failed/skipped action; honor conditional requests literally; decline out-of-scope; be warm/professional — see the system-prompt rules below>"
    },
    "input": { "userPrompt": "=coerce.toString($flow.content)", "conversationId": "" }
  }
}
```
```json
{
  "id": "WebsocketWriteData",
  "activity": { "ref": "#wswritedata", "settings": { "format":"String" },
    "input": { "message": "=$activity[AIAgent].response", "wsconnection": "=$flow.wsconnection" } }
}
```

**Orchestrator system-prompt rules (learned the hard way — bake these into `systemPrompt`):**
- **Never ask the user for internal/FK ids** (owner/account ids, surrogate keys) that a tool or agent can
  derive. The user speaks in friendly keys; the agent derives the FK from that key (see
  [postgres-activity-patterns.md](postgres-activity-patterns.md) Section D). Pass only what the user said.
- **Strict ordering:** call a notification/email agent **only AFTER** the write agent returns a
  **successful** result — never before the write, never in parallel with it.
- **Never confirm or email a failed or skipped action.** If a write returns an error, or a condition meant
  it wasn't performed, say so honestly — do not claim success and do not send a "done" notification.
- **Honor conditional requests literally.** "If X, do Y" means read/verify X first (via an MCP tool) and
  perform Y **only if X actually holds**; otherwise report that X wasn't met and stop.
- **Map tool-argument values exactly** to the enums/fields each agent expects, and do **not** pass fields
  the agent derives itself.
- Keep intent routing explicit (which questions → which MCP tool; which actions → which A2A agent), decline
  out-of-scope requests, and stay warm and professional.

**Connections:** OpenAI `#llmprovider`; one `#mcpserverconfig` (`serverType:"http"`, `serverUrl:"http://<host>:<mcpPort>/<usecase-bss>"`, `httpTransportType:"streamable"`); one `#a2aserverconnection` per A2A agent (`serverUrl:"http://<host>:<a2aPort>"`).
**Properties:** `AgenticAI.OpenAIConn.*` (API_Key SECRET; `LLM_Base_URL` empty for OpenAI — same rule as §2) + `LLM_Model`.
**Conversation memory:** `input.conversationId` is `""`, which the connector turns into a constant — every WebSocket client shares one history (up to `memoryMaxSize` messages) until the app restarts. Fine for a single-presenter demo; say so in the README.
**RAG apps:** the OpenAI vector extension's `OPENAI_API_ENDPOINT_URL` must stay `https://api.openai.com/v1` — its code rejects empty (unlike `LLM_Base_URL`).
**endpoints:** one entry `{ "protocol":"http","port":"<wsPort>","title":"WebsocketServer","type":"public" }`.

The `mcpServers`/`remoteAgents` `conn://` UUIDs must match the connection keys, and each connection's `serverUrl` must match the corresponding MCP/A2A app's port + endpoint path.

---

## UUID / contrib / port checklist

- Generate **fresh, unique** connection UUIDs per app; ensure every `conn://<uuid>` reference matches a key in that app's `connections`. (Cross-check with a script after building.)
- `contrib` (base64) differs by app type — copy from the matching reference app:
  - MCP server → MCP + PostgreSQL contrib
  - A2A app → AgenticAI + General + PostgreSQL contrib
  - Orchestrator → Websocket + AgenticAI contrib
- Assign a distinct port to each app; keep trigger port, `metadata.endpoints` port, the port property, and the orchestrator's connection `serverUrl` all in agreement.
