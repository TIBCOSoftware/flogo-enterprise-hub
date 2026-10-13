# Runtime gotchas: each one was found by running the apps, not by reading the designer

These were all hit while testing the scholarly-publishing sample end to end on Flogo 2.26.x. Design-time
checks (`fda cm`, the base validator) passed on every one of them.

## 1. wsserver headers need an INLINE schema, and conversationId must be mapped

The `tr_wsserver` trigger reads `handler.schemas.output.headers["value"]` at runtime. A `schema://Name`
reference is a plain string with no `"value"`, so **no header reaches `$flow.headers`**. A mapping like
`conversationId = $flow.headers["Sec-Websocket-Key"]` then fails with
`Invalid path '["Sec-Websocket-Key"]'`.

Fix: set the headers schema inline, then map `conversationId` from `Sec-Websocket-Key`. Without that
mapping, every client shares one conversation memory, and with it one verified session token.

**`fe_metadata` is NOT a copy of `value`.** For wsserver headers the designer stores `fe_metadata` as a
parameter list, and its **Sync** button rebuilds `value` from it:

```
value       = {"type":"object","properties":{"Accept":{"type":"string","visible":false}, … "Sec-Websocket-Key":{…}},"required":[]}
fe_metadata = [{"parameterName":"Accept","type":"string","repeating":"false","required":"false","visible":false}, …]
```

If `fe_metadata` is a JSON-schema copy of `value`, the app runs fine until someone clicks Sync. The designer
then parses zero headers and rewrites `value` to `{"type":"object","properties":{}}`. After that:
- the AI Agent's `conversationId = $flow.headers["Sec-Websocket-Key"]` shows a red ✗, and
- at runtime no header reaches the flow.

This happened to the scholarly-publishing sample after its first designer Sync. Also give the flow input
`headers` the same properties, in both `metadata.input[].schema.value` and `metadata.fe_metadata.input`, which is
the shape a designer Sync writes. `_rebuild/build_orchestrator.py` in the sample does all three with `fda sa
… --force`, and validator G7 rejects a non-list `fe_metadata` and a `conversationId` header that the schema doesn't
declare. To repair an app that is already broken, copy the headers block from `HospitalAIOrchestrator.flogo`
(designer-saved) or re-run those three `fda sa` steps on the closed file. Any `fda` write also regenerates the
top-level base64 `contrib` field (it renames connectors and adds unused General/Default entries). That's harmless,
but after patching a designer-saved file, restore `contrib` from a backup and deep-diff so that only the intended
paths changed.

> The original skill's Real Estate reference app has both problems: a `schema://` headers ref and no
> `conversationId` mapping. It "works" as a single-user demo only.

## 2. Temperature 0 means "omitted", not "deterministic"

In AI Agent 2.26.6+, `temperature: 0` means the parameter is **not sent**, so the provider default
applies. Any other value is sent, and gpt-5.x and Claude Opus 4.7+/Sonnet 5 reject non-default values.
So use 0, and do not describe it as deterministic anywhere. Determinism comes from the SQL functions.
The model's wording will vary between runs, so tests assert on database state (see testing-ladder.md).

## 3. Guardrail settings are not what their names suggest

| Setting | What it actually does | Applies when |
|---|---|---|
| `tokenLimit` | truncates **inbound** input (RedactAction, "end"). It is not a spend budget | `enableGuardrails=true` |
| `rateLimit` | requests per minute, BlockAction | `enableGuardrails=true` |
| `redactSensitiveData` | PII filter on input | always, if true |

`redactSensitiveData=true` on the orchestrator masks the identifier and the verification code, so the
user can never verify. Keep it `false` there, and `true` on sub-agents that never need identity.

## 4. The AI Agent's LLM call has no timeout

If one upstream LLM call hangs, that WebSocket conversation blocks indefinitely. It happened once in
testing: the same message succeeded immediately on a fresh connection. `chat_e2e.py` handles this by
reconnecting, replaying the verification and retrying once, and it **counts and logs** the retry
rather than hiding it. Report the retry count with every run. This is a product gap and belongs in
the README's limitations.

## 5. fda stores `--type boolean|number` as strings

`fda sa … --type boolean true` writes `"true"`. The runtime accepts that for trigger and activity
settings (reference apps look the same). **MCP tool hints are the exception.** They must be real JSON
booleans or clients ignore them, so use `--jsonValue true|false` (validator G8).

## 6. MCP tool result shape

A `tools/call` result's `content[0].text` is the Return's `response.data` **directly**, for example
`{"records":[…]}`. It is not wrapped in `{"data": …}`. Parse both shapes in test clients.

## 7. flogobuild context name

`FLOGOBUILD_CONTEXT_NAME` in `config.md` can go stale. It may name a context that doesn't exist on this
machine (for example, one written with dots after the version, while the real one uses digits only). Run
`flogobuild list-context` and use the name it prints; never copy a context name from another machine or
from a doc. Use `-f <app.flogo>`: it works on flogobuild 1.0.6 and 1.1.0, while `-a` exists only on 1.1.0.

```
cd "$HOME/<scratch>" && flogobuild build-exe -f <App>.flogo -c <context from list-context>   # RELATIVE -f
```
Build in a scratch folder **outside the repo**, because the copies carry real secrets, and pass a
**relative** `-f` from inside that folder. With an **absolute** `-f` the exe lands next to the source
`.flogo`, i.e. inside the repo. Each build takes about a minute. On Windows, bash `kill` doesn't stop the
native exes: find the PID with `netstat -ano | grep :<port>` and run `taskkill //PID <pid> //F`.

## 8. fda without `-f` creates a stub

`fda cm`, `fda ap` and other commands without `-f <app.flogo>` operate on (and create)
`flogo-project.flogo` in the current folder. Always pass `-f`. Delete a stray stub if one appears.

## 9. The model sometimes skips a step the prompt asked for

In one run the model opened a review case without the "shall I open it?" question the prompt asked
for. Two lessons:
(a) don't rely on the prompt for anything that matters, because the DB decides;
(b) write the prompt for the behaviour you actually want. The sample now says "when the request is
clear, open the case right away", and the test tolerates either path.

## 10. An A2A Server with zero Tool handlers silently runs as a Local Agent

The AI Agent trigger (`#agent` / `tr_agent`) starts its A2A server, with the port and the agent card,
**only when the trigger has at least one handler of type `Tool`**. With zero handlers it logs
`Local Agent [...] started`, never listens on its port, and the orchestrator can't reach it. Design-time
checks pass. So a "pure reasoning" agent still needs one tool.

**The remedy is a PostgreSQL reference tool.** Give every reasoning agent **one identity-free, read-only
tool** whose flow is `#act_postgresql_query` → `#actreturn`, running
`SELECT * FROM ref_<topic>(CAST(?lookup AS text))` over a section / term / meaning table that holds **no
personal data** (no names, people or account ids, emails, phones, tokens, case ids or customer free text).
The Agents app gets a PostgreSQL connection (same server, database and user as the MCP server) for this
read only. A static `#noop` → `#actreturn` text is no longer accepted (validator G10 rejects it). The SQL
shapes and the fda recipe are in [governed-patterns.md](governed-patterns.md), §8 "Agent reference tools
(PostgreSQL)".

- **The agent still never gets identity or scoped customer data.** It has no session token and no
  scoped-read tool. Its working data still comes only from the orchestrator's **minimised** A2A message,
  and the database connection reaches reference tables only. The model can supply just the optional lookup
  word, never the SQL.
- **Name the placeholder `?lookup`, not `?term`.** A placeholder named like a result column (`term`) gives
  duplicate `Fields` entries in the PostgreSQL activity. The tool argument is still called `term`
  (`lookup = $flow.toolParams.term`).
- **An agent skips its tool when its prompt already holds the facts.** One sample scored 8/18 in the A2A
  smoke test for this reason. Make at least one part of each agent's reply depend on text **only the table**
  holds: a standard sentence copied verbatim, a JSON key or field rule only the guide can fill, the
  plain-words meaning of codes. Then **remove** those facts from the prompt. Keep the prompt rule "call it
  at most once, and only when your input needs it", with the need spelled out ("your input normally needs
  it: …").
- **Ask for "meaning text, not code".** Write "the meaning text of the guide's X row, not its code". Asking
  for "the guide's X phrase" makes the model copy the term or code.
- **UNION existing lists rather than copying them.** If the list already lives in a table (a high-alert flag,
  the case-routing team and SLA, a catalogue's replacement part), `UNION ALL` it into the `ref_<topic>()`
  function so there is one source of truth. UNION only the public facts the agent needs, not a large catalogue
  it must not rank from.
- **Keep each guide to about 20–35 rows.** Agents send `term=""` (the whole guide) almost every time, so the
  whole guide is what lands in the context.

Give each agent its own port property. The multi-agent template is
`samples/Agentic_AI/Industry_Use_Cases/Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case/`
(`database.sql` `ref_match` + `ref_*`, `_rebuild/tool_spec.py` `AGENT_REF_TOOLS`, `_rebuild/build_agents.py`:
three agents, one PostgreSQL reference tool and one port each). Validator G10 rejects an A2A Server agent
trigger with no Tool handler, a tool flow with no PostgreSQL `SELECT` (static text), an agent tool that writes
or reads identity, and duplicate agent ports within one app.
