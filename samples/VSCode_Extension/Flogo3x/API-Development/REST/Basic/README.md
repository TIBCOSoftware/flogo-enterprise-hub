# REST Basic — Producer & Consumer Services — Flogo 3

## Overview

This sample demonstrates the core REST features of **TIBCO Flogo® 3** using two folder-based apps: a **producer** service (`flogo.rest.service`) that exposes a REST endpoint driven by an imported API spec with multiple response codes, and a **consumer** service (`Invoke.flogo.rest.service`) that calls the producer using the Invoke REST Service activity. Together they show how API specs auto-populate parameters and schemas, how branching returns different HTTP response codes, and how `ConfigureHTTPResponse` maps response bodies/headers to a `Return`.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **ReceiveHTTPMessage** | `#rest` trigger | REST endpoint configured from an imported API spec; path, query, and header params auto-populated |
| **Invoke REST Service** | `#rest` activity | Calls the producer service; URL is driven by the `InvokeRestURL` app property |
| **Configure HTTP Response** | `#httpresponse` activity | Maps a response body + headers for a specific response code into `Return` |
| **Mapper** | `#mapper` activity | Uses an app-level schema for request/response mapping |
| **Return** | `#actreturn` activity | Returns a per-branch response (200 / 222 / 400 / 500) |
| **Log** | `#log` activity | Prints branch progress to the terminal |

## Architecture

```
  Client (curl / Postman)
      |
      |  POST /bookdetails/{bookname}/{ISBN}/{authorName}   (port 9999)
      v
 +----------------------------------------------------------+
 |  Invoke.flogo.rest.service  (consumer)                    |
 |    ReceiveHTTPMessage trigger                             |
 |      -> InvokeRESTService (Uri = $property.InvokeRestURL) |
 |      -> branch by response code                           |
 |      -> ConfigureHTTPResponse -> Log -> Return            |
 +----------------------------------------------------------+
      |
      |  POST http://localhost:9998/bookdetails/...          (InvokeRestURL)
      v
 +----------------------------------------------------------+
 |  flogo.rest.service  (producer)                           |
 |    ReceiveHTTPMessage trigger (API spec, multi-response)  |
 |      -> Mapper -> branch by condition                     |
 |      -> ConfigureHTTPResponse -> Log -> Return            |
 |      responses: 200 / 222 / 400 / 500                     |
 +----------------------------------------------------------+
```

- **flogo.rest.service** (producer) listens on port **9998**. Its `ReceiveHTTPMessage` trigger is configured from the app-level API spec, so path/query/header parameters and the multiple response codes (200, 222, 400, 500) are auto-populated. Each response code is returned from its own branch based on payload/query conditions.
- **Invoke.flogo.rest.service** (consumer) listens on port **9999**. It calls the producer through the Invoke REST Service activity, whose `Uri` reads the `InvokeRestURL` app property, then branches on the response code it receives back.

## Files in This Sample

Each Flogo 3 app is a folder-based project (the folder containing `app.fgmd`).

| Path | Description |
|---|---|
| `flogo.rest.service/app.fgmd` | Producer app metadata (`flogoVersion: 3.0.0`) |
| `flogo.rest.service/app.fgprops` | Producer app properties (none defined) |
| `flogo.rest.service/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger on port `9998`, configured from `book_details.spec.json` |
| `flogo.rest.service/flows/postBookDetails.fgflow` | Producer flow — Mapper → branch → ConfigureHTTPResponse → Return (200/222/400/500) |
| `flogo.rest.service/specs/book_details.spec.json` | API spec (`POST /bookdetails/{bookname}/{ISBN}/{authorName}`) |
| `flogo.rest.service/schemas/*.json` | App-level request/response schemas |
| `Invoke.flogo.rest.service/app.fgmd` | Consumer app metadata (`flogoVersion: 3.0.0`) |
| `Invoke.flogo.rest.service/app.fgprops` | Consumer app properties — defines `InvokeRestURL` |
| `Invoke.flogo.rest.service/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger on port `9999` |
| `Invoke.flogo.rest.service/flows/post_Invokebookdetails.fgflow` | Consumer flow — InvokeRESTService → branch → ConfigureHTTPResponse → Return |
| `Invoke.flogo.rest.service/specs/book_details.spec.json` | API spec used to configure the Invoke REST Service activity |
| `Invoke.flogo.rest.service/schemas/BooksRequestSchema.json` | App-level schema |

The two apps are related: the **consumer** (`Invoke.flogo.rest.service`, port 9999) forwards requests to the **producer** (`flogo.rest.service`, port 9998) via its `InvokeRestURL` property. Start the producer first.

## Prerequisites

- TIBCO Flogo 3 extension for Visual Studio Code.
- No broker, database, or external runtime is required — these are pure-Go REST apps.

## Setup & Run

### Step 1 — Open the app in VS Code

Open this `Basic` folder in VS Code with the Flogo 3 extension. The extension detects the `flogo.rest.service` and `Invoke.flogo.rest.service` projects (each folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In `Invoke.flogo.rest.service`, open the `app.fgprops` file for App Properties and set `InvokeRestURL` to the base URL of the running producer service (default `http://localhost:9998`). The producer app (`flogo.rest.service`) defines no app properties. See the [App Properties Reference](#app-properties-reference) below.

### Step 3 — Create & select the Local Runtime

Click the Flogo 3 icon in the VS Code menu bar → in RUNTIME EXPLORER, add a new runtime with the + button → give it a name → Save.

### Step 4 — Build and Run

In the FLOGO3: WORKSPACE APPS EXPLORER, select an app module → right-click → Run As Executable. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. **Build and run `flogo.rest.service` (port 9998) first, then `Invoke.flogo.rest.service` (port 9999).**

### Step 5 — Invoke the endpoint

Call the producer directly (port 9998):

```bash
curl -X POST "http://localhost:9998/bookdetails/GoInAction/978-1617291784/WilliamKennedy?available=true&price=45&id=5" \
  -H "Content-Type: application/json" \
  -d '{"Book":[{"id":1,"name":"GoInAction","authorName":"WilliamKennedy","isbn":"978-1617291784","price":45,"signed":true,"vintage":false}]}'
```

Or call the consumer (port 9999), which forwards to the producer:

```bash
curl -X POST "http://localhost:9999/bookdetails/GoInAction/978-1617291784/WilliamKennedy?available=true&price=45&id=5" \
  -H "Content-Type: application/json" \
  -d '{"Book":[{"id":1,"name":"GoInAction","authorName":"WilliamKennedy","isbn":"978-1617291784","price":45,"signed":true,"vintage":false}]}'
```

The response code depends on the branch conditions: a `200` (success), `222` (custom), `400` (client error, e.g. `id` out of the 0–10 range), or `500` (server error) is returned with the corresponding body and headers.

## App Properties Reference

**`Invoke.flogo.rest.service`**

| Property | Default | Description |
|---|---|---|
| `InvokeRestURL` | `http://localhost:9998` | Base URL of the producer service invoked by the Invoke REST Service activity; override at runtime to point at a different endpoint |

**`flogo.rest.service`** — no app properties defined.

## Troubleshooting

- **Consumer returns no data / connection refused** — start the producer (`flogo.rest.service`, port 9998) before the consumer, and confirm `InvokeRestURL` points at the running producer.
- **Unexpected response code** — responses are driven by branch conditions (e.g. `id` must be within a valid range, book array size within limits). Check your query/body values against the conditions.
- **Port already in use** — the producer binds `9998` and the consumer `9999`; free the ports or change them in the respective `ReceiveHTTPMessage.fgtrigger`.
- **Parameters not populated** — the trigger and Invoke activity are configured from `book_details.spec.json`; ensure the spec is present under the app's `specs/` folder.

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
