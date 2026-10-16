---
name: mapping-from-excel
description: Description on how to create a flogo file that follows an excel mapping
user-invocable: true
---

> **Preflight:** run `python -c "import openpyxl"` first (`pip install openpyxl` if the import fails). `flogobuild version && flogobuild list-context && go version` are only needed when building the generated app — `flogobuild` from the [TIBCO downloads page](https://www.tibco.com/downloads/11810), Go from [go.dev/dl](https://go.dev/dl/) (see AGENT.md → Prerequisites and preflight).

Build a Flogo app that performs the field mappings described in an Excel file. The number of mapper activities matches the number of sheets in the workbook — one mapper per sheet, chained in declaration order — and they all feed a log activity fired by a timer trigger.

For mapping mechanics — `mm`, `sms`, source syntax (`$activity` / `$property` / `$flowctx` / `$loop`), `@foreach`, function packages — defer to the `fda-mapping` skill. For the underlying `fda` command reference and the full "Things to avoid" list, defer to the `fda` skill. This skill is just the per-Excel workflow.

## Before you start

1. **Read `config.md` first** (the one next to this skill under `.claude/skills/`) for `FLOGOBUILD_CONTEXT_NAME`, the Flogo apps folder, and CLI paths. Never hardcode a context name or a secret.
2. **Print the CLI tool path and version before running any commands** — e.g. `fda version` and `flogobuild version` from their configured paths (neither CLI accepts `--version`).
3. **Working directory:** run all `fda` / `flogobuild` commands from the Flogo apps directory named by `FLOGO_APPS_DIR` in `config.md` — resolved relative to `config.md` (which lives at `skills-library/.claude/skills/config.md`); the default `../../Flogo_Apps` points at `skills-library/Flogo_Apps/`, the same folder whether you opened the hub root or `skills-library` (create apps there, never in `skills-library/`). The `.flogo` files are created here; executables go to `<FLOGO_APPS_DIR>/../bin` (i.e. `skills-library/bin/`).
4. **Windows / Git Bash:** prefix any `fda` call whose value starts with `/` (or contains a URL) with `MSYS_NO_PATHCONV=1` so paths aren't mangled. Harmless on Linux/Mac. See the `fda` skill for details.

## Key facts

- Mapper activity type: `mapper` (alias for `act_general_mapper`)
- Log activity type: `log` (alias for `act_general_log`)
- Timer trigger type: `timer` (alias for `tr_timer`)
- Mapper output path: `$activity[<Activity>].output.<field>` — NOT `.output.output.<field>`
- **Always qualify function calls with the package name** — `string.concat(a, " ", b)`, `string.length(s)`, `utils.uuid()`. Bare `concat(...)` / `length(...)` are rejected by `mm` and flagged by `cm` as `FUNCTION_AMBIGUOUS` / `FUNCTION_NOT_QUALIFIED`.
- Use `mm` (make-mapping) for every mapper field; it auto-imports function packages, so you never need a manual `fda ai github.com/.../function/string`.
- Use `sms` (set-mapping-schema) to attach schemas — one command upserts the named schema AND attaches it to both `input.input` and `output.output`. No `--force` needed; compare-and-decide is built in.
- Run `fda cm` (check-mappings) before every build — it catches bad refs, missing imports, unqualified function calls, and other things that would otherwise fail at runtime. **`fda vm` and `fda ch` do not work for mapping validation** — the correct command is `fda cm`.
- **Do NOT run `fda ff` / `fda format-flow`.** It can silently delete activities not in its computed layout (data loss). The designer renders positions from the links without it. (See the `fda` skill.)

---

## Workbook structure (single-sheet vs multi-sheet)

Two layouts the skill handles:

**Single-sheet (the original `ExcelWithMapping.xlsx` shape)** — one sheet (`Sheet1`), three columns describing one transformation. This becomes a 2-mapper Source → Build chain: a `Source` mapper emits literals for the input fields, a `Build` mapper applies the rules.

**Multi-sheet (one sheet per mapper)** — the workbook has N sheets, each named after a mapper activity (e.g. `Intake`, `Adjudicate`; or `OrderIn`, `LineCalc`, `Build`; or `TradeIn`, `Enrich`, `Compute`, `Settle`). The mappers chain in sheet-declaration order: sheet 1's outputs feed sheet 2's inputs, sheet 2's outputs feed sheet 3, etc.

**Cell layout (identical for every sheet)** — top two rows are blank (visual padding), header row at **row 3**, data starts at **row 5**, columns A and C are spacers. Cells are written in **human-readable form** (camelCase → Title Case, dotted paths → `›` separators, Flogo wrappers stripped, function packages hidden), NOT in raw Flogo expression syntax — your job in the workflow below is to translate the human form back into the proper Flogo syntax that `mm` accepts.

| Col | Row 3 header | Row 5+ contents (human-readable form) |
|---|---|---|
| A | (blank) | (blank — spacer) |
| B | `Input Fields` | one row per unique input the sheet's expressions consume. Sources are sorted activities → properties → flow context. **Empty for the first sheet** (literals only — no upstream). Forms: `<Field> (from <UpstreamMapper>)`, `<Name> (property)`, `<Name> (flow context)`. |
| C | (blank) | (blank — spacer) |
| D | `Output Fields` | one row per mapping target, in Title Case with `›` joining nested path segments. Examples: `Policy Number`, `Damages`, `Damages › Part`, `Payer › Account › IBAN`. |
| E | `Mapping (from input fields)` | the right-hand-side expression in friendly notation (see "Notation legend" below). Annotations may follow in `[…]` brackets — `[for each item]` marks an array-iteration parent, `[(number)]` / `[(boolean)]` etc. signal a `--type X` literal coercion. |

The B column and the D/E columns are independent in length — Input Fields can be longer than Output Fields (or vice versa). Leave the shorter column blank past its last entry.

For multi-sheet workbooks, **the convention is**: the first sheet has no upstream, so its mappings are literals. Every later sheet references **any upstream mapper's output** (rendered as `<UpstreamSheetName>.<field>` in the Mapping column) — usually the immediately preceding sheet, but a sheet can reference any earlier sheet too. For example, a fourth `Build` sheet can reference both the first `OrderIn` sheet and the second `LineCalc` sheet at the same time. The only hard constraint is that the referenced sheet must be declared earlier than the referencing sheet.

**Notation legend (col E ↔ Flogo syntax)** — the Excel uses friendly tokens; your `mm` calls must use the real Flogo syntax in the right column below.

| In the Excel | Real Flogo syntax | Meaning |
|---|---|---|
| `Intake.policyNumber` | `$activity[Intake].output.policyNumber` | Output field of an upstream mapper |
| `[Policy.Provider]` | `$property["Policy.Provider"]` | App property |
| `{TraceId}` | `$flowctx["TraceId"]` | Flow-context value |
| `this.part` | `$loop[<var>].part` | Current item inside a `[for each item]` parent |
| `[for each item]` (annotation on parent row) | `--foreach '<expr>' --as item` | Array iteration; the loop variable name comes from the words after "for each" — `[for each item]` → `--as item`, `[for each line]` → `--as line`, etc. Child rows use `this.X` → `$loop[item].X` |
| `UPPER(x)` | `string.toUpper(x)` | (`LOWER`, `length`, `replace`, `substring`, `equalsIgnoreCase`, `concat` map similarly to `string.*`) |
| `asString(x)` / `asNumber(x)` / `asInt(x)` | `coerce.toString(x)` / `coerce.toFloat64(x)` / `coerce.toInt(x)` | Type coercion |
| `newUUID()` | `utils.uuid()` | Generate a UUID |
| `round(x)` / `ceil(x)` | `math.round(x)` / `math.ceil(x)` | |
| `count(x)` / `at(x, n)` / `sum(x)` | `array.count(x)` / `array.get(x, n)` / `array.sum(x)` | |
| `jq(x, "...")` | `json.jq(x, "...")` | jq query against JSON |
| `now()` | `datetime.now()` (or `datetime.currentDatetime()`) | |
| `formatDate(d, f)` / `addToDate(d, …)` / `parseDate(s)` | `datetime.formatDatetime` / `datetime.add` / `datetime.parse` | |
| `NOT(x)` | `boolean.not(x)` | |
| `a + b + c` (string context) | `string.concat(a, b, c)` | (Excel may also keep the literal `concat(a, b, c)` form — both mean the same thing) |

When you regenerate `mm` calls from the Excel, every function you emit must be **fully package-qualified** (`string.toUpper`, not `UPPER`), every `<Mapper>.<field>` must become `$activity[<Mapper>].output.<field>`, every `[X]` must become `$property["X"]`, and so on — `mm` rejects the friendly forms (and `fda cm` will catch any that slip through).

---

## Step 1: Read the Excel file

The Excel file is typically in the workspace root, not in `<FLOGO_APPS_DIR>`. Use the full path or `../<excel-file>` when running from `<FLOGO_APPS_DIR>`.

Ensure `openpyxl` is available (`pip install openpyxl` if you get `ModuleNotFoundError: No module named 'openpyxl'`).

```bash
python -c "
import openpyxl
wb = openpyxl.load_workbook('<excel-file>')  # full path or ../ExcelFile.xlsx if in <FLOGO_APPS_DIR>
print('Sheets:', wb.sheetnames)
for sh in wb.sheetnames:
    ws = wb[sh]
    print(f'\n=== {sh} ===')
    for r in range(3, ws.max_row + 1):  # headers row 3, data row 5+
        cells = [ws.cell(row=r, column=c).value for c in (2, 4, 5)]  # B, D, E
        if any(cells):
            print(cells)
"
```

For each sheet, extract three columns (read what's actually there — column letters above are the convention, not a hard requirement). Cells are in **human-readable form** — translate back to Flogo syntax via the Notation legend above before feeding them to `mm`:
- **Input Fields (col B)** — `Damages (from Intake)`, `Policy.Provider (property)`, `TraceId (flow context)`. Tells you what this mapper consumes; drives the upstream schema/refs.
- **Output Fields (col D)** — `Policy Number`, `Damages › Part`. Drop the spaces (`policyNumber`) and join nested with `.` (`damages.part`) to get the real `mm` target path. The first segment in the original camelCase form is also what feeds the OutputSchema property names.
- **Mapping rule per output field (col E)** — `Intake.policyNumber`, `UPPER(this.part)`, `[Policy.Provider]`, `newUUID()`. A bare upstream-mapper field reference → direct field copy. `concat(a, b, c)` or `a + b + c` → `string.concat(...)`. Annotations like `[for each item]` mean the parent target is an array (use `--foreach` + `--as`) and the child rows under it reference `this.<field>` (= `$loop[<var>].<field>`). For unknown function names → match them via the legend, then `fda lf <pkg>` / `fda exp function <pkg>.<fn>` for signature details.

---

## Step 2: Create project, flow, activities, trigger

**FIRST: Check whether the `.flogo` file already exists** — if it does, skip `fda cp` (re-running it would overwrite the existing project). If the file exists, also run `fda dp` to see exactly what's already been built so you know what still needs to be done.

```bash
ls <FLOGO_APPS_DIR>/<AppName>.flogo 2>/dev/null \
  && echo "EXISTS — skip fda cp" \
  || echo "NOT FOUND — run fda cp"

# If the file exists, inspect its current state (flows, triggers, activity count):
fda dp -f <AppName>.flogo
```

All commands take `-f <AppName>.flogo`. **The mapper activity names come straight from the sheet names** — preserve order.

**Chain all setup commands in a single `&&` call** so a failure mid-way doesn't leave the project partially built.

```bash
# Only run fda cp if the file does NOT exist (checked above).
# Add one 'fda aa' line per additional sheet between Sheet2Name and LogIt.
# Sheet-declaration order: single-sheet → Source, Build; multi-sheet → use sheet names as-is.
fda cp <AppName> -f <AppName>.flogo && \
fda cf MainFlow -f <AppName>.flogo && \
fda aa MainFlow <Sheet1Name> mapper -f <AppName>.flogo && \
fda aa MainFlow <Sheet2Name> mapper -f <AppName>.flogo && \
fda aa MainFlow LogIt        log    -f <AppName>.flogo && \
fda ct MyTimer timer -f <AppName>.flogo && \
fda cth MainFlow MyTimer -f <AppName>.flogo && \
echo "=== Flow + activities created ==="
```

`aa` (add-activity) links activities in creation order, so no manual layout is needed. **Do NOT run `fda ff` / `fda format-flow`** — it can delete activities silently (see Key facts). A `tr_timer` handler carries no payload, so it needs no `wth` wiring.

---

## Step 3: Attach schemas to every mapper

`sms` upserts the named schema in `flogoProject.schemas` AND attaches it to `input.input` + `output.output` of the activity in one call (default direction is `both`). Build the schema for each mapper from that sheet's **Output Fields** column (those become the mapper's output shape; mapper input fields aren't typed because mapper inputs are the mapping expressions themselves).

```bash
# One sms per mapper sheet — name the schema after the sheet for clarity
fda sms MainFlow.<Sheet1Name> <Sheet1Name>Schema --json-schema '{"$schema":"http://json-schema.org/draft-04/schema#","type":"object","properties":{"<outField1>":{"type":"string"},"<outField2>":{"type":"string"}}}' -f <AppName>.flogo
fda sms MainFlow.<Sheet2Name> <Sheet2Name>Schema --json-schema '{ … }' -f <AppName>.flogo
# … repeat for every mapper
```

Idempotent: re-running with the same content is a no-op; re-running with different content errors unless you pass `--force`.

---

## Step 4: Fill the FIRST sheet's mapper with literals

The first sheet has no upstream, so its Output Fields rows are seeded with literal sample values from the Mapping column. `mm` writes literals verbatim (no `=` prefix).

```bash
# For every Output Fields row in sheet 1
fda mm MainFlow.<Sheet1Name>.input.input.mapping.<OutField> "<literal-from-mapping-col>" -f <AppName>.flogo
```

If the Mapping column annotation is `[(number)]`, `[(boolean)]`, etc., add `--type <kind>` so the literal is coerced (`fda mm … 1.5 --type number`).

**JSON literals (arrays/objects) are auto-detected.** A Mapping cell like `[{"sku":"A","qty":3},{"sku":"B","qty":1}]` is stored as a real typed array (NOT a string) — no `--type` flag needed. Same goes for `{...}` object literals. If quoting the JSON in bash gets gnarly, use `--jsonValue '<json>'` or `--jsonValueFile <path>` instead of the positional value:

```bash
fda mm MainFlow.<Sheet1Name>.input.input.mapping.items \
  --jsonValue '[{"sku":"A","qty":3,"unitPrice":2.5},{"sku":"B","qty":1,"unitPrice":10}]' \
  -f <AppName>.flogo
```

---

## Step 5: Apply mapping rules on every subsequent sheet's mapper

For sheets 2..N, each Output Fields row is an expression (leading `=`) that references **any upstream sheet's mapper output** via `$activity[<UpstreamSheetName>].output.<field>` — plus optionally `$property["<name>"]` and `$flowctx["<name>"]`. The Mapping column gives the exact expression; just trim the surrounding annotation if any. The upstream sheet name is whatever appears before the `.` in the Mapping cell — usually the immediately preceding sheet, but a later sheet may reference any earlier sheet (e.g. a `Build` sheet referencing both `OrderIn.orderId` and `LineCalc.lines`).

```bash
# Direct field copy from upstream (immediate predecessor)
fda mm MainFlow.<SheetN>.input.input.mapping.<OutField> '=$activity[<SheetN-1>].output.<InField>' -f <AppName>.flogo

# Direct field copy from a non-immediate upstream (e.g. sheet 3 reading sheet 1)
fda mm MainFlow.<SheetN>.input.input.mapping.<OutField> '=$activity[<Sheet1>].output.<InField>' -f <AppName>.flogo

# Function call (always qualified — string.concat, not concat)
fda mm MainFlow.<SheetN>.input.input.mapping.<OutField> \
  '=string.concat($activity[<SheetN-1>].output.<InField1>, " ", $activity[<SheetN-1>].output.<InField2>)' \
  -f <AppName>.flogo

# Property / flow-context refs
fda mm MainFlow.<SheetN>.input.input.mapping.<OutField> '=$property["Some.Group.Name"]' -f <AppName>.flogo
fda mm MainFlow.<SheetN>.input.input.mapping.<OutField> '=$flowctx["TraceId"]'           -f <AppName>.flogo
```

**`[@foreach as <var>]` annotation in the Mapping column** means the row is the parent of an array iteration. Issue the parent first with `--foreach` + `--as`, then the child rows that follow:

```bash
# Parent (annotation: damages   [@foreach as d])
fda mm MainFlow.<SheetN>.input.input.mapping.damages \
  --foreach '=$activity[<SheetN-1>].output.damages' --as d -f <AppName>.flogo

# Children (subsequent rows under it: damages.part, damages.severityScore, …)
fda mm MainFlow.<SheetN>.input.input.mapping.damages.part          '=string.toUpper($loop[d].part)' -f <AppName>.flogo
fda mm MainFlow.<SheetN>.input.input.mapping.damages.severityScore '=$loop[d].severity * 100'      -f <AppName>.flogo
```

For other rule shapes (uppercase, substring, length, date format, jq, etc.) discover the right function with `fda lf <pkg>` and `fda exp function <pkg>.<fn>`. The `fda-mapping` skill has the full source-syntax reference.

---

## Step 6: Wire the log activity to the LAST mapper's output

The log line should surface the final mapper's result (`Build` for the single-sheet pattern, the last sheet for multi-sheet — e.g. `Adjudicate`, `Settle`).

```bash
fda mm MainFlow.LogIt.input.message '=coerce.toString($activity[<LastSheetName>].output)' -f <AppName>.flogo
```

---

## Step 7: Validate (and build/run only if asked)

**Always validate** with `fda cm` — it's read-only and catches bad refs, missing imports, and unqualified functions:

```bash
fda cm -f <FLOGO_APPS_DIR>/<AppName>.flogo
```

**Building the executable and running it is opt-in — do it ONLY if the user explicitly asks.** `fda cm` passing is the default "done" signal. When the user does ask for a build, run it in the foreground (real-time output), never in the background, and use the `FLOGOBUILD_CONTEXT_NAME` from `config.md`:

```bash
# From the Flogo apps directory. -o <FLOGO_APPS_DIR>/../bin places the exe in skills-library/bin/.
# If the configured context is rejected, list valid ones with `flogobuild list-context`.
mkdir -p <FLOGO_APPS_DIR>/../bin
flogobuild build-exe -f <AppName>.flogo -c <FLOGOBUILD_CONTEXT_NAME> -o <FLOGO_APPS_DIR>/../bin

# Run for ~5 seconds and read the log output (timer fires once)
timeout 5 <FLOGO_APPS_DIR>/../bin/<AppName>.exe 2>&1 || true
```

Outputs:
- The `.flogo` file: `<FLOGO_APPS_DIR>/<AppName>.flogo`
- The executable: `<FLOGO_APPS_DIR>/../bin/<AppName>.exe` (i.e. `skills-library/bin/`)

The `flogo.general.activity.log` line in the output is a JSON object with the mapped output fields.

---

## Discoverability mid-mapping

When you're stuck on what's available:

| You want to... | Task |
|---|---|
| List sources available to feed an activity | `fda lms <flow>.<activity> -f <AppName>.flogo` |
| List leaf paths of fields **already mapped** under an activity (NOT what's mappable) | `fda dmf <flow>.<activity>.input.input.mapping -f <AppName>.flogo` |
| Browse functions by package | `fda lf` / `fda lf string` |
| Show one function's signature + example | `fda exp function string.concat` |
| Show what's currently mapped (everywhere) | `fda lm -f <AppName>.flogo` |
| Add/remove a single property in an attached mappable schema | `fda ums <flow>.<activity> …` (update-mapping-schema) |

**Don't confuse `dmf` with "what could I map".** `dmf` walks the existing mapping tree and emits already-set leaf paths. On a brand-new mapper with a schema attached but no `mm` calls yet, it returns `0 mappable field(s)` — even though every field in the schema is, in practice, mappable. For "what's available to map FROM", use `lms`. For "what target fields the schema permits", inspect the schema directly (the JSON you passed to `sms`) — there is no FDA task that lists schema-defined target fields independently of mappings already set.

## Pitfalls specific to this workflow

1. **Don't use `set-attribute` (`sa`) for mapper fields.** `mm` auto-adds the function-package import; `sa` doesn't, and the resulting "function not found" error at runtime is hard to trace.
2. **Quote expressions in bash.** Anything starting with `=`, `$`, `(`, etc. needs single-quotes so the shell doesn't expand `$activity` / `$property`. Use `'=$activity[X]...'`, not `"=$activity[X]..."`.
3. **On Windows/Git Bash, prefix `MSYS_NO_PATHCONV=1`** for any `mm`/`sa` value that starts with `/` (or is a URL) so Git Bash doesn't rewrite it to `C:/Program Files/Git/...`. Harmless on Linux/Mac.
4. **`$activity[Name]` must reference an UPSTREAM activity.** Sheet-declaration order = activity-creation order = chain order. Any earlier sheet is a valid upstream — `$activity[<Sheet1>]` from inside `<Sheet3>` is fine, and so is `$activity[<Sheet2>]`. Referencing a *later* sheet is what fails validation.
5. **REST/HTTP activities expose per-leaf outputs** (`.responseBody`, `.statusCode`) — NOT a `.output` wrapper. The `.output` shape only applies to mapper activities. Doesn't matter for the standard mapper-chain pattern, but worth knowing if the Excel rules reference an upstream REST call.
6. **Don't trust the Input Fields column to be exhaustive.** It lists what THIS sheet's expressions reference, not everything that's available. Use `fda lms` (`list-mapping-sources`) on the target activity if the audience asks "what else could be mapped here?".
7. **`[(number)]` / `[(boolean)]` annotations require `--type`.** A literal Mapping cell like `1.5   [(number)]` means the original `mm` call passed `--type number`. Skipping the flag stores the literal as a string and the runtime will reject it with a type error in the schema-typed mapper.
8. **`fda vm` and `fda ch` do not work for mapping validation.** The correct mapping validation command is `fda cm` (check-mappings). `fda ch` is a different "check" task that expects a Flogo object type argument. Always use `fda cm` with the file path.
9. **Never run `fda ff` / `fda format-flow`.** It can silently delete activities that fall outside its computed layout (including `actreturn`). `aa` already links activities in order; the designer lays them out from the links.
10. **`json.jq` always returns an array of results.** Even when the jq expression yields a single scalar value (e.g. `[.[] | .qty * .unitPrice] | add`), the result is still wrapped in an array. Always call `array.get(..., 0)` to unwrap it before passing to a type-coercion function. Pattern: `coerce.toFloat64(array.get(json.jq($activity[X].output.field, "<jq-expr>"), 0))`. Forgetting the `array.get` wrapper causes a type mismatch at runtime.
11. **Nested struct fields in `mm` use dotted target paths naturally.** For an output field like `Ship To › Line 1` (schema: `shipTo.line1`), the `mm` target path is `MainFlow.<Mapper>.input.input.mapping.shipTo.line1`. The schema must define `shipTo` as a nested `object` type with the sub-properties; `sms` handles the attachment automatically.
