---
name: fda
description: fda (Flogo Design Assistant, the flogodesign-cli bundled in the TIBCO Flogo VS Code extension) — a command line tool to create and modify TIBCO Flogo Integration Applications (both Flogo 2.x and Flogo 3.x)
user-invocable: true
---

# fda (Flogo Design Assistant) — Flogo 2.x and 3.x app development

Everything in this skill applies to **both Flogo 2.x and Flogo 3.x** apps unless a line explicitly
says otherwise.

Build Flogo apps by driving `flogodesign-cli.exe` tasks. **Never hand-edit `.flogo` / `app.fgmd`
JSON** — the CLI keeps imports, the `contrib` blob, links and mappings consistent; hand edits
desynchronise them or are overwritten on the next `fda` write. Use the dedicated tasks.

## 1. Prerequisite: `$FDA` is already resolved

**First:** follow AGENT.md → "Resolving the `fda` CLI" (discover → decide Flogo 2.x/3.x → choose +
report CLI version) before using this skill.

`AGENT.md` owns locating the binary and reporting its version. By the time this skill runs, `$FDA`
holds the full path to `flogodesign-cli.exe`. If it does not, go do that first — do not guess a path.

**Invoking the CLI:** in this skill and every other skill, `fda …` in examples is shorthand for
`"$FDA" …` — the quoted, resolved path. Always run `"$FDA" …`. Never run a bare `fda`, and never rely
on the persistent `fda` shell function from AGENT.md: it always picks the newest **2.x** install and
ignores the Flogo version and CLI you chose.

## 2. Global options (apply to every task)

| Flag | Short | Env var | Meaning |
|---|---|---|---|
| `--file` | `-f` | `FLOGO_DESIGN_FLOGO_FILE` | Target project. **2.x CLI:** a Flogo file (default `flogo-project.flogo`). **3.x CLI:** a project directory, e.g. `MyProject` (default `flogo-project/`, resolved to `flogo-project/app.fgmd`) |
| `--type` | `-t` | | Type of the Flogo file (default `flow`) |
| `--json` | `-j` | | JSON output — only when you need the exact structure (see "Reading output") |
| `--configuration` | `-c` | `FLOGO_DESIGN_CONFIG_FILE` | Layer a config file over the bundled defaults |
| `--history` | `-H` | `FLOGO_DESIGN_ENABLE_HISTORY` | Record task history for the project |

There is **no `--help` flag**; help is the `fda help [<task>]` task. When to use it: see section 10.

**Reading output:** Use the default readable output, and narrow it with the task's own filter
argument (`fda lct sql`, `fda lat string`) or `fda da <type> [<selector>]`. Don't pipe into external
tools like `jq` or `grep` — they may not be installed. Use `-j` only when you need the exact JSON
structure, and read it directly.

**2.x vs 3.x project shape**

|                        | 2.x                     | 3.x                                  |
|---|---|---|
| `cp <name>` creates    | `<name>.flogo` (file)   | `<name>/app.fgmd` (folder)           |
| Later commands use `-f <app>` | `<app>` = `<name>.flogo` | `<app>` = `<name>`           |
| Default with no `-f`   | `flogo-project.flogo`   | `flogo-project/app.fgmd`             |

- **`-T` / `--flogo-type`:** the CLI creates its own version by default, so omit `-T`. Pass it only
  for cross-type creation: `-T 2x`/`-T 2` from a 3.x CLI, `-T 3x`/`-T 3` from a 2.x CLI.
- **Never pass `-f` on `create-project`.** The path's shape overrides the version (`app.fgmd` → 3.x,
  `.flogo` → 2.x, plain name → 2.x).
- **Run `create-project` from inside the apps folder (`FLOGO_APPS_DIR`).** Without `-f`, `cp` creates the
  project in the *current directory*. Run it from the repo root and the app lands outside the apps folder, so
  every later `-f <FLOGO_APPS_DIR>/…` command points at a file that doesn't exist. `cd` into the folder first
  (create it if missing): `mkdir -p "<FLOGO_APPS_DIR>" && cd "<FLOGO_APPS_DIR>" && "$FDA" cp <name> "<description>"`.
- **Always pass `-f` on every later command.** Without it, read-only tasks fail, and tasks that write
  silently auto-create the default project.

## 3. Working rules

- **Discover before creating.** `list-trigger-types`, `list-activity-types`, `list-connection-types`,
  `list-functions`, `explain <type> <name>`. Type strings are validated — never guess one.
- **Read before mapping.** `list-mapping-sources` for what you can map *from*,
  `describe-mapping-fields` for what can be mapped *to*.
- **`dmf` before `mm`.**  Always run `dmf <flow>.<activity>` and use its exact path as the `mm`
  field — mapping path structures differ by activity type.
- **`lf` / `exp function` before using any function in `mm`.** Run `fda exp function <package>`
  to confirm the function exists and its exact name before using it. Never guess — e.g.
  `coerce.toNumber()` does not exist; the correct function is `coerce.toInt()`.
- **Prefer the composite.** `wire-trigger-handler` does the four-slot trigger↔flow wiring in one call;
  don't hand-wire those slots.
- **Format after adding activities.** `create-activity` and `cms` place items at a default position that overlaps
  existing activities in the designer. Run `format-flow <flow-name> auto` after adding activities (`--all` after
  `cms`) to fix the layout.
  Afterwards, confirm `fda dp -f <app>` still lists every activity (older CLIs could drop some, e.g.
  `actreturn`); if any are missing, restore the file and skip `format-flow`.
- **Validate after mutating.** `check-mappings`, `check`, `analyze-project` — after the change, not
  only at the very end.
- **Report with `describe-project`.**
- **After `cp`, run `dp` to check if a flow exists — if not, run `cf` before `ct`/`cth`.**
- **After `cth`, always run `wth` to wire the trigger handler to the flow.** Without wiring, the flow
  cannot receive trigger data or send replies. The only exception is `tr_timer`, which carries no
  payloads. Do NOT manually run `wth` after `cas` or `cms` — both are self-contained skeleton builders
  that call `wth` internally.
- **After `wth`, read back `fda da flow <flow>.metadata` and confirm every reply field you plan to map exists.**

### Discover before you mutate

Always start a non-trivial task with the matching `list-*` / `describe-*` / `explain` task to confirm
the entity exists and to see its real shape:

```bash
fda dp -f <app>                              # project summary, incl. flow names
fda da activity Flow1.MyActivity -f <app>    # one activity's full attributes
fda lct sql                                # connection types matching "sql"
fda lat string                             # activity types matching "string"
fda lf string                              # functions matching "string" (last line gives the count)
fda exp activity log                       # full input-field list for log
fda exp function string                    # all functions in the string package
```

**To verify app properties or connection values, use `fda da property -f <app>` / `fda da connection
-f <app>` — never inspect the raw JSON with `python3`, `cat`, or `jq`.**

### Mutate idempotently, validate after

CRUD tasks are idempotent for create (existing entries get re-bound to the new config) but error on
remove if the target doesn't exist. After a sequence of edits, run a validator and a re-read:

```bash
fda cf MyFlow -f <app>
fda ca MyFlow Mapper mapper -f <app>
fda mm 'MyFlow.Mapper.input.input.mapping.uuid' '=utils.uuid()' -f <app>
fda cm -f <app>                                    # sweep for broken refs / missing imports
fda check activity MyFlow.Mapper exists -f <app>   # script-friendly assertion
```

> A "success" message + a clean `fda cm` do NOT guarantee the designer will render the result
> correctly. A few classes of bug (wrong connection binding in multi-connection apps, a mapping whose
> schema doesn't declare the mapped keys) are written silently and pass every static check, yet break
> in the VSCode designer. For anything structural — connection bindings, parameterized-activity schemas,
> mapping shapes — **read the value back and compare against a known-good, designer-authored app**.

### Mappings are first-class

The path shape is `<flow>.<activity>.input.input.mapping.<dotted>` for mapper activities and
`<flow>.<activity>.input.<field>` for any other activity (log, rest, etc.). Sources have a fixed
syntax — `$flowctx["X"]`, `$property["X"]`, `$activity[Name].output.X`, `$loop[name].X` — and
function calls auto-add the matching package to the project's `imports`.

```bash
fda dmf -f <app>
fda lms 'MyFlow.Mapper.input.input.mapping.orderId' -f <app>
fda mm 'MyFlow.Mapper.input.input.mapping.customerId' 1234 --type number -f <app>
fda mm 'MyFlow.Mapper.input.input.mapping.tag' '=$property["Env"]' -f <app>
fda mm 'MyFlow.Mapper.input.input.mapping.lineItems' \
       --foreach '$activity[Src].output.items' --as items -f <app>
fda mm 'MyFlow.Mapper.input.input.mapping.lineItems.sku' '=$loop[items].sku' -f <app>
fda cm -f <app>
```

## 4. Task reference and usage signatures

### general

| Task | Alias | Description | Usage |
|---|---|---|---|
| `version` | `v` | Display version | `fda version` |
| `help` | `h` | Show help | `fda help [<task>]` |
| `explain` | `exp` | Explain a function, activity, connector or trigger | `fda explain <type(function\|activity\|connector\|trigger)> <name>` |
| `show-design-config` | `sdc` | Show current Flogo Design configuration | `fda show-design-config [<config-pointer>]` |
| `export-design-config` | `edc` | Export Flogo Design configuration to file | `fda export-design-config [<config-file>] [--mode SINGLE_FILE\|MULTI_FILE]` |
| `list-flogo-projects` | `ls`, `lfp` | List flogo project files in current directory | `fda list-flogo-projects [--include-history-folder]` |
| `analyze-vscode-extension` | `ave` | Check for unknown imports in VSCode extension | `fda analyze-vscode-extension [<folder>] [--toConfigFile <path>] [--type(-T) <all\|activity\|trigger\|connection\|contribution\|function>] [--filter(-F) <str>] [--ignoreDefaultConfig] [--ignoreOverlay] [--customOverlayFile(-O) <path>] [--flogoVersion(-V) <ver>]` |
| `model-context-protocol` | `mcp` | Start an MCP server for Flogo development | `fda model-context-protocol [<stdio\|http\|sse>] [<port>] [--buildFlogoLocation <path>] [--multiFileMode]` |

### process-development

| Task | Alias | Description | Usage |
|---|---|---|---|
| `create-project` | `cp` | Create a new Flogo Project | `fda cp <name> <description> [--flogo-type (-T) 2x\|2\|3x\|3]` |
| `describe-project` | `dp` | Describe a Flogo Project | `fda dp [--json]` |
| `create-flow` | `cf` | Create a new Flogo Flow | `fda cf <flow-name> <flow-description>` |
| `remove-flow` | `rf` | Remove a Flogo Flow | `fda rf <flow-name>` |
| `create-activity` | `ca`, `aa`, `add-activity` | Add a Flogo Activity | `fda ca <flow> <name> <type> <description> [--doNotLink] [--connection (-C) <name>]` |
| `change-activity-type` | `cat` | Change activity type | `fda cat <flow> <activity> <new-type>` |
| `create-link` | `cl` | Link two activities in a flow | `fda cl <flow> <from-activity> <to-activity>` |
| `remove-link` | `rl` | Remove a link between activities | `fda rl <flow> <from-activity> <to-activity>` |
| `format-flow` | `ff` | Format a flow layout | `fda ff <flow> <format(auto\|snake\|dagre\|straight\|straight-down\|stairs)> [--all]` |
| `create-api-skeleton` | `cas` | Create flows from an API definition | `fda cas <spec-name> <skeleton(none\|logReply)>` |
| `create-mcp-skeleton` | `cms` | Create flows for MCP from an API definition | `fda cms <spec-name> [--readOnly] [--methodFilter <GET,POST,...>] [--token <token>]` |
| `describe-imports` | `di` | Describe imports in a project | `fda di [<filter>] [--json]` |
| `add-import` | `ai` | Add an import | `fda ai [<import-url>] [--alias <alias>] [--force (-F)]` |
| `remove-import` | `ri` | Remove an import | `fda ri <import-identifier> [--force (-F)]` |
| `describe-contributions` | `dco` | Describe contributions | `fda dco [<filter>] [--json]` |
| `add-contribution` | `aco` | Add a contribution | `fda aco <identifier> [--force (-F)]` |
| `remove-contribution` | `rco` | Remove a contribution | `fda rco <identifier> [--force (-F)]` |
| `describe-attributes` | `da` | Describe attributes of a Flogo item | `fda da <item-type(flow\|activity\|trigger\|handler\|connection\|property\|any)> [<selector>] [--json]` (selector required for `handler`) |
| `analyze-project` | `ap` | Check for unknown imports | `fda ap [--toConfigFile <path>]` |

### data-management

| Task | Alias | Description | Usage |
|---|---|---|---|
| `create-schema` | `cs` | Create a schema | `fda cs <schema-name> <json-schema> [--jsonSchemaFile <path>]` |
| `update-schema` | `us` | Add or remove a property in a schema | `fda us <schema-name> [--add-property (-ap) <name:type>] [--remove-property (-rp) <name>] [--required (-R)]` |
| `remove-schema` | `rs` | Remove a schema | `fda rs <schema-name>` |
| `create-spec` | `csp` | Create an API specification | `fda csp <spec-name> <spec-json> [--specFile <path>]` |
| `remove-spec` | `rsp` | Remove a spec | `fda rsp <spec-name>` |
| `create-app-property` | `cap` | Create an application property | `fda cap <[group.]name> <type(string\|number\|boolean)> <value>` |
| `remove-app-property` | `rap` | Remove an application property | `fda rap <[group.]name>` |

### connectivity

| Task | Alias | Description | Usage |
|---|---|---|---|
| `create-trigger` | `ct` | Create a new trigger | `fda ct <trigger-id> <trigger-type> <description> [--connection <name>]` |
| `create-trigger-handler` | `cth` | Create a trigger handler | `fda cth <flow> <trigger-id> <description> [--restResourcePath <path>] [--restHandlerMethod <GET\|POST\|...>] [--mcpHandlerType <Tool\|Resource\|Prompt>] [--mcpHandlerName <name>] [--mcpHandlerDescription <desc>]` |
| `remove-trigger` | `rt` | Remove a trigger | `fda rt <trigger-id>` |
| `remove-trigger-handler` | `rth` | Remove a trigger handler | `fda rth <trigger-id> <handler-name>` |
| `create-connection` | `cc` | Create a new connector | `fda cc <connection-name> <connection-type>` |
| `remove-connection` | `rc` | Remove a connection | `fda rc <connection-name>` |
| `list-trigger-types` | `ltt` | List possible trigger types | `fda ltt [filter] [--json]` |
| `list-activity-types` | `lat` | List possible activity types | `fda lat [filter] [--json]` |
| `list-connection-types` | `lct` | List possible connection types | `fda lct [filter] [--json]` |
| `list-contributions` | `lco` | List configured contributions | `fda lco [filter] [--json]` |
| `list-types` | `lt` | List all types known to the CLI | `fda lt [filter] [--json]` |

### testing

| Task | Alias | Description | Usage |
|---|---|---|---|
| `check` | `ch`, `va`, `validate` | Check validity of a Flogo object | `fda ch <type> <name> <validation(exists\|not-exists\|has-correct-value)> [<value>]` |
| `create-test-file` | `ctf` | Create a new test file | `fda ctf [--test-file (-s) <name>]` |
| `describe-test-file` | `dt` | Describe a test file | `fda dt [--test-file (-s) <name>] [--json]` |
| `create-test-suite` | `cts` | Create a test suite | `fda cts <suite-name> [--test-file (-s) <name>]` |
| `create-test-case` | `ctc` | Create a test case | `fda ctc <case-name> <flow> <description> <flow-inputs-json> [--test-file (-s) <name>]` |
| `create-assertion` | `cass`, `ass`, `add-assertion` | Add an assertion to a test case | `fda cass <case-name> <location> <type> <name> <value> [--test-file (-s) <name>]` |
| `add-test-case-to-suite` | `ats` | Add test case to a suite | `fda ats <case-name> <suite-name> [--test-file (-s) <name>]` |

### mapping

| Task | Alias | Description | Usage |
|---|---|---|---|
| `list-functions` | `lf` | List Flogo functions | `fda lf [<filter>]` |
| `describe-mapping-fields` | `dmf` | List all mappable fields (what *can* be mapped) | `fda dmf [<filter>]` |
| `list-mapping-sources` | `lms` | List mapping sources for a target (what to map *from*) | `fda lms <mapping-field> [<filter>]` |
| `list-mappings` | `lm` | List currently-set mappings (what *is* mapped) | `fda lm [<filter>]` |
| `check-mappings` | `cm`, `validate-mappings` | Check mappings (refs, imports, `@foreach` scopes) | `fda cm [<filter>] [--verbose (-v)]` |
| `remove-mapping` | `rmm` | Remove a mapping entry | `fda rmm <field>` |
| `set-mapping-schema` | `sms` | Attach a JSON Schema to a mappable activity or flow I/O | `fda sms <flow.activity[.direction]\|flow.<input\|output\|both>> [<schema-name>] [--json-schema (-js) <json>] [--json-schema-file (-jsf) <path>] [--json-value-to-schema (-jvs) <sample-json>] [--json-value-to-schema-file (-jvf) <path>] [--field (-fd) <name>] [--force (-F)]` |
| `remove-mapping-schema` | `rms` | Detach a JSON Schema from a mappable activity | `fda rms <flow.activity[.direction]> [--field (-fd) <name>]` |
| `update-mapping-schema` | `ums` | Add or remove a property in an activity's schema | `fda ums <flow.activity[.direction]\|flow.<input\|output\|both>> [--add-property (-ap) <name:type>] [--remove-property (-rp) <name>] [--required (-R)] [--field (-fd) <name>]` |

### history

| Task | Alias | Description | Usage |
|---|---|---|---|
| `show-history` | `sh` | Show history of executed tasks | `fda sh [<task-name>] [--all (-a)] [--json]` |
| `restore-history` | `rhi` | Restore app to a version in history | `fda rhi <task-name-or-number>` |
| `script-history` | `sch` | Create a script from historical commands | `fda sch <script-file>` |

History is only recorded when `-H` was passed on the originating commands (or
`FLOGO_DESIGN_ENABLE_HISTORY=true`).

---

## 5. Detailed tasks

### `set-attribute` (`sa`, `sc`, `set-configuration`)

```
fda sa <item-type> <item-selector> <value> [--jsonValue <json>] [--jsonFile <file>] [--configType (-C) <type>] [--force (-F)]
```

**item-type:** `flow`, `activity`, `trigger`, `handler`, `connection`, `property`, `any`

**Selector patterns:**
- **flow:** `<flow>.<configuration>.*`
- **activity:** `<flow>.<activity>.<configuration>.*`
- **trigger:** `<trigger-id>.<configuration>.*`
- **handler:** `<trigger-id>.<handler>.<configuration>.*`
- **connection:** `<connection>.<configuration>.*`
- **property:** `<property-name>.*`

**configType (-C):** `string`, `number`, `boolean`, `spec` (writes `spec://<id>`),
`app-property` (writes `=$property["<name>"]`), `schema` (writes `schema://<name>`),
`connection` (writes `conn://<uuid>` in 2.x, `conn://<ConnName>.fgconn` in 3.x)

**For `sa property`, use the bare property name as the selector** (e.g., `AppName`), not
`AppName.value`. The selector resolves to the property's value directly — appending `.value` or
`.type` causes a "Property not found" error.

**Always pass `-C <type>` when using `sa` for non-string values.** `sa` defaults to writing every
value as a string (e.g. `"true"` instead of `true`, `"200"` instead of `200`). The UI won't
recognise the value if the type is wrong — boolean toggles stay unset, number fields show as text.
Use `-C boolean` for true/false and `-C number` for numeric values.

```bash
fda sa flow MyFlow.description "Processes signup" -f <app>
fda sa activity MainFlow.Log.input.message "Hello World" -f <app>
fda sa activity Flow1.Log1.input.flowInfo true -C boolean -f <app>
fda sa connection EMS.settings.userName EMSAdmin -f <app>
fda sa trigger MyTrigger.settings.swagger MySpec -C spec -f <app>
fda sa trigger MyTrigger.settings.conn MyConnection -C connection -f <app>
fda sa trigger MyTrigger.settings.schema CustomerSchema -C schema -f <app>
```

---

### `wire-trigger-handler` (`wth`)

```
fda wth <flow> <trigger.handler> [flags]
```

| Flag | Short | Description |
|---|---|---|
| `--inputs-only` | `-io` | Wire only request side (skip reply) |
| `--reply-only` | `-ro` | Wire only response side (skip request) |
| `--input` | `-in` | Override input field — `name[:type]` (repeatable, comma-separated) |
| `--output` | `-ou` | Override output field — `name[:type]` (repeatable, comma-separated) |
| `--force` | `-F` | Overwrite existing wiring |
| `--input-schema` | `-is` | Existing schema name for input |
| `--input-schema-from-json` | `-isj` | Sample JSON to derive input schema |
| `--input-schema-from-json-file` | `-isjf` | Path to sample-JSON file for input side |
| `--output-schema` | `-os` | Existing schema name for output |
| `--output-schema-from-json` | `-osj` | Sample JSON to derive output schema |
| `--output-schema-from-json-file` | `-osjf` | Path to sample-JSON file for output side |
| `--input-mapping` | `-im` | Override action.input mapping template |
| `--reply-mapping` | `-rm` | Override reply mapping template |
| `--no-auto-derive-output-schema` | `-nad` | Disable auto-derivation of output schema from connected mapper |

Timer triggers skip wiring by default. Skip-if-already-wired — pass `--force` to overwrite.

`wth` propagates JSON-Schema to the four typed-tree slots when given `--output-schema` or
`--output-schema-from-json`. Without those flags, `wth` auto-derives the response schema from
a connected mapper's output schema if the actreturn binds one. Disable with
`--no-auto-derive-output-schema`.

| Trigger | Default shape |
|---|---|
| `tr_mcpserver` | `arguments` (any) → / `response` (object) ← |
| `tr_http` | `pathParams` + `queryParams` + `headers` + `content` → / `statusCode` + `responseBody` ← |
| `tr_timer` | none (timer doesn't carry payloads) |
| `tr_rest` | `headers` + `body` + `requestURI` + `method` → / `code` + `message` ← (`pathParams`/`queryParams` need explicit schema association + `--input` override) |

All reply mappings use the action-scope resolver `=$.<name>` (the runtime rejects `$flow` in
`handler.action.output` slots — `cm` catches strays as `RESOLVER_UNKNOWN`).

```bash
fda wth MyFlow Timer.MyFlow --inputs-only -f <app>
fda wth MyFlow HTTP.GetUsers --reply-only -f <app>
fda wth MyFlow X.Y --input id:string,qty:integer --output result:object -f <app>
```

---

### `make-mapping` (`mm`)

```
fda mm <field> [<value>] [--jsonValue (-jv) <json>] [--jsonValueFile (-jvf) <path>] [--type (-ty) <string|number|boolean>] [--foreach (-fe) <expr>] [--as (-as) <name>]
```

**field** selector: `<flow>.<activity>.input.input.mapping.<dotted-path>`
**value**: literal, or `=` prefix for expression. Function calls auto-add imports.

**Mapping values** (prefix with `=`):
- `$property["name"]` — app property
- `$flowctx["name"]` — flow context var
- `$activity[Name].output.field` — upstream activity output (must be upstream via links)
- `$loop[iter].field` — inside a `@foreach` scope
- `$.field` — inside `handler.action.input/output` (runtime accepts **only** `$.` there)
- Functions like `string.concat(...)` — `make-mapping` adds the function import automatically

Use `--jsonValue '<json>'` (or `--jsonValueFile <path>`) when shells make a positional `{...}` value
clunky to express — the JSON is parsed and used as the mapping value. JSON arrays and objects passed as
the positional value are auto-detected and stored as native typed values (NOT as a string expression).

```bash
fda mm Flow.Mapper.input.input.mapping.id 1234 -f <app>
fda mm Flow.Mapper.input.input.mapping.name '=$property["AppName"]' -f <app>
fda mm Flow.Mapper.input.input.mapping.label '=string.concat("X-", $property["P1"])' -f <app>
# Static JSON-array literal — stored as a real array of objects
fda mm Flow.Sensors.input.input.mapping.readings '[{"sensor":"S1","value":75},{"sensor":"S2","value":20}]' -f <app>
# @foreach loop
fda mm Flow.Mapper.input.input.mapping.items --foreach '$activity[Src].output.items' --as items -f <app>
fda mm Flow.Mapper.input.input.mapping.items.code '=$loop[items].sku' -f <app>
```

---

### `set-mapping-schema` (`sms`) — flow scope

In addition to the activity scope (`<flow>.<activity>[.<direction>]`), `sms` supports **flow scope**
via selectors `<flow>.input` / `<flow>.output` / `<flow>.both`. This targets the flow's own
`metadata.input/output` — the "Flow Inputs & Outputs" panel in the VSCode extension. The supplied
JSON Schema is walked and one entry is emitted per top-level property; the full schema is also
stringified into `flow.metadata.fe_metadata` for the VSCode JSON-Schema view to round-trip.

```bash
# Flow input schema
fda sms MyFlow.input --json-schema '{"type":"object","properties":{"body":{"type":"object","properties":{"msg":{"type":"string"}}},"method":{"type":"string"}}}' -f <app>

# Flow output schema derived from a sample
fda sms MyFlow.output --json-value-to-schema '{"code":200,"data":{"outputMessage":"hi"}}' -f <app>
```

`update-mapping-schema` (`ums`) also supports flow scope — updates the flow's own input/output
metadata, regenerating both the runtime `metadata.<side>[]` array and the designer
`metadata.fe_metadata.<side>` schema in lockstep:

```bash
fda ums MyFlow.input --add-property orderId:string --required -f <app>
```

---

## 6. Picking a trigger

The trigger choice shapes the whole flow; getting it wrong leads to runtime panics that no static
check catches before building.

| Trigger | When to use | Needs |
|---|---|---|
| `tr_rest` (TIBCO REST) | The user says "REST" or the prompt/image mentions a REST API — use this regardless of whether a swagger spec exists. If the user provides a spec, pair with `cas` (`create-api-skeleton`). Without a swagger, `tr_rest` still works — do NOT fall back to `tr_http`. | Configure method/path via handler settings. Optionally `settings.swagger` if user provides a spec. |
| `tr_http` (project-flogo HTTP, mode: Data) | Only when the user explicitly says "HTTP trigger" | Wire `handler.reply.{statusCode, responseBody}` from the upstream `actreturn` output, otherwise the response is HTTP 0 and the runtime panics with `invalid WriteHeader code 0`. `wth` seeds `reply.statusCode = 200` and `reply.responseBody = ""` as safe defaults, and `cm` flags gaps as `TR_HTTP_REPLY_STATUSCODE_ZERO` / `HTTP_TRIGGER_REPLY_UNWIRED`. |
| `tr_timer` | Periodic invocation; no I/O coupling | Just `Repeating` / `Time Interval` / `Interval Unit` settings. |

Quick rule: **prompt/image says "REST" or "Receive HTTP Message" → `tr_rest`** (no swagger needed).
**User explicitly provides a spec → `cas` with `tr_rest`.** **User explicitly says "HTTP trigger" →
`tr_http`.** Never auto-create a swagger spec. Never fall back to `tr_http` just because no spec
exists. If `cm` reports `TR_REST_NO_SWAGGER` and the user didn't provide a spec, silently ignore it.

## 7. Setting schemas on trigger handlers (prerequisite for `wth`)

`wth` only copies schemas that are already set on the trigger handler — it does not discover
application-level schemas on its own. Fields outside a trigger's default wiring (e.g. `tr_rest`
`pathParams` / `queryParams`) require schemas to be explicitly associated with the handler's output
fields before `wth` can propagate them to `flow.metadata.input`.

**Never use `-C schema` on `pathParams` or `queryParams` handler schemas** — it writes a `schema://`
reference that panics at runtime (`parameter.go` type assertion). Use `--jsonFile` with the
`{type, value, fe_metadata}` envelope instead. `-C schema` is fine for `body`, `headers`, and
`reply` schemas.

```bash
# pathParams / queryParams — must use inline envelope
fda sa handler "<trigger>.<handler>.schemas.output.<field>" --jsonFile <file.json> --force -f <app>
# body / headers / reply — can use -C schema
fda sa handler "<trigger>.<handler>.schemas.output.<field>" <schema_name> -C schema --force -f <app>
```

### `tr_rest` — schema association required before `wth`

`tr_rest` has default wiring for `headers`, `body`, `requestURI`, `method` → and `code`, `message` ←.
For extra fields (`pathParams`, `queryParams`), create a schema and associate it with the handler
output before running `wth`. **Only create and associate schemas for the fields the API actually
needs** — skip the rest:

| Output field | When needed | Flow access after wiring |
|---|---|---|
| `pathParams` | Resource path has `{paramName}` placeholders | `$flow.pathParams.<name>` |
| `queryParams` | API accepts `?key=value` query parameters | `$flow.queryParams.<name>` |
| `headers` | Flow needs request headers (e.g. Authorization) | `$flow.headers.<name>` |
| `body` | POST / PUT / PATCH with a request body | `$flow.body.<name>` |

#### Steps — example: GET `/books/{id}?genre=fiction` (needs pathParams + queryParams)

**Step 1.** Write inline schema JSON files and set on handler output (repeat per needed field).
Each file must use the `{type, value, fe_metadata}` envelope:

```bash
# pathparams.json → {"type":"json","value":"{\"$schema\":\"http://json-schema.org/draft-04/schema#\",\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}","fe_metadata":"[{\"parameterName\":\"id\",\"repeating\":\"false\",\"type\":\"string\",\"required\":\"true\"}]"}
fda sa handler "$TRIGGER.$HANDLER.schemas.output.pathParams" --jsonFile pathparams.json --force -f <app>

# queryparams.json → {"type":"json","value":"{\"$schema\":\"http://json-schema.org/draft-04/schema#\",\"type\":\"object\",\"properties\":{\"genre\":{\"type\":\"string\"}}}","fe_metadata":"[{\"parameterName\":\"genre\",\"repeating\":\"false\",\"type\":\"string\",\"required\":\"false\"}]"}
fda sa handler "$TRIGGER.$HANDLER.schemas.output.queryParams" --jsonFile queryparams.json --force -f <app>
```

**Step 2a.** Run `wth` without `--input` to discover default fields and types:

```bash
fda wth "$FLOW" "$TRIGGER.$HANDLER" --force -f <app>
# Output → flow.metadata.input : headers:object, body:object, requestURI:string, method:string
```

**Step 2b.** Re-run `wth` with every default field from 2a's output (preserving name:type) **plus**
the extra fields, all **comma-separated in a single `--input`**:

```bash
fda wth "$FLOW" "$TRIGGER.$HANDLER" --force \
    --input headers:object,body:object,requestURI:string,method:string,pathParams:object,queryParams:object \
    -f <app>
```

**IMPORTANT:** Never hardcode field names or types in step 2b — always read them from 2a's
`flow.metadata.input` output. Different triggers produce different defaults, and types may vary.
Without the `:type` suffix (e.g. bare `--input fieldName`), fields are downgraded to `any`.

#### More examples — typed `body` and `headers`

Associate a schema on `body` or `headers` only when the flow needs **typed** field access
(e.g. `$flow.body.title` instead of a generic object):

```bash
fda cs BookRequest '{"type":"object","properties":{"title":{"type":"string"},"author":{"type":"string"}},"required":["title"]}' -f <app>
fda sa handler "$TRIGGER.$HANDLER.schemas.output.body" BookRequest -C schema --force -f <app>
```

**Note:** `-C schema` works for `body` and `headers` (the runtime handles them differently).
Only `pathParams` and `queryParams` require the inline `--jsonFile` envelope.

Then run Step 2a (discover defaults) and Step 2b (re-apply every default field with its `name:type`,
adding any extra `pathParams`/`queryParams` you associated).

- **3.x (until `wth` is fixed):** `wth` can't resolve `schema://` on `body`/`headers` — run all `wth` steps first, then `sa … -C schema`, then `fda sms <flow>.input` with every 2b field, keeping each field's schema and adding the full schema on that field.

### `tr_rest` — response schema on reply side

To bind a response schema to a REST trigger handler's reply, use `schemas.reply.data`:

```bash
fda sa handler "$TRIGGER.$HANDLER.schemas.reply.data" <ResponseSchemaName> -C schema --force -f <app>
```

The field name is `data` — **not** `responseBody` or `message`.

### Triggers that do NOT need this step

| Trigger | Auto-wired inputs |
|---|---|
| `tr_http` | `pathParams` + `queryParams` + `headers` + `content` |
| `tr_mcpserver` | `arguments` |
| `tr_timer` | none (no payloads) |

### Schema for non-REST trigger data (e.g. SQS `Message`, Kafka `jsonValue`)

`wth` can't add a schema to these fields, so add it in three steps:

1. `fda sa handler "<trigger>.<handler>.schemas.output.<field>" --jsonFile <schema.json> --force -f <app>`
2. `fda wth "<flow>" "<trigger>.<handler>" --force -f <app>` and note every input field and type it prints.
   If `<field>` is a list, re-run with `--input` listing **every** field from that output, changing only
   `<field>` to `array` (e.g. `--input <fieldA>:<typeA>,<field>:array,<fieldB>:<typeB>`). `--input` replaces
   the whole input list — passing `<field>:array` alone drops the trigger's other inputs.
3. `fda sms "<flow>.input" --json-schema '<schema>' -f <app>`, where the schema lists **every** field from step 2 with its type and gives the full schema only to `<field>`. Fields left out are removed from the flow.

- **Check the field's real type before step 2:** FDA's default type can be wrong (e.g. SQS `Message` is a list, not an object). Confirm it from the trigger's output in the designer, and if it's a list, map the whole field (`$flow.<field>`), not `$flow.<field>.<child>`.

## 8. Binding schemas on activity input fields (non-mapper activities)

For any activity with a schema-capable input field (visible via `fda exp activity <type>` — look for
fields like `jsonSchema`, `responseSchema`, etc.), bind the schema at `schemas.input.<fieldName>`:

```bash
fda sa activity "<flow>.<activity>.schemas.input.<fieldName>" <SchemaName> -C schema --force -f <app>
```

The `<fieldName>` must match the input field name from `exp`. **Do NOT** set `input.<fieldName>`
directly (UI toggle won't activate) or use `sms --field` (writes to the wrong key).

- **Output fields work the same way:** bind a response/output schema at `schemas.output.<fieldName>` (e.g. `responseBody`), using the same `sa … -C schema --force` command.

## 9. Common runtime failures (and how `fda cm` catches them)

`fda cm` is the layer between "build succeeded" and "first request crashes the engine". Run it before
every build. The rules below cover the failures most likely to bite:

| Symptom at runtime | cm code | Fix |
|---|---|---|
| `WriteHeader code 0` panic from an `actreturn` flow | `INPUT_VS_SETTINGS_MISWRITE` | `actreturn.mappings` lives under `settings`, not `input`. `mm` and `sa` rewrite the path automatically; legacy files trip this error. |
| None: `tr_rest` runs without a spec | `TR_REST_NO_SWAGGER` | Expected when the user gave no spec — ignore it (section 6). Add `settings.swagger` via `cas` only when the user provides one. |
| `function [length] is not installed` at runtime | `FUNCTION_AMBIGUOUS` / `FUNCTION_NOT_QUALIFIED` | **Always qualify function calls** with the package name (`string.length(...)`, `utils.uuid(...)`). `mm` rejects every bare call at write-time. |
| `error parsing expression '=$activity[…]'` inside an `@foreach` | `FOREACH_HAS_LEADING_EQUALS` | The `--foreach` value must NOT have a leading `=` — the `@foreach()` wrapper is itself the expression marker. `mm` strips the `=` proactively. |
| `failed to resolve activity attr 'output'` | `ACTIVITY_OUTPUT_LEAF_UNKNOWN` | Non-mapper activities expose top-level outputs by name (`responseBody`, `statusCode`, etc.), not a single `.output` object. `lms` enumerates the real outputs. |
| Handler created but flow doesn't receive request data / can't reply | `TRIGGER_HANDLER_UNWIRED` | A handler bound to a flow needs four mutations wired. Use `fda wth <flow> <trigger.handler>`. |
| UI shows mapping JSON as raw text instead of typed tree | `MAPPING_SCHEMA_REF_MISSING` / `MAPPING_SCHEMA_INLINE_MALFORMED` | Mappable activities need a schema attached at `activity.schemas.<dir>.<field>`. Use `fda sms`. |
| `FLOW_OUTPUT_VS_ACTION_OUTPUT_MISMATCH` | Keys mismatch | `flow.metadata.output[].name` and `handler.action.output` keys must align. |
| `FLOW_OUTPUT_VS_ACTRETURN_MISMATCH` | Keys mismatch | `actreturn.settings.mappings` keys must match `flow.metadata.output[].name`. |
| `TR_HTTP_REPLY_STATUSCODE_ZERO` | Guaranteed panic | tr_http handler with `reply.statusCode=0` and no `action.output.statusCode` mapping. |
| `EXPRESSION_LITERAL_LEAK` | Flag absorbed by parser | Literal mapping values start with a CLI flag (`--jsonValue`, `--type`, etc.). |

## 10. Things to avoid (common pitfalls)

### CLI usage

- **Don't run `help` commands.** Use the usage signatures in section 4 instead. Only use `help`
  if a command fails or a flag is missing from this file.
- **Don't use `--force` to get past an error.** It bypasses validation and can write malformed state.
  If a command fails without it, fix the cause. Check `list-types` when a type string is rejected.
  The ONLY places `--force` is required are: (1) `fda sa handler "...schemas.output.<field>" <name>
  -C schema --force` for schema association on trigger handler output, (2) `fda wth ... --force` to
  overwrite already-wired sides, and (3) `fda sa ... --force` to create an attribute path that doesn't
  exist yet. Every other `fda` command must be run WITHOUT `--force`.
- **Confirm before destructive tasks.** `restore-history` overwrites the project, and `remove-*`
  deletes without cascading cleanup. Ask the user first when the target is a real project.
- **Escape `/`-prefixed arguments in Git Bash.** MSYS auto-converts arguments starting with `/`
  (e.g. `/rec1`, `/api/v1`) into Windows paths (`C:/Program Files/Git/rec1`). Prefix the command
  with `MSYS_NO_PATHCONV=1` whenever an argument contains a leading slash — REST resource paths,
  context paths, and similar values are all affected.
- **Prefer file-based schema input over inline JSON.** When passing JSON schemas to commands like
  `create-schema`, `set-mapping-schema`, or `sms` (flow scope), use `--json-schema-file` /
  `--jsonSchemaFile` pointing to an existing schema file on disk rather than inlining large JSON
  strings on the command line. For simple flat schemas (1-2 levels), inline JSON is fine.
- **`fda cc` requires the full connection type name (e.g. `con_sqlserver`), not the short alias
  (e.g. `sqlserver`).** `fda cc MyConn sqlserver` fails — use `fda cc MyConn con_sqlserver`. Run
  `fda lct` to find the full type name.
- **Activity aliases use `<group>_<entity>`** for everything outside the `general`, `default`, and
  `ems` groups (e.g. `mysql_query`, `salesforce_delete`, `auditsafe_query` — not bare `query`).
  Connection / trigger aliases stay bare (`kafka`, `ems`, `mysql`). `fda lat <filter>` and
  `fda exp activity <name>` show the canonical name + alias.
- **`exp function <name>` has four modes** — `category.fnName` (qualified), bare unique name (works),
  bare ambiguous name (errors with disambiguation), and bare category name (expands to every function
  in the package). When in doubt, qualify with `category.`.
- **`check activity` uses just the activity name, not `flow.activity`.** Unlike `sa` and `da` which
  use `<flow>.<activity>`, `check activity` takes only the bare activity name (e.g. `fda ch activity
  Act1 exists`, not `fda ch activity MainFlow.Act1 exists`). The `flow.activity` format causes a
  false "does not exist" result.
- **`check link` puts the flow name in `<name>` and `from.to` in `<value>`.** Format:
  `fda ch link <flow> exists <from>.<to>` — e.g. `fda ch link MainFlow exists StartActivity.Act1`.
  Putting `from.to` in the name position errors with "validation value for link must be in the
  format <from>.<to>".
- **`da handler` needs a trigger id:** `fda da handler <trigger-id>[.<handler>] -f <app>`.

### Connections

- **Bind connections by name with `-C`:** `ca … -C <ConnName>`, `ct … --connection <ConnName>`, or
  `sa … <ConnName> -C connection`. fda writes `conn://<uuid>` (2.x) or `conn://<ConnName>.fgconn` (3.x).
  Without `-C`, or via `mm`, the name is written as plain text and fails at runtime — `cm` won't catch it, so read it back (`fda da` hides the 3.x `.fgconn` suffix — `conn://<ConnName>` there is correct; only a bare name with no `conn://` is a bad binding).
- **To update a connection field backed by an app property, use `rap` + `cap` — not `sa`.** When a
  connection field value is `=$property[...]`, using `fda sa` replaces the reference with a hardcoded
  literal. Correct sequence: (1) `fda rap <PropertyName> -f <app>`, (2) `fda cap <PropertyName> <type>
  <newValue> -f <app>`. **`fda cap` type must be `number` (not `float64`) for numeric properties.**

### Database activities

- **SQL queries must end with `;`.** The trailing semicolon terminates the query so the engine can
  fetch metadata (column names, types). Without it, metadata discovery fails silently.
- **SQL placeholders must use `?<name>` syntax.** Prepared-statement parameters are written as
  `?keyName` (e.g. `?BookId`), not `@param`, `:param`, or bare `?`. Example:
  `SELECT * FROM BookStore WHERE id = ?BookId;`
- **Clear `input.input` BEFORE setting the SQL query, not after.** Applies to all DB connector
  activities (PostgreSQL, MySQL, SQL Server, etc.). `rmm` also clears the auto-generated schema;
  setting the query after `rmm` regenerates it. Correct order: (1) `rmm` on `input.input`,
  (2) `sa` to set `input.Query`, (3) `da --json` to confirm `parameters.properties` is populated —
  if empty (no live DB connection), fix with `sms` by declaring every `?param` from the query:
  `fda sms <flow>.<activity>.input --json-schema '{"type":"object","properties":{"parameters":
  {"type":"object","properties":{"<p1>":{"type":"<t1>"},"<p2>":{"type":"<t2>"}}}}}' --field input
  -f <app>`, (4) `mm` on each leaf field via `input.input.mapping.parameters.<paramName>`.
- **SQL query `Output` is an object with a nested `records` array — not a flat array.** Database query
  activities return `Output` as `{"records": [...]}`. When using `@foreach` to iterate over query
  results, the source must be `$activity[QueryName].Output.records` — **not** `$activity[QueryName].Output`.
  Always run `fda da activity <flow>.<activity>` to inspect the output schema before setting up
  `@foreach`.
- **A parameterized DB activity's input SCHEMA must declare the same params the mapping targets.**
  When you bind `?param` placeholders via `input.input.mapping.parameters.<name>`, the activity's
  input schema (`schemas.input.input`) MUST list every param under
  `properties.parameters.properties.<name>`. For INSERT/UPDATE the auto-derived schema may put params
  under `values.items.properties` instead — fix `parameters.properties` to hold every `?param` field.
  Verify by reading back `schemas.input.input`.

### REST trigger & reply

- **REST API identifiers belong in path parameters, not query parameters.** When a REST API accepts
  an identifier (BookId, userId, orderId, etc.), use path parameters (`/resource/{id}`) rather than
  query parameters (`/resource?id=`). Use `--restResourcePath /resource/{paramName}` on `cth`.
- **Reply has both `data` and `message` → put the payload only in `data`.** Put the value meant for `message` into
  `data` as-is, and map `message` to a constant (`fda mm <flow>.<actreturn>.input.mappings.message OK`) — unmapped fails `cm`. If `data` is missing,
  create it via `schemas.reply.data` (section 7) before `wth`, then in step 2b also pass `--output <every field from 2a's flow.metadata.output>,data:object`.
  Then run `fda sms <flow>.output` with every output field and the full reply schema on `data` — `wth --output` leaves `data` untyped, so the designer shows its Return mapping as raw JSON.
- **Don't hardcode HTTP status code in actreturn mappings.** Create an app property
  (`fda cap HttpStatusCode number 200`) and map it as `"code": "=$property[\"HttpStatusCode\"]"`.

### Mappings

- **Don't use `set-attribute` (sa) for mapper input fields when `make-mapping` (mm) exists.** `mm`
  proactively adds function imports for any expression you write; `sa` doesn't. Use `mm` for
  mapper activity mappings; use `sa` only for non-mapping settings.
- **Never guess activity output paths — run `fda lms <target-field>` before any `mm` that reads from
  another activity's output.**
- **Don't use `sms` on Mapper activity output side.** The Mapper's Output tab in the UI is read-only —
  it always mirrors the input schema. Only use `sms` on the input side (or omit the direction to apply
  to both, which is the default).
- **Mapper vs non-mapper `mm` paths — get it from `dmf`, never construct by hand.**
  Mapper (`act_general_mapper`): `<flow>.<activity>.input.input.mapping.<field>`
  All other activities: `<flow>.<activity>.input.<field>`
  Using the mapper path on a non-mapper silently writes to the wrong location — CLI reports success
  but no field is actually set. Always copy the exact PATH from `dmf` output into `mm`.
- **`actreturn` settings.mappings — use `fda mm`, not `sa` or hand-editing.** The actreturn mappings
  live under `settings.mappings` as a flat object. `fda mm` rewrites the path from `input.mappings`
  to `settings.mappings` automatically. Do NOT use `fda sa` — it mangles JSON objects. Example:
  ```bash
  fda mm "<flow>.<actreturn>.input.mappings.code" '=$property["HttpStatusCode"]' -f <app>
  ```
- **Dynamic input settings (e.g. MessageAttributeNames) require named entries.** Set the names array
  as `[{"Name":"X","Type":"String"}]` objects via `sa --jsonValue`. For activities, also map each
  value individually via `mm` on the parent object's children — never as a single JSON blob.
- **Link condition values don't take a leading `=`.** When setting a condition on a link via
  `fda sa flow '<Flow>.links[N].value'`, the value is already evaluated as an expression — don't
  prefix with `=`. Only mapping values (`mm`) need the `=` prefix. Example:
  `fda sa flow 'MyFlow.links[0].value' 'string.equals($flow.pathParams.type, "domestic")' -f <app>`
- **Check source vs target types before mapping; use `coerce.toXxx()` for mismatches.** The
  live-DB-derived schema is the source of truth — never override it to match the source type.
  REST path/query params are always strings; bridge mismatches with `coerce.toXxx()` in the mapping.
  Before every `mm` on a DB activity parameter: (1) run `fda da activity <flow>.<activity>` to read
  DB-derived types, (2) apply matching coerce (`coerce.toInt` for integer, `coerce.toFloat64` for
  float, etc.), (3) run `fda exp function coerce` to confirm the function exists. Don't wrap when
  types already match.
- **Never use `[N]` bracket indexing on function results or arrays in mapping expressions.** The
  Flogo expression engine parses `[N]` as a resolver reference, not array indexing. Always use
  `array.get(arr, N)` instead. Example:
  `=array.get(json.jq($activity[Source].output.catalog, ".[] | select(.code == \"P001\")"), 0)`
- **Prefer simple direct mappings.** Use a function when the user asks for a transformation (e.g. `json.jq`, `string.*`, `utils.uuid()`) or a type mismatch needs `coerce.toXxx()` — never add one on your own to reshape data (e.g. wrapping a field in `array.get` when a direct mapping works).
- **`flow.metadata.input` and `flow.metadata.output` must be arrays of `{"name","type","value"}`
  descriptors** — not nested objects. The UI calls `.reduce()` on them; a non-array causes
  `e.reduce is not a function`. Correct:
  `fda sa flow "Flow1.metadata" --jsonValue '{"output":[{"name":"result","type":"object","value":null}]}'`
- **Schema-typed or object fields on non-mapper activities need `.mapping.` in the child path.** When a
  non-mapper activity has a schema bound via `sms --field <fieldName>`, map children as
  `<flow>.<activity>.input.<field>.mapping.<child>` — not `input.<field>.<child>`. Without
  `.mapping.`, children collapse into a JSON blob on the parent.
  **Return (`actreturn`) is different:** its outputs live under `mappings`, so map an object output's children as
  `<flow>.<Return>.input.mappings.<output>.mapping.<child>`. The generic `input.<output>.mapping.<child>`
  path reports success and passes `cm`, but writes outside the returned values.