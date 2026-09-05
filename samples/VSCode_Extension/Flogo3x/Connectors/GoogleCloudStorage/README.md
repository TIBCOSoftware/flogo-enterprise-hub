# Google Cloud Storage CRUD — Flogo 3

## Overview

This sample demonstrates the full lifecycle of bucket and object management in **Google Cloud Storage (GCS)** using the **TIBCO Flogo® 3** folder-based project format. A single REST call triggers one flow that exercises all six GCS connector activities in sequence — Create, Upload, List, Get, Update, and Delete — for both buckets and objects.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /gcs-crud` on port `9999` starts the flow |
| **GCS Create** | `#create` activity | Creates a bucket and creates an object with inline content |
| **GCS Upload** | `#upload` activity | Chunked/resumable upload of a large local file to the bucket |
| **GCS List** | `#list` activity | Lists objects in the bucket |
| **GCS Get** | `#get` activity | Retrieves a specific object from the bucket |
| **GCS Update** | `#update` activity | Updates object metadata, content type, and ACL |
| **GCS Delete** | `#delete` activity | Deletes the object, the uploaded file, and the bucket |
| **Log** | `#log` activity | Prints each activity's output to the terminal |
| **Return** | `#actreturn` activity | Returns the final delete result to the REST caller |

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/gcs-crud
      v
 +-------------------------------------------------------------------+
 |  GCS-CRUD-App  (Flogo 3 app)                                     |
 |                                                                   |
 |  REST Trigger (ReceiveHTTPMessage, GET /gcs-crud, port 9999)      |
 |        |                                                          |
 |        v                                                          |
 |  GCS_All_Activity_Flow                                            |
 |    StartActivity(noop)                                            |
 |      -> CreateBucket   -> CreateObject   -> Log                   |
 |      -> UploadLargeFile -> Log                                    |
 |      -> ListObject     -> Log                                     |
 |      -> GetObject      -> Log                                     |
 |      -> UpdateObject   -> Log                                     |
 |      -> DeleteObject -> DeleteUploadedFile -> DeleteBucket -> Log |
 |      -> Return                                                    |
 |                          |                                        |
 |                          v                                        |
 |                 [ Google Cloud Storage ] (via googleconn)         |
 +-------------------------------------------------------------------+
```

All GCS activities authenticate through the shared `googleconn` connection, which uses a GCP service-account JSON key supplied as an app property.

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `GCS-CRUD-App/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `GCS-CRUD-App/app.fgprops` | App properties — the GCS connection's service-account key |
| `GCS-CRUD-App/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /gcs-crud` on port `9999` → `GCS_All_Activity_Flow` |
| `GCS-CRUD-App/flows/GCS_All_Activity_Flow.fgflow` | Flow chaining all six GCS activities plus Log and Return |
| `GCS-CRUD-App/connections/googleconn.fgconn` | Google connection used by all GCS activities |

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
- A **Google Cloud Platform (GCP)** account with an active project.
- A **Service Account** in your GCP project with a downloaded **JSON key file**. The service account needs the `Storage Admin` IAM role (or equivalent create/list/get/update/upload/delete permissions on buckets and objects).
- A **globally unique** bucket name. This sample uses `gcsflogo-test-bucket`; change it in the Create/Upload/List/Get/Update/Delete activities if it is already taken.
- For the **Upload** activity, a valid local file on your machine. Update the `filePath` in the `UploadLargeFile` activity to point to it before running.

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `GCS-CRUD-App` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `app.fgprops` file for App Properties and set the connection value for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum, set:

```
GoogleConnection.googleconn.Service_Account_Key = <Base64-encoded contents of your GCP service-account JSON key>
```

The committed value is a placeholder and must be replaced with your own service-account key.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

```bash
curl -X GET "http://localhost:9999/gcs-crud"
```

The flow creates the bucket and object, uploads the large file, lists and gets the object, updates its metadata/ACL, then deletes the object, uploaded file, and bucket. The final delete result is returned in the REST response, and each activity's output is logged to the VS Code terminal.

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `GoogleConnection.googleconn.Service_Account_Key` | *(placeholder Base64 key)* | Base64-encoded GCP service-account JSON key used to authenticate all GCS API calls |

> Replace the committed placeholder key with your own service-account key before running.

## Troubleshooting

- **`invalid_grant` / `Invalid JWT Signature`** — the service-account key is invalid, expired, or lacks permissions. Re-generate the key and ensure the account has the `Storage Admin` role (or sufficient create/list/get/update/delete permissions).
- **Create Bucket fails / bucket already exists** — bucket names are global. Change `gcsflogo-test-bucket` to a globally unique name in every GCS activity that references it.
- **Upload activity fails** — verify the `filePath` in the `UploadLargeFile` activity points to a file that exists locally, and that the bucket was created successfully first.
- **List returns empty results** — confirm any `prefix` filter on the List activity matches the actual object name prefix in your bucket.

## Help

For additional information, visit the [TIBCO Flogo® Connector for Google Cloud Storage documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/google-cloud-storage/overview.htm?TocPath=Connectors%2520User%2520Guide%257CSupported%2520Flogo%2520Connectors%257CGoogle%2520Cloud%2520Storage%257C_____0).
