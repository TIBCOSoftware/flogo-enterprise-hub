# **TIBCO Flogo® Samples**

Ready-to-run sample applications for **TIBCO Flogo®** — the low-code / no-code iPaaS for building **AI agents**, **MCP servers**, **enterprise integration flows**, and **event-driven microservices**. Explore everything from Agentic AI orchestration and Model Context Protocol (MCP) servers to REST/gRPC/GraphQL APIs, database connectors, and Docker deployment patterns.

**Jump to:** [Agentic AI Samples](#agentic-ai-samples) · [MCP Samples](#model-context-protocol-mcp-samples) · [More Sample Categories](#more-sample-categories)

---

## Agentic AI Samples

Build, orchestrate, and govern AI agents inside Flogo integration flows using the **Agentic AI Connector** (LLM Client Activity, AI Agent Activity, AI Agent Trigger) and the **Flogo-as-MCP-server** pattern. Samples are grouped by industry vertical.

**➡️ Full details, prerequisites & Quick Start: [Agentic AI README](./Agentic_AI/)**

| Sample | Vertical | What It Demonstrates |
|---|---|---|
| [Insurance Claims Processor](./Agentic_AI/InsuranceClaimsProcessor/) | Banking, Financial Services & Insurance | LLM Client chaining: MCP coverage check → A2A fraud scoring → decision |
| [Mortgage AI Processor](./Agentic_AI/mortgagedemo/) | Banking, Financial Services & Insurance | Flogo as an MCP server for autonomous loan decisioning (approve/escalate/decline) |
| [Healthcare Patient Support Agent](./Agentic_AI/Healthcare-Compliance-Agent/) | Healthcare | AI Agent Trigger with a custom PHI guardrail + custom conversation store (HIPAA-aware) |
| [BeautyCo Retail Intelligence](./Agentic_AI/demo_retail/) | Retail & Consumer | Flogo as an MCP server exposing enterprise data for personalized consultations |
| [Mobile Customer Care Multi-Agent Hub](./Agentic_AI/Mobile-Customer-Care-Multi-Agent/) | Telecommunications & Customer Service | AI Agent dispatcher with multi-agent handoff + deterministic `callagent` routing |
| [Travel Itinerary Planner with A2A Server](./Agentic_AI/Travel-Itinerary-Planner/) | Travel & Hospitality | Agent-to-Agent (A2A) protocol between two collaborating apps |
| [Smart Supply Chain Assistant](./Agentic_AI/Smart-Supply-Chain-Assistant/) | Manufacturing & Supply Chain | Agent Trigger using multiple MCP servers + a custom write tool |
| [AI-Powered Incident Triage Agent](./Agentic_AI/Ai-Triage-Agent/) | IT Operations & Service Management | AI Agent + MCP with semantic duplicate detection to cut ticket noise |
| [IT Help Desk Advisor](./Agentic_AI/LLMClient-Dynamic-Config-And-Memory/) | IT Operations & Service Management | LLM Client with memory conversation store + dynamic MCP/A2A config |
| [Dynamic Semantic Tool Selection at Scale](./Agentic_AI/DynamicSemanticToolSelectionAtScale/) | IT Operations & Service Management | Two-step tool selection across a large tool set (`filteredToolNames`) |
| [Scheduled Reasoning Agent](./Agentic_AI/ScheduledReasoningAgent/) | Cross-Industry / Workplace Productivity | Timer-driven pipeline: fetch → analyze → HTML report → email, unattended |
| [Morning Briefing](./Agentic_AI/morning-briefing/) | Cross-Industry / Workplace Productivity | Aggregate Slack / email / calendar / reminders into a prioritized AI briefing |

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
| [MCP JWT Scope Access Control](./Model_Context_Protocol(MCP)/MCP_JWT_Scope_Access_Control/) | Healthcare | Per-tool JWT scope enforcement + enhanced `tokenInfo` claims |
| [MCP OAuth 2.0 Access Control](./Model_Context_Protocol(MCP)/MCP_OAuth2_Access_Control/) | Healthcare | OAuth 2.0 with an external IdP (Keycloak, JWKS/RS256) + two-layer scopes |
| [MCP Stateful Server](./Model_Context_Protocol(MCP)/MCP_Stateful_Server/) | Banking & Financial Services | Stateful sessions (`Mcp-Session-Id`) for a multi-step loan wizard |
| [MCP Tool Annotations](./Model_Context_Protocol(MCP)/MCP_Tool_Annotations/) | Banking & Financial Services | Tool annotation hints (`readOnly` / `destructive` / `idempotent` / `openWorld`) |
| [MCP Stateless Server](./Model_Context_Protocol(MCP)/MCP_Stateless_Server/) | Retail & E-commerce | Stateless mode (`statelessServer: true`) for a scalable product catalog |
| [MCP Structured Content & Annotations](./Model_Context_Protocol(MCP)/MCP_Structured_Content_And_Annotations/) | Retail & E-commerce | Structured Content (output schema) + audience/priority annotations |
| [Smart Incident Response Assistant](./Model_Context_Protocol(MCP)/Smart_Incident_Response_Assistant/) | IT Operations | Elicitation + Logging + Sampling for guided incident triage |
| [MCP Client Activity](./Model_Context_Protocol(MCP)/MCP_Client_Activity/) | Cross-Industry / Reference | MCP gateway aggregating backend MCP servers via `#mcpclient` |
| [MCP Server Authentication](./Model_Context_Protocol(MCP)/MCP_Server_Authentication/) | Cross-Industry / Reference | Reference guide comparing all auth types (None / API Key / JWT / OAuth 2.0) |

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
