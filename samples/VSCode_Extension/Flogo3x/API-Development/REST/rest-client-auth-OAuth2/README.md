# REST Client Authorization with OAuth 2.0 (Google Tasks) — Flogo 3

## Overview

This sample demonstrates how to create and use an **HTTP Client Authorization connection** with **OAuth 2.0** in a **TIBCO Flogo® 3** folder-based project to authenticate and authorize calls to the Google Tasks API. A single REST endpoint drives a sequence of authenticated REST invocations that create a task list, insert a task, mark it complete, and finally delete the task list.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /tasks` on port `9999` starts the flow; reads the `tasklist_path` query parameter |
| **HTTP Client Authorization (OAuth2)** | `authorization` connection | OAuth 2.0 Authorization Code grant against Google, token sent as the `Authorization` header on each REST call |
| **Invoke REST Service** | `#rest` activity (x4) | POST, POST, PATCH, DELETE calls to the Google Tasks API, all using the `google-tasks` connection |
| **Log** | `#log` activity | Prints progress and API responses to the terminal |
| **Return / Error** | `actreturn` / `error` | Returns responses to the caller and handles the failure path |

---

## Architecture

```
  Client (curl / Postman)
      |
      |  GET http://localhost:9999/tasks?tasklist_path=users/@me/lists
      v
 +-------------------------------------------------------------------------+
 |  OAuth2_GoogleTask_Sample  (Flogo 3 app)                              |
 |                                                                         |
 |  REST Trigger (ReceiveHTTPMessage, GET /tasks, port 9999)              |
 |        |                                                                |
 |        v                                                                |
 |  google_tasks flow                                                      |
 |    POST_tasklist  -> TaskList_logs                                       |
 |        | (statusCode==200)                                              |
 |    POST_task      -> PostTask_logs                                       |
 |        | (statusCode==200)                                              |
 |    PATCH_task     -> AfterPatch_taskLogs -> Return                       |
 |        |                                                                 |
 |    DELETE_tasklist -> Delete_Status                                      |
 |                                                                         |
 |  Every REST activity authenticates via the google-tasks OAuth2 conn     |
 +-------------------------------------------------------------------------+
                                   |
                                   v
                    Google Tasks API (https://www.googleapis.com/tasks/v1)
```

The four REST activities call, in order:

| Step | Method | URI |
|---|---|---|
| POST_tasklist | `POST` | `https://www.googleapis.com/tasks/v1/{path}` — creates a task list |
| POST_task | `POST` | `https://www.googleapis.com/tasks/v1/lists/{tasklist}/tasks` — inserts a task |
| PATCH_task | `PATCH` | `https://www.googleapis.com/tasks/v1/lists/{tasklist}/tasks/{task}` — marks it `completed` |
| DELETE_tasklist | `DELETE` | `https://www.googleapis.com/tasks/v1/{path}/{tasklist}` — deletes the task list |

The `{path}` path parameter is populated from the incoming `tasklist_path` query parameter; `{tasklist}` and `{task}` are chained from the response body IDs of the earlier calls.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `OAuth2_GoogleTask_Sample/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `OAuth2_GoogleTask_Sample/app.fgprops` | App properties — OAuth 2.0 connection values (client id/secret, URLs, scope, token) |
| `OAuth2_GoogleTask_Sample/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /tasks` on port `9999` → `google_tasks` flow |
| `OAuth2_GoogleTask_Sample/flows/google_tasks.fgflow` | Main flow — create list, insert task, complete task, delete list |
| `OAuth2_GoogleTask_Sample/connections/google-tasks.fgconn` | HTTP Client Authorization (OAuth2) connection used by all REST activities |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.
- The **Google Tasks API** enabled in your Google Cloud account.
- A **connected web application** in your Google account (Credentials page) that provides a **Client ID** and **Client Secret**. See the [Google OAuth 2.0 for web server apps guide](https://developers.google.com/identity/protocols/oauth2/web-server).
- The connected web application must be configured with the VS Code callback URL `https://vscode.dev/redirect` (the connection's redirect URI).

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `OAuth2_GoogleTask_Sample` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

Open the `app.fgprops` file for **App Properties** and set the OAuth 2.0 connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum, provide your own:

```
General.google-tasks.Client_Id       = <your Google OAuth client id>
General.google-tasks.Client_Secret   = <your Google OAuth client secret>
```

The `google-tasks` connection uses the **Authorization Code** grant with `clientAuthentication = Body`, additional auth query parameters `access_type=offline&prompt=consent` (to obtain a refresh token and force the consent screen), and scope `https://www.googleapis.com/auth/tasks`. After you log in and grant access through the consent screen, the resulting access token is stored in the connection's `Token` field and sent as the `Authorization` header on every REST call.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

Call the endpoint with the `tasklist_path` query parameter set to the Google Tasks lists path:

```bash
curl "http://localhost:9999/tasks?tasklist_path=users/@me/lists"
```

The flow creates a task list, inserts a task, marks it `completed`, and deletes the task list, logging each API response in the VS Code terminal and returning the result to the caller.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `General.google-tasks.Auth_URL` | `https://accounts.google.com/o/oauth2/v2/auth` | OAuth 2.0 authorization endpoint |
| `General.google-tasks.Access_Token_URL` | `https://oauth2.googleapis.com/token` | OAuth 2.0 token endpoint |
| `General.google-tasks.Client_Id` | `YOUR_OAUTH_GOOGLETASK_CLIENT_ID_HERE` | OAuth client id from your Google connected app |
| `General.google-tasks.Client_Secret` | `YOUR_OAUTH_GOOGLETASK_CLIENT_SECRET_HERE` | OAuth client secret from your Google connected app |
| `General.google-tasks.Scope` | `https://www.googleapis.com/auth/tasks` | Scope granting create/edit/delete on all tasks |
| `General.google-tasks.Audience` | *(empty)* | Optional OAuth audience |
| `General.google-tasks.Token` | `YOUR_OAUTH_GOOGLETASK_TOKEN_HERE` | Access token populated after the consent flow |

> Replace `Client_Id`, `Client_Secret`, and `Token` with your own values before running. The committed values are placeholders and must be replaced.

---

## Troubleshooting

- **`401 Unauthorized` / `invalid_grant` from Google** — the access token is missing or expired. Re-run the OAuth consent flow so a fresh `Token` is populated in the `google-tasks` connection; `access_type=offline` keeps a refresh token available for longer runs.
- **`redirect_uri_mismatch`** — the Google connected app is not configured with the callback URL `https://vscode.dev/redirect`. Add it under the app's authorized redirect URIs.
- **`403` / API not enabled** — the Google Tasks API is not enabled for your account/project. Enable it in the Google Cloud console.
- **No `path` resolved / 404 on the first call** — the `tasklist_path` query parameter was not supplied. Include `?tasklist_path=users/@me/lists` on the request.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — HTTP Client Authorization connection](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all-vsc/http-client-auth-connection.htm).
