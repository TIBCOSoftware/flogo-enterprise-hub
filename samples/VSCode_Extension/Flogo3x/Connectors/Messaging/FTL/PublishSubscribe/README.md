# FTL Publish-Subscribe (Binary File Transfer) — Flogo 3

## Overview

This sample demonstrates the **publish-subscribe messaging pattern** over TIBCO FTL using the **TIBCO Flogo® 3** folder-based project format. A REST call triggers a flow that reads a file as binary content and publishes it to an FTL destination; a subscriber trigger listening on the same destination receives the message, logs it, and writes the binary content back out to a file.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /ftl` entry point on port `9999` that starts the Publisher flow |
| **Read File** | `#read` activity (Binary) | Reads a file's content as binary for the message payload |
| **FTL Publisher** | `#publisher` activity | Publishes the binary payload to FTL destination `read` (Opaque format, Send Inline) |
| **FTL Subscriber** | `#subscriber` trigger | Standard durable subscription (`readstandard`) on destination `read`; each message starts a new flow |
| **Log Message** | `#log` activity | Logs the received message data |
| **Write File** | `#write` activity (Binary) | Writes the received binary content to a file |

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/ftl
      v
 +----------------------------------------------------------------------+
 |  FTL_PublishSubscribe  (Flogo 3 app)                               |
 |                                                                      |
 |  REST Trigger (ReceiveHTTPMessage, port 9999, GET /ftl)             |
 |        |                                                             |
 |        v                                                             |
 |  Publisher flow                                                      |
 |    noop -> ReadFile (Binary) -> FTLPublisher -> Return              |
 |                                       |                              |
 |                          publish      v                             |
 |                          [ FTL destination: read ]                  |
 |                                       |                              |
 |                                       v                              |
 |  FTL Subscriber Trigger (FTLMessageSubscriber, dest=read,           |
 |                          durable=readstandard, Standard)            |
 |        |                                                             |
 |        v                                                             |
 |  Subscriber flow                                                     |
 |    noop -> LogMessage -> WriteFile (Binary)                         |
 +----------------------------------------------------------------------+
```

- The **Publisher** flow is triggered by `GET /ftl`. It reads a file as binary, publishes the payload to FTL destination `read` using the **Opaque** message format, and returns `200 / "Message Published"` to the REST caller.
- The **Subscriber** flow is triggered by the **FTL Subscriber** trigger with a Standard durable subscription (`readstandard`) on destination `read`. It logs the message data and writes the binary content to a file.

Both the publisher activity and subscriber trigger use the same FTL connection (`ftlConnection.fgconn`) and the same destination (`read`) with matching message format (**Opaque**).

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `FTL_PublishSubscribe/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `FTL_PublishSubscribe/app.fgprops` | App properties — FTL connection settings |
| `FTL_PublishSubscribe/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `GET /ftl` on port `9999` → Publisher flow |
| `FTL_PublishSubscribe/triggers/FTLMessageSubscriber.fgtrigger` | FTL Subscriber trigger — destination `read`, durable `readstandard` → Subscriber flow |
| `FTL_PublishSubscribe/flows/Publisher.fgflow` | Publisher flow — Read File (Binary), then FTL Publisher, then Return |
| `FTL_PublishSubscribe/flows/Subscriber.fgflow` | Subscriber flow — Log Message, then Write File (Binary) |
| `FTL_PublishSubscribe/connections/ftlConnection.fgconn` | FTL connection used by the publisher activity and subscriber trigger |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.
- A running **TIBCO FTL server** reachable from your machine (e.g., `https://localhost:8785`). The server must be up before you run the app.
- A **destination** configured on the FTL server (e.g., `read`).
- If your FTL server uses Basic Authentication with TLS, mTLS, or OAuth2.0, ensure you have the required credentials, certificates, and trust files.
- The **TIBCO FTL runtime libraries** available locally, with the `TIBFTL_ROOT` environment variable pointing to your FTL installation and the FTL `bin` directory on your system `PATH` (required by the local runtime to build/run FTL apps).
- If the FTL server is hosted on a remote instance, ensure your IP is whitelisted or the server is reachable from your network.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `FTL_PublishSubscribe` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `.fgprops` file for **App Properties** and set the FTL connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum, set:

```
FTL.ftlConnection.FTL_Server_URL = <your FTL server URL, e.g. https://localhost:8785>
FTL.ftlConnection.User_Name      = <your FTL user, if required>
FTL.ftlConnection.Password       = <your FTL password, if required>
```

Also update the file paths used by the flows before running:

- In the **Publisher** flow, set the **Read File** activity's `fileName` to the file you want to send (default placeholder `<path-to-your-file>`).
- In the **Subscriber** flow, set the **Write File** activity's `fileName` to the desired output path (default placeholder `<path-to-output-file>`).

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name and set the required FTL environment (`TIBFTL_ROOT` pointing to your FTL installation, with the FTL `bin` directory on `PATH`) → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999** and the FTL subscriber subscribes to destination `read`.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/ftl"
```

The REST response is:

```json
{"code":200,"message":"Message Published"}
```

The Publisher flow reads the configured file and publishes it to `read`; the Subscriber flow receives the message, logs the content, and writes the binary payload to the output path configured in the Write File activity. Progress is printed to the VS Code terminal.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `FTL.ftlConnection.FTL_Server_URL` | *(empty)* | FTL server URL to connect to (e.g., `https://localhost:8785`) |
| `FTL.ftlConnection.FTL_Secondary_Server_URL` | *(empty)* | Secondary FTL server URL for failover (optional) |
| `FTL.ftlConnection.FTL_Application_Instance_ID` | *(empty)* | Optional application instance identifier |
| `FTL.ftlConnection.FTL_Client_Label` | *(empty)* | Optional label identifying this client connection |
| `FTL.ftlConnection.User_Name` | *(empty)* | User name for authentication with the FTL server (if required) |
| `FTL.ftlConnection.Password` | *(empty)* | Password for authentication with the FTL server (if required) |
| `FTL.ftlConnection.Use_certificate_for_verification` | `false` | When `true`, verify the FTL server using the provided trust file |
| `FTL.ftlConnection.FTL_Server_Trust_File` | *(empty)* | CA / server trust certificate file for TLS verification |

> Set `FTL_Server_URL` (and credentials/certificates as needed) to match your FTL server before running. The committed values are placeholders and must be replaced with your own.

---

## Troubleshooting

- **`warn rscl: Client(_boot) Realm not responding at https://<host>:<port> ... Could not connect to server`** — the FTL server is down, or `FTL_Server_URL` is incorrect/unreachable. Confirm the server is running and the URL is correct.
- **`Failed to create engine instance due to error: failed to connect to FTL realm [...]: Invalid user name or password`** — authentication failed. Verify `User_Name`, `Password`, and (for TLS/mTLS/OAuth2.0) the certificate/trust file settings.
- **Build fails referencing FTL libraries** — the FTL runtime is not configured for the local runtime. Set `TIBFTL_ROOT` and add the FTL `bin` directory to `PATH`, then rebuild.
- **No file written / read error** — the `fileName` in the Read File or Write File activity is invalid. Ensure both file paths are correct and accessible before running.

---

## Help

For additional information, visit the [TIBCO FTL Connector documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/ftl/ftl_overview.htm?TocPath=Connectors%2520User%2520Guide%257CSupported%2520Flogo%2520Connectors%257CTIBCO%2520FTL%257C_____0).
