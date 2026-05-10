---
name: mapping-from-excel
description: Description on how to create a flogo file that follows an excel mapping
user-invocable: true
---

## Key Facts (verified)

- Mapper activity type: `act_general_mapper`
- Logger activity type: `act_general_log`
- Timer trigger type: `tr_timer`
- String concatenation in Flogo expressions: use `string.concat(a, b)` — NOT the `&` operator
- Mapper output path: `$activity[<activity_name>].output.<field>` — NOT `.output.output.<field>`
- All `set-attribute` calls for schemas and mappings need the `--force` flag (attributes don't pre-exist)
- `create-trigger-handler` inline syntax: `fda cth <flow-name> <trigger-id>`
- `create-activity` inline syntax: `fda ca <flow-name> <activity-name> <activity-type>`

---

## Step 1: Read the Excel file

Read the Excel file using Python (`openpyxl`). Extract:
- **Column 1** → Input field names
- **Column 2** → Output field names
- **Column 3** → Mapping rules (source expression per output field)

```bash
python3 -c "
import openpyxl
wb = openpyxl.load_workbook('<excel-file>')
ws = wb.active
for row in ws.iter_rows(values_only=True):
    print(row)
"
```

---

## Step 2: Create project, flow, activities, trigger

Run all commands from your Flogo apps directory (e.g. `./Flogo_Apps/`).

```bash
# Create flow (creates project file if it doesn't exist)
fda create-flow mapping_from_excel -f <AppName>.flogo

# Add activities (automatically linked in sequence)
fda ca mapping_from_excel mapper1 act_general_mapper -f <AppName>.flogo
fda ca mapping_from_excel mapper2 act_general_mapper -f <AppName>.flogo
fda ca mapping_from_excel logger  act_general_log    -f <AppName>.flogo

# Add timer trigger + handler
fda create-trigger timerTrigger tr_timer -f <AppName>.flogo
fda cth mapping_from_excel timerTrigger -f <AppName>.flogo

# Format flow
fda format-flow mapping_from_excel -f <AppName>.flogo
```

---

## Step 3: Create JSON schemas

Create one schema for input fields and one for output fields.

```bash
fda cs InputSchema  '{"$schema":"http://json-schema.org/draft-04/schema#","type":"object","properties":{"<field1>":{"type":"string"},...}}' -f <AppName>.flogo
fda cs OutputSchema '{"$schema":"http://json-schema.org/draft-04/schema#","type":"object","properties":{"<field1>":{"type":"string"},...}}' -f <AppName>.flogo
```

---

## Step 4 & 5: Assign schemas to mappers

```bash
fda sa activity mapping_from_excel.mapper1.schemas.input.input "schema://InputSchema"  -f <AppName>.flogo --force
fda sa activity mapping_from_excel.mapper2.schemas.input.input "schema://OutputSchema" -f <AppName>.flogo --force
```

---

## Step 6: Set example input values in mapper1

Set one field at a time:

```bash
fda sa activity mapping_from_excel.mapper1.input.input.mapping.<FieldName> "<example-value>" -f <AppName>.flogo --force
```

Repeat for every input field.

---

## Step 7: Set output mappings in mapper2

Map each output field from mapper1's output. Use `--force` on every call.

- Simple field mapping:
  ```bash
  fda sa activity "mapping_from_excel.mapper2.input.input.mapping.<OutputField>" \
    '=$activity[mapper1].output.<InputField>' -f <AppName>.flogo --force
  ```

- Concatenation of two fields (use `string.concat`, NOT `&`):
  ```bash
  fda sa activity "mapping_from_excel.mapper2.input.input.mapping.<OutputField>" \
    '=string.concat($activity[mapper1].output.<Field1>, " ", $activity[mapper1].output.<Field2>)' \
    -f <AppName>.flogo --force
  ```

---

## Step 8: Set logger message to mapper2 output

```bash
fda sa activity "mapping_from_excel.logger.input.message" \
  '=coerce.toString($activity[mapper2].output)' -f <AppName>.flogo --force
```

---

## Step 9: Build, run, and verify

```bash
# Build (use the flogobuild context configured for your Flogo version, e.g. flogo-2.26.0-1789)
mkdir -p ./bin
flogobuild build-exe -f <AppName>.flogo -c <YOUR_FLOGO_CONTEXT> -o ./bin

# Run for 5 seconds and read log output
chmod +x ./bin/<AppName>
timeout 5 ./bin/<AppName> 2>&1 || true
```

The logger should print a JSON object with the mapped output fields.
