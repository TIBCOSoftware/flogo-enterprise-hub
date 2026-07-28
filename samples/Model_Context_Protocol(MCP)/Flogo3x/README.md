# **TIBCO Flogo® 3 Model Context Protocol (MCP) Samples**

Build and deploy **MCP servers** with **TIBCO Flogo® 3** — the low-code way to expose enterprise business data and operations as AI-accessible tools. These samples demonstrate how to create MCP servers that AI agents (Claude Desktop, GitHub Copilot, Cursor, custom LLM apps) can discover and call using natural language, turning any integration flow into an AI-ready tool with zero boilerplate.

> These are the **Flogo 3** versions of the MCP samples. Each sample is a folder-based Flogo 3 project (a folder containing `app.fgmd`, `app.fgprops`, `flows/`, `triggers/`, and `connections/`) rather than a single `.flogo` file.

---

## Samples

| # | Sample | Key Feature | Description |
|---|--------|-------------|-------------|
| 1 | [Customer 360](./Customer360/) | Basic MCP Server | Expose customer, product, and sales data as MCP tools and query via AI agent |
| 2 | [Customer 360 with Auth](./Customer360WithAuth/) | HTTPS + JWT Auth | Same as Customer 360, secured with TLS encryption and JWT token authentication |
| 3 | [Customer 360 with Prompts & Resources](./Customer360WithPromptsAndResources/) | All 3 MCP Primitives | Tools, Resources (static + dynamic URIs), and Prompts working together |
| 4 | [MCP Stateless Server](./MCP_Stateless_Server/) | Stateless Design | Product catalog with `statelessServer = true` — no session tracking, horizontally scalable |
| 5 | [MCP Stateful Server](./MCP_Stateful_Server/) | Stateful Wizard | Multi-step loan application with `Mcp-Session-Id` and file-based state persistence |
| 6 | [MCP Tool Annotations](./MCP_Tool_Annotations/) | Tool Annotation Hints | Banking operations demonstrating `readOnly`, `destructive`, `idempotent`, and `openWorld` hints |
| 7 | [Smart Incident Response Assistant](./Smart_Incident_Response_Assistant/) | Elicitation, Logging, Sampling | Interactive incident intake form, real-time audit logging, and LLM-delegated root-cause analysis |
| 8 | [Customer Health Monitor](./customer-health-monitor/) | Multi-Source Integration | Unified customer insights from Salesforce, Google Sheets, and PostgreSQL |
| 9 | [MCP JWT Scope Access Control](./MCP_JWT_Scope_Access_Control/) | JWT Scope + TokenInfo | Healthcare patient records with per-tool JWT scope enforcement and enhanced tokenInfo claims (iss, sub, aud, name, email) for audit logging |
| 10 | [MCP Structured Content & Annotations](./MCP_Structured_Content_And_Annotations/) | Structured Content + Annotations | E-commerce orders with Tool Output Schema, structuredContent mapping, and audience/priority annotations |
| 11 | [MCP Client Activity](./MCP_Client_Activity/) | MCP Client Activity | MCP Gateway pattern — an MCP server that uses mcpclient activities to call tools on backend MCP servers |

---

## Learning Path

**Start here** if you're new to MCP in Flogo:

1. **Customer 360** — Foundation pattern: REST API backend + MCP server frontend with simple read-only tools
2. **Customer 360 with Auth** — Add production-ready security (TLS + JWT)
3. **Customer 360 with Prompts & Resources** — Learn when to use Resources vs Tools vs Prompts
4. **Stateless vs Stateful** — Understand the design trade-off for your use case
5. **Tool Annotations** — Guide AI client behavior with annotation hints
6. **Smart Incident Response** — Advanced features (Elicitation, Logging, Sampling)
7. **Customer Health Monitor** — Real-world multi-source integration
8. **JWT Scope Access Control** — Protect tools with JWT scopes and use tokenInfo for audit logging
9. **Structured Content & Annotations** — Return typed JSON alongside text, control audience visibility
10. **MCP Client Activity** — Use Flogo as an MCP client to call tools on other MCP servers

---

## Prerequisites

- **TIBCO Flogo® 3.0.0 or later** with the TIBCO Flogo® 3 VS Code extension
  - For more information, refer to the [MCP Connector documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/mcp/mcp-overview.htm)
- **AI Agent client** for testing: [Claude Desktop](https://claude.ai/download), GitHub Copilot in VS Code, or any MCP-compatible client
- **TLS certificates** (required only for the Auth sample)

## Quick Start

1. Clone or download this repository.
2. Open a sample folder under `samples/Model_Context_Protocol(MCP)/Flogo3x/<sample-name>/` in VS Code with the TIBCO Flogo® 3 extension. The extension detects each Flogo 3 project (a folder containing `app.fgmd`).
3. Open each app's `.fgprops` file and set the App Properties for your environment (ports, backend URLs, credentials).
4. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
5. In **FLOGO3: WORKSPACE APPS EXPLORER**, select an app module → right-click → **Run As Executable**. The native binary is produced in the app's `bin/` folder and logs stream to the integrated terminal.
6. Configure your AI agent client to connect to the MCP server endpoint (typically `http://localhost:<port>/mcp`) and start querying your data using natural language.

See each sample's individual `README.md` for detailed configuration, port numbers, and usage instructions.

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

<!-- SEO Keywords: MCP Server, Model Context Protocol, Build MCP Server, MCP Tools, MCP Resources, MCP Prompts, MCP Authentication, MCP Elicitation, MCP Sampling, Stateless MCP, Stateful MCP, Tool Annotations, AI Agent Tools, LLM Integration, Claude Desktop MCP, GitHub Copilot MCP, Low-Code MCP Server, Enterprise AI, TIBCO Flogo, iPaaS, No-Code AI Integration -->

**Topics:** `MCP Server` · `Model Context Protocol` · `AI Agent Tools` · `Low-Code` · `Claude Desktop` · `GitHub Copilot`
