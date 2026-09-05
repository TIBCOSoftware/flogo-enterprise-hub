# Salesforce Bulk API Sample — Flogo 3

## Overview

This sample demonstrates the **Salesforce Bulk API** activities using the **TIBCO Flogo® 3** folder-based project format. A REST call creates a Salesforce bulk *query* job for the `Account` object, checks the job status, and then retrieves the job results in paginated batches by looping over a subflow.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /salesforce/{bulk}` entry point that starts the main flow |
| **Salesforce Create Job** | `createjob` activity | Creates a bulk `query` job (`SELECT AccountNumber, Name, Id FROM Account limit 600`) |
| **Salesforce Check Job Status** | `checkjobstatus` activity | Polls the status of the newly created bulk job by Job ID |
| **Start a SubFlow** | `subflow` activity | Runs `SubFlowWithSFGetQueryJob` inside a loop to page through results |
| **Salesforce Get Query Job Results** | `getqueryjobresults` activity | Retrieves records from the query job in batches based on the locator |
| **Log Message** | `log` activity | Prints progress to the terminal |
| **Return** | `actreturn` activity | Returns the job output to the REST caller |

---

## Architecture

```
  Client (curl / Postman)
      |
      |  GET http://localhost:9999/salesforce/{bulk}
      v
 +--------------------------------------------------------------+
 |  Salesforce_BulkAPISample  (Flogo 3 app)                   |
 |                                                              |
 |  REST Trigger (ReceiveHTTPMessage, port 9999)               |
 |        |                                                     |
 |        v                                                     |
 |  MainFlowWithSFCreateCheckStatusJob                         |
 |    CreateJob -> Log -> CheckJobStatus -> StartaSubFlow(loop)|
 |                                              |    -> Return  |
 |                                              v               |
 |  SubFlowWithSFGetQueryJob                                    |
 |    GetQueryJobResults -> Log -> Return                       |
 +--------------------------------------------------------------+
              |
              v
      Salesforce.com (Bulk API 2.0)
```

- **MainFlowWithSFCreateCheckStatusJob** creates the bulk query job, checks its status, then invokes the subflow inside a loop to retrieve all result pages, and returns the output.
- **SubFlowWithSFGetQueryJob** fetches one batch of query results per invocation (paginated by the locator), so the loop walks the entire result set.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `Salesforce_BulkAPISample/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `Salesforce_BulkAPISample/app.fgprops` | App properties — Salesforce connection settings |
| `Salesforce_BulkAPISample/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /salesforce/{bulk}` on port `9999` → main flow |
| `Salesforce_BulkAPISample/flows/MainFlowWithSFCreateCheckStatusJob.fgflow` | Main flow — Create Job, Check Job Status, loop the subflow, Return |
| `Salesforce_BulkAPISample/flows/SubFlowWithSFGetQueryJob.fgflow` | Sub flow — Get Query Job Results, Return |
| `Salesforce_BulkAPISample/connections/SalesforceBulkAPI.fgconn` | Salesforce.com connection used by the activities |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
- An active **Salesforce.com** account.
- A **Connected App** in Salesforce with OAuth enabled, providing the **Consumer Key** (Client ID) and **Consumer Secret** (Client Secret) used by the Salesforce connection. See "Creating a Salesforce.com Connection" in the extension documentation for the OAuth setup steps.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `Salesforce_BulkAPISample` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `.fgprops` file for App Properties and set the Salesforce connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). Set your `Client_Id` and `Client_Secret` from the Connected App, then authorize the connection so an OAuth2 access token is generated and stored in `OAuth2_Token`.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

The path parameter `bulk` accepts any string value:

```bash
curl "http://localhost:9999/salesforce/trybulk"
```

The response body contains the bulk job output (`SalesforceBulkJob_Output`). The log activities in both flows print the job ID, status, and the paginated query results to the VS Code terminal.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `Salesforce.SalesforceBulkAPI.Client_Id` | `YOUR_SALESFORCE_CLIENT_ID_HERE` | Consumer Key of the Salesforce Connected App |
| `Salesforce.SalesforceBulkAPI.Client_Secret` | `YOUR_SALESFORCE_CLIENT_SECRET_HERE` | Consumer Secret of the Salesforce Connected App |
| `Salesforce.SalesforceBulkAPI.Environment` | `Production` | Salesforce environment (`Production` / `Sandbox`) |
| `Salesforce.SalesforceBulkAPI.OAuth2_Token` | `YOUR_SALESFORCE_OAUTH2_TOKEN_HERE` | OAuth2 access token generated after authorizing the connection |

> Replace `Client_Id` and `Client_Secret` with your own Connected App values, then re-authorize so a valid `OAuth2_Token` is populated before running.

---

## Troubleshooting

- **`401 Unauthorized` / invalid token** — the `OAuth2_Token` is missing or expired. Re-authorize the Salesforce connection so a fresh access token is generated.
- **`invalid_client` on authorization** — the `Client_Id` or `Client_Secret` does not match the Connected App, or OAuth permissions are not set up in Salesforce. Verify the Consumer Key/Secret and the OAuth scopes.
- **Empty or partial results** — the query job may not have finished; the loop relies on Check Job Status. Confirm the `Account` object has data and that the query in the Create Job activity is valid for your org.
- **`404 Not Found` when invoking** — ensure you include the `{bulk}` path segment, e.g. `GET /salesforce/trybulk` on port `9999`.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — Salesforce.com connector](https://docs.tibco.com/pub/flogo-vscode/latest/doc/html/Default.htm#connectors/salesforce/salesforcecreatejob.htm?TocPath=Supported%2520Flogo%2520Connectors%257CSalesforce.com%257C_____8).
