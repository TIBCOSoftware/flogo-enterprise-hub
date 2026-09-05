# Subflows — Basic (Attached & Detached Invocation) — Flogo 3

## Overview

This sample demonstrates how to build and invoke **subflows** in **TIBCO Flogo® 3** folder-based projects using the **Start a SubFlow** activity. It covers both invocation modes: **attached** (the caller waits for the subflow to finish and can read its output) and **detached** (fire-and-forget — the caller continues without waiting).

Two independent apps are included:

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **Start a SubFlow** | `flow/activity/subflow` | Calls a reusable subflow from a parent flow (attached and detached) |
| **Invoke REST Service** | `General/activity/rest` | Calls a backend REST API to fetch book data |
| **REST** | `General/trigger/rest` | `GET /books` and `GET /books/{isbn}` entry points (port `9999`) |
| **Timer** | `General/trigger/timer` | Fires the detached-invocation demo once |
| **Return** | `contrib/activity/actreturn` | Sends the JSON response back to the REST caller |
| **Error** | `contrib/activity/error` | Raises an error for invalid input (ISBN validation) |
| **Log / Sleep / Mapper / NoOp** | General & contrib activities | Trace ordering and subflow data flow |

---

## Architecture

### App 1 — `flogo.sample.rest_with_subflows`

```
  Client (curl / browser)
      |
      |  GET http://localhost:9999/books
      |  GET http://localhost:9999/books/{isbn}
      v
 REST Trigger (ReceiveHTTPMessage, port 9999)
      |
      +--> getBooks
      |       InvokeRESTService -> StartaSubFlow(SubFlowLogging) -> Return
      |
      +--> getBookByISBN
              InvokeRESTService1
                 |-- (default)              -> StartaSubFlow3(SubFlowLogging) -> Return1
                 |-- responseBody == "[]"   -> StartaSubFlow1(SubFlowLogging) -> Return2
                 |-- isbn has non-digits    -> StartaSubFlow2(SubFlowLogging) -> ThrowError

 SubFlowLogging (no trigger): LogMessage4 -> LogMessage3
```

Both flows call the shared, trigger-less **SubFlowLogging** subflow in attached mode to log messages. `getBookByISBN` branches on link expressions to handle a found book, an empty result (`[]`), and an invalid (non-numeric) ISBN.

### App 2 — `flogo.sample.subflows_detachedInvocation`

```
 Timer Trigger (fires once)
      |
      v
 mainflow:  NoOp -> Mapper -> StartaSubFlow(subflow1, detached=true) -> LogMessage
                                     |  (fire-and-forget)
                                     v
 subflow1:  NoOp -> Mapper -> Sleep -> StartaSubFlow(subflow2, detached=false) -> LogMessage
                                                 |  (waits for subflow2)
                                                 v
 subflow2:  NoOp -> Mapper -> LogMessage
```

Because `mainflow` calls `subflow1` with `detached: true`, it does not wait — `mainflow`'s log prints first, then `subflow2`'s, then `subflow1`'s (after its `Sleep`). The timestamps in the log make the ordering visible.

---

## Files in This Sample

Each Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `flogo.sample.rest_with_subflows/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `flogo.sample.rest_with_subflows/app.fgprops` | App properties — backend `URL` and `LOG_LEVEL` |
| `flogo.sample.rest_with_subflows/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger on port `9999` |
| `flogo.sample.rest_with_subflows/flows/getBooks.fgflow` | `GET /books` — invoke REST, call subflow, return all books |
| `flogo.sample.rest_with_subflows/flows/getBookByISBN.fgflow` | `GET /books/{isbn}` — invoke REST, branch, call subflow / raise error |
| `flogo.sample.rest_with_subflows/flows/SubFlowLogging.fgflow` | Trigger-less subflow invoked for logging |
| `flogo.sample.subflows_detachedInvocation/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `flogo.sample.subflows_detachedInvocation/app.fgprops` | App properties (none defined) |
| `flogo.sample.subflows_detachedInvocation/triggers/TimerTrigger.fgtrigger` | Timer trigger — fires the demo once |
| `flogo.sample.subflows_detachedInvocation/flows/mainflow.fgflow` | Parent flow — invokes `subflow1` in **detached** mode |
| `flogo.sample.subflows_detachedInvocation/flows/subflow1.fgflow` | Subflow — invokes `subflow2` in **attached** mode |
| `flogo.sample.subflows_detachedInvocation/flows/subflow2.fgflow` | Innermost subflow — logs a message |

The two apps are independent and illustrate the same feature from two angles: `flogo.sample.rest_with_subflows` shows practical attached subflow reuse behind a REST API, while `flogo.sample.subflows_detachedInvocation` isolates the difference between detached and attached invocation.

---

## Prerequisites

- TIBCO Flogo® 3 extension for Visual Studio Code.
- Outbound internet access from the runtime host — `flogo.sample.rest_with_subflows` calls the public backend `https://my-json-server.typicode.com/tibcosoftware/tci-flogo/Book`.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects each project (the folder containing `app.fgmd`) — `flogo.sample.rest_with_subflows` and `flogo.sample.subflows_detachedInvocation`.

### Step 2 — Configure App Properties

For `flogo.sample.rest_with_subflows`, open the `.fgprops` file for App Properties and confirm the backend `URL` and `LOG_LEVEL` for your environment (see the [App Properties Reference](#app-properties-reference) below). `flogo.sample.subflows_detachedInvocation` defines no properties.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal.

### Step 5 — Invoke the endpoint

**`flogo.sample.rest_with_subflows`** — the REST trigger listens on port `9999`:

```bash
# Get all books
curl "http://localhost:9999/books"

# Get a book by ISBN (valid, numeric)
curl "http://localhost:9999/books/1451648537"

# Invalid (non-numeric) ISBN -> triggers the error branch
curl "http://localhost:9999/books/abc"
```

Valid requests return the book JSON from the backend; an empty result returns `No Book found with the given ISBN Number`; a non-numeric ISBN raises an error. The `SubFlowLogging` subflow logs progress to the terminal in every case.

**`flogo.sample.subflows_detachedInvocation`** — the Timer trigger fires automatically once shortly after start. Watch the integrated terminal: `mainflow`'s log line appears before `subflow1`'s (proving the detached, non-blocking call), while `subflow2` completes before `subflow1` continues (the attached call blocks). Compare the log timestamps to confirm the ordering.

---

## App Properties Reference

### `flogo.sample.rest_with_subflows`

| Property | Default | Description |
|---|---|---|
| `URL` | `https://my-json-server.typicode.com/tibcosoftware/tci-flogo/Book` | Backend REST API used by the Invoke REST Service activities |
| `LOG_LEVEL` | `INFO` | Application log level |

### `flogo.sample.subflows_detachedInvocation`

No app properties are defined for this app.

---

## Troubleshooting

- **REST calls time out or return empty data** — the backend `URL` requires outbound internet access. Verify connectivity to `https://my-json-server.typicode.com` or point `URL` at a reachable equivalent.
- **`address already in use` on port 9999** — another process (or a previous run) is bound to `9999`. Stop it, or change the port in the REST trigger settings.
- **Detached ordering looks wrong** — the ordering depends on the `Sleep` in `subflow1`; if you edit or remove it, the interleaving of the log lines changes accordingly.
- **`GET /books/{isbn}` always errors** — the ISBN must be numeric; the branch `string.regex("[^0-9]", $flow.isbn)` routes any non-digit input to the Error activity by design.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — Using Subflows](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all-vsc/creating-subflows.htm?TocPath=User%2520Guide%257CApp%2520Development%257CCreating%2520Flows%2520and%2520Triggers%257CFlows%257CUsing%2520Subflows%257C_____1).
