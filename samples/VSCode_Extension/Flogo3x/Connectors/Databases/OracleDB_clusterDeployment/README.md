# Oracle Database — CRUD & Stored Procedure — Flogo 3

## Overview

This sample demonstrates end-to-end use of the **TIBCO Flogo® Connector for Oracle Database** in the **Flogo 3** folder-based project format. A single REST call (`GET /orcl`) drives a flow that runs a **Query → Insert → Update → Delete → Call Procedure** sequence against an Oracle database and returns the combined result. The `Dockerfile` and `deployment.yaml` shipped alongside show how to package the built binary (with the Oracle Instant Client runtime libraries) and deploy it to a Docker container or a local Kubernetes/Minikube cluster.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /orcl` on port `9999` entry point that starts the flow |
| **Oracle Database Query** | `wi-oracledb/.../activity/query` | Runs a `SELECT` against `ADMIN.DEMO_TABLE1` |
| **Oracle Database Insert** | `wi-oracledb/.../activity/insert` | Inserts a row using parameterized values |
| **Oracle Database Update** | `wi-oracledb/.../activity/update` | Updates a row by `EMP_ID` |
| **Oracle Database Delete** | `wi-oracledb/.../activity/delete` | Deletes a row by `EMP_NAME` |
| **Oracle Database Call Procedure** | `wi-oracledb/.../activity/callprocedure` | Calls a stored procedure returning REF CURSOR outputs |
| **Log / Return** | `#log`, `#actreturn` | Logs the combined activity outputs and returns them in the REST response |

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/orcl
      v
 +-------------------------------------------------------------------+
 |  oracle  (Flogo 3 app)                                          |
 |                                                                   |
 |  REST Trigger (ReceiveHTTPMessage, port 9999, GET /orcl)          |
 |        |                                                          |
 |        v                                                          |
 |  Oracle_flow                                                      |
 |    StartActivity(noop)                                            |
 |       -> OracleDatabaseQuery   (SELECT)                           |
 |       -> OracleDatabaseInsert  (INSERT)                           |
 |       -> OracleDatabaseUpdate  (UPDATE)                           |
 |       -> OracleDatabaseDelete  (DELETE)                           |
 |       -> OracleDatabaseCallProcedure (CALL)                       |
 |       -> LogMessage -> Return                                     |
 |                 |                                                 |
 |                 v                                                 |
 |        [ Oracle Database via oracleconn ]                         |
 +-------------------------------------------------------------------+
```

All database activities share the single `oracleconn` connection, whose settings are resolved from app properties.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `oracle/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name `oracle`, version `1.0.0`) |
| `oracle/app.fgprops` | App properties — Oracle connection settings (host, port, user, password, instance, pool sizing) |
| `oracle/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /orcl` on port `9999` → `Oracle_flow` |
| `oracle/flows/Oracle_flow.fgflow` | Main flow — Query, Insert, Update, Delete, Call Procedure, Log, Return |
| `oracle/connections/oracleconn.fgconn` | Oracle Database connection used by all DB activities |

The following deployment helpers (from the source sample) illustrate how to run the built binary in a container/cluster:

| Path | Description |
|---|---|
| `../../../Connectors/Databases/OracleDB_clusterDeployment/Dockerfile` | Alpine-based image that installs `libaio` + Oracle Instant Client and runs the Flogo binary |
| `../../../Connectors/Databases/OracleDB_clusterDeployment/deployment.yaml` | Kubernetes Deployment exposing container port `9999` with the Instant Client env vars |

> **Note:** The database schema is `ADMIN` and the demo table is `ADMIN.DEMO_TABLE1` (columns `EMP_ID`, `EMP_NAME`, `HIRE_DATE`). The call-procedure activity invokes `multipleCursorsQA`. Create these objects in your Oracle instance before running.

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
- A reachable **Oracle Database** with the schema/table/stored procedure used by the flow (`ADMIN.DEMO_TABLE1`, procedure `multipleCursorsQA`).
- **Oracle Instant Client** (Basic package) plus the **`libaio`** native library available on the machine where the built binary runs. The Oracle connector links against these Oracle client libraries at runtime; without them the binary fails with `libclntsh.so: cannot open shared object file`. Set `LD_LIBRARY_PATH` (Linux) to the Instant Client directory.
- (Optional, for cluster deployment) **Docker** and **Minikube/kubectl** if you want to package and run the binary in a container or local Kubernetes cluster.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in Visual Studio Code with the Flogo 3 extension. The extension detects the `oracle` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `app.fgprops` file for **App Properties** and set the Oracle connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum set `Host`, `Port`, `User`, `Password`, and `Database_Instance_value` (the SID/service).

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. Ensure the Oracle Instant Client libraries are on the runtime's library path (e.g. `LD_LIBRARY_PATH`) so the Oracle connector can link at build/run time.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/orcl"
```

The flow executes the query, insert, update, delete, and stored-procedure calls in sequence and returns the concatenated activity outputs in the REST response. Progress is also printed by the Log activity in the VS Code terminal.

To run the built binary in a container instead, use the provided `Dockerfile` (installs the Oracle Instant Client + `libaio`), then:

```bash
docker build -t oracle-app .
docker run -i -t -p 9999:9999 oracle-app
curl "http://localhost:9999/orcl"
```

For Minikube, load the image (`minikube image load oracle-app:latest`), apply `deployment.yaml`, then `kubectl port-forward <pod> 9999:9999`.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `OracleDatabase.oracleconn.Host` | `ENTER_YOUR_ORACLE_DATABASE_HOST_HERE` | Oracle database host |
| `OracleDatabase.oracleconn.Port` | `1521` | Oracle listener port |
| `OracleDatabase.oracleconn.User` | `ENTER_YOUR_ORACLE_DATABASE_USER_HERE` | Database user name |
| `OracleDatabase.oracleconn.Password` | `ENTER_YOUR_ORACLE_DATABASE_PASSWORD_HERE` | Database password |
| `OracleDatabase.oracleconn.Database_Instance_value` | `ENTER_YOUR_ORACLE_DATABASE_INSTANCE_VALUE_HERE` | Oracle SID / service name |
| `OracleDatabase.oracleconn.Max_Open_Connections` | `50` | Maximum open connections in the pool |
| `OracleDatabase.oracleconn.Max_Idle_Connections` | `10` | Maximum idle connections in the pool |
| `OracleDatabase.oracleconn.Connection_Max_Lifetime` | `180s` | Maximum lifetime of a pooled connection |

> Update `Host`, `Port`, `User`, `Password`, and `Database_Instance_value` to match your database before running. The committed values are placeholders and must be replaced with your own.

---

## Troubleshooting

- **`Cannot locate a 64-bit Oracle Client library: "libclntsh.so: cannot open shared object file"`** — the Oracle Instant Client libraries (and `libaio`) are not installed or not on `LD_LIBRARY_PATH`. Install the Instant Client Basic package and point `LD_LIBRARY_PATH` at it (the `Dockerfile` shows the exact steps).
- **Connection / login failures** — verify `Host`, `Port`, `User`, `Password`, and `Database_Instance_value` (SID/service) are correct and the listener is reachable from your machine.
- **`ORA-00942: table or view does not exist` / procedure errors** — create the `ADMIN.DEMO_TABLE1` table and the `multipleCursorsQA` stored procedure, or adjust the SQL in `Oracle_flow.fgflow` to match your schema.
- **Kubernetes connection errors (e.g. `couldn't get current server API group list`)** — ensure the Minikube/Docker Desktop cluster is up and healthy before running `kubectl apply`.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation - TIBCO Flogo Connector for Oracle Database](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/oracledatabase/oracle-database.htm).
