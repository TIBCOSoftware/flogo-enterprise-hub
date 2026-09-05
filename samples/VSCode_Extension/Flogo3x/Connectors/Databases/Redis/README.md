# Redis Sets Commands — Flogo 3

## Overview

This sample demonstrates how to create a **Redis connection** and run the **Redis Set-group commands** using the **TIBCO Flogo® 3** folder-based project format. A single REST call (`GET /redis`) triggers a flow that executes a series of `Redis Command` activities against a Redis database — adding, inspecting, removing, and moving members of a Set — and returns the result.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /redis` on port `9999` — entry point that starts the flow |
| **Redis Command (SADD)** | `#rediscommand` activity | Add one or more members to a Set stored at a key |
| **Redis Command (SMEMBERS)** | `#rediscommand` activity | Return all members of the Set stored at a key |
| **Redis Command (SISMEMBER)** | `#rediscommand` activity | Test whether an element is a member of the Set |
| **Redis Command (SCARD)** | `#rediscommand` activity | Return the cardinality (member count) of the Set |
| **Redis Command (SREM)** | `#rediscommand` activity | Remove the specified member(s) from the Set |
| **Redis Command (SPOP)** | `#rediscommand` activity | Remove and return one or more random members |
| **Redis Command (SMOVE)** | `#rediscommand` activity | Move a member from a source Set to a destination Set |
| **Log Message** | `#log` activity | Print progress to the runtime terminal |
| **Return** | `#actreturn` activity | Return the response to the REST caller |

---

## Architecture

```
  Client (curl / Postman)
      |
      |  GET http://localhost:9999/redis
      v
 +-----------------------------------------------------------+
 |  Redis-Sets-App  (Flogo 3 app)                          |
 |                                                           |
 |  REST Trigger (ReceiveHTTPMessage, port 9999, /redis)     |
 |        |                                                  |
 |        v                                                  |
 |  Sets flow                                                |
 |    SADD -> SMEMBERS -> SISMEMBER -> SCARD -> SREM         |
 |         -> SPOP -> SMOVE -> LogMessage -> Return          |
 |                     |                                     |
 |                     v                                     |
 |             [ Redis database ]                            |
 +-----------------------------------------------------------+
```

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `Redis-Sets-App/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `Redis-Sets-App/app.fgprops` | App properties — Redis connection settings |
| `Redis-Sets-App/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /redis` on port `9999` → `Sets` flow |
| `Redis-Sets-App/flows/Sets.fgflow` | Flow running the Set commands (SADD, SMEMBERS, SISMEMBER, SCARD, SREM, SPOP, SMOVE), then Log and Return |
| `Redis-Sets-App/connections/Redis-Conn-New.fgconn` | Redis connection resource used by the activities |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.
- A running **Redis server** reachable from your machine (local or cloud-hosted, e.g. AWS EC2). The server must be up before you run the app.
- If Redis is hosted on a cloud VM, ensure the host/port is reachable and your public IP is whitelisted.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in Visual Studio Code with the Flogo 3 extension. The extension detects the `Redis-Sets-App` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `.fgprops` file for **App Properties** and set the Redis connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum, set:

```
Redis.Redis-Conn-New.Host_Name = <your Redis host>
Redis.Redis-Conn-New.Port      = 6379
Redis.Redis-Conn-New.Username  = <your Redis user>
Redis.Redis-Conn-New.Password  = <your Redis password>
```

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/redis"
```

The flow runs the Set commands in sequence against your Redis database and returns the response. The Log activity prints progress to the VS Code terminal.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `Redis.Redis-Conn-New.Redis_Deployment_Mode` | `Standalone` | Redis deployment mode |
| `Redis.Redis-Conn-New.Host_Name` | `REPLACE_WITH_REDIS_HOST` | Redis server host (public DNS/IP or `localhost`) |
| `Redis.Redis-Conn-New.Port` | `6379` | Port on which the Redis server is running |
| `Redis.Redis-Conn-New.Default_Database_Index` | `0` | Default database index to connect to |
| `Redis.Redis-Conn-New.Username` | `ENTER_YOUR_REDIS_USER_NAME_HERE` | User name for connecting to Redis |
| `Redis.Redis-Conn-New.Password` | `ENTER_YOUR_REDIS_PASSWORD_HERE` | Password for authenticating the connection |

> Update `Host_Name`, `Username`, and `Password` to match your Redis server before running. The committed values are placeholders and must be replaced with your own.

---

## Troubleshooting

- **Connection refused / timeout** — Redis is not reachable. Confirm the server is running and `Host_Name` and `Port` are correct; if cloud-hosted, verify your public IP is whitelisted.
- **Authentication failure** — check `Username` and `Password`, and confirm the Redis instance requires (or does not require) auth as configured.
- **Wrong / empty results** — verify the `Default_Database_Index` (and any per-activity `DatabaseIndex`) points at the database partition holding your keys.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — TIBCO Flogo Connector for Redis](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/redis/overview.htm?TocPath=Connectors%2520User%2520Guide%257CSupported%2520Flogo%2520Connectors%257CRedis%257C_____0).
