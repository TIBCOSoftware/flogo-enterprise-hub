# PostgreSQL Activity Patterns (the gotchas that cause mapper errors)

The `wi-postgres` `#query` and `#insert` activities parameterize via `?placeholder` in the SQL,
`Fields[]` entries, an `input.mapping` object, and a `schemas.input.input.value` JSON-Schema string.
Get any of these out of alignment and the Flogo mapper shows a red ✗ on the activity's Input tab.

**Golden rule:** for a given activity, the set of `?params` in the Query must exactly equal the
`Fields` param names, the `input.mapping.parameters` keys, and the schema's `parameters.properties`
keys. Never use `RuntimeQuery` for parameters. Verify by running the real SQL against a loaded DB.

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

## C. INSERT — THE ONE THAT BREAKS. Suffix placeholder names so they DON'T match columns.

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

## Consistency check (run after authoring any A2A app)

```python
import json, re
d = json.load(open("<App>A2AServers.flogo", encoding="utf-8"))
for res in d["resources"]:
    for t in res["data"]["tasks"]:
        a = t.get("activity", {})
        if a.get("ref") not in ("#insert", "#query"): continue
        inp = a["input"]
        qp = sorted(re.findall(r"\?(\w+)", inp["Query"]))
        fp = sorted(f["FieldName"] for f in inp["Fields"] if f.get("Parameter"))
        mp = sorted(inp.get("input", {}).get("mapping", {}).get("parameters", {}).keys())
        sp = sorted(json.loads(a["schemas"]["input"]["input"]["value"])["properties"]["parameters"]["properties"].keys())
        assert qp == fp == mp == sp, (t["id"], qp, fp, mp, sp)
print("all query/insert params aligned")
```
For INSERTs also assert `values.items.properties` is empty and that no `?param` equals a target column name.
