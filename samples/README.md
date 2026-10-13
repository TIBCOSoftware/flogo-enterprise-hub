# **TIBCO Flogo® Samples**

Ready-to-run sample applications for **TIBCO Flogo®** — the low-code / no-code iPaaS for building **AI agents**, **MCP servers**, **enterprise integration flows**, and **event-driven microservices**. Explore everything from Agentic AI orchestration and Model Context Protocol (MCP) servers to REST/gRPC/GraphQL APIs, database connectors, and Docker deployment patterns.

**Jump to:** [Agentic AI Samples](#agentic-ai-samples) · [MCP Samples](#model-context-protocol-mcp-samples) · [More Sample Categories](#more-sample-categories)

---

## Agentic AI Samples

Build, orchestrate, and govern AI agents inside Flogo integration flows using the **Agentic AI Connector** (LLM Client Activity, AI Agent Activity, AI Agent Trigger) and the **Flogo-as-MCP-server** pattern. The [`Agentic_AI/`](./Agentic_AI/) folder holds two collections: **feature samples** (below) that each teach a building block, and **end-to-end industry use-case demos** grouped by industry (see [Industry Use-Case Demos](#agentic-ai-industry-use-case-demos)). To run a demo, start with the governed use cases in [`Agentic_AI/Industry_Use_Cases/`](./Agentic_AI/Industry_Use_Cases/); [`Industry_Use_Cases_old/`](./Agentic_AI/Industry_Use_Cases_old/) is legacy, kept for reference while it is migrated.

**➡️ Full details, prerequisites & Quick Start: [Agentic AI README](./Agentic_AI/README.md)**

### Feature Samples

| Sample | Vertical | What It Demonstrates |
|---|---|---|
| [Insurance Claims Processor](./Agentic_AI/Feature_Samples/InsuranceClaimsProcessor/) | Banking, Financial Services & Insurance | LLM Client chaining: MCP coverage check → A2A fraud scoring → decision |
| [Mortgage AI Processor](./Agentic_AI/Feature_Samples/mortgagedemo/) | Banking, Financial Services & Insurance | Flogo as an MCP server for autonomous loan decisioning (approve/escalate/decline) |
| [Agent Privilege IDs](./Agentic_AI/Feature_Samples/Agent-Privilege-IDs/) | Agent Governance (cross-industry) | Each AI agent has its own privilege ID: JWT scopes hide tools, a registry suspends agents, humans approve privileged changes |
| [Healthcare Patient Support Agent](./Agentic_AI/Feature_Samples/Healthcare-Compliance-Agent/) | Healthcare | AI Agent Trigger with a custom PHI guardrail + custom conversation store (HIPAA-aware) |
| [BeautyCo Retail Intelligence](./Agentic_AI/Feature_Samples/demo_retail/) | Retail & Consumer | Flogo as an MCP server exposing enterprise data for personalized consultations |
| [Mobile Customer Care Multi-Agent Hub](./Agentic_AI/Feature_Samples/Mobile-Customer-Care-Multi-Agent/) | Telecommunications & Customer Service | AI Agent dispatcher with multi-agent handoff + deterministic `callagent` routing |
| [Travel Itinerary Planner with A2A Server](./Agentic_AI/Feature_Samples/Travel-Itinerary-Planner/) | Travel & Hospitality | Agent-to-Agent (A2A) protocol between two collaborating apps |
| [Smart Supply Chain Assistant](./Agentic_AI/Feature_Samples/Smart-Supply-Chain-Assistant/) | Manufacturing & Supply Chain | Agent Trigger using multiple MCP servers + a custom write tool |
| [AI-Powered Incident Triage Agent](./Agentic_AI/Feature_Samples/Ai-Triage-Agent/) | IT Operations & Service Management | AI Agent + MCP with semantic duplicate detection to cut ticket noise |
| [IT Help Desk Advisor](./Agentic_AI/Feature_Samples/LLMClient-Dynamic-Config-And-Memory/) | IT Operations & Service Management | LLM Client with memory conversation store + dynamic MCP/A2A config |
| [Dynamic Semantic Tool Selection at Scale](./Agentic_AI/Feature_Samples/DynamicSemanticToolSelectionAtScale/) | IT Operations & Service Management | Two-step tool selection across a large tool set (`filteredToolNames`) |
| [Scheduled Reasoning Agent](./Agentic_AI/Feature_Samples/ScheduledReasoningAgent/) | Cross-Industry / Workplace Productivity | Timer-driven pipeline: fetch → analyze → HTML report → email, unattended |
| [Morning Briefing](./Agentic_AI/Feature_Samples/morning-briefing/) | Cross-Industry / Workplace Productivity | Aggregate Slack / email / calendar / reminders into a prioritized AI briefing |
| [Apartment Finder Agent](./Agentic_AI/Feature_Samples/Apartment-Finder-Agent/) | Real Estate & Property Management | AI Agent Activity over a Flogo MCP server (8 tools); one tool books a tour and sends a real email |
| [Drug Safety Intake Advisor](./Agentic_AI/Feature_Samples/LLMClient-Dynamic-Auth/) | Pharmaceutical & Life Sciences | LLM Client with **authenticated** MCP + A2A backends — provider, URLs and bearer tokens all injected at runtime |

> **TIBCO Flogo® 3 users:** nine of these feature samples are also available in the Flogo 3.x folder-based project format under [`Agentic_AI/Flogo3x/`](./Agentic_AI/Flogo3x/README.md).

### Agentic AI Industry Use-Case Demos

End-to-end, PostgreSQL-backed chat assistants that apply the same governed **three-app pattern** to a different industry each time: an **MCP Server** (verified identity, scoped reads, guarded two-step writes and routing to people, with the rules enforced in SQL), an **A2A Agents** app (read-only reasoning agents that never see the customer's identity), and a **WebSocket AI Orchestrator** (the conversation, with per-connection memory). All share the browser [Chatbot](./Agentic_AI/Chatbot/) client. See the [Agentic AI README](./Agentic_AI/README.md#part-2--industry-use-case-demos) for the full catalog, ports, and status of each.

#### Industry use cases (governed — start here)

| Use Case | Industry → Sub-category |
|---|---|
| [Banking — Retail Banking Assistant](./Agentic_AI/Industry_Use_Cases/Financial_Services/Banking/Retail_Banking_Assistant_Use_Case/) | Financial Services → Banking |
| [Banking — Corporate Payments Investigation Assistant](./Agentic_AI/Industry_Use_Cases/Financial_Services/Banking/Corporate_Payments_Investigation_Use_Case/) | Financial Services → Banking |
| [Telecom — Mobile Billing & Spend Control Assistant](./Agentic_AI/Industry_Use_Cases/Telecommunications/Mobile_Fixed_Cable_Operators/Telecom_Mobile_Billing_Use_Case/) | Telecommunications → Mobile, Fixed & Cable Operators |
| [Utilities — Electric Outage & Billing Assistant](./Agentic_AI/Industry_Use_Cases/Energy_Utilities/Electric_Gas_Utilities_Grid/Electric_Utility_Outage_Billing_Use_Case/) | Energy & Utilities → Electric, Gas & Utilities Grid |
| [Energy & Utilities — Oilfield Asset Health Monitoring Assistant](./Agentic_AI/Industry_Use_Cases/Energy_Utilities/Oil_Gas/Oilfield_Asset_Health_Monitoring_Use_Case/) | Energy & Utilities → Oil & Gas |
| [Healthcare — Hospital Post-Discharge Care Assistant](./Agentic_AI/Industry_Use_Cases/Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case/) | Healthcare & Life Sciences → Providers & Health Systems |
| [Airline — Passenger Services Assistant](./Agentic_AI/Industry_Use_Cases/Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case/) | Transportation & Logistics → Airlines & Aviation |
| [Logistics — Parcel Delivery Assistant](./Agentic_AI/Industry_Use_Cases/Transportation_Logistics/Parcel_Postal_Logistics/Parcel_Delivery_Last_Mile_Use_Case/) | Transportation & Logistics → Parcel & Postal Logistics |
| [High Tech — Semiconductor Orders & RMA Assistant](./Agentic_AI/Industry_Use_Cases/High_Tech_Software/Semiconductors_Electronics/Semiconductor_Orders_RMA_Use_Case/) | High Tech & Software → Semiconductors & Electronics |
| [Insurance — Auto Policy & Claims Assistant (RAG)](./Agentic_AI/Industry_Use_Cases/Insurance/PC_Multi_Line/Auto_Insurance_Policy_Claims_RAG_Use_Case/) | Insurance → Property & Casualty / Multi-Line |
| [Insurance — Life & Retirement Member Services Assistant](./Agentic_AI/Industry_Use_Cases/Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case/) | Insurance → Life, Pensions & Wealth |
| [Publishing — Author Services Assistant](./Agentic_AI/Industry_Use_Cases/Media_Travel/Media_Publishing/Scholarly_Publishing_Author_Services_Use_Case/) | Media & Travel → Media & Publishing |
| [Aerospace & Defense — MRO AOG Operations Assistant](./Agentic_AI/Industry_Use_Cases/Aerospace_Defense/Defense_Space/Aerospace_MRO_AOG_Operations_Use_Case/) | Aerospace & Defense → Defense & Space |
| [Real Estate — Lead Engagement Assistant](./Agentic_AI/Industry_Use_Cases/Real_Estate/Residential_Brokerage/Real_Estate_Lead_Engagement_Use_Case/) | Real Estate → Residential Brokerage |

#### Legacy (`_old` — reference, being migrated)

Earlier demos on the legacy pattern (the prompt filters the data and guards the writes, rather than the database). Kept for reference only; don't base new work on them.

| Use Case | Industry | Superseded by |
|---|---|---|
| [Aerospace MRO & AOG Operations](./Agentic_AI/Industry_Use_Cases_old/Aerospace_Defense_MRO_Use_Case/) | Aerospace & Defense | [Aerospace & Defense — MRO AOG Operations Assistant](./Agentic_AI/Industry_Use_Cases/Aerospace_Defense/Defense_Space/Aerospace_MRO_AOG_Operations_Use_Case/) |
| [Retail Banking Assistant](./Agentic_AI/Industry_Use_Cases_old/Retail_Banking_Assistant_Use_Case/) | Financial Services | [Banking — Retail Banking Assistant](./Agentic_AI/Industry_Use_Cases/Financial_Services/Banking/Retail_Banking_Assistant_Use_Case/) |
| [Life & Pensions Member Assistant](./Agentic_AI/Industry_Use_Cases_old/Life_And_Pensions_Use_Case/) | Insurance | [Insurance — Life & Retirement Member Services Assistant](./Agentic_AI/Industry_Use_Cases/Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case/) |
| [Auto Insurance Policyholder Assistant](./Agentic_AI/Industry_Use_Cases_old/Auto_Insurance_Assistant_RAG_Use_Case/) *(RAG)* | Insurance | [Insurance — Auto Policy & Claims Assistant (RAG)](./Agentic_AI/Industry_Use_Cases/Insurance/PC_Multi_Line/Auto_Insurance_Policy_Claims_RAG_Use_Case/) |
| [Hospital Post-Discharge Assistant](./Agentic_AI/Industry_Use_Cases_old/Hospital_AI-Agent_Use_Case/) | Healthcare & Life Sciences | [Healthcare — Hospital Post-Discharge Care Assistant](./Agentic_AI/Industry_Use_Cases/Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case/) |
| [Telecom Invoice Chatbot](./Agentic_AI/Industry_Use_Cases_old/Telecom_Invoice_Chatbot_Use_Case/) | Telecommunications | [Telecom — Mobile Billing & Spend Control Assistant](./Agentic_AI/Industry_Use_Cases/Telecommunications/Mobile_Fixed_Cable_Operators/Telecom_Mobile_Billing_Use_Case/) |
| [Electric Power Distribution](./Agentic_AI/Industry_Use_Cases_old/Power_Distribution_Use_Case/) | Energy & Utilities | [Utilities — Electric Outage & Billing Assistant](./Agentic_AI/Industry_Use_Cases/Energy_Utilities/Electric_Gas_Utilities_Grid/Electric_Utility_Outage_Billing_Use_Case/) |
| [Semiconductor Customer & Order Assistant](./Agentic_AI/Industry_Use_Cases_old/Semiconductor_Customer_Use_Case/) | High Tech & Software | [High Tech — Semiconductor Orders & RMA Assistant](./Agentic_AI/Industry_Use_Cases/High_Tech_Software/Semiconductors_Electronics/Semiconductor_Orders_RMA_Use_Case/) |
| [Predictive Maintenance & Asset Monitoring](./Agentic_AI/Industry_Use_Cases_old/Predictive_Maintenance_Use_Case/) | Manufacturing & Industrial | [Energy & Utilities — Oilfield Asset Health Monitoring Assistant](./Agentic_AI/Industry_Use_Cases/Energy_Utilities/Oil_Gas/Oilfield_Asset_Health_Monitoring_Use_Case/) |
| [Airline Passenger Services](./Agentic_AI/Industry_Use_Cases_old/Airline_Passenger_Services_Use_Case/) | Transportation & Logistics | [Airline — Passenger Services Assistant](./Agentic_AI/Industry_Use_Cases/Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case/) |
| [Logistics / Transport Shipper Assistant](./Agentic_AI/Industry_Use_Cases_old/Logistics_Transport_Use_Case/) | Transportation & Logistics | [Logistics — Parcel Delivery Assistant](./Agentic_AI/Industry_Use_Cases/Transportation_Logistics/Parcel_Postal_Logistics/Parcel_Delivery_Last_Mile_Use_Case/) |
| [Real Estate Lead Engagement Assistant](./Agentic_AI/Industry_Use_Cases_old/Real_Estate_Lead_Assistant_Use_Case/) | Real Estate | [Real Estate — Lead Engagement Assistant](./Agentic_AI/Industry_Use_Cases/Real_Estate/Residential_Brokerage/Real_Estate_Lead_Engagement_Use_Case/) |

#### BW6 + Flogo samples

TIBCO BusinessWorks 6 + Flogo "Better Together" samples — they need a BW6 runtime / Business Studio. See [`Agentic_AI/BW6_Flogo_Samples/`](./Agentic_AI/BW6_Flogo_Samples/).

| Sample | Industry |
|---|---|
| [Retail — BW & Flogo, Better Together](./Agentic_AI/BW6_Flogo_Samples/Retail_AI_BW_Flogo/) *(BW6)* | Retail & Consumer Goods |

---

## Model Context Protocol (MCP) Samples

Expose enterprise business data and operations as AI-accessible tools with **Flogo MCP servers** that any MCP client (Claude Desktop, GitHub Copilot, Cursor, custom LLM apps) can discover and call. Samples are grouped by industry vertical.

**➡️ Full details, learning path & Quick Start: [MCP README](./Model_Context_Protocol(MCP)/)**

| Sample | Vertical | MCP Features Demonstrated |
|---|---|---|
| [Customer 360](./Model_Context_Protocol(MCP)/Customer360/) | Sales, CRM & Customer Success | Tools (read-only) over a REST backend |
| [Customer 360 with Auth](./Model_Context_Protocol(MCP)/Customer360WithAuth/) | Sales, CRM & Customer Success | Tools secured with TLS/HTTPS + token auth |
| [Customer 360 with Prompts & Resources](./Model_Context_Protocol(MCP)/Customer360WithPromptsAndResources/) | Sales, CRM & Customer Success | All three MCP primitives — Tools + Resources + Prompts |
| [Customer Health Monitor](./Model_Context_Protocol(MCP)/customer-health-monitor/) | Sales, CRM & Customer Success | Multi-source tools across Salesforce, Google Sheets & PostgreSQL |
| [Patient Records with Scoped Access (JWT)](./Model_Context_Protocol(MCP)/MCP_JWT_Scope_Access_Control/) | Healthcare | Per-tool JWT scope enforcement + enhanced `tokenInfo` claims |
| [Patient Records with OAuth 2.0 (External IdP)](./Model_Context_Protocol(MCP)/MCP_OAuth2_Access_Control/) | Healthcare | OAuth 2.0 with an external IdP (Keycloak, JWKS/RS256) + two-layer scopes |
| [Loan Application Wizard (Stateful)](./Model_Context_Protocol(MCP)/MCP_Stateful_Server/) | Banking & Financial Services | Stateful sessions (`Mcp-Session-Id`) for a multi-step loan application |
| [Banking Operations Assistant (Tool Annotations)](./Model_Context_Protocol(MCP)/MCP_Tool_Annotations/) | Banking & Financial Services | Tool annotation hints (`readOnly` / `destructive` / `idempotent` / `openWorld`) |
| [Product Catalog Service (Stateless)](./Model_Context_Protocol(MCP)/MCP_Stateless_Server/) | Retail & E-commerce | Stateless mode (`statelessServer: true`) for a scalable product catalog |
| [E-Commerce Order Insights (Structured Content)](./Model_Context_Protocol(MCP)/MCP_Structured_Content_And_Annotations/) | Retail & E-commerce | Structured Content (output schema) + audience/priority annotations |
| [Smart Incident Response Assistant](./Model_Context_Protocol(MCP)/Smart_Incident_Response_Assistant/) | IT Operations | Elicitation + Logging + Sampling for guided incident triage |
| [Enterprise MCP Gateway (MCP Client)](./Model_Context_Protocol(MCP)/MCP_Client_Activity/) | Cross-Industry / Reference | MCP gateway aggregating backend MCP servers via `#mcpclient` |
| [MCP Server Security Guide](./Model_Context_Protocol(MCP)/MCP_Server_Authentication/) | Cross-Industry / Reference | Reference guide comparing all auth types (None / API Key / JWT / OAuth 2.0) |

---

## More Sample Categories

| Category | Description |
|----------|-------------|
| [Flogo Core & Connector Samples](./VSCode_Extension/) | API development (REST, gRPC, GraphQL), enterprise connectors, flow design concepts, mapping, and unit testing |
| [TIBCO Control Plane](./Tibco_Control_Plane/) | Custom Docker image deployment and TLS ingress configuration for TIBCO Platform |
| [DockerFiles](./DockerFiles/) | Dockerfile examples for multiple Linux distributions and supplemental connector types (EMS, IBM MQ, Oracle, SAP) |

---

## Shared Prerequisites

- **Microsoft Visual Studio Code** with the **TIBCO Flogo® Extension** installed
- **TIBCO Flogo® 2.26.x** or later (specific version requirements noted in each category)

Additional prerequisites (LLM API keys, Docker, database drivers, etc.) are listed in each category's README.

---

## Quick Start

1. Clone this repository.
2. Open the `flogo-enterprise-hub` folder in VS Code with the Flogo extension.
3. Navigate to the sample category that interests you and open its README for detailed instructions.
4. Click any `.flogo` file to open it in the visual flow designer.

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

<!-- SEO Keywords: TIBCO Flogo, MCP Server, Model Context Protocol, AI Agents, Agentic AI, Low-Code, No-Code, iPaaS, Enterprise Integration, Enterprise AI, MCP Server, GoLang, VS Code, Docker, Kubernetes, Integration Flows, Event-Driven Microservices -->

**Topics:** `MCP Server` · `AI Agents` · `Low-Code` · `iPaaS` · `Enterprise Integration`
