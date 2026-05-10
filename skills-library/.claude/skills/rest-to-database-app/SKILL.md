---
name: rest-to-database-app
description: Step-by-step guide to create a Flogo REST API application that queries a database and returns the result
user-invocable: true
---

## Key Facts (verified)

- Always run `fda` commands from your Flogo apps directory (e.g. `./Flogo_Apps/`)
- **Always use the `-f <filename>.flogo` flag** on every `fda` command to target the correct file — if omitted, fda defaults to `flogo-project.flogo` and will error if that file already exists or is not the intended target
- REST trigger type: `tr_rest` — exposes HTTP endpoints (default port 9999)
- Log activity type: `act_general_log`
- Reply activity type: `act_general_reply`
- Database query activity types: `act_mysql_query`, `act_postgresql_query`, `act_sqlserver_query`, `act_oracledatabase_query`
- Database connection types: `con_mysql` (MySQL), `con_postgresql` (PostgreSQL), `con_sqlserver` (SQLServer), `con_oracledb` (Oracle)
- Activities are automatically linked in sequence when added (no need to call `create-link`)
- The `--connection` flag on `create-activity` links the activity to a named connection — this sets `settings.connection` on the activity (the `input.Connection` field is left empty and is unused)
- When a connection is created, its settings are **automatically pre-wired to application properties** (e.g. `$property["MySQL.<ConnectionName>.Host"]`). Set those properties to configure the actual DB credentials — do NOT set `connection.settings.*` directly
- Flow input parameters must be declared in `flow.metadata.input` before they can be referenced as `$flow.<param>`
- Trigger handler input mapping (`action.input`) is how path/query params flow from the trigger into the flow
- `set-attribute` for handler mappings uses `--jsonValue` for object values
- Always call `format-flow` at the end to lay out the canvas properly

---

## Step 1: Create project and database connection

Run all commands from your Flogo apps directory. Use `-f <filename>.flogo` on every command to target the correct file.

```bash
fda -f <filename>.flogo create-project <AppName> "<App description>"

# Choose the connection type that matches the target database
fda -f <filename>.flogo create-connection <ConnectionName> MySQL        # or PostgreSQL, SQLServer, oracledb
```

---

## Step 2: Create the flow, trigger, and handler

```bash
# Create the flow
fda -f <filename>.flogo create-flow <FlowName> "<Flow description>"

# Create the REST trigger
fda -f <filename>.flogo create-trigger <TriggerName> rest "<Trigger description>"

# Create the handler — links the trigger path+method to the flow
fda -f <filename>.flogo create-trigger-handler <FlowName> <TriggerName> "<Handler description>" \
  --restResourcePath "/<resource>/{<pathParam>}" \
  --restHandlerMethod GET
```

Supported HTTP methods: `GET`, `POST`, `PUT`, `DELETE`, `PATCH`

---

## Step 3: Add activities in sequence

Activities are auto-linked in the order they are added.

```bash
# 1. Log the incoming request
fda -f <filename>.flogo create-activity <FlowName> LogRequest act_general_log "Log incoming request"

# 2. Query the database
#    The --connection flag sets settings.connection on the activity to the named connection's ID.
#    This is the ONLY step needed to bind the activity to the connection — do not set input.Connection separately.
fda -f <filename>.flogo create-activity <FlowName> QueryDatabase act_mysql_query "Query database" \
  --connection <ConnectionName>

# 3. Log the result
fda -f <filename>.flogo create-activity <FlowName> LogResult act_general_log "Log query result"

# 4. Reply to the REST caller
fda -f <filename>.flogo create-activity <FlowName> ReplyData act_general_reply "Reply with data"
```

---

## Step 4: Declare the flow input parameter

The flow needs an explicit input parameter so trigger mappings and activity expressions can reference `$flow.<param>`.

```bash
fda -f <filename>.flogo set-attribute flow "<FlowName>.metadata.input" "" \
  --jsonValue '[{"name": "<pathParam>", "type": "string"}]'
```

---

## Step 5: Configure activity attributes

**LogRequest** — log the incoming path parameter:
```bash
fda -f <filename>.flogo set-attribute activity "<FlowName>.LogRequest.input.message" \
  'string("Received request for <resource> ID: ") + coerce.toString($flow.<pathParam>)'
```

**QueryDatabase** — set the query name, SQL, and input binding:
```bash
fda -f <filename>.flogo set-attribute activity "<FlowName>.QueryDatabase.input.QueryName" "Get<Resource>ById"

fda -f <filename>.flogo set-attribute activity "<FlowName>.QueryDatabase.input.Query" \
  "SELECT <columns> FROM <table> WHERE id = ?"

fda -f <filename>.flogo set-attribute activity "<FlowName>.QueryDatabase.input.input" "" \
  --jsonValue '{"id": "$flow.<pathParam>"}'
```

**LogResult** — log the data returned from the database:
```bash
fda -f <filename>.flogo set-attribute activity "<FlowName>.LogResult.input.message" \
  'string("<Resource> data retrieved: ") + coerce.toString($activity[QueryDatabase].output)'
```

**ReplyData** — send the query output back to the caller:
```bash
fda -f <filename>.flogo set-attribute activity "<FlowName>.ReplyData.input.data" "" \
  --jsonValue '{"<resource>Data": "$activity[QueryDatabase].output"}'
```

---

## Step 6: Configure trigger handler mappings

Map the path parameter from the trigger into the flow, and map the reply output back.

```bash
# Trigger → Flow: pass path param into flow input
fda -f <filename>.flogo set-attribute handler "<TriggerName>.<FlowName>.action.input" "" \
  --jsonValue '{"<pathParam>": "$trigger.pathParams.<pathParam>"}'

# Flow → Reply: set the HTTP response body and code
fda -f <filename>.flogo set-attribute handler "<TriggerName>.<FlowName>.reply.data" "" \
  --jsonValue '{"body": "$activity[ReplyData].output.data"}'

fda -f <filename>.flogo set-attribute handler "<TriggerName>.<FlowName>.reply.code" "200"
```

---

## Step 7: Format the flow

```bash
fda -f <filename>.flogo format-flow <FlowName>
```

---

## Step 8: Configure the database connection credentials

When a connection is created, its settings are **automatically pre-wired to application properties**. Verify the exact property names first:

```bash
fda -f <filename>.flogo describe-attributes connection <ConnectionName>
```

Set each application property using the syntax: `create-app-property <name> <type> <value>` — the type argument (`string`, `number`, `boolean`) is required:

```bash
fda -f <filename>.flogo create-app-property "MySQL.<ConnectionName>.Host"          string "<db-host>"
fda -f <filename>.flogo create-app-property "MySQL.<ConnectionName>.Port"          number "3306"
fda -f <filename>.flogo create-app-property "MySQL.<ConnectionName>.Database_Name" string "<db-name>"
fda -f <filename>.flogo create-app-property "MySQL.<ConnectionName>.User"          string "<db-user>"
fda -f <filename>.flogo create-app-property "MySQL.<ConnectionName>.Password"      string "<db-password>"
```

---

## Complete example: Bookstore GET /books/{bookId}

```bash
cd ./Flogo_Apps

fda -f bookstore.flogo create-project BookstoreAPI "Bookstore REST API"
fda -f bookstore.flogo create-connection MySQLConnection MySQL

fda -f bookstore.flogo create-flow GetBook "Get book by ID"
fda -f bookstore.flogo create-trigger RestTrigger rest "Bookstore REST trigger"
fda -f bookstore.flogo create-trigger-handler GetBook RestTrigger "Handle GET /books/{bookId}" \
  --restResourcePath "/books/{bookId}" --restHandlerMethod GET

fda -f bookstore.flogo create-activity GetBook LogRequest     act_general_log   "Log request"
fda -f bookstore.flogo create-activity GetBook QueryDatabase  act_mysql_query   "Query DB" --connection MySQLConnection
fda -f bookstore.flogo create-activity GetBook LogResult      act_general_log   "Log result"
fda -f bookstore.flogo create-activity GetBook ReplyBookData  act_general_reply "Reply"

fda -f bookstore.flogo set-attribute flow "GetBook.metadata.input" "" \
  --jsonValue '[{"name": "bookId", "type": "string"}]'

fda -f bookstore.flogo set-attribute activity "GetBook.LogRequest.input.message" \
  'string("Received request for book ID: ") + coerce.toString($flow.bookId)'

fda -f bookstore.flogo set-attribute activity "GetBook.QueryDatabase.input.QueryName" "GetBookById"
fda -f bookstore.flogo set-attribute activity "GetBook.QueryDatabase.input.Query" \
  "SELECT id, title, author, isbn, price FROM books WHERE id = ?"
fda -f bookstore.flogo set-attribute activity "GetBook.QueryDatabase.input.input" "" \
  --jsonValue '{"id": "$flow.bookId"}'

fda -f bookstore.flogo set-attribute activity "GetBook.LogResult.input.message" \
  'string("Book data retrieved: ") + coerce.toString($activity[QueryDatabase].output)'

fda -f bookstore.flogo set-attribute activity "GetBook.ReplyBookData.input.data" "" \
  --jsonValue '{"bookData": "$activity[QueryDatabase].output"}'

fda -f bookstore.flogo set-attribute handler "RestTrigger.GetBook.action.input" "" \
  --jsonValue '{"bookId": "$trigger.pathParams.bookId"}'
fda -f bookstore.flogo set-attribute handler "RestTrigger.GetBook.reply.data" "" \
  --jsonValue '{"body": "$activity[ReplyBookData].output.data"}'
fda -f bookstore.flogo set-attribute handler "RestTrigger.GetBook.reply.code" "200"

fda -f bookstore.flogo format-flow GetBook

# Configure database credentials via application properties
fda -f bookstore.flogo create-app-property "MySQL.MySQLConnection.Host"          string "localhost"
fda -f bookstore.flogo create-app-property "MySQL.MySQLConnection.Port"          number "3306"
fda -f bookstore.flogo create-app-property "MySQL.MySQLConnection.Database_Name" string "bookstore"
fda -f bookstore.flogo create-app-property "MySQL.MySQLConnection.User"          string "dbuser"
fda -f bookstore.flogo create-app-property "MySQL.MySQLConnection.Password"      string "dbpassword"
```
