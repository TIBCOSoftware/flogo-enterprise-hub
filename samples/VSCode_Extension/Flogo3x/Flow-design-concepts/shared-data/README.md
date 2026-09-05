# Shared Data — Flogo 3

## Overview

This sample demonstrates the **Shared Data** activity in **TIBCO Flogo® 3**, which lets you set, get, and delete runtime data that can be shared **within a flow** or **across flows** in an app. Data set at *flow* scope is visible only inside the running flow instance, while data set at *application* scope is visible to every flow in the app (including subflows and error handlers). Two REST endpoints exercise the pattern, and one flow is invoked as a subflow to show cross-flow sharing.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **Shared Data** | `#shareddata` activity | Set / Get / Delete data at *flow* or *application* scope, keyed by name |
| **Subflow** | `#subflow` activity | Calls `Get_User1_User2_Delete_User2` from the main flow, sharing app-scope data across flows |
| **Log Message** | `#log` activity | Prints the retrieved user info to the runtime terminal |
| **Return** | `#actreturn` activity | Returns the user info in the REST response |
| **REST** | `#rest` trigger | `GET /user/{key}` and `GET /users2` entry points on port `9999` |

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET /user/{key}                         GET /users2
      v                                          v
 +---------------------------------------------------------------------+
 |  GetUsersInfo  (Flogo 3 app, REST trigger on port 9999)           |
 |                                                                     |
 |  Set_Get_User1_Set_User2                    Get_User2               |
 |    Set user1  (flow scope)                    Get user2 (app scope) |
 |    Get user1  (flow scope)                    Log -> Return         |
 |    Set user2  (application scope)                                   |
 |    StartaSubFlow ---------------+                                   |
 |    Return                       |                                   |
 |                                 v                                   |
 |            Get_User1_User2_Delete_User2  (subflow)                  |
 |              Get user1 / Get user2 / Delete user2 -> Return         |
 +---------------------------------------------------------------------+
```

- **Set_Get_User1_Set_User2** (`GET /user/{key}`) sets `user1` at *flow* scope, reads it back, sets `user2` at *application* scope, then calls the subflow.
- **Get_User1_User2_Delete_User2** is a **subflow** that gets `user1` / `user2` and can **delete** `user2` (app scope) based on its input key and an `isDelete` flag.
- **Get_User2** (`GET /users2`) is a separate flow that reads the `user2` value set at *application* scope, proving the data is shared across flows.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `GetUsersInfo/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name `GetUsersInfo`, version `1.0.0`) |
| `GetUsersInfo/app.fgprops` | App properties — the `user1`–`user4` string values |
| `GetUsersInfo/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger on port `9999` |
| `GetUsersInfo/flows/Set_Get_User1_Set_User2.fgflow` | Main flow — `GET /user/{key}`; sets/gets `user1` (flow scope), sets `user2` (app scope), calls the subflow |
| `GetUsersInfo/flows/Get_User1_User2_Delete_User2.fgflow` | Subflow — gets `user1`/`user2` and deletes `user2` based on input |
| `GetUsersInfo/flows/Get_User2.fgflow` | Flow — `GET /users2`; reads `user2` from application scope |
| `GetUsersInfo/schemas/UserInfo.json` | Shared object schema used by the Shared Data activities |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).

No broker, database, or external runtime is required — this sample uses only built-in General-category activities.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this `shared-data` folder in Visual Studio Code with the Flogo 3 extension. The extension detects the `GetUsersInfo` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `app.fgprops` file for **App Properties** and adjust the `user1`–`user4` values if desired (see the [App Properties Reference](#app-properties-reference) below). The defaults work as-is.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. No special environment variables are required for this sample.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoints

```bash
# Main flow: sets user1 (flow scope), sets user2 (app scope), runs the subflow
curl "http://localhost:9999/user/user1"
curl "http://localhost:9999/user/user2"

# Second flow: reads user2 shared at application scope
curl "http://localhost:9999/users2"
```

Each call returns the corresponding user info as JSON, and the Log activities print the set/get/delete progress to the VS Code terminal.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `user1` | `user1` | Sample value stored/retrieved as the `user1` key |
| `user2` | `user2` | Sample value stored/retrieved as the `user2` key |
| `user3` | `user3` | Additional sample user value |
| `user4` | `user4` | Additional sample user value |

---

## Troubleshooting

- **`404 Not Found`** — the path must match a configured handler: use `/user/{key}` (e.g. `/user/user1`) or `/users2`. Any other path returns 404.
- **Empty or missing `user2` in `/users2`** — application-scope data is populated by the main flow. Call `/user/{key}` first so `user2` is set at application scope, then call `/users2`.
- **Port `9999` already in use** — another process is bound to the port. Stop it, or change the `port` setting in `triggers/ReceiveHTTPMessage.fgtrigger` and rebuild.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — Shared Data activity](https://docs.tibco.com/pub/flogo-vscode/latest/doc/html/Default.htm#flogo-vscode-user-guide/app-development/general-triggers/shared-data.htm).
