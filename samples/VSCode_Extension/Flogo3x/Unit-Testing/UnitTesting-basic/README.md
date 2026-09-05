# Unit Testing (Basic) — Flogo 3

## Overview

This sample demonstrates **unit testing of Flogo flows and activities** in the **TIBCO Flogo® 3** folder-based project format. The app looks up a customer's zip code by calling a public REST service, and ships two flows that let you exercise the core unit-testing techniques — assert on output, assert on error, mock output, and mock error — so you can validate individual activities in isolation without depending on live external services.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST trigger** | `#rest` trigger | `GET /test2/{id}` entry point (port `9999`) that starts `GetZipcode` |
| **Invoke REST Service** | `#rest` activity | Calls an external REST endpoint to fetch user data — the unit under test for mocking |
| **Mapper** | `#mapper` activity | Extracts `address.zipcode` from the REST response |
| **Log Message** | `#log` activity | Prints progress to the runtime terminal |
| **Return** | `#actreturn` activity | Returns the resolved zip code to the caller |
| **NoOp** | `#noop` activity | Flow start activity |

The unit-testing concepts this sample is built for:

- **Assert on output** — pass a valid `id` so the REST call resolves and assert the returned zip code.
- **Assert on error** — pass a non-existent `id` so the zip-code path is not found (`Invalid path '.address.zipcode'. path not found.`) and assert on the error.
- **Mock output / mock error** — replace the Invoke REST Service result with mocked data or a mocked error so the test runs even when the external service is down or inaccessible.

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `UnitTesting/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name `UnitTesting`, version `1.0.0`) |
| `UnitTesting/app.fgprops` | App properties (none defined for this sample) |
| `UnitTesting/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /test2/{id}` on port `9999` → `GetZipcode` |
| `UnitTesting/flows/GetZipcode.fgflow` | Main flow — invokes `https://jsonplaceholder.typicode.com/users/{id}`, maps `address.zipcode`, returns it (assert-on-output / assert-on-error target) |
| `UnitTesting/flows/GetZipcode-With-DummyURL.fgflow` | Variant flow — invokes an unreachable dummy URL (`https://dummyurl.typicode.com/users/{id}`) to exercise mock output / mock error |

Both flows share the same activity chain (`noop → Invoke REST Service → Mapper → Log → Return`). `GetZipcode` is wired to the REST trigger and points at a working endpoint; `GetZipcode-With-DummyURL` points at a deliberately invalid endpoint so you can demonstrate mocking when the dependency is unavailable.

## Prerequisites

- TIBCO Flogo 3 extension for Visual Studio Code
- Outbound internet access to `https://jsonplaceholder.typicode.com` for the live (non-mocked) test path

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `UnitTesting` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

This sample defines no app properties, so no configuration is required. If you point the Invoke REST Service activity at a different endpoint, update it in the flow before running.

### Step 3 — Create & select the Local Runtime

Click the Flogo 3 icon in the VS Code menu bar → in RUNTIME EXPLORER, add a new runtime with the + button → give it a name → Save.

### Step 4 — Build and Run

In the FLOGO3: WORKSPACE APPS EXPLORER, select the `UnitTesting` app module → right-click → Run As Executable. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

Call the endpoint with a valid customer id (the id maps to a user on the public service):

```bash
curl "http://localhost:9999/test2/1"
```

You should receive the resolved zip code for that user. If you pass an id that does not resolve, the mapper cannot find `.address.zipcode` and the flow fails with `Invalid path '.address.zipcode'. path not found.` — the exact case the assert-on-error test verifies. To test without hitting the external service at all, mock the Invoke REST Service output/error in your test case (see the `GetZipcode-With-DummyURL` flow).

## App Properties Reference

This sample does not define any app properties (`app.fgprops` contains an empty properties list). No values need to be set for your environment.

## Troubleshooting

- **`Invalid path '.address.zipcode'. path not found.`** — the REST call returned data without an `address.zipcode` field (typically an id that does not resolve). This is expected for the assert-on-error scenario; use a valid id for the success path.
- **REST call times out or fails to connect** — the runtime has no outbound access to `jsonplaceholder.typicode.com`, or you are running the dummy-URL flow. Use a mock output/error for the Invoke REST Service activity to run the test offline.
- **Port `9999` already in use** — another process is bound to the port. Stop it or change the trigger port, then rebuild and run.

## Help

For additional information, see the [TIBCO Flogo® Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest) and the unit testing guidance for Flogo apps in the [TIBCO Flogo documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm).
