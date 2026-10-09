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
from a doc. Use `-a <app.flogo>`; `-f` is deprecated.

```
flogobuild build-exe -a <App>.flogo -c <context from list-context>
```
Build in a scratch folder **outside the repo**, because the copies carry real secrets. Each build takes
about a minute.

## 8. fda without `-f` creates a stub

`fda cm`, `fda ap` and other commands without `-f <app.flogo>` operate on (and create)
`flogo-project.flogo` in the current folder. Always pass `-f`. Delete a stray stub if one appears.

## 9. The model sometimes skips a step the prompt asked for

In one run the model opened a review case without the "shall I open it?" question the prompt asked
for. Two lessons:
(a) don't rely on the prompt for anything that matters, because the DB decides;
(b) write the prompt for the behaviour you actually want. The sample now says "when the request is
clear, open the case right away", and the test tolerates either path.
