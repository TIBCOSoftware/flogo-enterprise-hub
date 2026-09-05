# App Startup and Shutdown Triggers — Flogo 3

## Overview

This sample demonstrates the **App Startup** and **App Shutdown** hook triggers in the **TIBCO Flogo® 3** folder-based project format. The App Startup trigger runs its flow *before* any other trigger in the app starts (ideal for initialization); the App Shutdown trigger runs its flow *after* all other triggers have stopped (ideal for cleanup). Here, startup inserts rows into a MySQL table, a REST endpoint queries them, and shutdown deletes the table data.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **App Startup** | `#startuphook` trigger → `onStart` flow | Initialization logic executed before other triggers start |
| **App Shutdown** | `#shutdownhook` trigger → `onShut` flow | Cleanup logic executed after all triggers stop |
| **REST** | `#rest` trigger — `GET /mysql` on port `9999` → `MainFlow` | Entry point that queries the seeded data |
| **MySQL Insert** | `#insert` activity | Seeds `tutorials_tbl_New` during startup |
| **MySQL Query** | `#query` activity | Reads rows in `MainFlow` and re-checks in `onShut` |
| **MySQL Delete** | `#delete` activity | Removes the seeded data during shutdown |
| **Log** | `#log` activity | Prints progress in each flow |

> Note: The App Startup and App Shutdown triggers require no configuration of their own.

## Architecture

```
   App start
      |
      v
  AppStartupHook  --> onStart flow:  MySQL Insert -> Log      (seed tutorials_tbl_New)
      |
      v
  App running -----> REST Trigger (GET /mysql, port 9999)
                         |
                         v
                     MainFlow:  MySQL Query -> Log -> Return  (read seeded rows)
      |
      v
   App stop
      |
      v
  AppShutdownHook --> onShut flow:  MySQL Delete -> Log -> MySQL Query -> Log
                                    (delete rows, re-query returns null)
```

- **onStart** runs once, before other triggers, and inserts values into `tutorials_tbl_New`.
- **MainFlow** is triggered by `GET /mysql`, queries the table by `tutorial_id`, logs the result, and returns it.
- **onShut** runs once, after all triggers stop, deletes the rows, then re-queries to confirm the data is gone.

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `appStartupAndShutdownTriggers-demo/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `appStartupAndShutdownTriggers-demo/app.fgprops` | App properties — MySQL connection settings |
| `appStartupAndShutdownTriggers-demo/triggers/AppStartupHook.fgtrigger` | App Startup trigger → `onStart` flow |
| `appStartupAndShutdownTriggers-demo/triggers/AppShutdownHook.fgtrigger` | App Shutdown trigger → `onShut` flow |
| `appStartupAndShutdownTriggers-demo/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /mysql` on port `9999` → `MainFlow` |
| `appStartupAndShutdownTriggers-demo/flows/onStart.fgflow` | Startup flow — MySQL Insert, then Log |
| `appStartupAndShutdownTriggers-demo/flows/MainFlow.fgflow` | Main flow — MySQL Query, Log, Return |
| `appStartupAndShutdownTriggers-demo/flows/onShut.fgflow` | Shutdown flow — MySQL Delete, Log, MySQL Query, Log |
| `appStartupAndShutdownTriggers-demo/connections/MySQLSSL_conn.fgconn` | MySQL connection used by the activities |

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.
- A running **MySQL** database service reachable from your machine, with a table `tutorials_tbl_New` (columns used include `tutorial_id`). Update the connection settings in App Properties to match your instance.

## Setup & Run

### Step 1 — Open the app in VS Code

Open this `appHooks` folder in Visual Studio Code with the Flogo 3 extension. The extension detects the `appStartupAndShutdownTriggers-demo` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `.fgprops` file for **App Properties** and set the MySQL connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum, set `Host`, `Port`, `Database_Name`, `User`, and `Password`.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. As the app starts, the `onStart` flow seeds the table; the REST trigger then begins listening on port **9999**.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/mysql"
```

You should receive the rows that `onStart` inserted into `tutorials_tbl_New`. When you stop the app, the `onShut` flow deletes those rows and re-queries them (returning null), with progress logged to the VS Code terminal.

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `MySQL.MySQLSSL_conn.Host` | `YOUR_MYSQLSSL_HOST_HERE` | MySQL server host |
| `MySQL.MySQLSSL_conn.Port` | `3306` | MySQL server port |
| `MySQL.MySQLSSL_conn.Database_Name` | `YOUR_MYSQLSSL_DATABASE_NAME_HERE` | Database name |
| `MySQL.MySQLSSL_conn.User` | `YOUR_MYSQLSSL_USER_HERE` | Database user |
| `MySQL.MySQLSSL_conn.Password` | `YOUR_MYSQLSSL_PASSWORD_HERE` | Database password |
| `MySQL.MySQLSSL_conn.Maximum_Open_Connections` | `0` | Max open connections (`0` = unlimited) |
| `MySQL.MySQLSSL_conn.Maximum_Idle_Connections` | `2` | Max idle connections in the pool |
| `MySQL.MySQLSSL_conn.Maximum_Connection_Lifetime` | `0` | Max lifetime of a connection (`0` = unlimited) |
| `MySQL.MySQLSSL_conn.Maximum_Connection_Retry_Attempts` | `3` | Max connection retry attempts |
| `MySQL.MySQLSSL_conn.Connection_Retry_Delay` | `5` | Delay (s) between connection retries |
| `MySQL.MySQLSSL_conn.Connection_Timeout` | `20` | Connection timeout (s) |
| `MySQL.MySQLSSL_conn.CA_Certificate` | `{}` | CA certificate (for SSL connections) |
| `MySQL.MySQLSSL_conn.Client_Certificate` | `{}` | Client certificate (for mutual TLS) |
| `MySQL.MySQLSSL_conn.Client_Key` | `{}` | Client key (for mutual TLS) |

> Update `Host`, `Port`, `Database_Name`, `User`, and `Password` to match your MySQL instance before running. The committed values are placeholders and must be replaced with your own.

## Troubleshooting

- **Connection refused / timeout on startup** — MySQL is not reachable. Confirm the service is running and that `Host`, `Port`, `User`, and `Password` are correct.
- **`onStart` fails / table not found** — ensure the target database exists and `tutorials_tbl_New` is present (or that the configured user can create/insert into it).
- **`GET /mysql` returns empty** — the `onStart` insert may not have run or completed; check the terminal logs for the startup flow, and verify the query's `tutorial_id` matches the inserted row.
- **Port `9999` already in use** — stop the conflicting process or change the REST trigger port.

## Help

- [App Startup Trigger documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all-vsc/app_startup_trigger.htm)
- [App Shutdown Trigger documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all-vsc/app_shutdown_trigger.htm)
