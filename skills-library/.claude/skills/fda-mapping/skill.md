---
name: fda-mapping
description: How to construct, inspect, and validate Flogo mappings with the `fda` CLI — covers the mapper-activity input.input.mapping shape, regular activity input fields, the four source kinds ($flowctx / $property / $activity / $loop), function calls (auto-imported), and @foreach loops. Use when the user asks about Flogo mappings, mapping a field, $activity / $property / $flowctx / $loop / @foreach syntax, mapper activities, function calls inside mappings, or "how do I map X to Y in Flogo".
user-invocable: true
---

# Making Flogo mappings with `fda`

The `mapping` task category in `fda` mirrors the Flogo VSCode mapping UI. Every field you can map in the UI's "Activity inputs" panel is reachable from the CLI; every source you can drag from the "Available data" panel has a dedicated discovery task.

This skill is the practical "how do I map X" reference. For the broader CLI surface see the `flogo-design-assistant` skill.

## What you can map

Two distinct shapes — `dmf` enumerates both:

| Activity kind | Mapping path shape | Example |
|---|---|---|
| **Mapper** (`#mapper` / `tibco-wi-mapper`) | `<flow>.<activity>.input.input.mapping.<dotted>` | `MainFlow.MakeMapping.input.input.mapping.orderId` |
| **Any other activity** (log, rest, sleep, …) | `<flow>.<activity>.input.<field>` | `MainFlow.LogIt.input.message` |

For mappers, the leaf can be deeply nested (`...mapping.shippingAddress.city`). For non-mapper activities, the field comes from the activity's `initActDef.activity.input` schema (one level deep typically).

### Mappable inputs vs settings (non-mapper activities)

Most non-mapper activities have BOTH mappable inputs AND configuration settings, all serialised under `activity.input.<name>` in the .flogo JSON. The Flogo VSCode UI shows them in **two different tabs**: "Activity inputs" (mappable) vs "Settings" (configuration). `dmf` mirrors this distinction.

**The discriminator** (read from each activity's descriptor in the bundled VSCode extension): a field is mappable when its descriptor entry has **no `display` block** OR `display.mappable === true`. Otherwise (has a `display` block but no `mappable` flag) → it's a setting, hidden from `dmf`.

For example, the Log activity has 4 input fields in the JSON — `Log Level`, `flowInfo`, `message`, `logLevel` — but `dmf` only shows `message` and `logLevel`, matching the UI. The other two are settings.

The allow-list lives on each activity's FCon entry as `mappableFields: string[]`, populated by `analyze-vscode-extension`. When absent (e.g. for a custom activity not yet analyzed), `dmf` falls back to "show every field" — backwards-compat.

**`mm` and `rmm` are intentionally NOT filtered.** You can still set any input field including settings (`fda mm 'MainFlow.LogIt.input.Log Level' DEBUG …` works). The allow-list is purely a discovery hint for `dmf`; mutation is unrestricted because configuring a setting via mapping is normal usage.

## Source syntax (what you can map FROM)

Five kinds of right-hand-side. Always prefix with `=` to mark a value as an expression rather than a literal:

| Source | Syntax | Notes                                                                                                                                                                                                                                                                                       |
|---|---|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| App property | `=$property["Name"]` | Group properties use dots inside the quotes: `$property["Group_1.Property_1"]`                                                                                                                                                                                                              |
| Flow context var | `=$flowctx["Name"]` | Eight canonical names: `AppName`, `AppVersion`, `FlowId`, `FlowName`, `ParentFlowId`, `ParentFlowName`, `SpanId`, `TraceId`                                                                                                                                                                 |
| Upstream activity output | `=$activity[Name].output.<field>` | `Name` must be a task that runs upstream of the target activity (validated by `cm`)                                                                                                                                                                                                         |
| Loop iterator (inside `@foreach` only) | `=$loop[<iterName>].<field>` | `<iterName>` must match the `--as` name of an enclosing `@foreach` scope                                                                                                                                                                                                                    |
| Function call | `=string.concat("a","b")`, `=utils.uuid()`, … | **Always qualify with the package name** — bare calls like `length()` or `uuid()` are rejected by `mm` (codes `FUNCTION_AMBIGUOUS` for multi-package matches, `FUNCTION_NOT_QUALIFIED` for unique matches). Function package import is auto-added when the value is set via `make-mapping`. |

Literals (no `=`) are written verbatim. Use `--type number` / `--type boolean` to coerce.

## The 4-step workflow

> 🔴 **ALWAYS attach a schema to every activity you map.** Before you call `mm` on an activity, call `sms` to attach a schema to it (see [Attaching schemas](#attaching-schemas-sms--rms) below). Without a schema, the Flogo VSCode UI cannot render the mapping as a typed tree, drag-to-map autocomplete is broken, and `cm` cannot validate that the mapped fields actually exist in the expected shape. This applies to **both mapper activities AND non-mapper activities** (REST, log, etc.) — every activity that participates in a mapping (as a source OR a target) needs its schema set so downstream `lms` / `cm` / UI behaviour is correct.

### 1. Discover what's mappable

```bash
# All mappable fields in the project
fda dmf -f my-app.flogo

# Just one activity's fields
fda dmf MainFlow.LogIt -f my-app.flogo
fda dmf MainFlow.MakeMapping -f my-app.flogo
```

Output columns: `PATH`, `TYPE`, `SOURCE` (`schema` = default, `value` = literal set by user, `expression` = `=…` set by user).

### 2. Discover what you can map FROM

For a specific target field, list every available source (properties, $flowctx, upstream activity outputs):

```bash
fda lms MainFlow.MakeMapping.input.input.mapping.orderId -f my-app.flogo
# Filter to one source kind
fda lms MainFlow.MakeMapping.input.input.mapping.orderId activity -f my-app.flogo
```

For functions, use `lf` and `exp`:

```bash
fda lf                    # all functions, grouped by category
fda lf string             # all string functions
fda exp function string   # detailed (description + example) for every string function
fda exp function string.concat   # one specific function
fda exp activity log      # input fields of any activity / trigger / connector
```

### 3. Make the mapping

```bash
# Literal
fda mm MainFlow.Mapper.input.input.mapping.customerId 1234 --type number -f my-app.flogo

# Expression — function package import is auto-added (no manual add-import needed)
fda mm MainFlow.Mapper.input.input.mapping.tag '=string.concat("X-", $property["Env"])' -f my-app.flogo

# Reference an upstream activity's output
fda mm MainFlow.Mapper.input.input.mapping.orderId '=$activity[Setter].output.orderId' -f my-app.flogo

# Map onto a non-mapper activity (e.g. the Log activity's `message` field)
fda mm MainFlow.LogIt.input.message '=$activity[Mapper].output.tag' -f my-app.flogo
```

`mm` writes into the right place automatically; never hand-edit the JSON.

### 4. Validate before building

```bash
fda cm -f my-app.flogo            # sweep every mapping, report bad refs / missing imports
fda lm -f my-app.flogo            # confirm what's actually set vs schema defaults
```

`cm` checks the following categories (run it before every `flogobuild build-exe` — most rules catch failures that would otherwise crash the runtime):

- `ACTIVITY_NOT_FOUND` — `$activity[X]` references an unknown task
- `ACTIVITY_OUTPUT_LEAF_UNKNOWN` — `$activity[X].<leaf>` where `<leaf>` isn't in the activity's `outputs` schema (e.g. using `.output` on a REST activity instead of `.responseBody`)
- `PROPERTY_NOT_FOUND` — `$property["X"]` references an undefined property
- `FLOWCTX_UNKNOWN` (warning) — `$flowctx["X"]` not in the canonical list
- `FUNCTION_PKG_UNKNOWN` / `FUNCTION_NOT_FOUND` / `FUNCTION_IMPORT_MISSING` — function ref problems
- `FUNCTION_AMBIGUOUS` — bare function call (e.g. `length(...)`) resolving to multiple packages — qualify with the package name
- `FUNCTION_NOT_QUALIFIED` — bare function call (e.g. `uuid(...)`) that matches exactly one package — must STILL be qualified (`utils.uuid(...)`) per the always-qualified rule. Future-proofs against extensions adding same-named functions.
- `FOREACH_SCOPE_UNDEFINED` — `$loop[name]` outside any matching `@foreach` scope
- `FOREACH_HAS_LEADING_EQUALS` (warning) — `@foreach(=…)` stored key (the `--foreach` value should NOT take a leading `=`)
- `INPUT_VS_SETTINGS_MISWRITE` — fields like `actreturn.mappings` that the runtime reads from `Settings()` but were written under `input` (use `mm` — it auto-rewrites; or `sa` which now does too)
- `TR_REST_NO_SWAGGER` — `tr_rest` trigger with empty `settings.swagger` (panics on first request)
- `HTTP_TRIGGER_REPLY_UNWIRED` (warning) — `tr_http` handler in `mode: Data` with empty reply (response will be HTTP 0)

## Loops with `@foreach`

> ⚠ **`--foreach` is the ONE place where the source expression does NOT take a leading `=`.** Every other source path (`mm field '=$activity[…]'`, `mm field '=$property[…]'`) uses `=`; `@foreach` is different because the wrapper itself IS the expression marker. `mm` strips a leading `=` automatically, but be aware of the asymmetry. `cm` flags any stored `@foreach(=…)` key as `FOREACH_HAS_LEADING_EQUALS`.

For per-element transformations on an array, set up an `@foreach` scope on a mapper field, then add per-iteration child mappings:

```bash
# 1. Create the @foreach scope. The `--as` value is the iterator NAME used in $loop[…].
fda mm MainFlow.MakeMapping.input.input.mapping.lineItems \
    --foreach '$activity[Setter].output.items' --as items \
    -f my-app.flogo

# 2. Add child mappings — fda auto-descends through the @foreach wrapper.
fda mm MainFlow.MakeMapping.input.input.mapping.lineItems.code '=$loop[items].sku' -f my-app.flogo
fda mm MainFlow.MakeMapping.input.input.mapping.lineItems.qty  '=$loop[items].quantity' -f my-app.flogo
```

What gets written to the .flogo:

```json
"lineItems": {
  "@foreach($activity[Setter].output.items, items)": {
    "code": "=$loop[items].sku",
    "qty":  "=$loop[items].quantity"
  }
}
```

`rmm` of the last child also cleans up the empty `@foreach` wrapper AND the parent `lineItems` key. `--foreach` is **mapper-only** — using it with a non-mapper path errors with a helpful message.

## Worked example: a simple order-mapping flow

```bash
FILE=order.flogo

# Project + properties + flow + trigger
fda cp -f $FILE
fda cap Env string PROD -f $FILE
fda cf MainFlow -f $FILE
fda ct MyTimer timer -f $FILE
fda cth MainFlow MyTimer -f $FILE

# Two mapper activities + a log
fda aa MainFlow Source mapper -f $FILE
fda aa MainFlow Build  mapper -f $FILE
fda aa MainFlow LogIt  log    -f $FILE

# Attach schemas to every mapping participant FIRST (mandatory step — see rule above).
# Derive from sample values when you don't have a hand-written schema.
fda sms MainFlow.Source --json-value-to-schema '{"items":[{"sku":"A","qty":1}]}' -f $FILE
fda sms MainFlow.Build  --json-value-to-schema '{"envTag":"X","lineItems":[{"sku":"A","qty":1}]}' -f $FILE
fda sms MainFlow.LogIt.input --field message --json-schema '{"type":"string"}' -f $FILE

# Source emits the raw items
fda mm MainFlow.Source.input.input.mapping.items '[{"sku":"A","qty":1},{"sku":"B","qty":2}]' --type string -f $FILE

# Build maps each item into a line + adds metadata
fda mm MainFlow.Build.input.input.mapping.envTag '=string.concat($property["Env"], "-", $flowctx["FlowName"])' -f $FILE
fda mm MainFlow.Build.input.input.mapping.lineItems --foreach '=$activity[Source].output.items' --as it -f $FILE
fda mm MainFlow.Build.input.input.mapping.lineItems.sku '=$loop[it].sku' -f $FILE
fda mm MainFlow.Build.input.input.mapping.lineItems.qty '=$loop[it].qty' -f $FILE

# Log a summary (non-mapper activity input — same `mm` task, simpler path)
fda mm MainFlow.LogIt.input.message '=string.concat("processed for ", $activity[Build].output.envTag)' -f $FILE

# Validate
fda cm -f $FILE
```

Then build + run with `flogobuild build-exe -f order.flogo && ./order` (see the `flogobuild` skill).

## Worked example: map a REST activity's response body

REST (and most non-mapper activities) expose multiple top-level outputs — NOT a single `.output` object. Use `lms` to discover them:

```bash
FILE=spacex.flogo

# Project + flow + REST trigger (HTTP, mode: Data — no swagger needed)
fda cp SpaceX -f $FILE
fda cf Get -f $FILE
fda ct HTTP tr_http -f $FILE
fda cth Get HTTP --restResourcePath /capsules --restHandlerMethod GET -f $FILE

# Outbound REST invoke + a mapper to shape the response
fda ca Get Invoke rest -f $FILE
fda sa activity 'Get.Invoke.input.Method' GET --force -f $FILE
fda sa activity 'Get.Invoke.input.Uri' 'https://api.spacexdata.com/v4/capsules' --force -f $FILE
fda ca Get Build mapper -f $FILE

# Attach schemas to every activity that participates in the mapping (mandatory).
# Build's input schema describes the response we expect from Invoke.
fda sms Get.Build --json-value-to-schema '{"body":[{"id":"x"}],"count":0}' -f $FILE

# What outputs does Invoke expose? (lms expands per-leaf — NOT a single .output row)
fda lms 'Get.Build.input.input.mapping.foo' activity -f $FILE
# Shows: Invoke.responseBody (complex_object), Invoke.statusCode (integer),
#        Invoke.responseTimeInMilliSec (integer), Invoke.headers (complex_object), ...

# Map the response body — note `.responseBody`, NOT `.output.body` or `.output`
fda mm 'Get.Build.input.input.mapping.body'  '=$activity[Invoke].responseBody'           -f $FILE
fda mm 'Get.Build.input.input.mapping.count' '=string.length($activity[Invoke].responseBody)' -f $FILE
#                                                ↑ qualified — bare length() is ambiguous

# Wire the trigger reply (actreturn → metadata.output → handler.action.output → handler.reply
# is the 4-step requirement; see the `fda` skill's "Wiring actreturn" section)
fda ca Get Reply actreturn -f $FILE
fda mm 'Get.Reply.input.mappings.statusCode'   200                                  --type number -f $FILE
fda mm 'Get.Reply.input.mappings.responseBody' '=$activity[Build].output'           -f $FILE
# (^ mm auto-rewrites input.mappings.* → settings.mappings.* for actreturn)

fda cm -f $FILE      # catches any forgotten leaf / missing import / bad ref
```

## Attaching schemas (`sms` / `rms`)

> 🔴 **Set a schema on every activity you map. No exceptions.** This is not an optional polish step — it is part of the standard mapping workflow. Run `sms` immediately after `aa` / `ca` (creating the activity) and BEFORE the first `mm` against it. Skipping this leaves the Flogo VSCode UI showing raw JSON text instead of a typed tree, breaks drag-to-map autocomplete, weakens `cm` validation, and makes the mapping brittle to refactor. If you don't have a JSON Schema handy, derive one from a sample value with `--json-value-to-schema` (and refine later) — that's still better than no schema.

Use `fda sms` to attach, `fda rms` to detach.

### Where the schema lives

The schema slot is `activity.schemas.<direction>.<fieldName>`. Two storage shapes:

| Shape | When | Example |
|---|---|---|
| **Reference** — `"schema://<name>"` | The schema is reusable across activities (typical) | `schemas.input.input = "schema://Order"` references `flogoProject.schemas.Order` |
| **Inline** — `{type, value, fe_metadata}` | One-off, not worth a top-level entry | `schemas.output.output = {type:"json", value:"…", fe_metadata:"…"}` |

For mapper activities, both `<direction>.<fieldName>` slots use the literal `input` / `output` (mapper convention — input goes under `input.input`, output under `output.output`). For non-mapper activities, the inner key matches the activity's input field name (e.g. `schemas.input.message` for the log activity's `message` input).

### Three input modes for `sms`

| You have... | Command | Result |
|---|---|---|
| An existing top-level schema **(preferred — enables UI toggle)** | `fda sms <flow>.<activity> <name>` | Activity slot becomes `"schema://<name>"`. Create the schema first with `fda cs`, then reference it. Errors if the schema doesn't exist. |
| Raw JSON-Schema content | `fda sms <flow>.<activity> --json-schema '{...}'` | Stored inline (no top-level entry). Use `--json-schema-file <path>` for a file. |
| A sample JSON value | `fda sms <flow>.<activity> --json-value-to-schema '{...}'` | Runs the sample through `to-json-schema` and stores the derived schema inline. ⚠ Inferred from one example — review and refine via `--json-schema` if the types are off (no enum detection, format guesses can be quirky). |
| Both a name AND content | `fda sms <flow>.<activity> <name> --json-schema '{...}'` | Upserts the named schema (compare-and-decide), then references it. Pass `--force` to overwrite an existing entry with different content. |

### Direction defaults to `both`

The selector is `<flow>.<activity>[.<direction>]`. Direction is one of `input`, `output`, `both` — and defaults to `both` (mapper activities almost always have the same schema on both sides, so this is the most common case).

```bash
# Both sides of a mapper get the same named schema (most common)
fda sms MainFlow.MakeMapping StoreOrder

# Output side only — input side stays untouched
fda sms MainFlow.MakeMapping.output --json-schema '{"type":"object",...}'

# Input side only, derived from a sample
fda sms MainFlow.MakeMapping.input --json-value-to-schema '{"orderId":"X","amount":100}'
```

### Non-mapper activities require `--field`

Non-mapper activities don't have a single mappable input — they have N named fields (e.g. log has `message` and `logLevel`). `sms` requires `--field <name>` so there's no ambiguity:

```bash
fda sms MainFlow.LogIt.input --field message Order
# → activity.schemas.input.message = "schema://Order"
```

### Compare-and-decide on the named schema

When you pass `<schema-name>` AND content together, `sms` does the right thing automatically:
- Schema doesn't exist yet → creates it (via `addSchema`)
- Schema exists with the SAME content → no-op (idempotent)
- Schema exists with DIFFERENT content → errors with a clear message; pass `--force` to overwrite

This means you can run the same `sms` line repeatedly during development without churn. The compare uses the normalised (parsed + re-stringified) form so whitespace differences don't trigger spurious errors.

### Removing schemas

```bash
fda rms MainFlow.MakeMapping              # both sides
fda rms MainFlow.MakeMapping.input        # input side only
fda rms MainFlow.LogIt.input --field message     # specific field on a non-mapper
```

`rms` cleans up empty parent objects — once the last entry is gone, the entire `activity.schemas` block disappears.

### `cm` rules

| Rule | Severity | Triggers when |
|---|---|---|
| `MAPPING_SCHEMA_REF_MISSING` | error | `schemas.<dir>.<field> = "schema://X"` but `flogoProject.schemas[X]` doesn't exist (typically because someone removed the schema with `rs` and forgot the references) |
| `MAPPING_SCHEMA_INLINE_MALFORMED` | warning | Inline schema is missing `{type, value, fe_metadata}` keys, or the `value` doesn't parse as JSON |

## Wiring trigger handlers ↔ flows (`wth`)

Every trigger handler needs **four** mutations to talk to its flow:

1. **`flow.metadata.input[]`** — declare what the flow accepts (request shape)
2. **`handler.action.input.<X>`** — wire the trigger payload into those flow inputs (`Map to Flow Inputs` panel in the Flogo UI)
3. **`flow.metadata.output[]`** — declare what the flow produces (response shape)
4. **`handler.action.output.<X>` + `handler.reply.<X>`** — wire the flow output into the trigger's reply (`Map from Flow Outputs` panel)

`fda wth <flow> <trigger.handler>` does all four in one shot, using the trigger ref's seeded `defaultWiring` template:

```bash
# MCP server — defaults: arguments in / response out (with JSON-Schema)
fda cp -f mcp.flogo
fda cf MyFlow -f mcp.flogo
fda ct MCP tr_mcpserver -f mcp.flogo
fda cth MyFlow MCP -f mcp.flogo
fda wth MyFlow MCP.MyFlow -f mcp.flogo
# → flow.metadata + handler.action.input.arguments + handler.action.output.response + handler.reply.response.* are all populated

# tr_http (Data mode) — defaults: pathParams + queryParams + headers + content in / statusCode + responseBody out
fda ct HTTP tr_http -f http.flogo
fda cth MyFlow HTTP -f http.flogo
fda wth MyFlow HTTP.MyFlow -f http.flogo
```

> **NOTE — tr_http field names:** the runtime trigger reads `statusCode` (integer) and `responseBody` (any) from the action output — NOT the legacy `code`/`data`/`headers` names. `wth` now seeds the right names AND a safe `reply.statusCode = 200` / `reply.responseBody = ""` default so a fresh handler returns HTTP 200 instead of crashing with `WriteHeader code 0`. If you've inherited a flogo with the legacy names, `cm` flags them as `FLOW_OUTPUT_VS_ACTION_OUTPUT_MISMATCH` / `FLOW_OUTPUT_VS_ACTRETURN_MISMATCH`; align all three slots (`flow.metadata.output`, `actreturn.settings.mappings`, `handler.action.output`) on `statusCode` / `responseBody`.

**Optional flags** for non-default cases:
- `--inputs-only` / `--reply-only` — wire just one direction (timer needs neither; some flows are reply-only)
- `--input <name>[:<type>]` / `--output <name>[:<type>]` — repeatable; override the defaultWiring shape for custom triggers
- `--input-mapping <expr>` / `--reply-mapping <expr>` — override the templated mappings (default: `=$.<name>` for both directions — the runtime rejects `$flow` in `handler.action.input/output` slots, so `$.` is the correct action-scope resolver). The template accepts both `<name>` and `{name}` as the field-name placeholder.
- `--input-schema <name>` / `--output-schema <name>` — attach an existing project schema to the typed input/output field(s)
- `--input-schema-from-json '<sample>'` / `--output-schema-from-json '<sample>'` — derive a JSON Schema from a sample, upsert it, and attach
- `--no-auto-derive-output-schema` — disable the default behaviour of inferring the output schema from a connected mapper (when actreturn binds `=$activity[Mapper].output` and Mapper has a schema attached, `wth` propagates it for free)
- `--force` — overwrite already-wired sides (default skips with a warning so hand-tuned mappings aren't clobbered)

### Resolvers by slot

Different mapping slots accept different `$<resolver>` prefixes. Using the wrong one fails at engine init, not at design time — `cm` catches the most common cases as `RESOLVER_UNKNOWN`.

| Slot | Valid resolvers |
|---|---|
| `activity.input.*` (mapper or non-mapper) | `$flowctx`, `$property`, `$activity[X]`, `$loop[name]`, function calls |
| `handler.action.input.*` | `$.` (action-scope shorthand for the trigger payload) |
| `handler.action.output.*` | `$.` (action-scope shorthand for the flow output — `$flow` is rejected here) |
| `handler.reply.*` | typed values (literal `200`, schema content) — not expressions |
| `actreturn.settings.mappings.*` | `$activity[X].output.*`, `$property`, etc. — same as activity inputs |

**`cm` catches missed wiring** as `TRIGGER_HANDLER_UNWIRED` — any handler whose flow has populated `metadata.input/output` but whose `action.input` / `reply` is empty gets a warning with the exact `fda wth` command to fix it.

`createMCPSkeleton` (`cms`) calls `wth` internally per handler, so the same `defaultWiring` template drives both surfaces — single source of truth for the trigger ↔ flow shape.

## Activity-specific quirks

A handful of activities have descriptor-level peculiarities that surface at runtime. `fda` handles each automatically now, but knowing the shape helps when you read or hand-edit a flogo:

| Activity | Quirk | Handled by |
|---|---|---|
| **`actreturn`** | `mappings` is shown as a mapper-style input field but the runtime reads it from `Settings()`. The descriptor has `display.type: "mapper"` + `mapperOutputScope: "action.output"`. | `mm` and `sa` rewrite `<flow>.<actreturn>.input.mappings.<X>` → `<flow>.<actreturn>.settings.mappings.<X>` automatically (driven by `settingFields` metadata on the FCon entry). The user's selector stays the same. |
| **REST / HTTP / connector activities** | `authorizationConn` defaults to `"conn://"` in the raw descriptor, which crashes the runtime at engine init when `authorization` is false (the default). | `analyze-vscode-extension` blanks the value during seeding — no manual workaround needed in fresh projects. Re-seed via `fda ave … --toConfigFile <default-config.json>` if you see one. |
| **`tr_rest`** (TIBCO REST trigger) | Needs `settings.swagger` — without it the trigger panics on the first request inside `handler.Schemas()`. | No auto-fix. Either use `cas` to scaffold from a spec, or pick `tr_http` (project-flogo HTTP, mode: Data). `cm` flags missing swagger as `TR_REST_NO_SWAGGER`. |
| **`tr_http`** (project-flogo HTTP) | In `mode: Data`, the handler's `reply` block must be wired to the upstream `actreturn` output, otherwise the response is HTTP 0. | `fda wth <flow> <HTTP.handler>` populates the entire reply scaffold from the trigger's `defaultWiring` template. `cm` flags missed wiring as `HTTP_TRIGGER_REPLY_UNWIRED` / `TRIGGER_HANDLER_UNWIRED`. |

## Auto-managed function imports + always-qualified rule

> ⚠ **Always qualify function calls with the package name.** `mm` rejects bare calls like `length(x)` (ambiguous: json + string both export `length`) AND `uuid()` (unique to utils, but still bare). Use `string.length(x)`, `utils.uuid()`, etc. The rule is uniform regardless of whether the function is currently unique — that way mappings stay stable when future Flogo extensions add same-named functions in other packages.

When `mm` sees a qualified function call (`pkg.fn(...)`) inside the value, it adds `github.com/<...>/function/<pkg>` to the project's `imports[]` automatically. The defensive sweep inside `writeFlogoJSON` is a safety net that does the same scan over the entire project on every save — so even if you write a mapping via `set-attribute` or hand-edit, missing function imports get healed at the next save.

You **never** need `fda ai github.com/.../function/string` for functions — `mm` handles it.

**Discoverability:** when in doubt about a function's package, `fda lf <name>` lists every match with its qualified form, and `fda exp function <name>` shows the full signature + example.

## Pitfalls to avoid

0. **Forgetting to attach schemas (`sms`) to mapped activities.** Schemas are mandatory, not optional. Without them: VSCode UI shows raw JSON, drag-to-map is broken, `cm` can't catch type-shape mistakes. Run `sms` for every activity that appears in a mapping, on both sides. Use `--json-value-to-schema '<sample>'` if you don't have a hand-written schema yet.
1. **Don't use `set-attribute` for mapper fields when `make-mapping` exists.** `mm` proactively scans the value for function calls and adds the import; `sa` doesn't (the defensive sweep catches it eventually but the error is harder to trace).
2. **`$activity[Name]` must be UPSTREAM.** `cm` validates this. If you reference an activity that runs after the target, the runtime returns nothing.
3. **`$loop[name]` only works inside the matching `@foreach` scope.** Don't reference `$loop[items]` from outside the loop — `cm` flags this as `FOREACH_SCOPE_UNDEFINED`.
4. **Quote expression values.** Anything starting with `=`, `$`, `(`, etc. needs single-quotes around it in bash so the shell doesn't try to expand `$activity` / `$property`. Use `'=$activity[X].output.foo'`, not `="$activity[X]..."` (double-quotes still expand).
5. **`--foreach` is mapper-only.** For non-mapper activities, just use a regular mapping; loops aren't a thing on log/rest/sleep/etc.
6. **Field names with spaces** (e.g. `Log Level` on the log activity) work — quote the path: `fda mm 'MainFlow.LogIt.input.Log Level' WARN -f $FILE`.
7. **`-j` suppresses the table.** Use it when piping into `jq`; drop it for human reading.
8. **`cm` returns success.** It exits 0 even when issues exist — read the `error/warning` count in the message, or use `-j` and parse the `validation` array.

## When to call which task

| You want to... | Short | Full task name                                                          |
|---|---|-------------------------------------------------------------------------|
| Discover all mappable fields in the project | `dmf` | `describe-mapping-fields`                                               |
| Discover sources for a specific target field | `lms <field>` | `list-mapping-sources`                                                  |
| Discover available functions | `lf` | `list-functions`                                                        |
| Discover settable fields on any entity | `exp` | `explain` (works for `function` / `activity` / `trigger` / `connector`) |
| Set a mapping value | `mm <field> <value>` | `make-mapping`                                                          |
| Set up an @foreach loop scope | `mm <field> --foreach <expr> --as <iterName>` | `make-mapping` (with loop flags)                                        |
| Remove a mapping | `rmm <field>` | `remove-mapping`                                                        |
| Attach a schema to an activity (UI typed-tree) | `sms <flow>.<activity>[.<direction>] [<schema-name>] [--json-schema / --json-value-to-schema …]` | `set-mapping-schema`                                                    |
| Detach a schema from an activity | `rms <flow>.<activity>[.<direction>]` | `remove-mapping-schema`                                                 |
| List currently-set mappings | `lm` | `list-mappings`                                                         |
| Validate before build | `cm` | `check-mappings`                                                        |
| Wire a trigger handler ↔ flow (4-slot mutation) | `wth <flow> <trigger.handler>` | `wire-trigger-handler`                                                  |

Every task in the `mapping` category is listed above. Always end the session with `fda vm -f $FILE` before building — it's the cheapest way to catch what would otherwise be a runtime failure.
