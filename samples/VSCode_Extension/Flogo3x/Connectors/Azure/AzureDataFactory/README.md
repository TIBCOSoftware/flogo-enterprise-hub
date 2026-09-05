# Azure Data Factory Pipeline — Flogo 3

## Overview

This sample demonstrates how to trigger and run a **Microsoft Azure Data Factory (ADF)** pipeline from **TIBCO Flogo® 3** using the folder-based project format. A REST call starts a flow that invokes an ADF pipeline (a "Run Once" copy-data operation) via the Azure Data Factory connector and logs the activity output.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /azdf` entry point on port `9999` that starts the flow |
| **Azure Data Factory Pipeline** | `dfpipeline` activity | Runs an ADF pipeline (`Run Once`) to copy data from source to destination |
| **Log Message** | `log` activity | Logs the Azure Data Factory pipeline activity output |
| **Microsoft Azure connection** | `AzureAD` connection | OAuth (password grant) connection used to authenticate to Azure |

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/azdf
      v
 +-----------------------------------------------------------+
 |  AzureDataFactory  (Flogo 3 app)                        |
 |                                                           |
 |  REST Trigger (ReceiveHTTPMessage, port 9999, /azdf)      |
 |        |                                                  |
 |        v                                                  |
 |  RUN_Query flow                                           |
 |    StartActivity (noop)                                   |
 |        -> MicrosoftAzureDataFactoryPipeline (Run Once)    |
 |        -> LogMessage                                      |
 +--------------------------|--------------------------------+
                            v
                 [ Azure Data Factory: Copy_Data_0 pipeline ]
```

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `AzureDataFactory/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `AzureDataFactory/app.fgprops` | App properties file (no app-level properties defined; configuration lives in the connection resource) |
| `AzureDataFactory/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /azdf` on port `9999` → `RUN_Query` |
| `AzureDataFactory/flows/RUN_Query.fgflow` | Flow — noop → Azure Data Factory pipeline → Log Message |
| `AzureDataFactory/connections/test.fgconn` | Microsoft Azure connection (OAuth password grant) used by the pipeline activity |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.
- Access to the **Azure portal** with permission to run Data Factory pipelines.
- An existing **Azure Data Factory**, its **Subscription ID**, **Resource Group**, and a **Pipeline** to run. This sample references:
  - Subscription ID: `3d9f846f-9849-4329-a35e-91fa5ea16488`
  - Resource Group: `ADFTesting`
  - Data Factory: `tibcoazdf-1`
  - Pipeline: `Copy_Data_0` (parameter `filename = movies.csv`)
- Azure AD **Tenant ID**, **Client ID**, and a **user name / password** for the OAuth (password grant) connection.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `AzureDataFactory` project (the folder containing `app.fgmd`).

### Step 2 — Configure the connection and pipeline

This app has no app-level properties in `app.fgprops`; configuration is held in the connection and activity instead.

- Open `connections/test.fgconn` and set your Azure values: `tenantId`, `clientID`, `userName`, `password`, and resource URL (`https://management.azure.com`). The committed `WI_STUDIO_OAUTH_CONNECTOR_INFO` and the `ENTER_YOUR_AZURE_DATA_*` placeholders must be replaced with your own credentials.
- In `flows/RUN_Query.fgflow`, update the `MicrosoftAzureDataFactoryPipeline` activity inputs (`subscriptionId`, `resourceGroup`, `dataFactories`, `dfPipeline`, and any pipeline parameters) to match your environment.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/azdf"
```

The flow authenticates to Azure, triggers the `Copy_Data_0` pipeline (`Run Once`), and logs the pipeline activity output to the VS Code terminal.

---

## App Properties Reference

This app defines no app-level properties in `app.fgprops` (`properties` is empty). Environment-specific values are set directly on the resources instead:

| Location | Key | Description |
|---|---|---|
| `connections/test.fgconn` | `tenantId` | Azure AD tenant ID (App Registration) |
| `connections/test.fgconn` | `clientID` | Azure AD client (application) ID |
| `connections/test.fgconn` | `userName` / `password` | User credentials for the password grant |
| `connections/test.fgconn` | `grantType` | OAuth grant type (`password`) |
| `flows/RUN_Query.fgflow` | `subscriptionId` | Azure subscription ID |
| `flows/RUN_Query.fgflow` | `resourceGroup` | Resource group containing the Data Factory (`ADFTesting`) |
| `flows/RUN_Query.fgflow` | `dataFactories` | Data Factory name (`tibcoazdf-1`) |
| `flows/RUN_Query.fgflow` | `dfPipeline` | Pipeline to run (`Copy_Data_0`) |
| `flows/RUN_Query.fgflow` | `operation` | Pipeline operation (`Run Once`) |

---

## Troubleshooting

- **Login / test connection failed** — verify the tenant ID, client ID, user name, and password in `connections/test.fgconn`, and that the resource URL is `https://management.azure.com`.
- **Pipeline not found / 404 from Azure** — confirm the `subscriptionId`, `resourceGroup`, `dataFactories`, and `dfPipeline` values match an existing pipeline in your Azure portal.
- **Authorization error (403)** — the configured user/app must have permission to run pipelines in the target Data Factory and resource group.
- **Port 9999 already in use** — change the `port` in the REST trigger or free the port before running.

---

## Help

For additional information, visit the [TIBCO Flogo® Connector for Microsoft Azure Data Factory documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/azure_data_factory/azure_data_factory.htm).
