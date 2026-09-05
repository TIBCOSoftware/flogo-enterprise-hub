# Handling Null & Empty JSON Objects/Arrays in Condition Paths — Flogo 3

## Overview

This sample demonstrates how to safely evaluate **conditional branches** when incoming JSON data may contain null objects, empty JSON objects, or empty/null JSON arrays, using the **TIBCO Flogo® 3** folder-based project format. A single Timer trigger fires three independent flows, each showing a different technique for detecting empty/null JSON before branching.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **Timer** | `#timer` trigger | Starts all three demonstration flows automatically |
| **Mapper** | `#mapper` activity | Initializes sample JSON (`set_Input`) and reshapes it via a `foreach` mapping (`Mapper`) |
| **Conditional / Otherwise branches** | flow branch conditions | Detect empty array, null object, and null-valued field before proceeding |
| **Log Message** | `#log` activity | Reports whether the JSON was empty/null or valid |
| **Return** | `#actreturn` activity | Ends each branch with a result |

The three flows differ only in the branch condition they use:

- **Handle_EmptyNull_In_JSONArrayObject** — checks an empty/null array with `array.count($activity[Mapper].output.book) == 0`.
- **Handle_EmptyNull_In_JSONObject_1** — checks a null object via string comparison `utility.renderJSON($activity[set_Input].output.book, false) == 'null'`.
- **Handle_EmptyNull_In_JSONObject_2** — detects a null-valued field with `utility.renderJSON($activity[Mapper].output, false) == '{"book":null}'`.

## Architecture

```
  Timer Trigger (fires on start)
      |
      +--> Handle_EmptyNull_In_JSONArrayObject
      |        set_Input -> Mapper -> [empty/null array?] --yes--> LogMessage  -> Return
      |                                                     --no --> LogMessage1 -> Return1
      |
      +--> Handle_EmptyNull_In_JSONObject_1
      |        set_Input -> Mapper -> [book == null?]      --yes--> LogMessage  -> Return
      |                                                     --no --> LogMessage1 -> Return1
      |
      +--> Handle_EmptyNull_In_JSONObject_2
               set_Input -> Mapper -> [{"book":null}?]     --yes--> LogMessage  -> Return
                                                            --no --> LogMessage1 -> Return1
```

Each flow uses a **Conditional branch** (taken when the JSON is empty/null) and an **Otherwise branch** (taken when the JSON is valid).

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `HowTo_Handle_NullEmptyJSON_ObjArray/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `HowTo_Handle_NullEmptyJSON_ObjArray/app.fgprops` | App properties (none defined for this sample) |
| `HowTo_Handle_NullEmptyJSON_ObjArray/triggers/TimerTrigger.fgtrigger` | Timer trigger that starts the three flows |
| `HowTo_Handle_NullEmptyJSON_ObjArray/flows/Handle_EmptyNull_In_JSONArrayObject.fgflow` | Empty/null JSON array handling |
| `HowTo_Handle_NullEmptyJSON_ObjArray/flows/Handle_EmptyNull_In_JSONObject_1.fgflow` | Null JSON object handling (string comparison) |
| `HowTo_Handle_NullEmptyJSON_ObjArray/flows/Handle_EmptyNull_In_JSONObject_2.fgflow` | Null-valued field handling |

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in Visual Studio Code with the Flogo 3 extension. The extension detects the `HowTo_Handle_NullEmptyJSON_ObjArray` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

This sample defines no app properties, so no configuration is required. The sample JSON inputs are set directly inside each flow's `set_Input` mapper.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal.

### Step 5 — Observe the output

There is no external endpoint to invoke — the **Timer trigger fires automatically** when the app starts, running all three flows. Watch the integrated terminal: each flow's **Log Message** activity prints whether the JSON was detected as empty/null or valid, confirming the branch that was taken.

## App Properties Reference

This sample defines no app properties (`app.fgprops` contains an empty `properties` list). All demonstration inputs are configured within the flows themselves.

## Troubleshooting

- **Flows do not run** — the Timer trigger runs on app start; confirm the executable started cleanly and check the integrated terminal for engine startup errors.
- **Unexpected branch taken** — verify the sample JSON in each flow's `set_Input` mapper; the branch conditions rely on the exact shape produced by `set_Input`/`Mapper` (empty array, `null`, or `{"book":null}`).
- **Build fails** — ensure a Local Runtime is created and selected in the Flogo 3 extension before running **Run As Executable**.

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — Catching Errors](https://docs.tibco.com/pub/flogo-vscode/latest/doc/html/Default.htm#flogo-vscode-user-guide/app-development/creating-flows-triggers/flows/catching-errors.htm).
