# Oracle Database CRUD & Stored Procedure — Flogo 3

## Overview

This sample demonstrates how to use the **TIBCO Flogo® Connector for Oracle Database** in the **TIBCO Flogo® 3** folder-based project format. A single REST call runs a flow that performs the full set of Oracle operations end to end: **Query**, **Insert**, **Update**, **Delete**, and **Call Procedure** (stored procedure), logging each result and returning a response.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /orcl` entry point on port `9999` that starts the flow |
| **Oracle Query** | `OracleDatabase/activity/query` | Fetches rows (e.g. from the `EMPLOYEE` table) |
| **Oracle Insert** | `OracleDatabase/activity/insert` | Inserts a new row |
| **Oracle Update** | `OracleDatabase/activity/update` | Updates a row for a given employee ID |
| **Oracle Delete** | `OracleDatabase/activity/delete` | Deletes the updated row |
| **Oracle Call Procedure** | `OracleDatabase/activity/callprocedure` | Executes a stored procedure (multi-cursor `REF CURSOR` output) |
| **Log / Return** | `General/activity/log`, `contrib/activity/actreturn` | Logs each activity output and returns the REST response |

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/orcl
      v
 +-----------------------------------------------------------------------+
 |  oracleApp  (Flogo 3 app)                                           |
 |                                                                       |
 |  REST Trigger (ReceiveHTTPMessage, GET /orcl, port 9999)             |
 |        |                                                              |
 |        v                                                              |
 |  New_flow                                                            |
 |    noop -> Query -> Insert -> Update -> Delete -> CallProcedure      |
 |                                          -> Log -> Return            |
 |                    |                                                  |
 |                    v                                                  |
 |            [ Oracle Database via oracleconn connection ]             |
 +-----------------------------------------------------------------------+
```

All Oracle activities share the single `oracleconn` connection, which is driven by the app properties described below.

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `oracleApp/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `oracleApp/app.fgprops` | App properties — Oracle connection settings (host, port, credentials, instance, pool sizing) |
| `oracleApp/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /orcl` on port `9999` → `New_flow` |
| `oracleApp/flows/New_flow.fgflow` | Main flow — Query → Insert → Update → Delete → Call Procedure → Log → Return |
| `oracleApp/connections/oracleconn.fgconn` | Oracle Database connection used by all activities |

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.
- A running **Oracle Database** server reachable from your machine (on-premises or on a cloud VM such as AWS EC2). If the database is hosted on the cloud, ensure your public IP is whitelisted in the server's security group.
- **Oracle Instant Client** libraries installed locally (they provide `libclntsh.so`). On Linux, the **`libaio`** package is also required at build/run time. Install these via the Flogo VS Code extension's **Install Prerequisites for Flogo Connectors → Oracle Database** option, which installs the correct client libraries for your OS.
- The database objects used by the flow. The `EMPLOYEE` table plus the sample stored procedure and demo tables can be created from the `Script` file in the corresponding 2.x sample folder.

> **Platform note:** Because the Oracle connector depends on an OS-specific native client library, cross-platform executables cannot be built (e.g., a Linux binary on Windows is not supported for Oracle apps).

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in Visual Studio Code with the Flogo 3 extension. The extension detects the `oracleApp` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `app.fgprops` file for **App Properties** and set the Oracle connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum, set:

```
OracleDatabase.oracleconn.Host                     = <your Oracle host / public DNS>
OracleDatabase.oracleconn.Port                     = 1521
OracleDatabase.oracleconn.User                     = <your Oracle user>
OracleDatabase.oracleconn.Password                 = <your Oracle password>
OracleDatabase.oracleconn.Database_Instance_value  = <your SID or Service Name value>
```

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. Ensure the Oracle client libraries (see Prerequisites) are installed so the runtime can build and run the Oracle connector.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success, the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/orcl"
```

The flow runs the Query, Insert, Update, Delete, and Call Procedure activities against Oracle in sequence, logs each activity output to the VS Code terminal, and returns the response.

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `OracleDatabase.oracleconn.Host` | `ENTER_YOUR_ORACLE_DATABASE_HOST_HERE` | Oracle server host / public DNS |
| `OracleDatabase.oracleconn.Port` | `1521` | Oracle listener port |
| `OracleDatabase.oracleconn.User` | `ENTER_YOUR_ORACLE_DATABASE_USER_HERE` | Database user name |
| `OracleDatabase.oracleconn.Password` | `ENTER_YOUR_ORACLE_DATABASE_PASSWORD_HERE` | Database password |
| `OracleDatabase.oracleconn.Database_Instance_value` | `ENTER_YOUR_ORACLE_DATABASE_INSTANCE_VALUE_HERE` | Value for the SID or Service Name |
| `OracleDatabase.oracleconn.Max_Open_Connections` | `50` | Maximum number of open connections to the database |
| `OracleDatabase.oracleconn.Max_Idle_Connections` | `10` | Maximum number of idle connections in the pool |
| `OracleDatabase.oracleconn.Connection_Max_Lifetime` | `180s` | Maximum time a connection can be reused (valid units: ns, us, ms, s, m, h) |

> Update `Host`, `User`, `Password`, and `Database_Instance_value` to match your database before running. The committed values are placeholders and must be replaced with your own.

## Troubleshooting

- **`Cannot locate a 64-bit Oracle Client library: "libclntsh.so: cannot open shared object file"`** — the Oracle Instant Client is not installed or not on the library path. Install it via **Install Prerequisites for Flogo Connectors → Oracle Database** and rebuild. On Linux, also confirm `libaio` is installed.
- **Test connection fails with a connection time-out** — verify the Oracle server is running and reachable, the `Host`/`Port` are correct, and (for cloud-hosted databases) that your public IP is whitelisted in the server's security group.
- **Table/column auto-complete not working at design time** — ensure the connection is established successfully and that the schema name is set in the activity's Settings tab.
- **Stored procedure errors** — confirm the referenced procedure and its demo tables exist in the target schema (create them from the `Script` in the 2.x sample folder).

## Help

For additional information, visit the [TIBCO Flogo® Connector for Oracle Database documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/oracledatabase/oracle-database.htm).
