# **TIBCO Flogo® Model Context Protocol (MCP) Samples**

Build and deploy **MCP servers** with **TIBCO Flogo®** — the low-code way to expose enterprise business data and operations as AI-accessible tools. These samples show how to create MCP servers that AI agents (Claude Desktop, GitHub Copilot, Cursor, custom LLM apps) can discover and call using natural language, turning any integration flow into an AI-ready tool with zero boilerplate.

New here? See the **[Suggested Learning Order](#suggested-learning-order)**, or jump to the **[Sample Catalog](#sample-catalog)** to pick a sample by industry vertical.

---

## Sample Catalog

Samples grouped by **industry vertical**. The **MCP Features Demonstrated** column lists the MCP primitives, transport mode, and capabilities each sample exercises; the **Auth** column shows how it is secured. Click any sample name to open its folder and full README.

### Sales, CRM & Customer Success

| Sample | Business Scenario | MCP Features Demonstrated | Auth |
|---|---|---|---|
| [Customer 360](./Customer360/) | Expose customer, product & sales data as AI-queryable tools | **Tools** (read-only) · HTTP transport · REST backend | None |
| [Customer 360 with Auth](./Customer360WithAuth/) | Secured Customer 360 over encrypted transport | Tools · **TLS/HTTPS** · REST backend | JWT Token / API Key |
| [Customer 360 with Prompts & Resources](./Customer360WithPromptsAndResources/) | All three MCP primitives for customer analysis & cross-sell | **Tools + Resources** (static + dynamic URIs) **+ Prompts** | None |
| [Customer Health Monitor](./customer-health-monitor/) | Unified customer-health insights across Pre-Sales, Support & Sales | Tools · **multi-source connectors** (Salesforce, Google Sheets, PostgreSQL) | None |

### Healthcare

| Sample | Business Scenario | MCP Features Demonstrated | Auth |
|---|---|---|---|
| [Patient Records with Scoped Access (JWT)](./MCP_JWT_Scope_Access_Control/) | Patient-records server with per-tool access enforcement | Tools · **JWT scopes per handler** · enhanced `tokenInfo` claims (iss/sub/aud/name/email) | JWT Token + scopes |
| [Patient Records with OAuth 2.0 (External IdP)](./MCP_OAuth2_Access_Control/) | Patient records secured by an external identity provider | Tools · **OAuth 2.0 + Keycloak (JWKS/RS256)** · issuer/audience validation · server + per-handler scopes · protected-resource discovery | OAuth 2.0 + IdP |

### Banking & Financial Services

| Sample | Business Scenario | MCP Features Demonstrated | Auth |
|---|---|---|---|
| [Loan Application Wizard (Stateful)](./MCP_Stateful_Server/) | Multi-step loan application that accumulates session state | Tools · **stateful sessions** (`Mcp-Session-Id`, DELETE lifecycle) · file-based state · tool annotations | None |
| [Banking Operations Assistant (Tool Annotations)](./MCP_Tool_Annotations/) | Banking operations demonstrating every tool behavior hint | Tools · **Tool Annotations** (`readOnly` / `destructive` / `idempotent` / `openWorld`) | None |

### Retail & E-commerce

| Sample | Business Scenario | MCP Features Demonstrated | Auth |
|---|---|---|---|
| [Product Catalog Service (Stateless)](./MCP_Stateless_Server/) | Read-only product catalog, horizontally scalable | Tools · **stateless mode** (`statelessServer: true`, no session ID) · `readOnly` hints | None |
| [E-Commerce Order Insights (Structured Content)](./MCP_Structured_Content_And_Annotations/) | Order-management server returning typed output with routing hints | Tools · **Structured Content** (Tool Output Schema + `structuredContent`) · **content annotations** (audience / priority) | None |

### IT Operations

| Sample | Business Scenario | MCP Features Demonstrated | Auth |
|---|---|---|---|
| [Smart Incident Response Assistant](./Smart_Incident_Response_Assistant/) | Guided incident triage with interactive intake & AI root-cause analysis | Tool · **Elicitation + Logging + Sampling** · stateful server | None |

### Cross-Industry / Foundations & Reference

| Sample | Business Scenario | MCP Features Demonstrated | Auth |
|---|---|---|---|
| [Enterprise MCP Gateway (MCP Client)](./MCP_Client_Activity/) | An MCP gateway that aggregates multiple backend MCP servers | **MCP Client Activity** (`#mcpclient`) · gateway/aggregator pattern · Streamable-HTTP · client auth None / Static Token / OAuth 2.0 | None (gateway) |
| [MCP Server Security Guide](./MCP_Server_Authentication/) | Reference guide comparing every MCP server authentication type | Conceptual: **None · API Key · JWT Token · OAuth 2.0** + TLS, across Tools / Resources / Prompts | All (reference) |

---

## Suggested Learning Order

New to MCP in Flogo? This path walks from the foundations to advanced capabilities:

1. **[Customer 360](./Customer360/)** — foundation pattern: a REST backend exposed as read-only MCP tools.
2. **[Customer 360 with Auth](./Customer360WithAuth/)** — add production security (TLS + token auth).
3. **[Customer 360 with Prompts & Resources](./Customer360WithPromptsAndResources/)** — learn when to use Resources vs. Tools vs. Prompts.
4. **[Product Catalog Service (Stateless)](./MCP_Stateless_Server/)** vs. **[Loan Application Wizard (Stateful)](./MCP_Stateful_Server/)** — understand the session-design trade-off for your use case.
5. **[Banking Operations Assistant (Tool Annotations)](./MCP_Tool_Annotations/)** — guide AI-client behavior with `readOnly` / `destructive` / `idempotent` / `openWorld` hints.
6. **[E-Commerce Order Insights (Structured Content)](./MCP_Structured_Content_And_Annotations/)** — return typed JSON alongside text and control audience visibility.
7. **[Smart Incident Response Assistant](./Smart_Incident_Response_Assistant/)** — advanced interaction: Elicitation, Logging, and Sampling.
8. **[Customer Health Monitor](./customer-health-monitor/)** — real-world multi-source integration.
9. **[MCP Server Security Guide](./MCP_Server_Authentication/)** — choose and configure the right auth type.
10. **[Patient Records with Scoped Access (JWT)](./MCP_JWT_Scope_Access_Control/)** → **[Patient Records with OAuth 2.0 (External IdP)](./MCP_OAuth2_Access_Control/)** — enforce per-tool scopes, then secure with an external IdP.
11. **[Enterprise MCP Gateway (MCP Client)](./MCP_Client_Activity/)** — use Flogo as an MCP *client* to call and aggregate other MCP servers.

---

## Prerequisites

- **TIBCO Flogo® 2.26.1 or later**. Some samples need a newer build:
  - Smart Incident Response Assistant — **2.26.3+**
  - Patient Records with Scoped Access (JWT), E-Commerce Order Insights, and Enterprise MCP Gateway — **2.26.5+**
  - Patient Records with OAuth 2.0 — **2.26.6+**
  - See the [MCP Connector documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/mcp/mcp-overview.htm) for details.
- **AI Agent client** for testing: [Claude Desktop](https://claude.ai/download), GitHub Copilot in VS Code, or any MCP-compatible client.
- **TLS certificates** — required only for the Auth sample.
- Some samples have extra prerequisites (PostgreSQL, Salesforce, Google Sheets, Keycloak/Docker) — see each sample's README.

## Quick Start

1. Clone or download this repository.
2. Open the `flogo-enterprise-hub` folder in VS Code with the Flogo extension installed.
3. Navigate to a sample folder and open the `.flogo` file.
4. Run the app from VS Code.
5. Configure your AI agent client to connect to the MCP server endpoint (typically `http://localhost:<port>/mcp`).
6. Start querying your data using natural language.

See each sample's individual `README.md` for detailed configuration, port numbers, and usage instructions.

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

<!-- SEO Keywords: MCP Server, Model Context Protocol, Build MCP Server, MCP Tools, MCP Resources, MCP Prompts, MCP Authentication, MCP Elicitation, MCP Sampling, Stateless MCP, Stateful MCP, Tool Annotations, Structured Content, MCP Client, AI Agent Tools, LLM Integration, Claude Desktop MCP, GitHub Copilot MCP, Low-Code MCP Server, Enterprise AI, TIBCO Flogo, iPaaS, No-Code AI Integration -->

**Topics:** `MCP Server` · `Model Context Protocol` · `AI Agent Tools` · `Low-Code` · `Claude Desktop` · `GitHub Copilot`
