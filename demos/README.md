# **TIBCO Flogo® Demos**

End-to-end proof-of-concept demonstrations showcasing **TIBCO Flogo®** as a **low-code integration platform** for **AI-powered services**, **MCP server integration**, **GraphQL APIs**, and **real-time machine learning inference** — ready to clone, run, and explore.

---

## Index

| Demo | Category | Description |
|------|----------|-------------|
| [Agent AI - Platform Error Alert Agent](./flogo-ai-alert-agent/) | AI & MCP | Flogo Agentic AI scenario consuming Platform MCP servers and Platform Alerts |
| [AI-Powered Customer Service](./ai-powered-customer-service/) | AI & MCP | MCP server integrating CRM, order management, and notifications for AI agents (Claude Desktop, Cursor, VS Code) |
| [AI-Powered MFT](./flogo-mcp-mft/) | AI & MCP | MCP server for TIBCO Managed File Transfer — AI-powered B2B file transfer, user management, and audit trails |
| [GraphQL](./flogo-graphql/) | Integration | GraphQL trigger with MongoDB resolvers for device data queries, with Docker Compose deployment |
| [ML Anomaly Detection](./flogo-machine-learning-anomaly-detection/) | AI & ML | Real-time temperature anomaly detection using Python scikit-learn Isolation Forest, deployable to TIBCO Platform |

> **Looking for the Agentic AI industry use cases?** They now live under [`samples/Agentic_AI/`](../samples/Agentic_AI/README.md) — end-to-end, vertical-specific demos (MCP Server + A2A Agents + WebSocket orchestrator, PostgreSQL-backed, with a shared browser Chatbot).

---

## Prerequisites

All demos require:
- **Microsoft Visual Studio Code** with the **[TIBCO Flogo® Extension](https://marketplace.visualstudio.com/items?itemName=tibco.flogo)** installed
- **TIBCO Flogo® 2.26.x** or later

Additional requirements per demo:

| Demo | Additional Prerequisites |
|------|------------------------|
| AI-Powered Customer Service | Node.js v16+, Go v1.19+, MCP-compatible AI client |
| AI-Powered MFT | TIBCO MFT environment, Claude Desktop, Docker Desktop |
| GraphQL | Docker, Docker Compose, MongoDB |
| ML Anomaly Detection | Python 3.x with scikit-learn, numpy, fastapi |

See each demo's `README.md` for detailed setup and run instructions.

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

<!-- SEO Keywords: TIBCO Flogo, AI Agents, MCP, MCP Server, GraphQL, Machine Learning, Anomaly Detection, Low-Code, No-Code, integration platform, Enterprise AI, Demo, AI-Powered Automation, B2B Integration, Agentic AI Use Cases, MCP Use Cases, Build MCP Server, Zero-Code MCP Server, No-Code MCP Server, No-Code Agent Builder, Zero-Code Agent Builder, Best Integration Tool, Fastest Integration Tool, Most Performant Integration Tool, High-Performance Integration, Low-Code Integration, No-Code Integration -->

**Topics:** `AI Agents` · `MCP Server` · `GraphQL` · `Machine Learning` · `Low-Code`

**Hashtags:** #AgenticAI #AgenticAIUseCases #AIAgents #NoCodeAgentBuilder #MCP #MCPServer #ModelContextProtocol #ZeroCodeMCP #BuildMCPServer #LLMOrchestration #EnterpriseIntegration #TIBCOFlogo
