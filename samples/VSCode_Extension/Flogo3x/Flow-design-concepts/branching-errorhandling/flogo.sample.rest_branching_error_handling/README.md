# REST Branching & Error Handling — Flogo 3

## Overview

This sample demonstrates **conditional branching** and **error handling** in a REST flow using the **TIBCO Flogo® 3** folder-based project format. A single REST trigger routes requests to two flows: one returns all books, the other looks up a book by ISBN and branches on the response — returning data, logging a "not found" message, or throwing an error for an invalid ISBN that is then caught by a flow-level error handler.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST Trigger** | `trigger/rest` | One `#rest` trigger serving two paths on port `9999` |
| **Invoke REST Service** | `activity/rest` | Calls an external REST backend to fetch book data |
| **Conditional branches** | link `type: expression` | Routes execution based on the backend response / input validation |
| **Log Message** | `activity/log` | Logs "not found" and "invalid ISBN" diagnostics |
| **Throw Error** | `activity/error` | Raises an error for an invalid ISBN |
| **Error Handler** | flow `errorHandler` | Catches the thrown error and returns a formatted message |
| **Return** | `activity/actreturn` | Sends the correct HTTP response for each branch |

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/books
      |  GET http://localhost:9999/books/{isbn}
      v
 +-------------------------------------------------------------------------+
 |  flogo_sample_rest_branching_error_handling (Flogo 3 app)             |
 |                                                                         |
 |  REST Trigger (ReceiveHTTPMessage, port 9999)                           |
 |     |                                                                   |
 |     |-- GET /books ---------> getBooks flow                             |
 |     |        InvokeRESTService -> Return                                |
 |     |                                                                   |
 |     |-- GET /books/{isbn} --> getBookByISBN flow                        |
 |              InvokeRESTService1                                          |
 |                 |                                                       |
 |                 |-- (default) ----------------> Return1  (book JSON)    |
 |                 |-- responseBody == "[]" -----> LogMessage -> Return2   |
 |                 |-- isbn matches [^0-9] ------> LogMessage1 -> ThrowError|
 |                                                        |                |
 |                                                        v                |
 |                                        errorHandler: LogMessage2 -> Return3 |
 +-------------------------------------------------------------------------+
```

- **getBooks** (`GET /books`) calls the backend and returns the full book list.
- **getBookByISBN** (`GET /books/{isbn}`) calls the backend, then branches:
  - **Default** — a book was found → `Return1` renders the book JSON.
  - **Empty result** (`string.equals(string.tostring($activity[InvokeRESTService1].responseBody), "[]")`) → `LogMessage` logs "No Book found…" → `Return2`.
  - **Invalid ISBN** (`string.regex("[^0-9]", $flow.isbn)`) → `LogMessage1` logs "Invalid ISBN Number" → `ThrowError` raises an error, which the flow-level **error handler** catches (`LogMessage2` → `Return3`) and returns `string.concat($error.activity, " ", $error.message)`.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `flogo_sample_rest_branching_error_handling/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `flogo_sample_rest_branching_error_handling/app.fgprops` | App properties — backend `URL` and `LOG_LEVEL` |
| `flogo_sample_rest_branching_error_handling/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger on port `9999`, serving `GET /books` and `GET /books/{isbn}` |
| `flogo_sample_rest_branching_error_handling/flows/getBooks.fgflow` | `GET /books` → Invoke REST Service → Return all books |
| `flogo_sample_rest_branching_error_handling/flows/getBookByISBN.fgflow` | `GET /books/{isbn}` → Invoke REST Service → branch (Return / Log / Throw Error) with an error handler |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
- Outbound network access to the backend REST API used by the sample: `https://my-json-server.typicode.com/tibcosoftware/tci-flogo/Book`.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `flogo_sample_rest_branching_error_handling` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `.fgprops` file for App Properties and set the values for your environment (see the [App Properties Reference](#app-properties-reference) below). The `URL` property points the Invoke REST Service activities at the book backend; leave the default to use the public sample API.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

Get all books:

```bash
curl "http://localhost:9999/books"
```

Get a book by a valid ISBN (returns the book JSON):

```bash
curl "http://localhost:9999/books/1451648537"
```

Get a book by an ISBN that has no match (returns "No Book found with the given ISBN Number"):

```bash
curl "http://localhost:9999/books/999"
```

Trigger the invalid-ISBN branch and error handler (non-numeric ISBN):

```bash
curl "http://localhost:9999/books/abc"
```

You can browse valid ISBNs in the backend data at `https://my-json-server.typicode.com/tibcosoftware/tci-flogo/Book`.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `URL` | `https://my-json-server.typicode.com/tibcosoftware/tci-flogo/Book` | Backend REST endpoint called by the Invoke REST Service activities |
| `LOG_LEVEL` | `INFO` | Log level for the app |

---

## Troubleshooting

- **Empty or error response from `/books`** — verify outbound connectivity and that the `URL` app property is reachable; the default backend is a public service that must be accessible from your machine.
- **`GET /books/{isbn}` always returns "No Book found"** — the ISBN has no matching record in the backend data. Use a valid ISBN from the backend list.
- **Port 9999 already in use** — another process (or a previous run) is bound to the trigger port. Stop it or change the trigger port, then rebuild and run.
- **Invalid-ISBN branch not firing** — the branch matches non-numeric input via `string.regex("[^0-9]", $flow.isbn)`; supply a value containing letters/symbols (e.g. `abc`) to exercise the Throw Error path and error handler.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — Creating a Flow Execution Branch](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all-vsc/creating-a-flow-exec.htm?TocPath=User%2520Guide%257CApp%2520Development%257CCreating%2520Flows%2520and%2520Triggers%257CFlows%257CCreating%2520a%2520Flow%2520Execution%2520Branch%257C_____0).
