# Hello World — Flogo 3

## Overview

This sample is a minimal Flogo app that returns a greeting based on a value you supply in the URL. A REST `GET` request carrying a path parameter starts the `sayHello` flow, which logs the name and returns a JSON greeting. It is a good first look at how a trigger, an activity, and mapping expressions fit together in the **TIBCO Flogo® 3** folder-based project format.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /hello/{name}` on port `9999`; maps the `name` path parameter into the flow |
| **Log Message** | `#log` activity | Prints `Name: <name>` to the runtime logs |
| **Return** | `#actreturn` activity | Returns `{"message":"Hello <name>"}` to the REST caller |
| **String function** | `string.concat` | Builds the log and reply strings from the input |

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/hello/{name}
      v
 +-----------------------------------------------------+
 |  HelloWorld  (Flogo 3 app)                         |
 |                                                     |
 |  REST Trigger (ReceiveHTTPMessage, port 9999)       |
 |     GET /hello/{name}  ->  name = $.pathParams.name |
 |        |                                            |
 |        v                                            |
 |  sayHello flow                                      |
 |     LogMessage -> Return                            |
 |        |             |                              |
 |   "Name: <name>"   {"message":"Hello <name>"}       |
 +-----------------------------------------------------+
```

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `HelloWorld/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name `HelloWorld`, version `1.0.0`) |
| `HelloWorld/app.fgprops` | App properties (none defined for this sample) |
| `HelloWorld/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /hello/{name}` on port `9999` → `sayHello` |
| `HelloWorld/flows/sayHello.fgflow` | Flow — `LogMessage` then `Return` |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this `hello-world` folder in Visual Studio Code with the Flogo 3 extension. The extension detects the `HelloWorld` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

This sample defines no app properties, so no configuration is required. If you want to override the trigger port or path, edit `HelloWorld/triggers/ReceiveHTTPMessage.fgtrigger` and the trigger handler in `HelloWorld/flows/sayHello.fgflow`.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. No special environment variables are required for this pure-Go REST sample.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/hello/world"
```

Expected response:

```json
{"message":"Hello world"}
```

The `LogMessage` activity also prints `Name: world` to the VS Code terminal. Replace `world` in the URL with any name to get a different greeting.

---

## App Properties Reference

This sample does not define any app properties (`app.fgprops` contains an empty properties list).

| Property | Default | Description |
|---|---|---|
| *(none)* | — | No app properties are defined for this sample |

---

## Troubleshooting

- **`404 Not Found`** — check the path: the resource is `/hello/{name}` (e.g. `/hello/world`), not `/hello`.
- **`address already in use` / port bind error** — port `9999` is taken by another process. Stop the other process or change the `port` in `ReceiveHTTPMessage.fgtrigger`.
- **Empty or unexpected greeting** — make sure you pass a value for the `name` path segment; the reply is built from `$flow.name`.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — Creating Your First App](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all/creating-your-first-.htm?TocPath=User%2520Guide%257CIntroduction%257C_____2).
