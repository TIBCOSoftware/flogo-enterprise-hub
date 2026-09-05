# PostgreSQL Database CRUD (TLS/SSL) — Flogo 3

## Overview

This sample demonstrates the full set of **PostgreSQL CRUD operations** — Insert, Update, Query, and Delete — against a PostgreSQL database over a **TLS/SSL-secured connection**, using the **TIBCO Flogo® 3** folder-based project format. A single REST call drives one flow that inserts a row, updates it, queries it back, deletes it, logs the result, and returns a response.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /postgres/ssl` entry point on port `9999` that starts the flow |
| **PostgreSQL Insert** | `#insert` activity | Inserts a row into `public.company` and returns it |
| **PostgreSQL Update** | `#update` activity | Updates `salary`/`notes` of the inserted row by `id` |
| **PostgreSQL Query** | `#query` activity | Selects the row back by `id` |
| **PostgreSQL Delete** | `#delete` activity | Deletes the row by `id` |
| **Log Message** | `#log` activity | Logs the query output to the terminal |
| **Return** | `#actreturn` activity | Returns the delete result in the REST response |

All four CRUD activities use the same TLS/SSL-secured connection resource (`PostgreSQL-SSL-Conn`).

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/postgres/ssl
      v
 +-----------------------------------------------------------------------+
 |  postgresql-ssl  (Flogo 3 app)                                      |
 |                                                                       |
 |  REST Trigger (ReceiveHTTPMessage, port 9999, GET /postgres/ssl)      |
 |        |                                                              |
 |        v                                                              |
 |  CRUD_Flow                                                            |
 |    StartActivity (noop)                                               |
 |        -> PostgreSQLInsert   INSERT INTO public.company ...           |
 |        -> PostgreSQLUpdate   UPDATE public.company SET ...            |
 |        -> PostgreSQLQuery    SELECT * FROM public.company ...         |
 |        -> PostgreSQLDelete   DELETE FROM public.company ...           |
 |        -> LogMessage -> Return                                        |
 |                  |                                                    |
 |                  v  (TLS/SSL)                                         |
 |         [ PostgreSQL database: public.company ]                       |
 +-----------------------------------------------------------------------+
```

The four CRUD activities run in sequence, each connecting to PostgreSQL through the shared, SSL-secured `PostgreSQL-SSL-Conn` connection.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `postgresql-ssl/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `postgresql-ssl/app.fgprops` | App properties — PostgreSQL connection settings (host, port, database, credentials, timeouts, and SSL certificates) |
| `postgresql-ssl/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /postgres/ssl` on port `9999` → `CRUD_Flow` |
| `postgresql-ssl/flows/CRUD_Flow.fgflow` | Flow — Insert → Update → Query → Delete → Log → Return |
| `postgresql-ssl/connections/PostgreSQL-SSL-Conn.fgconn` | PostgreSQL connection resource (TLS/SSL) used by all CRUD activities |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.
- A running **PostgreSQL database server** reachable from your machine (local, on-prem VM, or a cloud instance such as AWS EC2). If the DB is hosted on a cloud VM, ensure your public IP is whitelisted.
- The **PostgreSQL connector driver** installed locally. In VS Code, click the **Flogo** icon → **Install Prerequisites for Flogo Connectors**, select **PostgreSQL**, and confirm. This installs the ODBC Driver Manager and the PostgreSQL connector driver (administrative privileges required).
- A table matching the sample schema. The flow operates on `public.company` with columns `id`, `name`, `age`, `address`, `salary`, `join_date`, and `notes`.
- Since this connection uses TLS/SSL, have your **CA certificate**, **client certificate**, and **client key** ready.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this `PostgreSQL-CRUD` folder in VS Code with the Flogo 3 extension. The extension detects the `postgresql-ssl` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `.fgprops` file for **App Properties** and set the PostgreSQL connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum, set:

```
PostgreSQL.PostgreSQL-SSL-Conn.Host          = <your PostgreSQL host>
PostgreSQL.PostgreSQL-SSL-Conn.Port          = 5432
PostgreSQL.PostgreSQL-SSL-Conn.Database_Name = <your database name>
PostgreSQL.PostgreSQL-SSL-Conn.User          = <your DB user>
PostgreSQL.PostgreSQL-SSL-Conn.Password      = <your DB password>
```

For the secure connection, also provide `CA_Certificate`, `Client_Certificate`, and `Client_Key` (base64-encoded PEM). The committed certificate values are environment-specific placeholders and must be replaced with your own.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. Then select this runtime for the app.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success, the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/postgres/ssl"
```

The flow inserts a row into `public.company`, updates it, queries it back, then deletes it. The REST response contains the delete result, and the query output is logged to the VS Code terminal.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `PostgreSQL.PostgreSQL-SSL-Conn.Host` | `ENTER_YOUR_POSTGRESQL_HOST_HERE` | PostgreSQL server host / public DNS |
| `PostgreSQL.PostgreSQL-SSL-Conn.Port` | `5432` | PostgreSQL server port |
| `PostgreSQL.PostgreSQL-SSL-Conn.Database_Name` | `ENTER_YOUR_POSTGRESQL_DATABASE_NAME_HERE` | Database name to connect to |
| `PostgreSQL.PostgreSQL-SSL-Conn.User` | `ENTER_YOUR_POSTGRESQL_USER_HERE` | Database user name |
| `PostgreSQL.PostgreSQL-SSL-Conn.Password` | `ENTER_YOUR_POSTGRESQL_PASSWORD_HERE` | Database password |
| `PostgreSQL.PostgreSQL-SSL-Conn.Maximum_Open_Connections` | `0` | Max total open connections (`0` = unlimited) |
| `PostgreSQL.PostgreSQL-SSL-Conn.Maximum_Idle_Connections` | `2` | Max idle connections in the pool (`<= 0` = none retained) |
| `PostgreSQL.PostgreSQL-SSL-Conn.Maximum_Connection_Lifetime` | `0` | Max time a connection may be reused (`0` = forever); units ns/us/ms/s/m/h |
| `PostgreSQL.PostgreSQL-SSL-Conn.Maximum_Connection_Retry_Attempts` | `3` | Max reconnect attempts to the DB server |
| `PostgreSQL.PostgreSQL-SSL-Conn.Connection_Retry_Delay` | `5` | Seconds to wait between reconnect attempts |
| `PostgreSQL.PostgreSQL-SSL-Conn.Connection_Timeout` | `20` | Seconds to wait when establishing a connection (`0` = no timeout) |
| `PostgreSQL.PostgreSQL-SSL-Conn.CA_Certificate` | *(base64 PEM)* | CA certificate used to verify the server (SSL) |
| `PostgreSQL.PostgreSQL-SSL-Conn.Client_Certificate` | *(base64 PEM)* | Client certificate presented to the server (SSL) |
| `PostgreSQL.PostgreSQL-SSL-Conn.Client_Key` | *(base64 PEM)* | Client private key (SSL) |

> Update `Host`, `Database_Name`, `User`, `Password`, and the certificate properties to match your environment before running.

---

## Troubleshooting

- **`Connection timed out` when creating the connection** — the PostgreSQL server is not reachable. Confirm the DB is running and that `Host`, `Port`, and (for cloud instances) IP whitelisting are correct.
- **`test connection failed: ... driver name not found, check whether any postgres driver is installed`** — the PostgreSQL driver is not installed. Install it via the Flogo icon → **Install Prerequisites for Flogo Connectors** → PostgreSQL, then retry.
- **SSL/certificate errors on connect** — verify `CA_Certificate`, `Client_Certificate`, and `Client_Key` are valid base64-encoded PEM values that match your server's TLS configuration.
- **Insert/Update/Query/Delete fails on the table** — ensure the target `public.company` table exists with the expected columns (`id`, `name`, `age`, `address`, `salary`, `join_date`, `notes`) and that the DB user has the required privileges.

---

## Help

For additional information, visit the [TIBCO Flogo® Connector for PostgreSQL documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/postgres/postgresql-connector.htm).
