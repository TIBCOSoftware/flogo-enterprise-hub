# **TIBCO Flogo® Extension for VS Code — Samples**

Build **enterprise integration flows** visually with **TIBCO Flogo®** — the low-code / no-code iPaaS inside VS Code. These samples cover REST, gRPC, and GraphQL API development; enterprise connectors for Salesforce, SAP, Oracle, PostgreSQL, Redis, Kafka, and more; flow design patterns; and unit testing — all without writing boilerplate code.

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
| [Azure Service Bus](./Connectors/Azure/AzureSericeBus/) | Azure Service Bus messaging integration |

### CRM — Salesforce
| Sample | Description |
|--------|-------------|
| [Salesforce Upsert & Change Data Capture](./Connectors/CRM/Salesforce/SalesforceUpsertAndChangeDataCapture/) | Upsert bulk records and subscribe to Change Data Capture events |
| [Salesforce Bulk API](./Connectors/CRM/Salesforce/Salesforce_BulkAPISample/) | Bulk query operations and job status monitoring |

### Databases
| Sample | Description |
|--------|-------------|
| [Oracle DB — Cluster Deployment](./Connectors/Databases/OracleDB_clusterDeployment/) | Oracle Database stored procedure calls and CRUD activities |
| [Oracle DB — Container Deployment](./Connectors/Databases/OracleDatabase/) | Deploy and run Flogo Oracle DB app in Docker and Kubernetes (minikube) |
| [PostgreSQL CRUD](./Connectors/Databases/PostgreSQL-CRUD/) | Insert, update, delete, and query operations with TLS/SSL authentication |
| [Redis](./Connectors/Databases/Redis/) | Redis Sets group commands |

### Messaging
| Sample | Description |
|--------|-------------|
| [EMS Request-Reply](./Connectors/Messaging/EMS/RequestReply/) | TIBCO Enterprise Message Service with TLS, queue and topic subscriptions |
| [Kafka Producer-Consumer](./Connectors/Messaging/Kafka/Basic-producer-consumer-flow/) | Basic Kafka publish-subscribe pattern |

### SAP
| Sample | Description |
|--------|-------------|
| [SAP S/4HANA](./Connectors/SAP_Connectors/SAPS4HANA/) | CRUD activities using the SAP S/4HANA connector |

---

## Flow Design Concepts

| Sample | Description |
|--------|-------------|
| [Hello World](./Flow-design-concepts/hello-world/) | Simple HTTP trigger that prints and returns a greeting — start here |
| [App Hooks](./Flow-design-concepts/appHooks/) | Application startup and shutdown hooks with ReceiveHTTPMessage trigger |
| [Branching & Error Handling](./Flow-design-concepts/branching-errorhandling/) | Branch-level error handling for null, empty, and invalid JSON objects |
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

- **Microsoft Visual Studio Code** with the **TIBCO Flogo® Extension** installed
- **TIBCO Flogo® 2.26.x** or later
- **Connector-specific requirements:**
  - Oracle samples: Oracle Instant Client libraries
  - PostgreSQL: PostgreSQL server with TLS certificates
  - Salesforce: Salesforce developer account and connected app
  - Azure: Azure subscription and service credentials
  - EMS: TIBCO Enterprise Message Service broker
  - Kafka: Kafka broker (local or cloud)
  - SAP: SAP S/4HANA system with RFC SDK
  - Redis: Redis server instance

## Quick Start

1. Open the `flogo-enterprise-hub` folder in VS Code with the Flogo extension installed.
2. Navigate to the sample you want to try and open the `.flogo` file.
3. Configure any required connections (database, messaging, API credentials) in the connection settings.
4. Select a Flogo runtime and click **Run**.

See each sample's individual `readme.md` for detailed configuration and usage instructions.

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

<sub>

**Keywords:** Integration Flows, REST API, gRPC, GraphQL, Enterprise Connectors, Low-Code Integration, No-Code iPaaS, Visual Flow Designer, Salesforce Connector, SAP S/4HANA, Oracle Database, PostgreSQL, Redis, Kafka, Azure Service Bus, TIBCO EMS, API Development, Microservices, Event-Driven Architecture, Unit Testing, VS Code Extension, TIBCO Flogo

`#Integration` `#RESTAPI` `#gRPC` `#GraphQL` `#LowCode` `#NoCode` `#iPaaS` `#TIBCOFlogo` `#Salesforce` `#SAP` `#Oracle` `#PostgreSQL` `#Kafka` `#VSCode` `#EnterpriseConnectors` `#Microservices`

</sub>
