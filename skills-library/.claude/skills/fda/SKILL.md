---
name: flogo-design-assistant
description: A command line tool to create and modify TIBCO Flogo Integration Applications
user-invocable: true
---

> **Preflight:** run `fda version` first (see AGENT.md → Prerequisites and preflight). If it fails, install/update the TIBCO Flogo VS Code extension (2.26.6+).

Follow the multi-step processes and "Things to avoid" below — do not skip steps.

`fda` (Flogo Design Assistant) builds and edits Flogo Integration apps from the command line. Every task takes the same global flags and either prints a human-readable result or, with `-j`, emits machine-readable JSON.

## Global flags (all tasks)

```
--file(-f)        Name of the Flogo file (default: flogo-project.flogo)
--type(-t)        Type of the Flogo file (default: flow)
--json(-j)        Output in JSON format (default: false)
--configuration(-c)  Layered configuration file (env: FLOGO_DESIGN_CONFIG_FILE)
--history(-H)     Enable history (env: FLOGO_DESIGN_ENABLE_HISTORY)
--debug           Verbose debug output (great for diagnosing arg parsing)
--force           Force-create / force-remove past validation guards (only some tasks honor it)
```

**`-j` usage:** Omit for interactive discovery (readable table output). Add only when piping into `jq` in a script — e.g. `fda dp -f app.flogo -j | jq '.flows | keys'`.

`-j` / `--json` is the lever to use when scripting `fda` from another tool: every list-style task emits a JSON body that `jq` can consume, and CRUD tasks return a `{message, ...}` shape.

## Tasks

```
 --- general ---- 
Task: version (v)                     Display version
Task: help (h)                        Show help
Task: explain (exp)                   Explain a function, activity, connector or trigger
Task: show-design-config (sdc)        Show the current Flogo Design configuration
Task: export-design-config (edc)      Export the current Flogo Design configuration to a file
Task: list-flogo-projects (ls)        List all the flogo project files in the current directory
Task: analyze-vscode-extension (ave)  Checks for unknown imports in the VSCode Flogo Extension
Task: model-context-protocol (mcp)    Starts an MCP Sever for Flogo Development
 --- process-development ---- 
Task: create-project (cp)             Create a new Flogo Project
Task: describe-project (dp)           Describe a Flogo Project
Task: describe-imports (di)           Describe the imports defined in a Flogo Project
Task: add-import (ai)                 Add an import to a Flogo Project
Task: remove-import (ri)              Remove an import from a Flogo Project
Task: describe-contributions (dco)    Describe a Flogo Project's contributions
Task: add-contribution (aco)          Add a contribution to a Flogo Project
Task: remove-contribution (rco)       Remove a contribution from a Flogo Project
Task: describe-attributes (da)        Describes the attributes of a Flogo Item
Task: analyze-project (ap)            Checks for unknown imports in a Flogo Project
Task: create-flow (cf)                Create a new Flogo Flow
Task: remove-flow (rf)                Removes a Flogo Flow
Task: create-api-skeleton (cas)       Creates new Flogo Processes and Flows based on an API Definition
Task: create-mcp-skeleton (cms)       Creates new Flogo Processes and Flows for MCP, based on an API Definition
Task: create-activity (ca)            Add a Flogo Activity
Task: change-activity-type (cat)      Change the type of a Flogo Activity
Task: create-link (cl)                Create a link between two activities in a Flogo Flow
Task: remove-link (rl)                Removes a link between two activities in a Flogo Flow
Task: format-flow (ff)                Format a flow
 --- data-management ---- 
Task: create-spec (csp)               Create an API specification for a Flogo Project
Task: remove-spec (rsp)               Removes a spec from a Flogo Project
Task: create-schema (cs)              Create a schema for a Flogo Project
Task: remove-schema (rs)              Removes a schema from a Flogo Project
Task: update-schema (us)              Add or remove a single property in an existing schema
Task: create-app-property (cap)       Create an application property for a Flogo Project
Task: remove-app-property (rap)       Removes an application property from a Flogo Project
Task: set-attribute (sa)              Set attribute for a Flogo Object
 --- connectivity ---- 
Task: create-trigger (ct)             Create a new Flogo Trigger — Usage: fda ct <trigger-id> <trigger-type> <trigger-description>
Task: remove-trigger (rt)             Removes a Flogo Trigger
Task: create-trigger-handler (cth)    Create a new Flogo Trigger Handler — Usage: fda cth <flow-name> <trigger-id> <handler-description>
Task: remove-trigger-handler (rth)    Removes a Flogo Trigger Handler
Task: create-connection (cc)          Create a new Flogo Connector
Task: remove-connection (rc)          Removes a Flogo Connection
Task: list-connection-types (lct)     List the possible connections types of a Flogo Project
Task: list-trigger-types (ltt)        List the possible triggers for a Flogo Flow
Task: list-activity-types (lat)       List the possible types of a Flogo Activities
Task: list-contributions (lco)        List the configured Flogo Contributions
Task: list-types (lt)                 List all the possible types currently know to Flogo Design CLI
 --- testing ---- 
Task: check (ch)                      Check the validity of a Flogo Object or a configuration.
Task: create-test-file (ctf)          Creates a new Flogo test file
Task: describe-test-file (dt)         Describes a Flogo test file
Task: create-test-suite (cts)         Creates a new Flogo test suite in a test file
Task: create-test-case (ctc)          Creates a new Flogo test case in a test file
Task: create-assertion (cass)         Add an assertion to a test case
Task: add-test-case-to-suite (ats)    Adds a test case to a test suite in a test file
 --- mapping ---- 
Task: list-functions (lf)             List Flogo functions
Task: describe-mapping-fields (dmf)   List all mappable fields in the project
Task: list-mapping-sources (lms)      List mapping sources for a target field
Task: make-mapping (mm)               Set a mapper field value (or @foreach scope)
Task: remove-mapping (rmm)            Remove a mapping entry
Task: list-mappings (lm)              List currently-set mappings
Task: check-mappings (cm)             Check mappings (refs, imports, @foreach scopes)
Task: wire-trigger-handler (wth)      Wire a trigger handler ↔ flow (inputs + reply mappings)
Task: set-mapping-schema (sms)        Attach a JSON Schema to a mappable activity OR to a flow's input/output (typed-tree UI)
Task: remove-mapping-schema (rms)     Detach a JSON Schema from a mappable activity
Task: update-mapping-schema (ums)     Add or remove a single property in a mappable activity's attached schema
 --- history ---- 
Task: show-history (sh)               Show the history of executed tasks
Task: restore-history (rhi)           Restores your flogo application to the version in the history
Task: script-history (sch)            Creates a script out of the historical commands
```

`fda help <task-name>` (or `fda help <shortcode>`) prints the long-form help for a single task — usage line, all flags, all positional inputs, examples. Always start there when picking up a task you haven't used in a while; the short description in the table above is intentionally one-line.

Inline parameters use `<>` brackets; flags use `--name` (or the `-X` shortcode shown by `fda help <task>`).

## How to use `fda` from Claude Code in VS Code

The `fda` CLI is the right tool for any "edit this Flogo file" or "tell me what's in this Flogo file" task. Use it directly — don't hand-edit the JSON. Reasons: every task validates against the live FDev configuration, every save runs the contrib re-derivation + defensive function-import sweep, and history is recorded so a bad change can be rolled back via `restore-history`.

Three practical patterns Claude Code should reach for:

### 1. Discover before you mutate
Always start a non-trivial task with the matching `list-*` / `describe-*` / `explain` task to confirm the entity exists and to see its real shape. The `-j` flag pipes cleanly into `jq`:

```bash
fda dp -f my-app.flogo -j | jq '.flows | keys'                       # list flow names
fda da activity Flow1.MyActivity -f my-app.flogo -j | jq             # full activity JSON
fda lct -j | jq '.connectionTypes[].name'                            # available connection types
fda lat string -j | jq '.activityTypes[]'                            # filter activity types
fda lf string -j | jq '.functions | length'                          # how many string functions
fda exp activity log                                                 # full input-field list for `log`
fda exp function string                                              # all 42 functions in the string package
```

**To verify app properties or connection values, always use `fda dp` (pipe through `grep` to filter) — never inspect the raw `.flogo` JSON with `python3`, `cat`, or `jq`.** Note: `fda dp -j` may return `null` for `.appProperties` (the JSON shape varies); use `fda dp` (human-readable) when that happens.

### 2. Mutate idempotently, validate after
CRUD tasks are idempotent for create (existing entries get re-bound to the new config) but error on remove if the target doesn't exist. After a sequence of edits, run a validator and a re-read to confirm the state is what you expected:

```bash
fda cf MyFlow -f my-app.flogo
fda ca MyFlow Mapper mapper -f my-app.flogo
fda mm 'MyFlow.Mapper.input.input.mapping.uuid' '=utils.uuid()' -f my-app.flogo
fda cm -f my-app.flogo                            # sweep for broken refs / missing imports
fda check activity MyFlow.Mapper exists -f my-app.flogo   # script-friendly assertion
```

`fda check ...` is the assertion-style task — it exits non-zero on failure, perfect for shell scripts and CI.

> ⚠ **A "success" message + a clean `fda cm` do NOT guarantee the designer will render the result correctly.** A few classes of bug (wrong connection binding in multi-connection apps, a mapping whose schema doesn't declare the mapped keys) are written silently and pass every static check, yet break in the VSCode designer. For anything structural — connection bindings, parameterized-activity schemas, mapping shapes — **read the value back and compare it against a known-good, designer-authored app** of the same kind before considering it done. Trust the on-disk shape, not the exit status.

### 3. Mappings are first-class
The `mapping` category covers the entire Flogo VSCode UI mapping panel — see the `fda-mapping` skill for the full how-to. The path shape is `<flow>.<activity>.input.input.mapping.<dotted>` for mapper activities and `<flow>.<activity>.input.<field>` for any other activity (log, rest, …). `dmf` only surfaces fields that are mappable in the UI's "Activity inputs" panel — settings (the UI's other tab) are filtered out via the `mappableFields` allow-list on each activity's FCon entry, populated by `analyze-vscode-extension` from the descriptor's `display.mappable` rule. `mm`/`rmm` are NOT filtered — you can still set any input field directly. Sources have a fixed syntax — `$flowctx["X"]`, `$property["X"]`, `$activity[Name].output.X`, `$loop[name].X` — and function calls auto-add the matching package to the project's `imports`.

```bash
# Discover what can be mapped + what can be mapped FROM
fda dmf -f my-app.flogo
fda lms 'MyFlow.Mapper.input.input.mapping.orderId' -f my-app.flogo

# Set a literal, an expression, and an @foreach loop
fda mm 'MyFlow.Mapper.input.input.mapping.customerId' 1234 --type number -f my-app.flogo
fda mm 'MyFlow.Mapper.input.input.mapping.tag' '=$property["Env"]' -f my-app.flogo
fda mm 'MyFlow.Mapper.input.input.mapping.lineItems' \
       --foreach '$activity[Setter].output.items' --as items -f my-app.flogo
fda mm 'MyFlow.Mapper.input.input.mapping.lineItems.sku' '=$loop[items].sku' -f my-app.flogo

# Validate before building
fda cm -f my-app.flogo
```

## Picking a trigger

The trigger choice shapes the whole flow shape; getting it wrong leads to runtime panics that no static check catches before `flogobuild build-exe`.

| Trigger | When to use | Needs |
|---|---|---|
| `tr_rest` (TIBCO REST) | The user says "REST" or the prompt/image mentions a REST API — use this regardless of whether a swagger spec exists. If the user provides a spec, pair with `cas` (`create-api-skeleton`). Without a swagger, `tr_rest` still works — do NOT fall back to `tr_http`. | Configure method/path via handler settings. Optionally `settings.swagger` if user provides a spec. |
| `tr_http` (project-flogo HTTP, mode: Data) | Only when the user explicitly says "HTTP trigger" | Wire `handler.reply.{statusCode, responseBody}` (the runtime contract — NOT `code`/`data`/`headers`) from the upstream `actreturn` output, otherwise the response is HTTP 0 and the runtime panics with `invalid WriteHeader code 0`. `wth` now seeds `reply.statusCode = 200` and `reply.responseBody = ""` as safe defaults, and `cm` flags any remaining gaps as `TR_HTTP_REPLY_STATUSCODE_ZERO` / `HTTP_TRIGGER_REPLY_UNWIRED`. |
| `tr_timer` | Periodic invocation; no I/O coupling | Just `Repeating` / `Time Interval` / `Interval Unit` settings. |

Quick rule: **prompt/image says "REST" or "Receive HTTP Message" → `tr_rest`** (no swagger needed). **User explicitly provides a spec → `cas` with `tr_rest`.** **User explicitly says "HTTP trigger" → `tr_http`.** Never auto-create a swagger spec. Never fall back to `tr_http` just because no spec exists. If `cm` reports `TR_REST_NO_SWAGGER` and the user didn't provide a spec, silently ignore it — don't create a spec or ask about it.

## Common runtime failures (and how `fda cm` catches them)

`fda cm` is the layer between "build succeeded" and "first request crashes the engine". Run it before every `flogobuild build-exe`. The rules below cover the failures most likely to bite — each maps to a cm code so the user knows what to fix.

| Symptom at runtime | cm code | Fix |
|---|---|---|
| `connection with id 'conn://' not configured` at engine init | (caught by `analyze-vscode-extension` — `conn://` defaults are blanked at seed-time, never appear in the flogo) | Re-seed `default-config.json` if you see one: `fda ave <path-to-extension> --type activity --toConfigFile <path>` (`<path-to-extension>` = the newest `~/.vscode*/extensions/tibco.flogo-*` folder, resolved dynamically as in AGENT.md — never pin the version) |
| `WriteHeader code 0` panic from an `actreturn` flow | `INPUT_VS_SETTINGS_MISWRITE` | `actreturn.mappings` lives under `settings`, not `input`. `mm` and `sa` rewrite the path automatically (settingFields metadata); legacy files trip the cm error and need the block moved. |
| `handler.Schemas() nil pointer` panic on first REST request | `TR_REST_NO_SWAGGER` | `tr_rest` needs `settings.swagger`. Use `cas` to scaffold from a spec, or replace with `tr_http`. |
| `function [length] is not installed` at runtime | `FUNCTION_AMBIGUOUS` / `FUNCTION_NOT_QUALIFIED` | **Always qualify function calls** with the package name (`string.length(...)`, `utils.uuid(...)`). `mm` rejects every bare call at write-time, regardless of whether it currently resolves to one package or many — uniform rule, future-proof against extensions adding same-named functions. |
| `error parsing expression '=$activity[…]'` inside an `@foreach` | `FOREACH_HAS_LEADING_EQUALS` | The `--foreach` value must NOT have a leading `=` — the `@foreach()` wrapper is itself the expression marker. `mm` strips the `=` proactively now; legacy files trip the cm warning. |
| `failed to resolve activity attr 'output'` | `ACTIVITY_OUTPUT_LEAF_UNKNOWN` | Non-mapper activities expose top-level outputs by name (`responseBody`, `statusCode`, etc.), not a single `.output` object. `lms` enumerates the real outputs; `cm` validates `$activity[X].<leaf>` against the schema. |
| Handler created (cth) but flow doesn't receive request data / can't reply | `TRIGGER_HANDLER_UNWIRED` | A handler bound to a flow needs four mutations wired (flow.metadata.input/output + handler.action.input/output + handler.reply). Use `fda wth <flow> <trigger.handler>` — one call does both directions, with sensible defaults per trigger ref. |
| Flogo VSCode UI shows mapping JSON as raw text instead of a typed tree; `schema://X` reference doesn't resolve at runtime | `MAPPING_SCHEMA_REF_MISSING` / `MAPPING_SCHEMA_INLINE_MALFORMED` | Mappable activities need a schema attached at `activity.schemas.<dir>.<field>`. Either reference a top-level schema (`fda sms <flow>.<activity> <name>`) or write content directly (`--json-schema` / `--json-value-to-schema`). Both sides default to the same schema for mapper activities. `cm` flags dangling `schema://` references and malformed inline blocks. |

**Known `cm` false positives.** These mappings are valid and resolve at runtime, but `cm` reports them as errors:
- `ACTIVITY_OUTPUT_LEAF_UNKNOWN` on `$activity[<task>].<field>` when `<task>` is a **subflow** activity. Its outputs are the called flow's `metadata.output` fields.
- `RESOLVER_UNKNOWN` on `$iteration[...]` inside a loop task, and on `$error` references in an error branch.

Treat a `cm` error as a false positive only if it matches one of these exactly. Fix everything else, and when in doubt, build and exercise that exact path before you dismiss it.

## Setting schemas on trigger handlers (prerequisite for `wth`)

`wth` only copies schemas that are already set on the trigger handler — it does not discover application-level schemas on its own. Triggers with empty `defaultWiring` (notably `tr_rest`) require schemas to be explicitly associated with the handler's output fields before `wth` can propagate them to `flow.metadata.input`.

Use `fda sa` to associate a schema with any handler output field — this is the CLI equivalent of the "Set Mapping Schema" toggle in the VSCode Flogo UI's Output Settings panel:

```bash
fda sa handler "<trigger>.<handler>.schemas.output.<field>" <schema_name> -C schema --force -f <file>
```

### `tr_rest` — schema association required before `wth`

`tr_rest` has default wiring for `headers`, `body`, `requestURI`, `method` → and `code`, `message` ←. For extra fields (`pathParams`, `queryParams`), create a schema and associate it with the handler output before running `wth`. **Only create and associate schemas for the fields the API actually needs** — skip the rest:

| Output field | When needed | Flow access after wiring |
|---|---|---|
| `pathParams` | Resource path has `{paramName}` placeholders | `$flow.pathParams.<name>` |
| `queryParams` | API accepts `?key=value` query parameters | `$flow.queryParams.<name>` |
| `headers` | Flow needs request headers (e.g. Authorization, correlation IDs) | `$flow.headers.<name>` |
| `body` | POST / PUT / PATCH with a request body | `$flow.body.<name>` |

#### Steps — example: GET `/books/{id}?genre=fiction` (needs pathParams + queryParams)

**Step 1.** Create schemas and associate with handler output (repeat per needed field):

```bash
fda cs BookPathParams '{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}' -f "$FILE"
fda sa handler "$TRIGGER.$HANDLER.schemas.output.pathParams" BookPathParams -C schema --force -f "$FILE"

fda cs BookQueryParams '{"type":"object","properties":{"genre":{"type":"string"}}}' -f "$FILE"
fda sa handler "$TRIGGER.$HANDLER.schemas.output.queryParams" BookQueryParams -C schema --force -f "$FILE"
```

**Step 2a.** Run `wth` without `--input` to discover default fields and types:

```bash
fda wth "$FLOW" "$TRIGGER.$HANDLER" --force -f "$FILE"
# Output → flow.metadata.input : headers:object, body:object, requestURI:string, method:string
```

**Step 2b.** Re-run `wth` with every default field from 2a's output (preserving name:type) **plus** the extra fields, all **comma-separated in a single `--input`**:

```bash
fda wth "$FLOW" "$TRIGGER.$HANDLER" --force \
    --input headers:object,body:object,requestURI:string,method:string,pathParams:object,queryParams:object \
    -f "$FILE"
```

**IMPORTANT:** Never hardcode field names or types in step 2b — always read them from 2a's `flow.metadata.input` output. Different triggers produce different defaults, and types may vary. Without the `:type` suffix (e.g. bare `--input fieldName`), fields are downgraded to `any`.

#### More examples — typed `body` and `headers`

`body`, `headers`, `requestURI`, `method` are already default-wired (Step 2a discovers them), so you don't add them to `--input` just to receive them. Associate a schema on one of these fields only when the flow needs **typed** field access to it (e.g. `$flow.body.title`, `$flow.headers.Authorization` instead of a generic object). Do the schema association in Step 1, then run the same two-step `wth`.

```bash
# POST /books with a JSON body — type the body for $flow.body.<field> access
fda cs BookRequest '{"type":"object","properties":{"title":{"type":"string"},"author":{"type":"string"}},"required":["title"]}' -f "$FILE"
fda sa handler "$TRIGGER.$HANDLER.schemas.output.body" BookRequest -C schema --force -f "$FILE"

# Type a specific request header (e.g. Authorization) for $flow.headers.<name> access
fda cs BookHeaders '{"type":"object","properties":{"Authorization":{"type":"string"}}}' -f "$FILE"
fda sa handler "$TRIGGER.$HANDLER.schemas.output.headers" BookHeaders -C schema --force -f "$FILE"
```

Then run Step 2a (discover defaults) and Step 2b (re-apply every default field with its `name:type`, adding any extra `pathParams`/`queryParams` you associated).

### `tr_rest` — response schema on reply side

To bind a response schema to a REST trigger handler's reply, use `schemas.reply.data`:

```bash
fda sa handler "$TRIGGER.$HANDLER.schemas.reply.data" <ResponseSchemaName> -C schema --force -f "$FILE"
```

The field name is `data` — **not** `responseBody` or `message`. Using the wrong field name writes to the flogo file but the UI's Response Schema toggle stays off.

### Triggers that do NOT need this step

The following triggers have built-in `defaultWiring` — `wth` auto-discovers their output fields without manual schema association:

| Trigger | Auto-wired inputs |
|---|---|
| `tr_http` | `pathParams` + `queryParams` + `headers` + `content` |
| `tr_mcpserver` | `arguments` |
| `tr_timer` | none (no payloads) |

## Wiring trigger handlers ↔ flows (`wth`)

> **If the flow needs fields beyond the trigger's default wiring** (e.g. pathParams or queryParams on `tr_rest`), complete the schema association steps in "Setting schemas on trigger handlers" above first, then use the two-step `wth` process (2a: without `--input` to discover default types, 2b: with combined `--input`).

`fda wth <flow> <trigger.handler>` does the four-step wiring in one call: populates `flow.metadata.input/output`, `handler.action.input/output`, and `handler.reply`. The field shapes come from the trigger ref's `defaultWiring` template (seeded by `analyze-vscode-extension`):

| Trigger | Default shape |
|---|---|
| `tr_mcpserver` | `arguments` (any) → / `response` (object) ← |
| `tr_http` | `pathParams` + `queryParams` + `headers` + `content` → / `statusCode` + `responseBody` ← |
| `tr_timer` | none (timer doesn't carry payloads) |
| `tr_rest` | `headers` + `body` + `requestURI` + `method` → / `code` + `message` ← (`pathParams`/`queryParams` still need explicit schema association + `--input` override when the API uses them) |
| Custom | error: pass `--input` / `--output` explicitly |

Override defaults with `--input <name>[:<type>]` and `--output <name>[:<type>]` (comma-separated for multiple: `--input a:string,b:object`). Use `--inputs-only` / `--reply-only` to wire just one direction. `--force` overwrites already-wired sides (default behaviour skips with a warning, so you don't accidentally clobber hand-tuned mappings). All reply mappings use the action-scope resolver `=$.<name>` (the runtime rejects `$flow` in `handler.action.output` slots — `cm` catches strays as `RESOLVER_UNKNOWN`).

`wth` also propagates JSON-Schema to the four typed-tree slots (flow.metadata, handler.action, handler.reply) when given `--output-schema <name>` (or `--output-schema-from-json '<sample>'`). Without those flags, `wth` auto-derives the response schema from a connected mapper's output schema if the actreturn binds one — chain `mapper → actreturn → flow.metadata.output → handler.action.output → handler.reply` is fully knowable at design time. Disable with `--no-auto-derive-output-schema`.

`createMCPSkeleton` (`cms`) calls `wth` internally — same template, single source of truth for the wiring shape.

## Binding schemas on activity input fields (non-mapper activities)

For any activity with a schema-capable input field (visible via `fda exp activity <type>` — look for fields like `jsonSchema`, `responseSchema`, etc.), bind the schema at `schemas.input.<fieldName>` using `fda sa`:

```bash
fda sa activity "<flow>.<activity>.schemas.input.<fieldName>" <SchemaName> -C schema --force -f <file>
```

The `<fieldName>` must match the input field name from `exp`. **Do NOT** set `input.<fieldName>` directly (UI toggle won't activate) or use `sms --field` (writes to the wrong key).

## Subflows, loops and retries

**Calling a subflow.** Create the child flow first and give it typed inputs/outputs with `fda sms <Child>.input --json-schema '…'` and `fda sms <Child>.output --json-schema '…'`. Then, in the parent:

```bash
fda ca <Parent> CallChild subflow "Call the child flow" -f "$FILE"
fda sa activity "<Parent>.CallChild.settings.flowURI" "res://flow:<Child>" -f "$FILE"
fda rmm "<Parent>.CallChild.input.input" -f "$FILE"     # removes the empty placeholder ca leaves behind
fda sms "<Parent>.CallChild.input"  --field input  --json-schema '<Child input schema>'  -f "$FILE"
fda sms "<Parent>.CallChild.output" --field output --json-schema '<Child output schema>' -f "$FILE"
fda mm "<Parent>.CallChild.input.<childInput>" '=$flow.someValue' -f "$FILE"
```

- A subflow activity is not a mapper: `sms` needs `--field input` / `--field output`, and its inputs are mapped one child input at a time (`input.<childInput>`, no `.mapping.`).
- Downstream activities read the child's outputs by name: `$activity[CallChild].<childOutput>` (this trips a known `cm` false positive, see above).
- `fda cat <flow> <activity> subflow` keeps the activity's links but empties its fields. Recreate the settings with `sa … --force` (case 3 of the `--force` rule).
- `settings.execTimeout` (ms, accepts `=$property["…"]`) cancels the child flow when it runs too long. The cancellation takes the subflow activity's `error` link.

**Error branches.** On an `error`-type link, read the failure with `$error[<FailedTask>].message`. The generic `$error.message` is not always set: after a subflow `execTimeout` cancellation, for example, it fails at runtime with `failed to resolve error, not found in flow`, while `$error[<FailedTask>].message` returns the timeout message.

**Repeat while true (`doWhile`) loop.** `fda` has no loop flag, so set the task type and loop settings with `sa any`. `<i>` is the flow's 0-based position in `fda dp`, and `<j>` is the task's 0-based position in `fda da flow '<Flow>.tasks'`. Confirm both with `fda da any "resources.<i>.data.tasks.<j>.id"` before writing:

```bash
fda sa any "resources.<i>.data.tasks.<j>.type" doWhile --force -f "$FILE"
fda sa any "resources.<i>.data.tasks.<j>.settings.doWhile" --jsonValue '{"condition":"=$activity[RetryLoop].retryable == true && $iteration[index] < $property[\"Retry_Count\"]","delay":"=$property[\"Retry_Interval\"]","accessOutputInInput":true}' --force -f "$FILE"
fda sa any "resources.<i>.data.tasks.<j>.settings.accumulate" --jsonValue false --force -f "$FILE"
```

- The condition runs after each execution. `$iteration[index]` is `0` after the first one, so `$iteration[index] < N` allows up to `N + 1` executions (1 try + N retries). Inside the loop, `=$iteration[index] + 1` is the current attempt number.
- `delay` (ms, accepts `=$property["…"]`) is applied only before a repeat. `accessOutputInInput: true` lets the condition and the inputs read the previous iteration's `$activity[<task>]` output.
- An **error ends the loop**: a failed iteration does not repeat. For retries, put the attempt in a subflow that never throws. Route its success, non-success and `error` links to separate Return activities that all return the same result shape (for example `ok`, `retryable`, `status`, `errorMessage`), and loop on `retryable`.

## Things to avoid (common pitfalls)

- **Prefix `MSYS_NO_PATHCONV=1` when passing values that start with `/`.** Git Bash on Windows converts `/path` arguments to `C:/Program Files/Git/path`. Always use `MSYS_NO_PATHCONV=1 fda ...` for commands like `cth --restResourcePath /books/{id}` or any `sa`/`mm` value starting with `/`. This is harmless on Linux/Mac (just an unused env var).
- **Do NOT use `fda ff` (format-flow).** `ff` can silently delete activities that are not in its computed layout — including critical activities like `actreturn` — causing data loss and broken flows. Until this bug is fixed, never run `fda ff` or `fda format-flow`. The UI will render activity positions correctly based on the links without manual formatting.
- **Always pass the app name as a positional arg to `cp`:** `fda cp MyApp -f MyApp.flogo` — without it the project defaults to `Flogo_project`.
- **After `cp`, run `dp` to check if a flow exists — if not, run `cf` before `ct`/`cth`.**
- **Do NOT manually run `wth` after `cas` or `cms`.** Both are self-contained skeleton builders — they call `wth` internally and derive schemas from the spec automatically. Manual `wth` wiring is only needed when creating triggers and handlers individually (via `ct` + `cth`).
- **After `cth`, always run `wth` to wire the trigger handler to the flow.** Without wiring, the flow cannot receive trigger data or send replies (`TRIGGER_HANDLER_UNWIRED`). For triggers with path parameters, create and associate the pathParams schema before running `wth` (see "Setting schemas on trigger handlers" section). The only exception is `tr_timer`, which carries no payloads.
- **Never use `--force` unless the skill docs explicitly show it for that exact command.** `--force` bypasses validation guards — using it unnecessarily can silently create malformed attributes or overwrite correct state. The ONLY places `--force` is required are: (1) `fda sa handler "...schemas.output.<field>" <name> -C schema --force` for schema association on trigger handler output, (2) `fda wth ... --force` to overwrite already-wired sides, and (3) `sa` on an attribute that a documented recipe says does not exist yet, which fails with `Attribute not found`: a link's condition `value` (see the link-condition rule below), a task's loop settings (see "Subflows, loops and retries"), and activity settings emptied by `fda cat`. Every other `fda` command must be run WITHOUT `--force`. If a command fails without it, investigate the root cause instead of forcing past it.
- **Don't hand-edit the .flogo JSON.** The `flogoProject.contrib` blob is base64-encoded and re-derived on every save; ad-hoc edits to it vanish on the next `fda` write. Use the dedicated tasks.
- **Don't use `set-attribute` (sa) for mapper input fields when `make-mapping` (mm) exists.** `mm` proactively adds function imports for any expression you write; `sa` doesn't, so you'd rely on the defensive sweep at save time. The sweep catches it eventually but `mm` is more explicit and surfaces errors immediately.
- **Bind an activity's connection when you create it: `fda ca <flow> <task> <type> <label> -C <ConnName>`.** `ca -C` resolves the name to the connection's internal UUID (`conn://<uuid>`), picks the named connection even when it is not first in the file, and later `fda` writes leave the binding alone. Never use `fda mm` for connection fields — it writes the name as a literal string (`conn://SQLServerConn`), which the runtime won't resolve. `fda sa activity "Flow.QueryDB.input.Connection" "conn://SQLServerConn"` also resolves to a UUID, but in a multi-connection app it binds the FIRST connection (next bullet) — use it only on a single-connection app.
- **`fda sa trigger` does NOT resolve `conn://` names to UUIDs.** Unlike `fda sa activity`, `fda sa trigger` writes the literal string as-is. When binding a connection to a trigger, first look up the UUID from the flogo file's `connections` array (or from an activity that already resolved it), then pass `conn://<uuid>` directly: `fda sa trigger "MyTrigger.settings.connection" "conn://c63e4311-..." -f app.flogo`.
- **In a MULTI-connection app, never set `input.Connection` with `fda sa activity` — it binds the FIRST connection in the file.** On fda 0.9.3, `fda sa activity "<flow>.<task>.input.Connection" …` reports success but writes the UUID of the first entry in the project's `connections` map, whatever you pass — the name with `-C connection`, the literal `conn://<uuid>`, `--force`, or `--jsonValue` — and it overwrites a correct binding made by `ca -C`. It is silent (`fda cm` still passes) and position-dependent: single-connection apps, and apps whose target connection happens to be first, never show it. `fda ca … -C <ConnName>` binds correctly regardless of position, and neither that binding nor a hand-set `conn://<uuid>` is changed by later `fda` writes (`sa` on other fields, `mm`, `ca`, `cap`, `sa trigger` — all verified with a readback after each). **Detect:** read back each DB/connector activity's `input.Connection` and confirm the UUID maps to the intended connection's `name` in the `connections` map — don't trust the success message. **Fix an existing activity:** set `input.Connection = "conn://<correct-uuid>"` directly in the `.flogo` JSON, or with `fda sa any "resources.<i>.data.tasks.<j>.activity.input.Connection" --jsonValue '"conn://<uuid>"'` (the generic path keeps the value you pass). This is the one place hand-patching the JSON is justified.
- **Always pass `-C <type>` when using `sa` for non-string values.** `sa` defaults to writing every value as a string (e.g. `"true"` instead of `true`, `"200"` instead of `200`). The UI won't recognise the value if the type is wrong — boolean toggles stay unset, number fields show as text. Use `-C boolean` for true/false and `-C number` for numeric values: `fda sa activity Flow1.Log1.input.flowInfo true -C boolean`.
- **To update a connection field that is backed by an app property, use `rap` + `cap` — not `sa`.** When a connection field value is an app property reference (e.g. `=$property[PostgreSQL.POSTGRESQL_HOST]`), using `fda sa` would replace the reference with a hardcoded literal, breaking the property binding. There is no "update app property" command, so the correct sequence is: (1) `fda rap <PropertyName> -f app.flogo` to remove the old property, then (2) `fda cap <PropertyName> <type> <newValue> -f app.flogo` to recreate it with the updated value. Conversely, if the connection field currently holds a hardcoded value (no `=$property[...]` reference), `fda sa` can be used directly to change it. **`fda cap` type must be `number` (not `float64`) for numeric properties** — `float64` is rejected with `Unknown Flogo Property Type`.
- **`fda cap` has no password/secret type** (only `string`, `number`, `boolean`). For a credential used only inside mapping expressions (for example a Basic-Auth header built with `string.concat`), store a non-secret placeholder with `cap` and supply the real value at runtime: with `FLOGO_APP_PROPS_ENV=auto` set, an environment variable named after the property with `.` replaced by `_` overrides it (`Group.Password` → `Group_Password`). Never write the real secret into the `.flogo` or log it. A **password-typed field of a connector or activity** is different: its property value must be a `SECRET:`-prefixed value, and a plain placeholder there is a design-time type error (see `agentic-ai-use-case-builder/references/postgres-activity-patterns.md`, section E). Never decrypt existing `SECRET:` values or fabricate new ones by hand.
- **Pass the `--file` global with the right shape.** A bare `fda <task>` with no `-f` opens `flogo-project.flogo` in the cwd and AUTO-CREATES it if missing — a silent no-op trap when you meant to operate on a different file. When scripting, always pass `-f <path>` explicitly.
- **`exp function <name>` has three modes** — `category.fnName` (qualified), bare unique name (works), bare ambiguous name (errors with disambiguation), and bare category name (expands to every function in the package). When in doubt, qualify with `category.`.
- **`-j` JSON output suppresses tables.** Helpful when piping into `jq` from a script, but if you want to read the table yourself, drop the flag.
- **Stale `default-config.json`.** When working on a fresh clone the function catalog (`fda lf`, `fda exp function ...`) needs to be seeded once: `fda ave <path-to-extension> --type function --toConfigFile tibcopilot-flogo-command-line-developer/default-config/default-config.json`, where `<path-to-extension>` is the newest `~/.vscode*/extensions/tibco.flogo-*` folder resolved dynamically (see AGENT.md → Resolving the `fda` CLI). The repo's committed `default-config.json` already has it; only matters if someone has reset that file.
- **Never guess activity output paths — run `fda lms <target-field>` before any `mm` that reads from another activity's output.**
- **Don't use `sms` on Mapper activity output side.** The Mapper's Output tab in the UI is read-only — it always mirrors the input schema. Setting an inline schema on the output via `sms --json-schema` or `--json-value-to-schema` writes to the JSON file but has no effect in the UI. Only use `sms` on the input side (or omit the direction to apply to both, which is the default).
- **SQL queries must end with `;`.** The trailing semicolon terminates the query so the engine can fetch metadata (column names, types). Without it, metadata discovery fails silently and downstream mappings may not resolve.
- **SQL placeholders must use `?<name>` syntax.** Prepared-statement parameters are written as `?keyName` (e.g. `?BookId`), not `@param`, `:param`, or bare `?`. Example: `SELECT * FROM BookStore WHERE id = ?BookId;`
- **`fda cc` requires the full connection type name (e.g. `con_sqlserver`), not the short alias (e.g. `sqlserver`).** `fda cc MyConn sqlserver` fails — use `fda cc MyConn con_sqlserver`. Run `fda lct` to find the full type name.
- **Activity aliases use `<group>_<entity>`** for everything outside the `general`, `default`, and `ems` groups (e.g. `mysql_query`, `salesforce_delete`, `auditsafe_query` — not bare `query`). Connection / trigger aliases stay bare (`kafka`, `ems`, `mysql`) — there are no clashes there. `fda lat <filter>` and `fda exp activity <name>` show the canonical name + alias; `analyze-vscode-extension` warns at the end of its run if it spots any remaining alias clashes (`mapXxxAlias()` would silently pick the first match otherwise — `helper-validate-shortcodes` is the strict CI gate for the same check).
- **REST API identifiers belong in path parameters, not query parameters.** When a REST API accepts an identifier (BookId, userId, orderId, etc.), use path parameters (`/resource/{id}`) rather than query parameters (`/resource?id=`). Path parameters are the REST convention for resource identifiers. When creating `cth` for a REST trigger, use `--restResourcePath /resource/{paramName}`, create a pathParams schema with matching property names, and associate it with the handler output before running `wth`.
- **Clear `input.input` BEFORE setting the SQL query, not after.** `rmm` also clears the auto-generated schema; setting the query after `rmm` regenerates it. Correct order: (1) `rmm` on `input.input`, (2) `sa` to set `input.Query`, (3) `da` to confirm schema is populated, (4) `mm` on each leaf field. Wrong order causes `mm` to write a JSON blob on the parent.
- **SQL query `Output` is an object with a nested `records` array — not a flat array.** Database query activities (`sqlserver_query`, `postgresql_query`, `mysql_query`) return `Output` as an object shaped `{"records": [...]}`. When using `@foreach` in a Mapper to iterate over query results, the source must be `$activity[QueryName].Output.records` — **not** `$activity[QueryName].Output`. Using the bare `.Output` causes a type error in the UI: `Expected type of parameter 'input' to be 'any[]' but got 'object'`. Always run `fda da activity <flow>.<activity>` to inspect the output schema and confirm the correct path before setting up `@foreach`.
- **A parameterized DB activity's input SCHEMA must declare the same params the mapping targets — or the designer dumps the mapping on the ROOT node.** When you bind `?param` placeholders via `input.input.mapping.parameters.<name>`, the activity's input schema (`schemas.input.input`) MUST list every one of those params under `properties.parameters.properties.<name>` (with matching types). For INSERT/UPDATE activities the auto-derived schema frequently gets this wrong: it puts the `?param` fields under `values.items.properties` (the bulk-row-insert shape) and leaves `parameters.properties` empty `{}`. When the schema's `parameters` doesn't contain the keys your mapping writes to, the VSCode designer can't bind them to leaf nodes and renders the entire mapping as one raw JSON blob on the ROOT `input` node with a red error. **This is a designer-only symptom — the runtime and `fda cm` both still pass**, so you won't catch it from validation alone. Fix: make `parameters.properties` hold every `?param` field; keep `values.items.properties` empty `{}` for the placeholder-param pattern (values is only used for the bulk-array insert style, which is a different mapping shape). Verify by reading back `schemas.input.input` and comparing against a known-good, designer-authored DB activity of the same kind (query vs insert).
- **`actreturn` settings.mappings — use `fda mm`, not `sa` or hand-editing.** The actreturn mappings live under `settings.mappings` as a flat object (keys = flow output names from `flow.metadata.output`, values = literals or `=expression` strings). `fda mm` rewrites the path from `input.mappings` to `settings.mappings` automatically via the settingFields metadata, so always use `mm` to set actreturn mappings. Do NOT use `fda sa` — it mangles JSON objects. Do NOT hand-edit the `.flogo` JSON — that contradicts the tool's purpose and the `contrib` blob gets re-derived on every `fda` save. Example:
  ```bash
  fda mm "<flow>.<actreturn>.input.mappings.code" '=$property["HttpStatusCode"]' -f app.flogo
  fda mm "<flow>.<actreturn>.input.mappings.message" '=coerce.toString($activity[QueryDB].Output)' -f app.flogo
  ```
- **Don't hardcode HTTP status code in actreturn mappings.** When setting up `actreturn` `settings.mappings` for `code`, create an app property (`fda cap HttpStatusCode number 200`) and map it as `"code": "=$property[\"HttpStatusCode\"]"` instead of hardcoding `"code": 200`. This makes the response code configurable at deployment time.
- **Dynamic input settings (e.g. MessageAttributeNames) require named entries.** Set the names array as `[{"Name":"X","Type":"String"}]` objects via `sa --jsonValue`. For activities, also map each value individually via `mm` on the parent object's children (e.g. `mm ...MessageAttributes.X "val"`) — never as a single JSON blob. For trigger handlers, only add the attribute names — values are picked up automatically from the activity.
- **Use `--jsonSchemaFile` for complex nested JSON schemas.** When a schema has more than 2 levels of object/array nesting (e.g. arrays of objects containing sub-arrays), write the JSON to a file and use `fda cs <name> --jsonSchemaFile <path>` instead of inline JSON. Inline JSON with deeply nested structures is error-prone — miscounting closing braces `}` is nearly impossible to spot visually and leads to invalid JSON or silently malformed schemas. For simple flat schemas (1-2 levels), inline JSON is fine.
  ```bash
  # Complex nested schema — write to file first, then reference it
  fda cs OrderRequest --jsonSchemaFile ./schemas/order_request.json -f my-app.flogo

  # Simple flat schema — inline is fine
  fda cs BookPathParams '{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}' -f my-app.flogo
  ```
- **Link condition values don't take a leading `=`.** When setting a condition on a link via `fda sa flow '<Flow>.links[N].value'`, the value is already evaluated as an expression — don't prefix with `=`. Only mapping values (`mm`) need the `=` prefix. A link created by `cl` has a `type` but no `value` yet, so set the type first and create the value with `--force` (without it `sa` fails with `Attribute not found: links[N].value`). Example: `fda sa flow 'MyFlow.links[0].type' expression -f app.flogo` then `fda sa flow 'MyFlow.links[0].value' 'string.equals($flow.pathParams.type, "domestic")' --force -f app.flogo` — note no `=` before `string.equals(...)`. For the error path of an activity, set `.type error` (no value). Find `N` with `fda da flow '<Flow>.links'` (0-based, in stored order). Expression rules (no unary `!`, etc.) are in the `fda-mapping` skill, "Expression rules".
- **Store links in flow order when you build with `--doNotLink` + `cl`.** Create the link *into* an activity before any link *out of* it. The VS Code designer saves the file when it opens it and deletes activities whose incoming link is stored before their predecessor's link, and neither `fda cm` nor `flogobuild` reports it. If you created links out of order, `fda rl` the affected ones and `cl` them again in flow order, then check the order with `fda da flow '<Flow>.links'`.
- **Check source vs target types before mapping; use `coerce.toXxx()` for mismatches.** Compare source type (from `da` or `lms`) against target type. Run `fda exp function coerce` to see all available conversions (toString, toInt, toFloat64, toBool, toObject, toArray, etc.). Don't wrap when types already match.
- **Never use `[N]` bracket indexing on function results or arrays in mapping expressions.** The Flogo expression engine parses `[N]` as a resolver reference (looking for a name), not array indexing — `json.jq(...)[0]` fails with "Invalid reference, cannot find name '0'". Always use `array.get(arr, N)` instead. This applies to any function that returns an array (e.g. `json.jq`, `array.slice`, `array.flatten`). Example: `=array.get(json.jq($activity[Source].output.catalog, ".[] | select(.code == \"P001\")"), 0)` — NOT `=json.jq(...)[0]`.
- **`flow.metadata.input` and `flow.metadata.output` must be arrays of `{"name","type","value"}` descriptors** — not nested objects. The UI calls `.reduce()` on them; a non-array causes `e.reduce is not a function`. Correct: `fda sa flow "Flow1.metadata" --jsonValue '{"output":[{"name":"result","type":"object","value":null}]}'`. Wrong: `'{"output":{"result":{"type":"object"}}}'`.
- **Schema-typed fields on non-mapper activities need `.mapping.` in the child path.** When a non-mapper activity has a schema bound via `sms --field <fieldName>`, map children as `<flow>.<activity>.input.<field>.mapping.<child>` — not `input.<field>.<child>`. Without `.mapping.`, children collapse into a JSON blob on the parent. Example: `fda mm "Flow1.Publish.input.payload.mapping.MsgText" "hello"` — not `...input.payload.MsgText`.

## When the user asks "build and run this app"

`fda` itself doesn't build/run — that's `flogobuild` (see the `flogobuild` skill). Typical end-to-end loop is:

1. `fda` to construct/edit the .flogo project
2. `fda cm -f <file>` to validate mappings before building
3. `flogobuild build-exe -f <file>` to compile to a native binary
4. `./<binary>` to run it

Use the `flogobuild` skill for the build/run side; this skill is for the design-time edits that come before.
