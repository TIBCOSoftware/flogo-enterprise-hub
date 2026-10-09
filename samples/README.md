# **TIBCO Flogo® Samples**

Ready-to-run sample applications for **TIBCO Flogo®** — the low-code / no-code iPaaS for building **AI agents**, **MCP servers**, **enterprise integration flows**, and **event-driven microservices**. Explore everything from Agentic AI orchestration and Model Context Protocol (MCP) servers to REST/gRPC/GraphQL APIs, database connectors, and Docker deployment patterns.

**Jump to:** [Agentic AI Samples](#agentic-ai-samples) · [MCP Samples](#model-context-protocol-mcp-samples) · [More Sample Categories](#more-sample-categories)

---

## Agentic AI Samples

Build, orchestrate, and govern AI agents inside Flogo integration flows using the **Agentic AI Connector** (LLM Client Activity, AI Agent Activity, AI Agent Trigger) and the **Flogo-as-MCP-server** pattern. The [`Agentic_AI/`](./Agentic_AI/) folder holds two collections: **feature samples** (below) that each teach a building block, and **end-to-end industry use-case demos** grouped by vertical (see [Industry Use-Case Demos](#agentic-ai-industry-use-case-demos)).

**➡️ Full details, prerequisites & Quick Start: [Agentic AI README](./Agentic_AI/README.md)**

### Feature Samples

| Sample | Vertical | What It Demonstrates |
|---|---|---|
| [Insurance Claims Processor](./Agentic_AI/Feature_Samples/InsuranceClaimsProcessor/) | Banking, Financial Services & Insurance | LLM Client chaining: MCP coverage check → A2A fraud scoring → decision |
| [Mortgage AI Processor](./Agentic_AI/Feature_Samples/mortgagedemo/) | Banking, Financial Services & Insurance | Flogo as an MCP server for autonomous loan decisioning (approve/escalate/decline) |
| [Agent Privilege IDs](./Agentic_AI/Feature_Samples/Agent-Privilege-IDs/) | Banking, Financial Services & Insurance | Each AI agent has its own privilege ID: JWT scopes hide tools, a registry suspends agents, humans approve privileged changes |
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

End-to-end, PostgreSQL-backed demos that apply the same **three-app pattern** — an **MCP Server** (read-only tools), an **A2A Agents** app (guarded write workflows), and a **WebSocket AI Orchestrator** — to a different vertical each time. All share the browser [Chatbot](./Agentic_AI/Chatbot/) test client. See the [Agentic AI README](./Agentic_AI/README.md#part-2--industry-use-case-demos) for the full catalog, ports, and status of each.

| Use Case | Vertical |
|---|---|
| [Aerospace MRO & AOG Operations](./Agentic_AI/Industry_Use_Cases_old/Aerospace_Defense_MRO_Use_Case/) | Aerospace & Defense |
| [Retail Banking Assistant](./Agentic_AI/Industry_Use_Cases_old/Retail_Banking_Assistant_Use_Case/) | Banking, Financial Services & Insurance |
| [Life & Pensions Member Assistant](./Agentic_AI/Industry_Use_Cases_old/Life_And_Pensions_Use_Case/) | Banking, Financial Services & Insurance |
| [Auto Insurance Policyholder Assistant](./Agentic_AI/Industry_Use_Cases_old/Auto_Insurance_Assistant_RAG_Use_Case/) *(RAG)* | Banking, Financial Services & Insurance |
| [Hospital Post-Discharge Assistant](./Agentic_AI/Industry_Use_Cases_old/Hospital_AI-Agent_Use_Case/) | Healthcare |
| [Telecom Invoice Chatbot](./Agentic_AI/Industry_Use_Cases_old/Telecom_Invoice_Chatbot_Use_Case/) | Telecommunications |
| [Electric Power Distribution](./Agentic_AI/Industry_Use_Cases_old/Power_Distribution_Use_Case/) | Utilities & Energy |
| [Semiconductor Customer & Order Assistant](./Agentic_AI/Industry_Use_Cases_old/Semiconductor_Customer_Use_Case/) | Manufacturing & Industrial |
| [Predictive Maintenance & Asset Monitoring](./Agentic_AI/Industry_Use_Cases_old/Predictive_Maintenance_Use_Case/) | Manufacturing & Industrial |
| [Airline Passenger Services](./Agentic_AI/Industry_Use_Cases_old/Airline_Passenger_Services_Use_Case/) | Transportation, Travel & Logistics |
| [Logistics / Transport Shipper Assistant](./Agentic_AI/Industry_Use_Cases_old/Logistics_Transport_Use_Case/) | Transportation, Travel & Logistics |
| [Retail — BW & Flogo, Better Together](./Agentic_AI/Industry_Use_Cases_old/Retail_AI_BW_Flogo/) *(BW6)* | Retail & Consumer |
| [Real Estate Lead Engagement Assistant](./Agentic_AI/Industry_Use_Cases_old/Real_Estate_Lead_Assistant_Use_Case/) | Real Estate |
| [Scholarly Publishing — Author Services](./Agentic_AI/Industry_Use_Cases/Scholarly_Publishing_Author_Services_Use_Case/) *(governed)* | Publishing & Education |
| [Airline Passenger Services — Meridian](./Agentic_AI/Industry_Use_Cases/Airline_Passenger_Services_Use_Case/) *(governed)* | Transportation & Travel |
| [Parcel Delivery — Swiftbound Last-Mile](./Agentic_AI/Industry_Use_Cases/Parcel_Delivery_Last_Mile_Use_Case/) *(governed)* | Transportation, Travel & Logistics |
| [Retail Banking Assistant — Kestrel Bank](./Agentic_AI/Industry_Use_Cases/Retail_Banking_Assistant_Use_Case/) *(governed)* | Banking & Financial Services |
| [Corporate Payment Investigation & Status — Aurelia Global Bank](./Agentic_AI/Industry_Use_Cases/Corporate_Payments_Investigation_Use_Case/) *(governed)* | Banking & Financial Services |

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
