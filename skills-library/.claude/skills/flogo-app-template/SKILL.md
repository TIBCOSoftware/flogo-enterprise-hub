---
name: flogo-app-template
description: Turn an AI-built Flogo app into a deterministic, parameterized app TEMPLATE by harvesting the fda commands recorded in its design history, then generate new apps from inputs (OpenAPI swagger + Excel mapping workbook + topic/URLs) with no AI in the loop. Use when the user asks for "app templates", "harvest the fda commands", "make this repeatable / deterministic", "generate apps from a swagger and a mapping spreadsheet", "script the FDA session", the BW Design Assistant "template" story, or wants many look-alike integration apps (one per API) that follow one pattern. Ships a verified REST (OpenAPI) → mapper → Kafka → HTTP 202 template.
user-invocable: true
---

> **Preflight:** `fda version` (TIBCO Flogo VS Code extension; `fda` ships inside it) and `python -c "import openpyxl"` (`pip install openpyxl`). `flogobuild` is needed only for `--build`. Read `config.md` (next to this skill) first; the scripts read `FLOGOBUILD_PATH` / `FLOGOBUILD_CONTEXT_NAME` from it. Print each CLI's path and version before running it.

Three stages. **AI is used only in stage 1.**

```
1. GOLDEN  (AI + fda, history ON)   prompts -> golden .flogo + .flogodesign/history/<app>/history.json
2. HARVEST (scripts/harvest.py)     history + golden params.json -> <pattern>.fdatemplate (${PARAMS}, @foreach blocks)
3. GENERATE(scripts/generate_app.py) template + <app>.params.json (swagger, workbook, topic, brokers, port)
                                     -> <App>.flogo + build-<App>.sh (exact fda commands) + fda cm
```

Ready-made: `templates/rest-to-kafka.fdatemplate` + `templates/rest-to-kafka.pattern-guide.md` (the pattern rules and mapping notation). For the REST→Kafka pattern you can go straight to stage 3.

## Stage 1: build the golden app with history on
- Work in a fresh folder under `FLOGO_APPS_DIR`. **Turn history on before the first command:** `export FLOGO_DESIGN_ENABLE_HISTORY=true` (or `-H` on every call). Use the `fda`, `fda-mapping` and `mapping-from-excel` skills for the actual edits.
- **Keep the session clean.** Every successful mutating command is recorded, including detours. If you take a wrong turn, delete the `.flogo` and `.flogodesign/` and rebuild, or the detour ends up in the template. Read-only commands (`dp`, `lms`, `cm`, `sh`) are not recorded.
- Use **fixed activity and connection names** (the pattern's vocabulary) and put every environment value in an **app property**. Only names that differ per app should become parameters.
- Do **all** mappings with `fda mm`, one command per field. The repeated per-row commands are what the harvester turns into `@foreach` blocks.
- Show the log: `fda sh -f <App>.flogo`. Roll back with `fda rhi <step>`. FDA's own raw export is `fda sch <file>.sh`.

## Stage 2: harvest
```bash
python scripts/harvest.py --flogo <golden>/<App>.flogo --params <golden-inputs>/<app>.params.json --out templates/<pattern>.fdatemplate
```
What it fixes in FDA's raw `script-history`, and why a raw export alone isn't a template:
1. **Quoting is lost.** History stores argv space-joined (`mm X =string.concat(a, "-", b)`), so a raw replay breaks on spaces and lets the shell expand `$property`. The harvester re-splits each command using per-task positional arity (the last positional is greedy) plus known flags, then re-quotes it.
2. **`cp` is not recorded.** History starts at `0_<App>.initial.flogo`, so the harvester prepends `cp ${APP_NAME} ${APP_DESCRIPTION}`.
3. **Raw scripts call `flogodesign`**, which isn't on PATH. Generated scripts resolve `$FDA` instead.
4. **Values are concrete.** The golden app's values (from `fdalib.derive(params)`) are replaced with `${PARAM}`, longest literal first, with token boundaries. Opaque base64 (the flow layout) is left alone.
5. **Per-row mapping commands** (`BLOCKS` in `harvest.py`) collapse into `@foreach EVENT_MAPPING` / `@foreach REPLY_MAPPING` blocks fed from the workbook. Whole-argument JSON schemas (`ARG_RULES`) become `${EVENT_SCHEMA}` / `${REPLY_SCHEMA}`.

## Stage 3: generate
```bash
python scripts/generate_app.py --template templates/rest-to-kafka.fdatemplate --params <inputs>/<app>.params.json [--out generated] [--force] [--build] [--dry-run]
python scripts/compare_flogo.py <golden>.flogo generated/<App>/<App>.flogo     # determinism check (ignores fda-generated UUIDs)
```
`<app>.params.json` keys: `appName, description, swagger (OpenAPI 3 JSON, operationId required), operationId, mappingWorkbook, eventSchemaName, keyField, topic, brokers, httpPort`. Paths are relative to the params file.

The workbook has two sheets, **Event** and **Response**, with columns *Target Field | Type | Mapping Rule | Description*. Notation: `request.<field>`, `event.<field>` (Response sheet), `[Event.Topic]`, `"literal"`, `UPPER/LOWER/TRIM/concat/newUUID/now/asString/asInt/asNumber`, and `=<raw Flogo expression>`. `scripts/make_mapping_xlsx.py --out <dir>` writes two sample workbooks to copy from. If the user gives the mapping as **prose**, draft the workbook for them to review (this is the only AI step at generate time), then generate.

Validation happens before any `fda` call. Unknown `request.*` fields (checked against the swagger request body), Response targets missing from the 2xx reply, unknown functions or properties, and a `keyField` missing from the Event sheet all fail with the row number.

## Verified gotchas (fda 0.9.3)
- `fda cas <Spec> logReply` names the trigger after the spec **title** with non-alphanumerics replaced by `_`, and the flow `<operationId>_<METHOD>`. It builds `StartActivity → Log_API → ConfigureHTTPResponse → Return` and lays the flow out.
- To insert activities into the cas flow: `rl <flow> Log_API ConfigureHTTPResponse`, then `ca … --doNotLink` + `cl`. **`ca` adds no layout position** (and `ff` is unsafe), so set the whole layout with `fda sa flow '<flow>.fe_metadata' <base64 of {"Activity":{"x":..,"y":..},...}>`. It's a recorded fda command, so it harvests verbatim.
- **Link order or the designer deletes `Return` (verified 2026-10-15).** The VS Code designer **saves a `.flogo` the moment it opens it** (even with Don't Save). While loading, it silently drops any activity whose incoming link is stored before that activity's own predecessor is connected. `cas` stores `ConfigureHTTPResponse → Return` as link #2, so after inserting activities the designer deletes `Return`. The flow then never replies: the REST trigger answers `200 null`, although the Kafka publish still runs. Fix with fda as the **last** structural step: `rl <flow> ConfigureHTTPResponse Return` then `cl <flow> ConfigureHTTPResponse Return`, so the link is stored last in flow order. (The stray empty `Return.input:{mappings:[]}` that cas writes is **not** the cause; the designer tidies it. And `fda rmm …Return.input.mappings` is wrong: it deletes `settings.mappings`.) After a designer save, the golden file differs from the template output. Restore it with `fda rhi <last step>` before running `compare_flogo.py`.
- cas leaves `ConfigureHTTPResponse.input.input` empty when the 2xx schema is a `$ref`. Create a `{"type":"object","properties":{"body":<reply schema>}}` schema with `fda cs`, attach it with `sa activity '<flow>.ConfigureHTTPResponse.schemas.input.input' <Schema> -C schema --force`, set `input.trigger` to the trigger name, then `mm …input.input.mapping.body.<field>` one field at a time.
- HTTP port as a property: `cap HTTP.Port number <n>` + `sa trigger '<Trigger>.settings.port' '=$property["HTTP.Port"]'` (the runtime honours it).
- Kafka: `cc EventBus con_kafka`, `sa connection EventBus.settings.brokers '=$property["Kafka.EventBus.Brokers"]'`, `sa connection EventBus.settings.authMode None` (local). Then `ca <flow> PublishEvent kafka_producer "…" -C EventBus --doNotLink` binds `conn://<uuid>` correctly. Set `topic`, `key` and `stringValue` (`=coerce.toString($activity[BuildEvent].output)`) with `mm`.

## Adding another pattern
Build a golden app for it (stage 1). Then in `fdalib.derive()`, add the parameters your pattern needs, and in `harvest.py`, adjust `BLOCKS` (which commands repeat per input row), `ARG_RULES` (whole-argument values) and `LITERAL_PARAMS`. Harvest, then prove it by regenerating the golden app and running `compare_flogo.py`. It must report `IDENTICAL`.
