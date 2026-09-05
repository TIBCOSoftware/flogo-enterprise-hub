# Kafka Basic Producer-Consumer Flow — Flogo 3

## Overview

This sample demonstrates the **Apache Kafka producer/consumer messaging pattern** using the **TIBCO Flogo® 3** folder-based project format. A REST call publishes a message to a Kafka topic with the **Kafka Producer** activity; a **Kafka Consumer** trigger listening on the same topic receives the message, commits the offset, and logs it.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | `GET /produce/{message}` entry point that starts the producer flow |
| **Kafka Producer** | `#producer` activity | Publishes the message from the path parameter to the configured topic |
| **Kafka Consumer** | `#consumer` trigger | Subscribes to the topic; each message starts a new flow |
| **Kafka Commit Offset** | `#commit` activity | Explicitly commits the consumer offset for the received message |
| **Log Message** | `#log` activity | Prints the received message to the terminal |

---

## Architecture

```
  Client (curl / browser / Postman)
      |
      |  GET http://localhost:9999/produce/{message}
      v
 +----------------------------------------------------------------------+
 |  KafkaAppSample  (Flogo 3 app)                                     |
 |                                                                      |
 |  REST Trigger (ReceiveHTTPMessage, port 9999)                        |
 |        |                                                             |
 |        v                                                             |
 |  ProducerFlow                                                        |
 |    StartActivity (noop) -> KafkaProducer -> Return                   |
 |                                  |                                   |
 |                publish message   v                                   |
 |                        [ Kafka topic: testPart28 ]                   |
 |                                  |                                   |
 |                                  v                                   |
 |  Kafka Consumer Trigger (KafkaConsumer, group: sasl-consumer-grp)    |
 |        |                                                             |
 |        v                                                             |
 |  ConsumerFlow                                                        |
 |    StartActivity (noop) -> KafkaCommitOffset -> LogMessage           |
 +----------------------------------------------------------------------+
```

- **ProducerFlow** is triggered by `GET /produce/{message}`. It publishes the `{message}` path parameter to the Kafka topic and returns a confirmation in the REST response.
- **ConsumerFlow** is triggered by the **Kafka Consumer** trigger subscribed to the same topic. It commits the offset and logs the received message.

---

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `KafkaAppSample/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `KafkaAppSample/app.fgprops` | App properties — Kafka connection settings, topic, and consumer group |
| `KafkaAppSample/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger — port `9999`, handles `GET /produce/{message}` → `ProducerFlow` |
| `KafkaAppSample/triggers/KafkaConsumer.fgtrigger` | Kafka Consumer trigger → `ConsumerFlow` |
| `KafkaAppSample/flows/ProducerFlow.fgflow` | Producer flow — noop → Kafka Producer → Return |
| `KafkaAppSample/flows/ConsumerFlow.fgflow` | Consumer flow — noop → Kafka Commit Offset → Log Message |
| `KafkaAppSample/connections/kafkaSSLGCPConn.fgconn` | Apache Kafka client connection used by the trigger and producer activity |

---

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
- An active **Apache Kafka cluster** reachable from your machine, with the target topic available (or auto-creation enabled). The brokers must be up before you run the app.
- If your cluster uses **SSL/SASL** or a **Schema Registry (Avro)**, ensure you have the required credentials/certificates and the registry URL.
- If the broker is hosted on a cloud VM (e.g., AWS EC2 / GCP), ensure the broker host/port is reachable and your public IP is whitelisted.

---

## Setup & Run

### Step 1 — Open the app in VS Code

Open this `Basic-producer-consumer-flow` folder in Visual Studio Code with the Flogo 3 extension. The extension detects the `KafkaAppSample` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

In the Flogo app, open the `.fgprops` file for **App Properties** and set the Kafka connection and destination values for your environment (see the [App Properties Reference](#app-properties-reference) below). At minimum, set:

```
Kafka.kafkaSSLGCPConn.Brokers = <broker1:9092,broker2:9092>
topic                         = <your Kafka topic>
cgp                           = <your consumer group>
```

For an SSL/SASL cluster, also configure the certificate properties (`CA_or_Server_Certificate`, `Client_Certificate`, `Client_Key`) to match your broker.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999** and the Kafka Consumer trigger subscribes to the configured topic.

### Step 5 — Invoke the endpoint

```bash
curl "http://localhost:9999/produce/HelloKafka"
```

The producer flow publishes `HelloKafka` to the topic and returns a confirmation such as:

```
Message successfully sent on topic: testPart28
```

The Kafka Consumer trigger then receives the message, commits the offset, and the Log activity prints it to the VS Code terminal:

```
Message Received in Consumer on Topic : testPart28 is: HelloKafka
```

---

## App Properties Reference

| Property | Default | Description |
|---|---|---|
| `Kafka.kafkaSSLGCPConn.Brokers` | `gasdflgflogo301.dev.tibco.com:9093` | Comma-separated Kafka broker list (`host:port`) |
| `Kafka.kafkaSSLGCPConn.CA_or_Server_Certificate` | *(cert)* | CA / server certificate (SSL mode) |
| `Kafka.kafkaSSLGCPConn.Client_Certificate` | *(cert)* | Client certificate (SSL/mTLS mode) |
| `Kafka.kafkaSSLGCPConn.Client_Key` | *(key)* | Client private key (SSL/mTLS mode) |
| `Kafka.kafkaSSLGCPConn.Connection_Timeout` | `30` | Time (s) to wait for the initial connection |
| `Kafka.kafkaSSLGCPConn.Retry_Backoff` | `250` | Time (ms) to wait before retrying leader election |
| `Kafka.kafkaSSLGCPConn.Max_Retry` | `3` | Number of metadata request retries during leader election |
| `Kafka.kafkaSSLGCPConn.Refresh_Frequency` | `40` | Time (s) after which metadata is refreshed |
| `topic` | `testPart28` | Kafka topic used by the producer and consumer |
| `cgp` | `sasl-consumer-grp` | Consumer group for the Kafka Consumer trigger |

> Update `Brokers`, `topic`, `cgp`, and the certificate values to match your cluster before running. The committed values are environment-specific placeholders and must be replaced with your own.

---

## Troubleshooting

- **Connection refused / no brokers available** — verify `Kafka.kafkaSSLGCPConn.Brokers` and that the cluster/firewall allows access from your machine.
- **Authentication / TLS handshake errors** — confirm the auth mode and the SSL/SASL credentials or certificates (`CA_or_Server_Certificate`, `Client_Certificate`, `Client_Key`) are correct.
- **No message delivered to the consumer** — check that the topic exists (and has partitions), that producer and consumer use the same `topic`, and that the consumer group `cgp` is valid.
- **Message not consumed after restart** — the consumer commits offsets (`KafkaCommitOffset`); already-committed messages will not be re-delivered to the same group. Use a new consumer group or reset offsets to re-read.

---

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation - TIBCO Flogo Connector for Apache Kafka](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/kafka/overview.htm).
