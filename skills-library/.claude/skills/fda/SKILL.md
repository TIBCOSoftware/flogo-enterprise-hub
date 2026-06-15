---
name: flogo-design-assistant
description: A command line tool to create and modify TIBCO Flogo Integration Applications
user-invocable: true
---

`fda` (Flogo Design Assistant) builds and edits Flogo Integration apps from the command line. Every task takes the same global flags and either prints a human-readable result or, with `-j`, emits machine-readable JSON.

## Prerequisite: resolve the `fda` binary

The `fda` CLI (`flogodesign-cli`) ships inside the TIBCO Flogo VS Code extension. The extension folder name changes with every update, so **discover the path dynamically** before running any command:

```bash
# Check PATH first, then fall back to dynamic discovery
HOME_DIR="${HOME:-$USERPROFILE}"
EXT_NAME="flogodesign-cli"
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
  EXT_NAME="flogodesign-cli.exe"
fi

FDA_CMD=$(which fda 2>/dev/null)
if [ -z "$FDA_CMD" ]; then
  for dir in "$HOME_DIR/.vscode/extensions" \
             "$HOME_DIR/.vscode-insiders/extensions" \
             "$HOME_DIR/.vscode-server/extensions"; do
    FDA_CMD=$(ls -td "$dir/tibco.flogo-"*/bin/"$EXT_NAME" 2>/dev/null | head -1)
    [ -n "$FDA_CMD" ] && break
  done
fi
```

Use `"$FDA_CMD"` (or the alias `fda` if it resolves) for all commands below. Never hardcode the extension version folder.

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
Task: compose-flogo-file (cff)        Composes a flogo file from project parts
 --- data-management ---- 
Task: create-spec (csp)               Create an API specification for a Flogo Project
Task: remove-spec (rsp)               Removes a spec from a Flogo Project
Task: create-schema (cs)              Create a schema for a Flogo Project
Task: remove-schema (rs)              Removes a schema from a Flogo Project
Task: create-app-property (cap)       Create an application property for a Flogo Project
Task: remove-app-property (rap)       Removes an application property from a Flogo Project
Task: set-attribute (sa)              Set attribute for a Flogo Object
 --- connectivity ---- 
Task: create-trigger (ct)             Create a new Flogo Trigger
Task: remove-trigger (rt)             Removes a Flogo Trigger
Task: create-trigger-handler (cth)    Create a new Flogo Trigger Handler
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
Task: validate-mappings (vm)          Validate mappings (refs, imports, @foreach scopes)
Task: wire-trigger-handler (wth)      Wire a trigger handler ↔ flow (inputs + reply mappings)
Task: set-mapping-schema (sms)        Attach a JSON Schema to a mappable activity (typed-tree UI)
Task: remove-mapping-schema (rms)     Detach a JSON Schema from a mappable activity
 --- history ---- 
Task: show-history (sh)               Show the history of executed tasks
Task: restore-history (rhi)           Restores your flogo application to the version in the history
Task: script-history (sch)            Creates a script out of the historical commands
```

`fda help <task-name>` (or `fda help <shortcode>`) prints the long-form help for a single task — usage line, all flags, all positional inputs, examples. Always start there when picking up a task you haven't used in a while; the short description in the table above is intentionally one-line.

Inline parameters use `<>` brackets; flags use `--name` (or the `-X` shortcode shown by `fda help <task>`).

## How to use `fda` from Claude Code in VS Code

The `fda` CLI is the right tool for any "edit this Flogo file" or "tell me what's in this Flogo file" task. Use it directly — don't hand-edit the JSON. Reasons: every task validates against the live FDA configuration, every save runs the contrib re-derivation + defensive function-import sweep, and history is recorded so a bad change can be rolled back via `restore-history`.

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

### 2. Mutate idempotently, validate after
CRUD tasks are idempotent for create (existing entries get re-bound to the new config) but error on remove if the target doesn't exist. After a sequence of edits, run a validator and a re-read to confirm the state is what you expected:

```bash
fda cf MyFlow -f my-app.flogo
fda ca MyFlow Mapper mapper -f my-app.flogo
fda mm 'MyFlow.Mapper.input.input.mapping.uuid' '=utils.uuid()' -f my-app.flogo
fda vm -f my-app.flogo                            # sweep for broken refs / missing imports
fda check activity MyFlow.Mapper exists -f my-app.flogo   # script-friendly assertion
```

`fda check ...` is the assertion-style task — it exits non-zero on failure, perfect for shell scripts and CI.

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
fda vm -f my-app.flogo
```

## Picking a trigger

The trigger choice shapes the whole flow shape; getting it wrong leads to runtime panics that no static check catches before `flogobuild build-exe`.

| Trigger | When to use | Needs |
|---|---|---|
| `tr_rest` (TIBCO REST) | You have an OpenAPI/swagger spec to scaffold from | **Mandatory** `settings.swagger`. Pair with `cas` (`create-api-skeleton`) which seeds project + flow + trigger + handler in one shot. Without a swagger, the trigger panics on the **first** request — `vm` flags this as `TR_REST_NO_SWAGGER`. |
| `tr_http` (project-flogo HTTP, mode: Data) | You DON'T have a spec; flow controls the response shape directly | Wire `handler.reply.{statusCode, responseBody}` (the runtime contract — NOT `code`/`data`/`headers`) from the upstream `actreturn` output, otherwise the response is HTTP 0 and the runtime panics with `invalid WriteHeader code 0`. `wth` now seeds `reply.statusCode = 200` and `reply.responseBody = ""` as safe defaults, and `vm` flags any remaining gaps as `TR_HTTP_REPLY_STATUSCODE_ZERO` / `HTTP_TRIGGER_REPLY_UNWIRED`. |
| `tr_timer` | Periodic invocation; no I/O coupling | Just `Repeating` / `Time Interval` / `Interval Unit` settings. |

Quick rule: **have a spec → `cas`. No spec → `tr_http`.** The default in `create-trigger` is `tr_rest`; switch with `--trigger-type tr_http` when you don't have a spec.

## Common runtime failures (and how `fda vm` catches them)

`fda vm` is the layer between "build succeeded" and "first request crashes the engine". Run it before every `flogobuild build-exe`. The rules below cover the failures most likely to bite — each maps to a vm code so the user knows what to fix.

| Symptom at runtime | vm code | Fix |
|---|---|---|
| `connection with id 'conn://' not configured` at engine init | (caught by `analyze-vscode-extension` — `conn://` defaults are blanked at seed-time, never appear in the flogo) | Re-seed `default-config.json` if you see one: `fda ave resources/tibco.flogo-2.26.2-2236 --type activity --toConfigFile <path>` |
| `WriteHeader code 0` panic from an `actreturn` flow | `INPUT_VS_SETTINGS_MISWRITE` | `actreturn.mappings` lives under `settings`, not `input`. `mm` and `sa` rewrite the path automatically (settingFields metadata); legacy files trip the vm error and need the block moved. |
| `handler.Schemas() nil pointer` panic on first REST request | `TR_REST_NO_SWAGGER` | `tr_rest` needs `settings.swagger`. Use `cas` to scaffold from a spec, or replace with `tr_http`. |
| `function [length] is not installed` at runtime | `FUNCTION_AMBIGUOUS` / `FUNCTION_NOT_QUALIFIED` | **Always qualify function calls** with the package name (`string.length(...)`, `utils.uuid(...)`). `mm` rejects every bare call at write-time, regardless of whether it currently resolves to one package or many — uniform rule, future-proof against extensions adding same-named functions. |
| `error parsing expression '=$activity[…]'` inside an `@foreach` | `FOREACH_HAS_LEADING_EQUALS` | The `--foreach` value must NOT have a leading `=` — the `@foreach()` wrapper is itself the expression marker. `mm` strips the `=` proactively now; legacy files trip the vm warning. |
| `failed to resolve activity attr 'output'` | `ACTIVITY_OUTPUT_LEAF_UNKNOWN` | Non-mapper activities expose top-level outputs by name (`responseBody`, `statusCode`, etc.), not a single `.output` object. `lms` enumerates the real outputs; `vm` validates `$activity[X].<leaf>` against the schema. |
| Handler created (cth) but flow doesn't receive request data / can't reply | `TRIGGER_HANDLER_UNWIRED` | A handler bound to a flow needs four mutations wired (flow.metadata.input/output + handler.action.input/output + handler.reply). Use `fda wth <flow> <trigger.handler>` — one call does both directions, with sensible defaults per trigger ref. |
| Flogo VSCode UI shows mapping JSON as raw text instead of a typed tree; `schema://X` reference doesn't resolve at runtime | `MAPPING_SCHEMA_REF_MISSING` / `MAPPING_SCHEMA_INLINE_MALFORMED` | Mappable activities need a schema attached at `activity.schemas.<dir>.<field>`. Either reference a top-level schema (`fda sms <flow>.<activity> <name>`) or write content directly (`--json-schema` / `--json-value-to-schema`). Both sides default to the same schema for mapper activities. `vm` flags dangling `schema://` references and malformed inline blocks. |

## Wiring trigger handlers ↔ flows (`wth`)

`fda wth <flow> <trigger.handler>` does the four-step wiring in one call: populates `flow.metadata.input/output`, `handler.action.input/output`, and `handler.reply`. The field shapes come from the trigger ref's `defaultWiring` template (seeded by `analyze-vscode-extension`):

| Trigger | Default shape |
|---|---|
| `tr_mcpserver` | `arguments` (any) → / `response` (object) ← |
| `tr_http` | `pathParams` + `queryParams` + `headers` + `content` → / `statusCode` + `responseBody` ← |
| `tr_timer` | none (timer doesn't carry payloads) |
| `tr_rest` | use `cas` instead — wiring is swagger-driven |
| Custom | error: pass `--input` / `--output` explicitly |

Override defaults with repeatable `--input <name>[:<type>]` and `--output <name>[:<type>]`. Use `--inputs-only` / `--reply-only` to wire just one direction. `--force` overwrites already-wired sides (default behaviour skips with a warning, so you don't accidentally clobber hand-tuned mappings). All reply mappings use the action-scope resolver `=$.<name>` (the runtime rejects `$flow` in `handler.action.output` slots — `vm` catches strays as `RESOLVER_UNKNOWN`).

`wth` also propagates JSON-Schema to the four typed-tree slots (flow.metadata, handler.action, handler.reply) when given `--output-schema <name>` (or `--output-schema-from-json '<sample>'`). Without those flags, `wth` auto-derives the response schema from a connected mapper's output schema if the actreturn binds one — chain `mapper → actreturn → flow.metadata.output → handler.action.output → handler.reply` is fully knowable at design time. Disable with `--no-auto-derive-output-schema`.

`createMCPSkeleton` (`cms`) calls `wth` internally — same template, single source of truth for the wiring shape.

## Things to avoid (common pitfalls)

- **Don't hand-edit the .flogo JSON.** The `flogoProject.contrib` blob is base64-encoded and re-derived on every save; ad-hoc edits to it vanish on the next `fda` write. Use the dedicated tasks.
- **Don't use `set-attribute` (sa) for mapper input fields when `make-mapping` (mm) exists.** `mm` proactively adds function imports for any expression you write; `sa` doesn't, so you'd rely on the defensive sweep at save time. The sweep catches it eventually but `mm` is more explicit and surfaces errors immediately.
- **Pass the `--file` global with the right shape.** A bare `fda <task>` with no `-f` opens `flogo-project.flogo` in the cwd and AUTO-CREATES it if missing — a silent no-op trap when you meant to operate on a different file. When scripting, always pass `-f <path>` explicitly.
- **`exp function <name>` has three modes** — `category.fnName` (qualified), bare unique name (works), bare ambiguous name (errors with disambiguation), and bare category name (expands to every function in the package). When in doubt, qualify with `category.`.
- **`-j` JSON output suppresses tables.** Helpful when piping into `jq` from a script, but if you want to read the table yourself, drop the flag.
- **Stale `default-config.json`.** When working on a fresh clone the function catalog (`fda lf`, `fda exp function ...`) needs to be seeded once: `fda ave resources/tibco.flogo-2.26.2-2236 --type function --toConfigFile tibcopilot-flogo-command-line-developer/default-config/default-config.json`. The repo's committed `default-config.json` already has it; only matters if someone has reset that file.
- **Activity aliases use `<group>_<entity>`** for everything outside the `general`, `default`, and `ems` groups (e.g. `mysql_query`, `salesforce_delete`, `auditsafe_query` — not bare `query`). Connection / trigger aliases stay bare (`kafka`, `ems`, `mysql`) — there are no clashes there. `fda lat <filter>` and `fda exp activity <name>` show the canonical name + alias; `analyze-vscode-extension` warns at the end of its run if it spots any remaining alias clashes (`mapXxxAlias()` would silently pick the first match otherwise — `helper-validate-shortcodes` is the strict CI gate for the same check).

## When the user asks "build and run this app"

`fda` itself doesn't build/run — that's `flogobuild` (see the `flogobuild` skill). Typical end-to-end loop is:

1. `fda` to construct/edit the .flogo project
2. `fda vm -f <file>` to validate mappings before building
3. `flogobuild build-exe -f <file>` to compile to a native binary
4. `./<binary>` to run it

Use the `flogobuild` skill for the build/run side; this skill is for the design-time edits that come before.
