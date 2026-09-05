# Google Connection — Override Service Account Key — Flogo 3

## Overview

This sample demonstrates how to **override the Google Connection Service Account Key at runtime** using an app property, instead of embedding the key at design time. The key is referenced from the `googleconn` connection as `=$property["GoogleConnection.googleconn.Service_Account_Key"]`, so it can be replaced at startup — Base64-encoded value, raw JSON, a `file://` path, or a Kubernetes secret — without rebuilding the app. A single REST-triggered flow (`GCS-CRUD-App`) exercises the key against Google Cloud Storage by running a full create/upload/list/get/update/delete cycle.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /gcs-crud` on port `9999` starts the flow |
| **Google Connection** | `connections/googleconn.fgconn` | Service Account Key bound to an app property for runtime override |
| **GCS Create** | `GoogleCloudStorage/activity/create` | Creates a bucket and an object |
| **GCS Upload** | `GoogleCloudStorage/activity/upload` | Uploads a large local file in chunks |
| **GCS List / Get / Update / Delete** | `list` / `get` / `update` / `delete` activities | Lists objects, reads, updates ACL/metadata, then deletes object, file, and bucket |
| **Log / Return** | `#log`, `#actreturn` | Logs each step result and returns the final delete result |

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/gcs-crud
      v
 +-------------------------------------------------------------------+
 |  GCS-CRUD-App  (Flogo 3 app)                                     |
 |                                                                   |
 |  REST Trigger (ReceiveHTTPMessage, port 9999)                     |
 |        |                                                          |
 |        v                                                          |
 |  GCS_All_Activity_Flow                                            |
 |    CreateBucket -> CreateObject -> Upload -> List ->              |
 |    Get -> Update -> Delete(object) -> Delete(file) ->             |
 |    Delete(bucket) -> Return                                       |
 |        |                                                          |
 |        | authenticates with Service Account Key                   |
 |        v                                                          |
 |  googleconn (Service_Account_Key = $property[...] )               |
 +-------------------------------------------------------------------+
                          |
                          v
                  Google Cloud Storage
```

The connection reads its Service Account Key from the app property `GoogleConnection.googleconn.Service_Account_Key`. Change the property value (or override it at runtime) to point the app at a different service account without editing or rebuilding the flow.

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `GCS-CRUD-App/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `GCS-CRUD-App/app.fgprops` | App properties — holds `GoogleConnection.googleconn.Service_Account_Key` (the value overridden at runtime) |
| `GCS-CRUD-App/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /gcs-crud` on port `9999` → `GCS_All_Activity_Flow` |
| `GCS-CRUD-App/flows/GCS_All_Activity_Flow.fgflow` | The GCS CRUD flow — create, upload, list, get, update, delete, return |
| `GCS-CRUD-App/connections/googleconn.fgconn` | Google Connection resource; Service Account Key bound to the app property |

## Prerequisites

- TIBCO Flogo 3 extension for Visual Studio Code.
- A Google Cloud Platform account with an active project.
- A **Service Account** with the required IAM roles (e.g., `Storage Admin` for GCS) and its **JSON key file** downloaded from the GCP Console.
- For the Kubernetes override method: a running cluster with `kubectl` configured, and the app built/deployed as a container image.

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `GCS-CRUD-App` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `.fgprops` file for App Properties and set `GoogleConnection.googleconn.Service_Account_Key` to your Service Account Key value (see the App Properties Reference below). The value can be supplied as:

- **Base64-encoded** Service Account Key
- **Raw JSON** (JSON-escaped) Service Account Key
- **File path** beginning with `file://` pointing to the key file
- **Kubernetes secret** referenced via the deployment's `values.yaml`

To override at runtime without rebuilding, start the app with the key passed via environment. Set `FLOGO_APP_PROPS_ENV=auto` and either:

```
GoogleConnection_googleconn_Service_Account_Key=<base64_or_file://path>
```

or point `FLOGO_APP_PROPS_JSON` at a JSON env file (which must also include `"FLOGO_APP_PROPS_ENV": "auto"`) containing the property:

```json
{
  "FLOGO_APP_PROPS_ENV": "auto",
  "GoogleConnection.googleconn.Service_Account_Key": "file:///path/to/key.json"
}
```

The runtime override takes precedence over the design-time value.

### Step 3 — Create & select the Local Runtime

Click the Flogo 3 icon in the VS Code menu bar → in RUNTIME EXPLORER, add a new runtime with the + button → give it a name → Save.

### Step 4 — Build and Run

In the FLOGO3: WORKSPACE APPS EXPLORER, select the app module → right-click → Run As Executable. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port `9999`.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/gcs-crud"
```

The flow creates a bucket and object, uploads a file, lists/gets/updates the object, then deletes the object, uploaded file, and bucket. A `200` response with the final delete result confirms the overridden Service Account Key authenticated successfully with Google Cloud. Each step is logged in the VS Code terminal.

> **Note:** The `UploadLargeFile` activity references a local file path (`C:\path\to\file1GB.bin`). Update it to a real file on your machine, or remove the activity, before running the full flow.

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `GoogleConnection.googleconn.Service_Account_Key` | *(Base64-encoded placeholder key)* | Google service account key used by the `googleconn` connection. Override at runtime with a Base64 value, raw JSON, a `file://` path, or a Kubernetes secret. |

> The committed default is a placeholder key and must be replaced with your own service account key (design-time value or runtime override) before the GCS operations will succeed.

## Troubleshooting

- **`oauth2: cannot fetch token: 400 Bad Request ... invalid_grant / Invalid JWT Signature`** — the Service Account Key value is invalid. Verify the key JSON, Base64 encoding, or `file://` path you supplied.
- **`invalid base64 encoded service account key`** — the Base64 value is malformed. Re-encode the key file and pass the full value without line breaks.
- **`The system cannot find the path specified` with a `file://` value** — the path is wrong or the file is not readable by the app process. Use an absolute path and confirm the file exists.
- **Override not applied (old key still used)** — ensure `FLOGO_APP_PROPS_ENV=auto` is set and the property name in the override exactly matches `GoogleConnection.googleconn.Service_Account_Key`.
- **Upload activity fails** — the sample points at a placeholder local file path; set it to a real file or remove `UploadLargeFile`.

## Help

For additional information, see the [Creating a Google Connection documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/google-cloud-storage/creating-a-google-connection.htm) and the [Google Connection Details documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/google-cloud-storage/google-connection-details.htm) on docs.tibco.com.
