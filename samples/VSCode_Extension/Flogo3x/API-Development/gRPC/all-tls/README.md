# gRPC Server & Client with Mutual TLS (all-tls) — Flogo 3

## Overview

This sample demonstrates a secure **gRPC service and client** built with the **TIBCO Flogo® 3** folder-based project format. A gRPC server exposes a `SayHello` unary method (defined in `greet.proto`) over a **mutual-TLS (mTLS)** connection, and a REST-fronted client invokes that method securely and returns the greeting to the HTTP caller. Both endpoints load the service definition from an app-level proto spec.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **gRPC Trigger** | `grpc` trigger (`ND_Server`) | Hosts the `Greeting/SayHello` service on port `6443` with TLS + mTLS enabled |
| **gRPC Invoke** | `grpc` activity (`ND_Client`) | Calls the server's `SayHello` method over mTLS using client certificates |
| **REST Trigger** | `rest` trigger (`ND_Client`) | `GET /grpc` on port `9999` — HTTP entry point that drives the gRPC call |
| **Return** | `actreturn` activity | Returns the gRPC response to the caller |
| **Log** | `log` activity | Prints the request/greeting to the terminal |
| **App-level proto spec** | `specs/greet.proto` | Shared service definition referenced as `spec://greet.proto` |

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/grpc
      v
 +---------------------------------------------------+
 |  ND_Client  (Flogo 3 app)                       |
 |  REST Trigger (GET /grpc, port 9999)              |
 |     StartActivity -> gRPCInvoke -> Log -> Return  |
 +---------------------------------------------------+
      |
      |  gRPC SayHello  (mutual TLS, localhost:6443)
      v
 +---------------------------------------------------+
 |  ND_Server  (Flogo 3 app)                       |
 |  gRPC Trigger (Greeting/SayHello, port 6443)      |
 |     StartActivity -> Log -> Return                |
 +---------------------------------------------------+
```

- **ND_Server** hosts the `Greeting` service and answers `SayHello` requests. TLS and mTLS are both enabled, so it presents a server certificate and requires the client to present a trusted client certificate.
- **ND_Client** exposes a REST endpoint that, when called, invokes `SayHello` on the server over mTLS and returns the `greet` field from the gRPC response.

Run **ND_Server first**, then **ND_Client** — the client fails to connect if the server is not already listening on `6443`.

---

## Files in This Sample

Each Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `ND_Server/app.fgmd` | Server app metadata (`flogoVersion: 3.0.0`, name `ND_Server`) |
| `ND_Server/app.fgprops` | Server app properties |
| `ND_Server/triggers/gRPCTrigger.fgtrigger` | gRPC trigger — `Greeting/SayHello` on port `6443`, `enableTLS` + `enableMTLS` true, with root CA / server cert / server key |
| `ND_Server/flows/New_flow.fgflow` | Server flow — logs the request name and returns `greet` |
| `ND_Server/specs/greet.proto` | Proto spec for the `Greeting` service |
| `ND_Client/app.fgmd` | Client app metadata (`flogoVersion: 3.0.0`, name `ND_Client`) |
| `ND_Client/app.fgprops` | Client app properties |
| `ND_Client/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — port `9999` (flow binds `GET /grpc`) |
| `ND_Client/flows/New_flow.fgflow` | Client flow — gRPC Invoke (`SayHello` @ `localhost:6443`, mTLS) then Return |
| `ND_Client/specs/greet.proto` | Proto spec shared with the server (`spec://greet.proto`) |

The `greet.proto` service definition:

```proto
syntax = "proto3";
package greet;
message SayHelloRequest  { string name  = 1; }
message SayHelloResponse { string greet = 1; }
service Greeting { rpc SayHello(SayHelloRequest) returns (SayHelloResponse); }
```

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
- A configured **Local Runtime** in the Flogo VS Code extension (no special native SDK is required for gRPC — it is a pure-Go connector).
- TLS material for mutual authentication. The sample already embeds a matching set of certificates/keys in the trigger and gRPC Invoke activity (root CA, server cert/key, and client cert/key). Replace them with your own for a real deployment; the committed certificates are self-signed for `localhost` and for demonstration only.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this `all-tls` sample folder in VS Code with the Flogo 3 extension. The extension detects both the `ND_Server` and `ND_Client` projects (each folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In each Flogo app, open the `.fgprops` file for App Properties and review the values for your environment (see the [App Properties Reference](#app-properties-reference) below). The gRPC endpoint host/port and the certificates are configured on the gRPC trigger (server) and the gRPC Invoke activity (client); update them there if you change hosts or supply your own certificates. The default client target is `localhost:6443`.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. No additional environment variables are required for gRPC.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the **`ND_Server`** module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and the gRPC server starts listening on port `6443`. Then repeat for the **`ND_Client`** module; its REST trigger starts listening on port `9999`. Execution logs for both appear in the integrated terminal.

### Step 5 — Invoke the endpoint

Call the client's REST endpoint:

```bash
curl "http://localhost:9999/grpc"
```

The client invokes `SayHello` on the server over mTLS with the request name `Nehu` (the value mapped in the gRPC Invoke activity) and returns the greeting, for example:

```json
{ "output": "Nehu" }
```

The server logs the received name and the client logs the returned `greet` value in the VS Code terminal.

---

## App Properties Reference

### ND_Server (`ND_Server/app.fgprops`)

| Property | Default | Description |
|---|---|---|
| `Property_1` | *(empty)* | Placeholder app property; not used by the flow |

> The server's TLS material (`rootCA`, `serverCert`, `serverKey`), gRPC `port` (`6443`), `protoName` (`greet`), and `enableTLS` / `enableMTLS` are configured directly on `triggers/gRPCTrigger.fgtrigger`.

### ND_Client (`ND_Client/app.fgprops`)

| Property | Default | Description |
|---|---|---|
| `clientcert` | *(local path)* | Placeholder for a client certificate path |
| `clientbase` | *(base64 cert)* | Placeholder base64-encoded certificate value |

> The client's effective mTLS material (`clientCert` root CA, `clientCert2` client cert, `clientKey`), target `hosturl` (`localhost:6443`), and `enableTLS` / `enableMTLS` are configured on the gRPC Invoke activity in `flows/New_flow.fgflow`. The REST listen port (`9999`) is set on `triggers/ReceiveHTTPMessage.fgtrigger`.

---

## Troubleshooting

- **Client fails with a connection refused / transport error** — the gRPC server is not running. Start `ND_Server` before `ND_Client` and confirm it is listening on port `6443`.
- **TLS handshake / certificate verification error** — the client and server certificates must be issued by the same CA and valid for the connection host (`localhost`). If you replaced any certificate, update the matching CA / cert / key on both the server trigger and the client gRPC Invoke activity.
- **`address already in use` on 6443 or 9999** — another process is bound to the port. Stop it or change the port on the gRPC trigger / REST trigger respectively.
- **`SayHello` not found / method error** — ensure both apps reference the same `greet.proto` spec (`spec://greet.proto`) with `serviceName: Greeting` and `methodName: SayHello`.

---

## Help

For additional information, visit the [TIBCO Flogo® Connector for gRPC documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/grpc/overview.htm).
