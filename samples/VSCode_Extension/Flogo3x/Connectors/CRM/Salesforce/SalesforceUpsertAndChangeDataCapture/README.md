# Salesforce Upsert (Bulk) with Change Data Capture — Flogo 3

## Overview

This sample demonstrates the **Salesforce Upsert** activity performing a bulk create/update of records, together with a **Salesforce Change Data Capture (CDC)** trigger that reacts to those record changes — using the **TIBCO Flogo® 3** folder-based project format.

A REST call fetches rows from a MySQL database, maps them into the Salesforce **Upsert** activity, and creates or updates `Contact` records based on the external-ID field `ContactID__c`. Each Salesforce change then publishes a change event that starts a second flow, which logs the CDC payload.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /sfupsert/{upsert}` on port `9999` starts the upsert flow |
| **MySQL Query** | `wi-mysql/.../activity/query` | Reads source records from a MySQL database |
| **Salesforce Upsert** | `wi-salesforce/.../activity/upsert` | Bulk create/update of `Contact` records keyed on external ID `ContactID__c` |
| **Salesforce Query** | `wi-salesforce/.../activity/query` | Reads back the upserted records to confirm the result |
| **Salesforce Trigger (CDC)** | `wi-salesforce/.../trigger/salesforce` | Subscribes to `ContactChangeEvent` change events and starts a flow |
| **Log** | `General/.../activity/log` | Prints progress and the CDC event payload |

---

## Architecture

```
  Client (curl / Postman)
      |
      |  GET http://localhost:9999/sfupsert/{upsert}
      v
 +------------------------------------------------------------------+
 |  SFSubscriberTypesWithUpsertActivity  (Flogo 3 app)            |
 |                                                                  |
 |  REST Trigger (ReceiveHTTPMessage, port 9999)                    |
 |        |                                                         |
 |        v                                                         |
 |  SFUpsertWithMySQLDB                                             |
 |    MySQLQuery -> Log -> SalesforceUpsert -> Log                  |
 |                              |   -> SalesforceQuery -> Log -> Return
 |                              v                                   |
 |                   [ Salesforce Contact object ]                 |
 |                              |  change event                    |
 |                              v                                   |
 |  Salesforce CDC Trigger (ReceiveSalesforceMessage,              |
 |     channel /data/ContactChangeEvent)                           |
 |        |                                                         |
 |        v                                                         |
 |  SFChangeDataCapture                                             |
 |    Log (CDC payload)                                             |
 +------------------------------------------------------------------+
```

- **SFUpsertWithMySQLDB** is triggered by `GET /sfupsert/{upsert}`. It queries MySQL, upserts the records into Salesforce (`Contact`, external ID `ContactID__c`), queries them back, and returns.
- **SFChangeDataCapture** is triggered by the Salesforce CDC trigger subscribed to `ContactChangeEvent`. When the upsert changes records, the change event starts this flow, which logs the payload.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `SFSubscriberTypesWithUpsertActivity/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `SFSubscriberTypesWithUpsertActivity/app.fgprops` | App properties — MySQL and Salesforce connection settings and CDC channel/replay values |
| `SFSubscriberTypesWithUpsertActivity/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /sfupsert/{upsert}` on port `9999` → `SFUpsertWithMySQLDB` |
| `SFSubscriberTypesWithUpsertActivity/triggers/ReceiveSalesforceMessage.fgtrigger` | Salesforce CDC trigger — `ContactChangeEvent` → `SFChangeDataCapture` |
| `SFSubscriberTypesWithUpsertActivity/flows/SFUpsertWithMySQLDB.fgflow` | Upsert flow — MySQL Query → Salesforce Upsert → Salesforce Query → Return |
| `SFSubscriberTypesWithUpsertActivity/flows/SFChangeDataCapture.fgflow` | CDC flow — logs the Salesforce change event payload |
| `SFSubscriberTypesWithUpsertActivity/connections/Salesforce.fgconn` | Salesforce OAuth2 connection used by the upsert/query activities and the CDC trigger |
| `SFSubscriberTypesWithUpsertActivity/connections/MySQL.fgconn` | MySQL connection used by the MySQL Query activity |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
- An active **Salesforce.com account** with **OAuth permissions** configured (a Connected App providing the Client ID / Consumer Key and Client Secret / Consumer Secret used in the Salesforce connection).
- **Change Data Capture** enabled in Salesforce for the `Contact` object (so `ContactChangeEvent` change events are published).
- A reachable **MySQL database** (local or hosted, e.g. AWS EC2) containing the source records. If hosted remotely, ensure your public IP is whitelisted.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `SFSubscriberTypesWithUpsertActivity` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `app.fgprops` file for **App Properties** and set the MySQL and Salesforce connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum set the MySQL host/credentials and the Salesforce `Client_Id`, `Client_Secret`, and `OAuth2_Token`.

> For the Salesforce connection, `Client_Id` is the Consumer Key and `Client_Secret` is the Consumer Secret from your Salesforce Connected App. After both are supplied and you complete the Salesforce login/consent, a Base64-encoded access token populates the `OAuth2_Token` field; it is sent as the Authorization header when the app calls the Salesforce API.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. (No special build environment is required for this connector.)

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999** and the Salesforce CDC trigger subscribes to `/data/ContactChangeEvent`.

### Step 5 — Invoke the endpoint

The path parameter `{upsert}` accepts any string value:

```bash
curl "http://localhost:9999/sfupsert/testupsert"
```

The `SFUpsertWithMySQLDB` flow queries MySQL, upserts the records into Salesforce (`Contact`, keyed on `ContactID__c`), and returns the queried-back records with HTTP `200`. Records with a matching external ID are updated; others are created. Each change triggers the CDC flow, and the change event payload is printed to the VS Code terminal.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `MySQL.MySQL.Host` | `REPLACE_WITH_MYSQL_HOST` | MySQL server host |
| `MySQL.MySQL.Port` | `3306` | MySQL server port |
| `MySQL.MySQL.Database_Name` | `Northwind` | MySQL database name |
| `MySQL.MySQL.User` | `CHANGEME_MYSQL_USER` | MySQL user |
| `MySQL.MySQL.Password` | `CHANGEME_MYSQL_Password` | MySQL password |
| `MySQL.MySQL.Maximum_Open_Connections` | `0` | Max open connections (`0` = unlimited) |
| `MySQL.MySQL.Maximum_Idle_Connections` | `2` | Max idle connections in the pool |
| `MySQL.MySQL.Maximum_Connection_Lifetime` | `0` | Max connection lifetime (`0` = unlimited) |
| `MySQL.MySQL.Maximum_Connection_Retry_Attempts` | `3` | Max connection retry attempts |
| `MySQL.MySQL.Connection_Retry_Delay` | `5` | Delay between connection retries |
| `MySQL.MySQL.Connection_Timeout` | `20` | Connection timeout |
| `Salesforce.Salesforce.Environment` | `Production` | Salesforce environment (Production / Sandbox) |
| `Salesforce.Salesforce.Client_Id` | `YOUR_SALESFORCE_CLIENT_ID_HERE` | Consumer Key from the Salesforce Connected App |
| `Salesforce.Salesforce.Client_Secret` | `YOUR_SALESFORCE_CLIENT_SECRET_HERE` | Consumer Secret from the Salesforce Connected App |
| `Salesforce.Salesforce.OAuth2_Token` | `YOUR_SALESFORCE_OAUTH2_TOKEN_HERE` | Base64 OAuth2 access token populated after login/consent |
| `channel` | `/data/ContactYog__ChangeEvent` | CDC channel name |
| `channelname` | `/data/ContactYog__ChangeEvent` | CDC channel name (alternate property) |
| `ReplayID` | `-1` | Replay ID for the CDC subscription |
| `replayid` | `-1` | Replay ID (alternate property) |

> Replace all `REPLACE_WITH_*`, `CHANGEME_*`, and `YOUR_SALESFORCE_*` placeholders with your own values before running. The CDC trigger in this app subscribes to `ContactChangeEvent` (`/data/ContactChangeEvent`); align the channel property values with the object for which Change Data Capture is enabled in your Salesforce org.

---

## Troubleshooting

- **Salesforce authentication fails / `401`** — verify `Client_Id`, `Client_Secret`, and `OAuth2_Token` are set, that the Connected App OAuth scopes are correct, and that the token has not expired (re-run the login/consent to refresh it).
- **No CDC events in the logs** — confirm Change Data Capture is enabled for the `Contact` object in Salesforce and that the subscribed channel (`/data/ContactChangeEvent`) matches the enabled entity.
- **MySQL connection errors** — confirm `Host`, `Port`, `Database_Name`, and credentials are correct, the database is reachable, and (for remote/EC2 hosts) your public IP is whitelisted.
- **Upsert creates duplicates instead of updating** — ensure the source records supply valid `ContactID__c` external-ID values so existing records match and are updated rather than created.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — Salesforce Upsert activity](https://docs.tibco.com/pub/flogo-vscode/latest/doc/html/Default.htm#connectors/salesforce/salesforceupsert.htm).
