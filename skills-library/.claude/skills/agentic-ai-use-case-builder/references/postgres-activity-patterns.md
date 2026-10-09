# PostgreSQL Activity Patterns (the gotchas that cause mapper errors)

The `wi-postgres` `#query` and `#insert` activities parameterize via `?placeholder` in the SQL,
`Fields[]` entries, an `input.mapping` object, and a `schemas.input.input.value` JSON-Schema string.
Get any of these out of alignment and the Flogo mapper shows a red ✗ on the activity's Input tab.

**Golden rule (activity level) — it is MODE-AWARE.** A `wi-postgres` write activity can be wired in
**two valid, mutually exclusive modes**. The authoritative signal for which mode an activity is in is
the **`Fields[].Value` flag** — read it FIRST. Whatever the mode, three things must all agree with that
flag: the **`Fields` classification**, the **`mapping` container**, and the **populated schema
container**. When they disagree, the designer reads the *empty* container the flag points at and renders
the whole mapping as one raw "Not Mappable" JSON blob on the node — which looks like "my mappings
vanished". The fix is never "move the schema" blind; it is: **read `Fields[].Value`, decide the mode,
then make the other two containers match it.**

| mode | `Fields[].Value` | `Fields[].Parameter` | `mapping` container | populated schema container |
|---|---|---|---|---|
| **values-mode** — designer-generated simple column INSERT; placeholder names **equal** column names | `true` | `false` | `input.input.mapping.values[0]` (ONE object inside the array) | `properties.values.items.properties` (leave `parameters.properties` = `{}`) |
| **parameters-mode** — hand-written SQL / computed exprs / suffixed `?pN` names that **differ** from columns | `false` | `true` | `input.input.mapping.parameters` | `properties.parameters.properties` (leave `values.items.properties` = `{}`) |

Both modes are correct — what breaks is a **hybrid**: e.g. `Fields[].Value:true` (says values-mode) but
the mapping and schema sitting under `parameters` (says parameters-mode). The designer then reads the
empty `values` container the flag points at and shows nothing. This is the single most common mapping
defect; the validator at the bottom of this file detects it.

> ⚠️ **`Fields[].Value` / `Fields[].Parameter` may be JSON booleans (`true`/`false`) OR the STRINGS
> `"true"`/`"false"`** — both occur in shipped apps (e.g. Hospital uses booleans, mortgage uses strings).
> When you read the flag in code, normalize: a bare `"false"` string is *truthy* in Python/JS, so
> `if field["Value"]` misreads parameters-mode as values-mode. Compare `str(v).lower() == "true"`.
> Also note the mapped fields in **values-mode carry BOTH `Value:true` and `Parameter:true`** — so
> `Parameter` is **not** a mode signal; only `Value` is.

Independent of mode: **every `?placeholder` in the Query must have exactly one mapping entry** (else
runtime `query execution failed: missing substitution for: <name>`); **`Fields` must be non-empty on any
write** (with no column metadata the designer renders nothing); the populated schema container's names
must equal the mapping keys; and `input.State` must stay a verbatim copy of `input.Query`. Never use
`RuntimeQuery` for parameters. Verify by running the real SQL against a loaded DB **and** by running the
validator at the bottom of this file before you declare the app done.

> ⚠️ **A `?placeholder` must be followed by a space or one of `; ) , < > + - * % /` — otherwise the
> connector never substitutes it.** The connector's own rewrite (`EvaluateQuery` in the wi-postgres
> `queryHandler.go`) turns `?name` into `$N` only when the next character is in that set, and it runs both
> for the designer's metadata fetch **and** at runtime. `?p5::date` (next char `:`) and `?a||?b` (next char
> `|`) stay in the SQL verbatim: the designer fails with **`syntax error at or near "$5p5"`** (42601 — the
> ODBC driver renumbers the stray `?`) and the flow fails at runtime too, because the literal `?p5` is
> never bound. Write **`CAST(?p5 AS date)`**, or cast an enclosing expression (`NULLIF(?p5,'')::date` is
> fine — there `?p5` is followed by `,`), and space out concatenations (`?a || ?b`). A local SQL client
> will NOT show this (it never sees `?name`); the validator does.

**Two levels of wiring.** The golden rule above is the *activity-level* alignment. Inside an **A2A agent
flow** there is a second, *flow-level* piece: the flow must declare `toolParams` as a flow input (with a
schema) so `=$flow.toolParams.<field>` resolves in the designer. Miss it and the mapper shows a red ✗
even when the SQL is perfect. The full picture is a **3-part contract** — see the next section.

---

## The 3-part designer contract (A2A agent flows)

An A2A write agent receives its inputs from the LLM as `toolParams` and feeds them to a `#query`/`#insert`.
For that to both **run** and **validate in the designer**, three things must agree. The trigger **Sync**
button regenerates all three together.

| # | Where | What it is | Symptom if missing/wrong |
|---|-------|-----------|--------------------------|
| 1 | `activity.input.input.mapping.parameters.<placeholder>` = `"=$flow.toolParams.<field>"` | **Runtime mapping** — the ONLY part the engine reads at run time | runtime error `query execution failed: missing substitution for: <name>` |
| 2 | flow input schema: `resource.data.metadata.input[name=toolParams].schema` = `{"type":"json","value":"<compact-properties-json>"}` | **Flow-input schema** — tells the designer `$flow.toolParams.<field>` exists | design-time red ✗ on `$flow.toolParams.<field>` |
| 3 | `activity.schemas.input.input.value` (draft-04, with `properties.parameters.properties.<p>`) | **Activity-input schema** — tells the designer the mapping *target* exists | design-time red ✗ on the activity Input tab |

Only **#1 runs**; #2 and #3 are design-time validation only (the engine ignores `schemas` blocks at run
time). Therefore:

- To make a broken/generated app **run**, hand-patch **#1** — that alone clears `missing substitution`.
- To make it **validate** (clear every red ✗), the cleanest path is: hand-patch #1, then open each agent
  flow and click the trigger **Sync** — the designer regenerates #2 and #3 consistently. The #3 draft-04
  blob is error-prone to hand-write; let Sync emit it. (Lesson: patching #1 and #2 but forgetting #3
  leaves the red ✗; Sync fixes all three.)
- If you must hand-write #2: its `value` is the **compact `properties` object only** — i.e.
  `{"<field>":{"type":"string"},...}` serialized to a string — NOT the full `type`/`required` wrapper.

**A query-text-only change keeps all three parts valid.** If you edit only the SQL string (and the `State`
copy of it) **without changing the `?placeholder` set**, #1/#2/#3 still align, so no Sync is needed. This
is what makes the derive-FK pattern in Section D a safe surgical patch.

> ⚠️ **Never write to a `.flogo` that is open in the Flogo web designer.** A disk write races with the
> designer's unsaved in-memory state; if the user clicked **Sync** but not **Save**, your patch is
> invisible and their Sync is lost on reload ("your fix messed up my mappings"). Tell the user to Save or
> set aside unsaved work first, patch on disk, then **Discard** unsaved changes and reload so the app
> picks up the on-disk fix. Prefer on-disk patching (covers all flows at once) over dictating manual steps.

---

## A. Read-only tool query (MCP server) — no parameters

`SELECT * FROM <table>` returning all rows (the LLM filters). Every column is a result Field with
`Parameter:false`; there are no params.

```json
{
  "id": "PostgreSQLQuery",
  "settings": { "retryOnError": { "count": 0, "interval": 0 } },
  "activity": {
    "ref": "#query",
    "input": {
      "Connection": "conn://<pg-uuid>",
      "Schema": "public",
      "Query": "SELECT * FROM public.<table> ORDER BY <col> ASC;",
      "manualmode": false,
      "Fields": [
        { "FieldName": "<col1>", "Type": "VARCHAR",  "Selected": true, "Parameter": false, "isEditable": false },
        { "FieldName": "<col2>", "Type": "INTEGER",  "Selected": true, "Parameter": false, "isEditable": false },
        { "FieldName": "<col3>", "Type": "NUMERIC",  "Selected": true, "Parameter": false, "isEditable": false }
      ],
      "RuntimeQuery": "",
      "State": "<uuid><the same SELECT statement>"
    },
    "schemas": {
      "input":  { "input":  { "type": "json", "value": "{\"$schema\":\"http://json-schema.org/draft-04/schema#\",\"type\":\"object\",\"definitions\":{},\"properties\":{\"parameters\":{\"type\":\"object\",\"properties\":{}}}}" } },
      "output": { "Output": { "type": "json", "value": "{\"$schema\":\"http://json-schema.org/draft-04/schema#\",\"type\":\"object\",\"definitions\":{},\"properties\":{\"records\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"<col1>\":{\"type\":\"string\"},\"<col2>\":{\"type\":\"integer\"},\"<col3>\":{\"type\":\"number\"}}}}}}" } }
    }
  }
}
```
Column `Type` → schema type: `VARCHAR/DATE/TIMESTAMP` → `"string"`, `INTEGER` → `"integer"`, `NUMERIC` → `"number"`. `State` must be present (any uuid prefix + the query string).

---

## B. Parameterized SELECT or UPDATE — params under `parameters`

A **SELECT with a WHERE**, or any **UPDATE** (`#insert` activity with an UPDATE statement), has no
INSERT column-list, so **all `?placeholders` are parameters** and can safely reuse column names.

```json
"input": {
  "Connection": "conn://<pg-uuid>",
  "Schema": "public",
  "Query": "SELECT a.col1, b.col2 FROM t1 a JOIN t2 b ON ... WHERE a.key = ?key ORDER BY a.id ASC;",
  "manualmode": false,
  "Fields": [
    { "FieldName": "key",  "Type": "LONGVARCHAR", "Selected": false, "Parameter": true,  "isEditable": false },
    { "FieldName": "col1", "Type": "VARCHAR",     "Selected": true,  "Parameter": false, "isEditable": false },
    { "FieldName": "col2", "Type": "VARCHAR",     "Selected": true,  "Parameter": false, "isEditable": false }
  ],
  "RuntimeQuery": "",
  "State": "<uuid><the query>",
  "input": { "mapping": { "parameters": { "key": "=$flow.toolParams.key" } } }
}
```
Schema `input.value`: `{"...","properties":{"parameters":{"type":"object","properties":{"key":{"type":"string"}}}}}`.
(For UPDATE via `#insert`: same idea — `Fields` params `Parameter:true, Value:false`, schema has
`values.items.properties:{}` empty and `parameters.properties` = the params.)

---

## C. INSERT — THE ONE THAT BREAKS. Two valid shapes; pick one and keep it internally consistent.

> **There are two correct ways to wire an INSERT — do not treat either as "the wrong one".**
> - **values-mode** (what the designer generates for a plain `INSERT (cols) VALUES (?cols)` with
>   placeholder names *equal* to the columns): `Fields[].Value:true`, mapping under
>   `input.mapping.values[0]`, schema under `values.items.properties`. Ground truth:
>   `Hospital_AI-Agent_Use_Case/endevour-api.flogo → appointment-booking/PostgreSQLInsert`.
> - **parameters-mode** (the suffix trick below): placeholder names *differ* from columns, so every one
>   stays a parameter. Ground truth: the shipped `PostgreSQL-CRUD` sample and
>   `Aerospace_Defense_MRO_Use_Case/…A2AServers.flogo → dispatch_technician_agent_flow/WriteRow`.
>
> The failure the rest of this section fixes is **not** "you used values-mode"; it is a **hybrid** —
> the `Fields[].Value` flag says one mode while the mapping/schema live in the other container. If you
> INSERT with column-named placeholders, either let it be a clean values-mode activity, or apply the
> suffix trick below to make it a clean parameters-mode one. Never leave it split across both.

For `INSERT INTO t (colA, colB, ...) VALUES (?...)`, the designer auto-classifies each `?placeholder`:
a placeholder whose **name matches a column in the column-list** is moved to the `values` slot; a
name that **doesn't match** stays a `parameter`. If you map everything under `parameters` (the pattern
that works at runtime) but your placeholder names equal the column names, the designer moves them to
`values`, the parameters mapping no longer lines up, and you get the red ✗ (the mapping collapses to a
single object at the top of the mapper).

**Fix (canonical — matches the shipped `PostgreSQL-CRUD` sample `?id1, ?name1, …`):** name every
INSERT placeholder so it does **not** match any column — append a digit or suffix (`?colA1`). Then all
placeholders stay parameters, and the parameters mapping is clean AND runtime-correct.

```json
{
  "id": "PostgreSQLInsert",
  "settings": { "retryOnError": { "count": 0, "interval": 0 } },
  "activity": {
    "ref": "#insert",
    "input": {
      "Connection": "conn://<pg-uuid>",
      "Schema": "public",
      "Query": "INSERT INTO t (colA, colB, amount, status) VALUES (?colA1, ?colB1, ?amount1, 'OPEN');",
      "manualmode": false,
      "Fields": [
        { "FieldName": "colA1",   "Type": "VARCHAR", "Selected": false, "Parameter": true, "isEditable": false, "Value": false },
        { "FieldName": "colB1",   "Type": "VARCHAR", "Selected": false, "Parameter": true, "isEditable": false, "Value": false },
        { "FieldName": "amount1", "Type": "NUMERIC", "Selected": false, "Parameter": true, "isEditable": false, "Value": false }
      ],
      "RuntimeQuery": "",
      "State": "<uuid><the INSERT statement>",
      "input": { "mapping": { "parameters": {
        "colA1":   "=$flow.toolParams.colA",
        "colB1":   "=$flow.toolParams.colB",
        "amount1": "=$flow.toolParams.amount"
      } } }
    },
    "schemas": {
      "input":  { "input":  { "type": "json",
        "value": "{\"$schema\":\"http://json-schema.org/draft-04/schema#\",\"type\":\"object\",\"definitions\":{},\"properties\":{\"values\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{}}},\"parameters\":{\"type\":\"object\",\"properties\":{\"colA1\":{\"type\":\"string\"},\"colB1\":{\"type\":\"string\"},\"amount1\":{\"type\":\"number\"}}}}}" } },
      "output": { "Output": { "type": "json",
        "value": "{\"$schema\":\"http://json-schema.org/draft-04/schema#\",\"type\":\"object\",\"definitions\":{},\"properties\":{\"records\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{}}}}}" } }
    }
  }
}
```

Rules for INSERT:
- **Placeholder names ≠ column names** (append `1`/suffix). Positional order still maps them to the
  right columns; the name is only a bind identifier.
- Every param Field: `Parameter:true, Value:false`.
- Schema: `values.items.properties` **empty `{}`**; put all params under `parameters.properties`.
- Map under `input.mapping.parameters`, keyed by the suffixed names → `=$flow.toolParams.<realName>`.
- Literals (`'OPEN'`, `CURRENT_DATE`, `CURRENT_DATE + INTERVAL '5 days'`, `CURRENT_TIMESTAMP`) go
  straight in the SQL — no placeholder needed.
- Also keep the copy of the statement in `State` in sync with `Query`.

Note: `fe_metadata` mirrors `value` in each schema block — set both to the same string.

---

## D. Deriving a NOT-NULL foreign key the prompt never carries (INSERT … SELECT)

Write agents often INSERT into a table with a **NOT-NULL foreign-key column** (e.g. an owner/account id)
that a natural-language prompt will never contain — the user names an entity by a *friendly* key (an order
number, a tracking code, an email), not by the internal FK. If the INSERT maps that FK column from
`=$flow.toolParams.<fk>`, the LLM sends null and you get
`pq: null value in column "<fk>" violates not-null constraint`. The agent then stalls, asking the user for
an id they don't know.

**Fix — derive the FK in SQL from the parent row the user DID name.** When the flow can look up a parent
by a provided key, rewrite the INSERT as `INSERT … SELECT` that pulls the FK from that parent row, with
`COALESCE(NULLIF(?fk,''), parent.<fk>)` so an explicitly-supplied value still wins:

```sql
INSERT INTO public.<child> (<key_col>, <fk_col>, <c3>, <c4>, status)
SELECT p.<key_col>, COALESCE(NULLIF(?p2,''), p.<fk_col>), ?p3, NULLIF(?p4,'')::date, 'Requested'
FROM   public.<parent> p
WHERE  p.<key_col> = ?p1;
```

Rules:
- **Keep the same `?placeholder` set** (`?p1…?pN` all still referenced). This is a **query-text-only**
  change, so the 3-part contract above stays aligned — no Sync, no red ✗ (patch `Query` **and** `State`).
- Reference the lookup key `?p1` **once**, in the `WHERE`; take every derived column from the
  `SELECT … FROM <parent>` row. Referencing the same placeholder twice invites duplicate-param ambiguity.
- Use `NULLIF(?p,'')` to treat the LLM's empty string as "not supplied", then apply `::date` / `::numeric`
  casts *after* the `NULLIF`. Never cast the placeholder itself with `::` — `?p::date` is not substituted
  (see the ⚠️ placeholder rule at the top); use `CAST(?p AS date)` when there is no enclosing expression.
- **Validate before shipping** with a rolled-back transaction:
  `BEGIN; INSERT … RETURNING *; ROLLBACK;`.
- Applies whenever the child has a NOT-NULL FK derivable from a parent the prompt DOES name. It does
  **not** apply when there is no parent to derive from — then the FK is a genuine required input the
  orchestrator/agent must collect or default explicitly.

---

## E. Password-typed connector fields — the value must carry a `SECRET:` prefix

Some connector inputs are **password-typed** in the activity's own schema — the clearest example is the
`#sendmail` `Password` input. The designer does **not** read a JSON `type:"password"` (app-property JSON
`type` is always `string`); it **derives `dataType=password` from the value having a leading `SECRET:`
prefix**. So a password-typed field whose backing value is a plain string makes the designer infer
`dataType=string` and the field errors with **`wrongTypeProp`** ("mapping is not there" / red ✗).

Rules (generic — applies to any connector field the designer types as `password`):
- Bind the field to an **app property**, e.g. `#sendmail.Password = "=$property[<EmailPwdProp>]"` — don't
  inline a literal.
- That property's **value must resolve to a `SECRET:`-prefixed string**, never a plain placeholder.
- Keep the property JSON `type` as **`string`** — do **not** set `type:"password"` (the designer drops
  it on save).
- **How to get a working `SECRET:` value without shipping a real secret:** the value the designer stores
  is AES ciphertext under Flogo's data-secret key (the shared build-time default when
  `FLOGO_DATA_SECRET_KEY` is unset), so a **designer-produced `SECRET:` blob of a *dummy* value is
  portable** across apps that use that default key — it decrypts cleanly, keeps `dataType=password`, and
  leaks nothing. This is the same "carry `SECRET:` values verbatim from a cloned app" rule the SKILL
  states — reuse an existing dummy blob; **never fabricate a `SECRET:` string from scratch** (fake
  ciphertext fails to decrypt → *"An error occurred while attempting to decrypt secrets"* and the app
  won't render), and never scrub a password-typed field to a bare placeholder (that reintroduces
  `wrongTypeProp`). Verify a scrubbed dummy by loading the app in the designer.
- **Distinction from ordinary secret scrubbing:** non-password-typed secrets (OpenAI key, DB password in
  a connection block) are scrubbed to *plain* placeholders per SECURITY.md; only genuinely
  *password-typed activity fields* need the `SECRET:`-dummy treatment.

---

## Validation gate — run before declaring any app done

`references/validate_flogo_apps.py` is a generic, no-hardcoding checker for the two defect classes above
plus the 3-part `toolParams` contract. Run it on every `.flogo` you author or edit; fix everything it
prints before you tell the user the app is done.

```bash
python references/validate_flogo_apps.py <path/to/App1.flogo> [App2.flogo ...]
# or, from the use-case folder, scan everything:
python /full/path/to/validate_flogo_apps.py            # globs **/*.flogo under cwd
```

It verifies, for every wi-postgres activity (found through the app's `imports`, whatever its alias —
`#query`, `#insert`, `#update`, `#delete`, `#query_1`, …), walking any app (no app/column/property names
baked in):

1. **Mapping-mode integrity** — reads the authoritative `Fields[].Value` flag, then confirms the mapping
   container (`values[0]` vs `parameters`) and the populated schema container agree with it. Flags the
   **hybrid** (flag says one mode, mapping/schema in the other) — the single most common defect.
2. **Every `?placeholder` is mapped** (else runtime `missing substitution for: <name>`) **and is actually
   substituted by the connector** — it replays the connector's own `?name` → `$N` rewrite and flags any
   placeholder left behind (`?p5::date`, `?a||?b`), the cause of the designer's `syntax error at or near
   "$5p5"`.
3. **`Fields[]` non-empty on writes**, and **`State` carries a verbatim copy of `Query`**.
4. **Schema names == mapping keys** in the populated container.
5. **`toolParams` flow-input schema present** on any flow that reads `$flow.toolParams` (3-part
   contract #2 — otherwise click the trigger **Sync**).
6. **Password-typed fields** (e.g. `#sendmail Password`) resolve to a `SECRET:` value, not a plain
   string.

Exit code is non-zero when it finds anything, so it can gate a build. Note it catches design-time
alignment and secret-type issues, not table/column existence — still run the real SQL against a loaded DB
(Phase 5) to catch schema mismatches.
