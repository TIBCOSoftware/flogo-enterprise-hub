# SAP S/4HANA Cloud CRUD — Flogo 3

## Overview

This sample demonstrates the full **create / read / update / delete** lifecycle against **SAP S/4HANA Cloud** OData services using the **TIBCO Flogo® 3** folder-based project format. A single REST call drives a flow that creates a product long-text record, updates it, reads it back, and deletes it — exercising all four SAP S/4HANA Cloud activities in sequence against the `API_PRODUCT_SRV` (product basic text) service.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger (`tibco-wi-rest`) | `GET /sap` on port `9999` starts the flow |
| **SAP S/4HANA Cloud Create** | `SAPS4HANACloud/activity/create` | POSTs a new product long-text (`Product`, `Language`, `LongText`) |
| **SAP S/4HANA Cloud Update** | `SAPS4HANACloud/activity/update` | PATCHes the long-text of the record just created |
| **SAP S/4HANA Cloud Get** | `SAPS4HANACloud/activity/get` | Reads product basic text back with OData `$filter` / `$top` |
| **SAP S/4HANA Cloud Delete** | `SAPS4HANACloud/activity/delete` | Deletes the product long-text record |
| **Log / Return** | `#log`, `#actreturn` | Logs the delete result and returns it in the REST response |

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/sap
      v
 +---------------------------------------------------------------+
 |  SAPS4HANA  (Flogo 3 app)                                   |
 |                                                              |
 |  REST Trigger (ReceiveHTTPMessage, GET /sap, port 9999)       |
 |        |                                                     |
 |        v                                                     |
 |  New_flow                                                     |
 |    NoOp -> Create -> Update -> Get -> Delete -> Log -> Return |
 |              \___________ SAP S/4HANA Cloud ___________/      |
 |                    (API_PRODUCT_SRV / ProductBasicText)       |
 +---------------------------------------------------------------+
```

The activities are chained so each step feeds the next: the `Update`, `Get`, and `Delete` activities reference the `Product` / `Language` returned by the previous activity, all operating on product `A002`, language `EN`.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `SAPS4HANA/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name `SAPS4HANA`, version `1.0.0`) |
| `SAPS4HANA/app.fgprops` | App properties (none defined; add environment overrides here if needed) |
| `SAPS4HANA/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /sap` on port `9999` → `New_flow` |
| `SAPS4HANA/flows/New_flow.fgflow` | Flow — Create → Update → Get → Delete → Log → Return |
| `SAPS4HANA/connections/test.fgconn` | SAP connection (`wi-sap` SAPConnector) used by all four SAP activities |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
- A valid **SAP account on [api.sap.com](https://api.sap.com)** with credentials/API key for the SAP S/4HANA Cloud APIs.
- Access to a reachable **SAP S/4HANA Cloud tenant** (or the SAP sandbox). Note: the sandbox supports only the **Get** operation; Create/Update/Delete require a Production tenant with write access.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `SAPS4HANA` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

This app defines no app-level properties in `app.fgprops`. All environment-specific values live on the **SAP connection** (`connections/test.fgconn`). Open the connection and set your SAP credentials for your environment (see the [App Properties / Connection Reference](#app-properties--connection-reference) below): API key, tenant URL, tenant user name, and tenant password. Choose the correct **Type** (`Production` for full CRUD, `sandbox` for Get-only) and **Authentication Type** (`Basic Authentication` or `SSL Client certificate`).

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. Select this runtime for the app.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/sap"
```

The flow creates the product long-text for product `A002` (language `EN`), updates it, reads it back, and deletes it. The REST response returns the delete activity output, and the Log activity prints the delete result to the VS Code terminal.

---

## App Properties / Connection Reference

`app.fgprops` contains no properties in this sample. The following settings are configured on the **SAP connection** (`connections/test.fgconn`, connector `github.com/tibco/wi-sap/src/app/SAPConnector`):

| Setting | Default | Description |
|---|---|---|
| `name` | `test` | Connection name |
| `authType` | `Basic Authentication` | Authentication type (`Basic Authentication` or `SSL Client certificate`) |
| `conntype` | `Production` | Connection type (`Production` = full CRUD, `sandbox` = Get only) |
| `apikey` | `ENTER_YOUR_APIKEY_HERE` | SAP API key / repository password from api.sap.com |
| `tenantPassword` | `ENTER_YOUR_PASSWORD_HERE` | SAP tenant password |
| `tenantUrl` | *(empty)* | SAP S/4HANA Cloud tenant URL |
| `tenantUserName` | *(empty)* | SAP tenant user name |
| `APIUrl` | *(empty)* | SAP API repository URL (api.sap.com) |
| `SSL Client Configuration` | *(empty)* | SSL client config (SSL Client certificate mode) |
| `X.509 Certificate` | *(empty)* | Client certificate (SSL Client certificate mode) |

> Replace the placeholder credentials (`apikey`, `tenantPassword`) and fill in `tenantUrl` / `tenantUserName` with your own SAP account details before running. The committed values are placeholders.

---

## Troubleshooting

- **401 / authentication errors** — verify the `apikey`, `tenantUserName`, and `tenantPassword` on the connection, and that your account has access to the `API_PRODUCT_SRV` service on api.sap.com.
- **Create/Update/Delete fail but Get works** — the connection `Type` is set to `sandbox`. Switch to a `Production` tenant with write access to run the full CRUD lifecycle.
- **Port already in use** — another process is bound to `9999`. Stop it or change the REST trigger port and re-run.
- **404 / OData resource not found** — confirm `tenantUrl` points at a tenant that exposes `API_PRODUCT_SRV` and that product `A002` / language `EN` exist (or adjust the activity mappings).

---

## Help

For additional information, visit the [TIBCO Flogo® Connector for OData Services for SAP S/4HANA documentation](https://docs.tibco.com/products/tibco-flogo-connector-for-odata-services-for-sap-s-4hana).
