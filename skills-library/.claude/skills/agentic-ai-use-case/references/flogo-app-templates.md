# Flogo App Templates (3-app Agentic AI pattern)

Domain-agnostic JSON skeletons for the three apps. Placeholders are written as `<LIKE_THIS>`.
The **most reliable way to build** is to copy a same-type app from an existing use case under
`demos/Agentic_AI/*_Use_Case/` and swap in the domain specifics; these skeletons show what to change
and what must stay. Always carry `contrib` and `SECRET:` values verbatim from the cloned app.

Common to every app: `"appModel": "1.1.1"`, and `"metadata": { "flogoVersion": "2.26.5", "endpoints": [...] }`.

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

## 2. A2A Servers — `<Prefix>A2AServers.flogo`

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
    "temperature": 0.7, "enableGuardrails": true, "conversationStoreType": "Memory", "memoryMaxSize": 100,
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
- `#log` uses `=string.concat("Agent Invocation started: ", $flowctx["FlowName"], " ...", $flow.toolParams.<x>)`.
- optional `#query` validates (e.g. cross-check a charge against usage) and its output is included in the return so the agent can explain findings.
- `#insert` performs the write — **follow the INSERT pattern in [postgres-activity-patterns.md](postgres-activity-patterns.md) exactly.**
- `#actreturn` builds a human-readable confirmation via `string.concat(...)`.

**Email agent (optional):** flow `#noop → #sendmail → #log → #actreturn`. `#sendmail`: `Server smtp.gmail.com`, `Port 465`, `Connection Security SSL`, `Username/Password/sender/recipients` from `Email_*` / `To_Email` properties, `subject/message` from `$flow.toolParams.subject/body`. Set the agent's `enableGuardrails:false`, `conversationStoreType:"None"`. System prompt: "recipient is preconfigured; email address optional; send exactly once."

**Connections:** OpenAI `#llmprovider` (`OpenAIConn`) + PostgreSQL `#connection` (`PostgresConn`).
**Properties:** `AgenticAI.OpenAIConn.*` (incl. `API_Key` SECRET), `PostgreSQL.PostgresConn.*`, `LLM_Model`, `To_Email`/`Email_Username`/`Email_App_Password`(SECRET) if email, and a `<Agent>_A2AServer_PORT` + `<Agent>_A2AServer_URL` per agent.
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
      "temperature": 0.7, "enableGuardrails": true, "responseType": "Text",
      "remoteAgents": [ "conn://<a2a-uuid-1>", "conn://<a2a-uuid-2>", "..." ],
      "mcpServers": [ "conn://<mcp-uuid>" ],
      "conversationStoreType": "Memory", "memoryMaxSize": 100,
      "systemPrompt": "<identify the user; INTENT ROUTING: which questions -> which MCP tools; which actions -> which A2A agent; confirm before writes; email once/last; decline out-of-scope; be warm/professional>"
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

**Connections:** OpenAI `#llmprovider`; one `#mcpserverconfig` (`serverType:"http"`, `serverUrl:"http://<host>:<mcpPort>/<usecase-bss>"`, `httpTransportType:"streamable"`); one `#a2aserverconnection` per A2A agent (`serverUrl:"http://<host>:<a2aPort>"`).
**Properties:** `AgenticAI.OpenAIConn.*` (API_Key SECRET) + `LLM_Model`.
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
