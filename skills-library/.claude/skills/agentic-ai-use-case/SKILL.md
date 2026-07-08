---
name: agentic-ai-use-case
description: Build a customer/industry/vertical-specific Agentic AI use case (demo) on TIBCO Flogo Enterprise — a real-time WebSocket chatbot backed by three apps: an MCP Server (read-only DB lookup tools), an A2A Servers app (write-workflow agents), and an AI Orchestrator that classifies intent and routes between them. Use when the user asks to build/create/scaffold an agentic AI use case, demo, chatbot, or "MCP + A2A + orchestrator" solution for ANY domain (telecom, airline, hospital, banking, retail, insurance, logistics, utilities, …). Produces PostgreSQL-backed .flogo apps + database.sql + reset_data.sql + prompts.md + README, modeled on the reference use cases under demos/Agentic_AI/*_Use_Case.
user-invocable: true
---

# Agentic AI Use Case Builder

Scaffolds a complete, runnable Agentic AI demo for any vertical, following the proven 3-app pattern used by the reference use cases in `demos/Agentic_AI/` (Airline Passenger Services, Hospital, Telecom Invoice Chatbot). Everything here is domain-agnostic — you supply the domain, the skill supplies the structure, the wiring, and the gotchas that are easy to get wrong.

## What it produces

A new folder `demos/Agentic_AI/<UseCase>_Use_Case/` containing:

| File | Purpose |
|------|---------|
| `database.sql` | PostgreSQL schema + demo data, engineered so each demo scenario works |
| `reset_data.sql` | TRUNCATE + reload; clears agent-written tables; volatile dates made relative to today |
| `<Prefix>MCPServer.flogo` | **1 MCP Server** — N read-only tools, each querying one table/join |
| `<Prefix>A2AServers.flogo` | **1 A2A Servers app** — M business-logic agents (write workflows), each its own trigger/port |
| `<Prefix>AIOrchestrator.flogo` | **1 AI Orchestrator** — WebSocket trigger, an AI Agent activity that routes to MCP tools or A2A agents |
| `prompts.md` | Demo prompts grouped by scenario |
| `README.md` | Architecture, apps/tools/agents tables, DB summary, demo scenarios, **prerequisites + setup steps (manual steps folded in)**, ports, troubleshooting |

The architecture (all three use cases share it):

```
Chatbot UI --WebSocket--> AI Orchestrator --MCP(HTTP)--> MCP Server --\
                                 |                                      +--> PostgreSQL
                                 \--------A2A-------> A2A Servers ------/   (+ SMTP for email)
```
- **MCP Server** = read-only lookups. Stateless, safe to retry, LLM picks tools by intent.
- **A2A Servers** = write workflows (create/update). Own guardrails, multi-step, separate deploy/scale.
- **Orchestrator** = the AI brain. WebSocket chat, LLM decides intent, calls MCP tools or hands off to A2A agents.

## Reference files (read before building)

- [references/flogo-app-templates.md](references/flogo-app-templates.md) — exact JSON structure of all 3 apps: triggers, flows, connections, `contrib` blobs, ports, UUID rules.
- [references/postgres-activity-patterns.md](references/postgres-activity-patterns.md) — **the critical gotchas**: how to parameterize `#query` and (especially) `#insert`/UPDATE so the Flogo mapper doesn't break. Read this every time — it is the #1 source of errors.
- [references/data-and-docs.md](references/data-and-docs.md) — conventions for `database.sql`, `reset_data.sql`, `prompts.md`, and the combined `README.md`.

---

## Workflow — always follow these phases in order

### Phase 0 — Read environment config
Read `skills-library/.claude/skills/config.md` first for the psql path, PostgreSQL host/port/user/password, and CLI paths. Do not hardcode these.

### Phase 1 — Frame the use case (tell the user BEFORE anything else)
Before asking questions or writing code, state back to the user, in a few lines:
1. **How the end user will interact** — e.g. "A <role> chats in natural language over a WebSocket; the orchestrator answers and can perform write actions on confirmation."
2. **What problem is being automated** — the business outcome (e.g. "self-service billing inquiries + disputes + recharges without an agent").
3. **The shape of the solution** — 1 MCP server (read tools), 1 A2A app (write agents), 1 orchestrator, PostgreSQL-backed.

### Phase 2 — Ask clarifying questions (use AskUserQuestion)
Only ask what changes the build. Typical questions:
- **Domain entities & scenarios** — what the chatbot must answer/do (drives tables + tools + agents). Propose a default set from the domain and let them confirm/trim.
- **Write workflows / A2A agents** — which actions change state (each becomes an A2A agent). Confirm count and scope.
- **Email/notification agent?** — include a confirmation-email agent (reuses SMTP creds) or not.
- **Locale/currency & sample persona** — so demo data feels real (e.g. AED/UAE, USD/US).
- **Ports & folder** — default to a free port block and `demos/Agentic_AI/<UseCase>_Use_Case/`; confirm if unsure.

### Phase 3 — Present a plan (EnterPlanMode → write plan → ExitPlanMode)
Plan must list: the tables, the MCP tools (name → table/query), the A2A agents (name → write workflow), the orchestrator routing rules, ports, folder, and the demo scenarios each piece enables. Get approval before building.

### Phase 4 — Build (in this order, because later files depend on earlier names)
1. `database.sql` — schema + demo data. Engineer the data so each scenario is demonstrable (e.g. one record that is a clean case, one that is the "discrepancy/exception" case a write-agent acts on). See [references/data-and-docs.md](references/data-and-docs.md).
2. `reset_data.sql` — same data, agent-written tables emptied, volatile dates relative to today.
3. `<Prefix>MCPServer.flogo` — one read tool per lookup. See [references/flogo-app-templates.md](references/flogo-app-templates.md).
4. `<Prefix>A2AServers.flogo` — one agent per write workflow. Use the INSERT/UPDATE param pattern from [references/postgres-activity-patterns.md](references/postgres-activity-patterns.md) exactly.
5. `<Prefix>AIOrchestrator.flogo` — WebSocket trigger + AI Agent activity wired to the MCP server connection and all A2A connections.
6. `README.md` + `prompts.md`.

**Fastest reliable method:** clone the JSON shape of an existing use case app of the same type (e.g. `demos/Agentic_AI/Telecom_Invoice_Chatbot_Use_Case/*.flogo`) and swap in the new domain's tables, tool/agent names, SQL, system prompts, ports, and **fresh** connection UUIDs. **Carry over the `contrib` base64 blobs and every `SECRET:` value verbatim** from the cloned app — they are environment/version-specific boilerplate, not domain data. Only change the PostgreSQL `Database_Name` property to the new DB.

### Phase 5 — Verify (do this before declaring done)
- Create a scratch DB, load `database.sql`, confirm row counts; confirm `reset_data.sql` reloads clean.
- Run the **exact** SQL from every MCP tool and every A2A query/insert against the DB (substitute demo values for `?params`) — this catches any table/column mismatch.
- `python -m json.tool` each `.flogo` file — must parse.
- Cross-check: every `conn://<uuid>` resolves to a connection key in that app; the orchestrator's MCP/A2A `serverUrl`s match the MCP/A2A ports; `metadata.endpoints` ports match trigger ports and property values.
- Tell the user what was verified vs. what still needs a Flogo Enterprise import + live run.

---

## Key facts (verified across all three reference use cases)

- `appModel`: `1.1.1`; `metadata.flogoVersion`: `2.26.5` (match the reference apps / installed version).
- **MCP Server** — trigger `#mcpserver` (serverType `HTTP`, `serverEndpointPath` e.g. `/telecom-bss`, port from a property). Each tool = a handler → a flow of `#noop → #query → #actreturn`. Read pattern: `SELECT * FROM <table>` (no params), return `=coerce.toString($activity[PostgreSQLQuery].Output)`. The LLM filters the rows — so tools are simple and the `handlerDescription` must be rich (the LLM chooses tools from it). Set `readOnlyToolHint: true`.
- **A2A Servers** — one `#agent` trigger per agent (each with its own `agentName`, `systemPrompt`, `agentPort`, `agentUrl`, and a handler with `agentToolName` + `toolParams` schema). Write flow: `#noop → #log → #query (optional validation) → #insert (write) → #log → #actreturn`. An email agent uses `#sendmail` (Gmail SSL:465, recipient from a property).
- **Orchestrator** — trigger `#wsserver` (port, `path` e.g. `/ws/chat` or `/<usecase>`) → flow `#noop → #agentactivity → #wswritedata`. The `#agentactivity` lists the MCP connection under `mcpServers` and all A2A connections under `remoteAgents`, with a `systemPrompt` holding the intent-routing rules. `input.userPrompt = =coerce.toString($flow.content)`; `#wswritedata` message = `=$activity[AIAgent].response`.
- **Connections per app**: MCP → 1 PostgreSQL `#connection`. A2A → 1 OpenAI `#llmprovider` + 1 PostgreSQL `#connection`. Orchestrator → 1 OpenAI `#llmprovider` + 1 `#mcpserverconfig` + one `#a2aserverconnection` per A2A agent. UUIDs must be unique within an app and every `conn://<uuid>` must match a `connections` map key.
- **Ports**: give each app a distinct port; the orchestrator's `#mcpserverconfig.serverUrl` and each `#a2aserverconnection.serverUrl` must point at the MCP/A2A ports; keep `metadata.endpoints` in sync with trigger ports and port properties.
- **Secrets**: OpenAI API key, PostgreSQL password, and email app password are stored as `SECRET:...` app properties — reuse the encoded values from an existing use case app; never invent or plaintext them.

## Top gotchas (these are the fixes learned the hard way)

1. **PostgreSQL `#insert` parameter naming — the #1 error.** Name `?placeholders` so they do **not** match column names (append a digit, e.g. `?customer_id1`). Set each Field `Parameter:true, Value:false`, declare params under `schemas.input.input.value → properties.parameters.properties` (NOT under `values`; leave `values.items.properties` empty), and map under `input.mapping.parameters`. If a placeholder name matches a column, the designer reclassifies it into `values` and the mapping breaks with a red ✗. Full explanation + template in [references/postgres-activity-patterns.md](references/postgres-activity-patterns.md).
2. **Never use `RuntimeQuery`** for parameters — always `?param` + `Fields[].Parameter:true` + `input.mapping.parameters`.
3. **Return/response building** — assemble the tool/agent reply `data` with `string.concat(...)` and `coerce.toString($activity[...].Output)`.
4. **Keep table/column names identical** across `database.sql`, MCP queries, and A2A queries — verify by running the actual SQL against a loaded DB.
5. **Carry `contrib` + `SECRET:` verbatim**; only change the DB name. Regenerating these by hand breaks import.
6. If any tool is exposed over REST/HTTP response instead of MCP, set `ConfigureHTTPResponse` body fields individually, never as one JSON blob.
