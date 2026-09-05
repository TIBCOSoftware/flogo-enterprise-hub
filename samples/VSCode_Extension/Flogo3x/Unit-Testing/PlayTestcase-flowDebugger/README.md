# Unit Testing — Play a Test Case Once (Flow Debugger) — Flogo 3

## Overview

This sample demonstrates the **Play (flow debugger)** feature of unit testing in the **TIBCO Flogo® 3** VS Code extension. You provide input to a flow and *play* it once — the flow executes on demand without firing its trigger, each activity runs independently and prints its logs, and the executed path is highlighted so you can spot errors early, before building the app. It mirrors the flow tester in TCI.

The `Play Feature` flow itself is a simple REST-backed lookup used as the subject under test.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /test2/{id}` on port `9999` starts the flow |
| **NoOp** | `noop` activity (`StartActivity`) | Flow start / branch point |
| **REST Invoke** | `#rest` activity (`InvokeRESTService`) | Calls `https://jsonplaceholder.typicode.com/users/{id}` |
| **Mapper** | `mapper` activity | Extracts `zipcode` from the REST response |
| **Log Message** | `log` activity | Prints values during play/debug execution |
| **Return** | `actreturn` activity | Returns `code 200` and the mapped `zipcode` |
| **Conditional link** | link expression | Branches to a second log when `$flow.pathParams.id == 1000` |

## Architecture

```
  GET http://localhost:9999/test2/{id}
      |
      v
  Play Feature (flow)
      StartActivity (noop)
         |------------------------------------> LogMessage1 (log)   [when pathParams.id == 1000]
         v
      InvokeRESTService (GET jsonplaceholder /users/{id})
         v
      Mapper (-> zipcode)
         v
      LogMessage (log zipcode)
         v
      Return (code 200, { zipcode })
```

- The main path resolves the user, maps out the `zipcode`, logs it, and returns it.
- The conditional link from `StartActivity` to `LogMessage1` fires only when the path param `id` equals `1000`, demonstrating branch coverage while playing a test case.

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `PlayTestcase/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name `PlayTestcase`, version `1.0.0`) |
| `PlayTestcase/app.fgprops` | App properties file (no properties defined for this sample) |
| `PlayTestcase/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /test2/{id}` on port `9999` → `Play Feature` |
| `PlayTestcase/flows/Play Feature.fgflow` | The flow under test — NoOp → REST Invoke → Mapper → Log → Return, with a conditional branch to a second Log |

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code**.
- Outbound internet access to `https://jsonplaceholder.typicode.com` (the REST activity calls this public endpoint).

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `PlayTestcase` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

This sample defines no app properties, so no configuration is required. If you point the REST activity at a different endpoint, update the flow accordingly.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. No special build environment is needed for this pure-Go REST app.

### Step 4 — Play the test case (flow debugger)

To use the play/debug feature — the focus of this sample:

1. Open `flows/Play Feature.fgflow` in the Flogo editor.
2. Start the play/test mode and provide the flow input (the path param `id`, e.g. `1` for the main path or `1000` to exercise the conditional branch).
3. Play the flow once. Each activity executes independently; the executed path is highlighted and the others appear grayed out.
4. Click an executed activity to inspect its input, output, or error in read-only mode.
5. Stop the test to change inputs or play a different case.

### Step 5 — (Optional) Build and Run as executable

To run the app end to end instead of playing it: in the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal, with the REST trigger listening on port **9999**.

```bash
curl "http://localhost:9999/test2/1"
```

Expected response (the mapped `zipcode` for user `1`):

```json
{"zipcode":"92998-3874"}
```

## App Properties Reference

This sample defines no app properties (`app.fgprops` contains an empty `properties` list).

| Property | Default | Description |
|---|---|---|
| *(none)* | — | No app-level properties are used by this sample. |

## Troubleshooting

- **REST activity fails / times out** — confirm outbound access to `https://jsonplaceholder.typicode.com`; a proxy or firewall may be blocking the call.
- **Play icon is disabled or a test won't start** — stop any running test first; only one play session runs at a time, and the icon toggles to a Stop icon while running.
- **Conditional branch never runs** — the `StartActivity → LogMessage1` link fires only when `pathParams.id == 1000`; supply `id = 1000` to exercise it.
- **Port `9999` already in use** (when running as executable) — free the port or change it in `triggers/ReceiveHTTPMessage.fgtrigger`.

## Help

For additional information, see the [TIBCO Flogo® Extension for Visual Studio Code documentation — Unit Testing](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
