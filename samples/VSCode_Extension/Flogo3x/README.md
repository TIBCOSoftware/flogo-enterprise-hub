# **TIBCO Flogo® 3 Core & Connector Samples**

Build **enterprise integration flows** visually with **TIBCO Flogo® 3** — the low-code / no-code iPaaS inside VS Code. These samples use the **Flogo 3 folder-based project format** (modular `app.fgmd`, `app.fgprops`, `flows/`, `triggers/`, `connections/`) and cover REST, gRPC, and GraphQL API development; enterprise connectors for Salesforce, SAP, Oracle, PostgreSQL, Redis, Kafka, FTL, Google Cloud Storage, and more; flow design patterns; and unit testing — all without writing boilerplate code.

Each sample mirrors the path of its 2.x counterpart under [`../Flogo2x/`](../Flogo2x/) and has its own `README.md` with prerequisites and step-by-step run instructions (screenshot-free — steps only, so they stay accurate over time).

---

## API Development

| Sample | Protocol | Description |
|--------|----------|-------------|
| [REST Basic](./API-Development/REST/Basic/) | REST | REST trigger and InvokeRestService activity with API spec import, response code branching, and header management |
| [REST OAuth2 — Google Tasks](./API-Development/REST/rest-client-auth-OAuth2/) | REST | OAuth2 authentication flow with Google Tasks API |
| [gRPC with TLS](./API-Development/gRPC/all-tls/) | gRPC | Bidirectional gRPC client and server with mutual TLS authentication |
| [GraphQL Basic](./API-Development/graphQL/Basic/) | GraphQL | GraphQL server using the GraphQL Trigger with schema defined via App-Level Spec |

---

## Connectors

### Azure
| Sample | Description |
|--------|-------------|
| [Azure Data Factory](./Connectors/Azure/AzureDataFactory/) | Create and use Azure Data Factory activities for cloud-based data integration |
| [Azure Service Bus](./Connectors/Azure/AzureSericeBus/) | Azure Service Bus messaging integration (queue receive, topic subscribe, publish) |

### CRM — Salesforce
| Sample | Description |
|--------|-------------|
| [Salesforce Upsert & Change Data Capture](./Connectors/CRM/Salesforce/SalesforceUpsertAndChangeDataCapture/) | Upsert bulk records and subscribe to Change Data Capture events |
| [Salesforce Bulk API](./Connectors/CRM/Salesforce/Salesforce_BulkAPISample/) | Bulk query operations and job status monitoring |

### Databases
| Sample | Description |
|--------|-------------|
| [Oracle DB — Cluster Deployment](./Connectors/Databases/OracleDB_clusterDeployment/) | Oracle Database stored procedure calls and CRUD activities |
| [Oracle DB — Container Deployment](./Connectors/Databases/OracleDatabase/) | Deploy and run the Flogo Oracle DB app in Docker and Kubernetes (minikube) |
| [PostgreSQL CRUD](./Connectors/Databases/PostgreSQL-CRUD/) | Insert, update, delete, and query operations with TLS/SSL authentication |
| [Redis](./Connectors/Databases/Redis/) | Redis Sets group commands |

### Google Cloud
| Sample | Description |
|--------|-------------|
| [Google Cloud Storage CRUD](./Connectors/GoogleCloudStorage/) | Full bucket/object lifecycle — create, upload, list, get, update, delete — on Google Cloud Storage |
| [Google Connection — Override Service Account Key](./Connectors/GoogleConnection/OverrideServiceAccountKey/) | Google Cloud Storage CRUD using a Google connection with a runtime-overridable service account key |

### Messaging
| Sample | Description |
|--------|-------------|
| [EMS Request-Reply](./Connectors/Messaging/EMS/RequestReply/) | TIBCO Enterprise Message Service request-reply over a topic, with message properties |
| [Kafka Producer-Consumer](./Connectors/Messaging/Kafka/Basic-producer-consumer-flow/) | Basic Kafka publish-subscribe pattern |
| [FTL Publish-Subscribe](./Connectors/Messaging/FTL/PublishSubscribe/) | TIBCO FTL publish/subscribe with binary file transfer (Opaque format) |

### SAP
| Sample | Description |
|--------|-------------|
| [SAP S/4HANA](./Connectors/SAP_Connectors/SAPS4HANA/) | CRUD activities using the SAP S/4HANA connector |

---

## Flow Design Concepts

| Sample | Description |
|--------|-------------|
| [Hello World](./Flow-design-concepts/hello-world/) | Simple HTTP trigger that prints and returns a greeting — start here |
| [App Hooks](./Flow-design-concepts/appHooks/) | Application startup and shutdown hooks with a ReceiveHTTPMessage trigger |
| [Branching & Error Handling — Null/Empty JSON](./Flow-design-concepts/branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/) | Branch-level error handling for null, empty, and invalid JSON objects/arrays |
| [REST Branching & Error Handling](./Flow-design-concepts/branching-errorhandling/flogo.sample.rest_branching_error_handling/) | REST flow with conditional branching and error handling |
| [Shared Data](./Flow-design-concepts/shared-data/) | Share runtime data within a flow or across flows using the SharedData activity |
| [Subflow Basic](./Flow-design-concepts/subflow-basic/) | Call subflows and detached invocation subflows from a parent flow |

---

## Mapping & Arrays

| Sample | Description |
|--------|-------------|
| [Conditional Mappings (if-else)](./Mapping-Arrays/if-else/) | Conditional data mappings using if-else blocks across flows and subflows |

---

## Unit Testing

| Sample | Description |
|--------|-------------|
| [Play Testcase — Flow Debugger](./Unit-Testing/PlayTestcase-flowDebugger/) | Test and debug activities in play mode — inspect input/output data and detect errors without building |
| [Unit Testing Basic](./Unit-Testing/UnitTesting-basic/) | Test individual flows in isolation to verify behavior and catch issues early |

---

## Prerequisites

- **Microsoft Visual Studio Code** with the **TIBCO Flogo® 3 Extension** installed
- **TIBCO Flogo® 3.0.0** or later
- **Connector-specific requirements:**
  - Oracle samples: Oracle Instant Client libraries (plus `libaio`) at runtime
  - PostgreSQL: PostgreSQL server with TLS certificates
  - Salesforce: Salesforce developer account and connected app (OAuth)
  - Azure: Azure subscription and Service Bus / Data Factory credentials
  - EMS: TIBCO Enterprise Message Service broker (`EMS_HOME` set on the local runtime)
  - Kafka: Kafka broker (local or cloud)
  - FTL: TIBCO FTL server / realm (`TIBFTL_ROOT` set to build)
  - SAP: SAP S/4HANA system with the RFC SDK
  - Redis: Redis server instance
  - Google Cloud Storage: a GCP service account key with Cloud Storage permissions

## Quick Start

1. Open the sample's **project folder** (the folder containing `app.fgmd`) in VS Code with the Flogo 3 extension.
2. Open the `.fgprops` file and configure the app properties / connection settings for your environment.
3. Create and select a **Local Runtime** — click the **Flogo 3** icon → in **RUNTIME EXPLORER** add a runtime with the **+** button, set any required env (e.g. `EMS_HOME`), and **Save**.
4. In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. The binary is produced in `bin/` and logs appear in the integrated terminal.

See each sample's individual `README.md` for detailed configuration and usage instructions.

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

<!-- SEO Keywords: TIBCO Flogo 3, Integration Flows, REST API, gRPC, GraphQL, Enterprise Connectors, Low-Code Integration, No-Code iPaaS, Visual Flow Designer, Salesforce Connector, SAP S/4HANA, Oracle Database, PostgreSQL, Redis, Kafka, TIBCO FTL, Google Cloud Storage, Azure Service Bus, TIBCO EMS, API Development, Microservices, Event-Driven Architecture, Unit Testing, VS Code Extension, Flogo 3 folder-based project -->

**Topics:** `REST API` · `gRPC` · `GraphQL` · `Enterprise Connectors` · `Low-Code` · `iPaaS` · `Flogo 3`
