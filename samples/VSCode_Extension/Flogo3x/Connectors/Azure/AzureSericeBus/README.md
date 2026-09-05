# Azure Service Bus — Publish, Queue Receive & Topic Subscribe — Flogo 3

## Overview

This sample demonstrates how to publish messages to **Microsoft Azure Service Bus** queues and topics, and how to consume them with a **Queue Receiver** and a **Topic Subscriber**, using the **TIBCO Flogo® 3** folder-based project format. A single REST call publishes one message to a queue and one to a topic; the queue-receiver and topic-subscriber triggers then pick those messages up and log them.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **Azure Service Bus Publish** | `#publish` activity | Publishes a message to a Service Bus queue (`testazure`) |
| **Azure Service Bus Publish** | `#publish` activity | Publishes a message to a Service Bus topic (`azuretopic`) |
| **Azure Service Bus Queue Receiver** | `#queuereceiver` trigger | Receives messages from queue `testazure` and starts a flow |
| **Azure Service Bus Topic Subscriber** | `#topicsubscriber` trigger | Subscribes to topic `azuretopic` (subscription `test1`) and starts a flow |
| **REST** | `#rest` trigger | `POST /publisher` on port `9999` that kicks off the Publisher flow |
| **Log** | `#log` activity | Logs published/received messages to the terminal |

---

## Architecture

```
  Client (curl / Postman)
      |
      |  POST http://localhost:9999/publisher   { "QueueMessage": "...", "TopicMessage": "..." }
      v
 +------------------------------------------------------------------------+
 |  AzureServicebusSample  (Flogo 3 app)                                |
 |                                                                        |
 |  REST Trigger (ReceiveHTTPMessage, port 9999, POST /publisher)         |
 |        |                                                               |
 |        v                                                               |
 |  Publisher                                                             |
 |    Publish(queue: testazure) -> Publish(topic: azuretopic)            |
 |        -> LogMessage -> Return                                         |
 |              |                       |                                 |
 |     publish  |                       | publish                         |
 |              v                       v                                 |
 |     [ ASB queue: testazure ]   [ ASB topic: azuretopic ]              |
 |              |                       |                                 |
 |              v                       v                                 |
 |  Queue Receiver Trigger        Topic Subscriber Trigger               |
 |        |                        (subscription: test1)                 |
 |        v                            |                                 |
 |  QueueReceiver flow                 v                                 |
 |    LogMessage                  TopicSubscriber flow                   |
 |                                    LogMessage                         |
 +------------------------------------------------------------------------+
```

- **Publisher** is triggered by `POST /publisher`. It publishes to the queue and to the topic, logs, then returns an HTTP 200 response.
- **QueueReceiver** is triggered by the Queue Receiver trigger on queue `testazure` (`ReceiveAndDelete` mode) and logs the received message.
- **TopicSubscriber** is triggered by the Topic Subscriber trigger on topic `azuretopic`, subscription `test1` (`ModePeekLock`) and logs the received message.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `AzureServicebusSample/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `AzureServicebusSample/app.fgprops` | App properties — Azure Service Bus connection settings |
| `AzureServicebusSample/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — `POST /publisher` on port `9999` → `Publisher` |
| `AzureServicebusSample/triggers/AzureServiceBusQueueReceiver.fgtrigger` | Queue Receiver trigger → `QueueReceiver` flow |
| `AzureServicebusSample/triggers/AzureServiceBusTopicSubscriber.fgtrigger` | Topic Subscriber trigger → `TopicSubscriber` flow |
| `AzureServicebusSample/flows/Publisher.fgflow` | Publisher flow — two Publish activities (queue + topic), Log, Return |
| `AzureServicebusSample/flows/QueueReceiver.fgflow` | Queue consumer flow — logs the message received from queue `testazure` |
| `AzureServicebusSample/flows/TopicSubscriber.fgflow` | Topic consumer flow — logs the message received from topic `azuretopic` |
| `AzureServicebusSample/connections/AzureServiceBus.fgconn` | Azure Service Bus connection (SAS Token auth) shared by the triggers and activities |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.
- Access to a **Microsoft Azure** subscription with an **Azure Service Bus** namespace.
- A queue named `testazure` and a topic named `azuretopic` with a subscription `test1` created in your namespace (or update the trigger/activity destinations to match your own).
- Azure Service Bus credentials for one of the supported authentication modes:
  - **SAS Token** (used by this sample) — Service Bus Namespace, Authorization Rule Name, and Shared Access Key.
  - **OAuth2** — Service Bus Namespace, Tenant ID, Client ID, and Client Secret.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `AzureServicebusSample` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `app.fgprops` file for **App Properties** and set the Azure Service Bus connection values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum, set:

```
AzureServiceBus.AzureServiceBus.Service_Bus_Namespace      = <your Service Bus namespace>
AzureServiceBus.AzureServiceBus.Authorization_Rule_Name    = <your SAS authorization rule name>
AzureServiceBus.AzureServiceBus.SharedAccessKey            = <your shared access key>
```

The connection uses **SAS Token** authentication by default. If you switch the connection to **OAuth2**, provide the Tenant ID, Client ID, and Client Secret instead.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. Then select this runtime for the app.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999** and the Queue Receiver / Topic Subscriber triggers begin listening on their configured destinations.

### Step 5 — Invoke the endpoint

```bash
curl -X POST "http://localhost:9999/publisher" \
  -H "Content-Type: application/json" \
  -d '{"QueueMessage":"Hello from queue","TopicMessage":"Hello from topic"}'
```

The Publisher flow publishes `QueueMessage` to queue `testazure` and `TopicMessage` to topic `azuretopic`, returns an HTTP 200 response, and the Queue Receiver and Topic Subscriber flows log the messages they consume in the VS Code terminal.

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `AzureServiceBus.AzureServiceBus.Service_Bus_Namespace` | `ENTER_YOUR_AZURE_SERVICE_NAMESPACE_HERE` | Azure Service Bus namespace (resource URI) to connect to |
| `AzureServiceBus.AzureServiceBus.Authorization_Rule_Name` | `ENTER_YOUR_AZURE_SERVICE_AUTHORIZATION_RULE_NAME_HERE` | SAS authorization rule name |
| `AzureServiceBus.AzureServiceBus.SharedAccessKey` | *(empty)* | SAS shared access key (primary/secondary key) |
| `AzureServiceBus.AzureServiceBus.Retry_Count` | `3` | Maximum number of connection retry attempts |
| `AzureServiceBus.AzureServiceBus.Retry_Interval` | `4000` | Interval (ms) between retry attempts |

> Update the namespace, authorization rule name, and shared access key to match your Azure Service Bus instance before running. The committed values are placeholders and must be replaced with your own.

---

## Troubleshooting

- **`401 Unauthorized` / authentication failed** — verify the Service Bus namespace, authorization rule name, and shared access key. The SAS rule must grant Send (for publishing) and Listen (for receiving) claims.
- **Publish succeeds but no message is received** — confirm the queue `testazure`, topic `azuretopic`, and subscription `test1` exist in your namespace and match the trigger/activity settings. Note the queue receiver uses `ReceiveAndDelete` mode (messages are removed on receive).
- **REST call returns a connection error** — ensure the app is running and port `9999` is free; the request body must be valid JSON with `QueueMessage` and `TopicMessage` fields.
- **Timeouts / transient connection drops** — increase `Retry_Count` and `Retry_Interval`, and confirm your network allows outbound access to the Azure Service Bus namespace.

---

## Help

For additional information, visit the [TIBCO Flogo® Connector for Microsoft Azure Service Bus documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/azservicebus/overview.htm).
