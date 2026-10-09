# **Hub for TIBCO Flogo®**

Welcome to the **Hub for TIBCO Flogo®** — your community-driven space for sharing FLOGO samples, demos, and custom contributions for TIBCO Flogo®.

TIBCO Flogo® is a **low-code / no-code integration platform (iPaaS)** for building **AI agents**, **MCP servers**, and **enterprise integration flows** — all from a visual flow designer inside Visual Studio Code. Powered by a high-performance **Go (Golang)** engine, Flogo® delivers ultra-light memory footprint, fast startup, and low-latency processing across **edge, cloud, serverless, and on-premises** environments. With native support for **Agentic AI orchestration**, the **Model Context Protocol (MCP)**, and 40+ enterprise connectors, Flogo® transforms business data into intelligent, event-driven, AI-ready workflows — no heavy coding required.

If you have purchased commercial support for TIBCO Flogo®, please create a Service Request using your TIBCO Support credentials at [https://support.tibco.com/](https://support.tibco.com/).

---

## **Quick Navigation**

| Section | What You'll Find |
|---------|-----------------|
| [AI & Agents](#ai--agents) | Agentic AI samples, MCP servers, AI-powered demos, prompt engineering |
| [Integration & Connectors](#integration--connectors) | REST/gRPC/GraphQL, database/messaging/CRM connectors, flow patterns |
| [Deployment & DevOps](#deployment--devops) | Docker images, TIBCO Platform deployment, ML inference |
| [Flogo Skill Library](#flogo-skill-library) | AI coding agent skills for Claude Code |
| [Flogo Resources](#flogo-resources) | Documentation, downloads, blogs, and video tutorials |

---

## **Getting Started**

**Prerequisites**

- **Visual Studio Code** with the **[TIBCO Flogo® Extension](https://marketplace.visualstudio.com/items?itemName=tibco.flogo)** — also available from the [TIBCO downloads page](https://www.tibco.com/downloads/11810)
- **TIBCO Flogo® 2.26.x** or later

**Clone and open**

```bash
git clone https://github.com/TIBCOSoftware/flogo-enterprise-hub.git
cd flogo-enterprise-hub
code .
```

Then pick a starting point:

- **[Product Samples](./samples/README.md)** — ready-to-run TIBCO Flogo® samples (quick start).
- **[Flogo Skill Library](./skills-library/README.md)** — skills for AI coding agents such as Claude Code.
- **[Agentic AI Samples & Industry Use Cases](./samples/Agentic_AI/README.md)** — connector feature samples plus end-to-end, vertical-specific industry demos.

---

## **AI & Agents**

Build AI-powered agents, expose business data via MCP, and orchestrate intelligent workflows.

- **[Agentic AI Feature Samples](./samples/Agentic_AI/README.md#part-1--connector-feature-samples)** — AI agents with custom guardrails, multi-agent handoff, MCP server integration, the "Flogo as an MCP tool server" pattern, A2A (Agent-to-Agent) protocol, LLM Client Activity, memory conversation store, dynamic MCP/A2A server configuration, dynamic semantic tool selection at scale (150 tools), scheduled reasoning with automated report generation and email delivery, and incident triage. Supports OpenAI, Gemini, Anthropic, Ollama, and vLLM.
- **[Agentic AI Industry Use Cases](./samples/Agentic_AI/README.md#part-2--industry-use-case-demos)** — end-to-end, industry-specific Agentic AI demos organized by vertical (banking, insurance, healthcare, telecom, utilities, aerospace, manufacturing, retail, real estate, and more). Each uses the same three-app pattern — an MCP Server (read-only tools), an A2A Agents app (guarded write workflows), and a WebSocket AI Orchestrator — backed by PostgreSQL, and shares the browser [Chatbot](./samples/Agentic_AI/Chatbot/) test client.
- **[Model Context Protocol (MCP) Samples](./samples/Model_Context_Protocol(MCP)/)** — MCP servers exposing business data as AI-accessible tools: stateless, stateful, authenticated, annotated, advanced primitives (elicitation, logging, sampling), JWT and OAuth 2.0 access control (external IdP via JWKS), structured content with annotations, and MCP client gateway.
- **[OpenAI RAG & Vector Search Extension](./extensions/openAI/)** — Flogo activities for the OpenAI platform: file management, vector-store lifecycle, semantic vector search (RAG), and image generation — build retrieval-augmented AI flows with no code.
- **[AI Alert Agent Demo](./demos/flogo-ai-alert-agent/)** — Autonomous AI Agent (Flogo AI Agent Activity) that investigates TIBCO Platform application alerts using Platform MCP services as tools and reports its root-cause findings automatically.
- **[AI-Powered Customer Service Demo](./demos/ai-powered-customer-service/)** — End-to-end demo integrating CRM, orders, and notifications as MCP tools for AI agents.
- **[AI-Powered MFT Demo](./demos/flogo-mcp-mft/)** — MCP server for TIBCO Managed File Transfer — AI-powered B2B file transfer management.
- **[Pongo2 Prompt Engine Extension](./extensions/pongo2/)** — Dynamic prompt engineering activity using Django/Jinja2-style templates for LLMs.

---

## **Integration & Connectors**

Design Flogo applications with enterprise connectors, API protocols, and flow patterns.

- **[Flogo Core & Connector Samples](./samples/VSCode_Extension/)** — REST, gRPC, GraphQL API development; connectors for Azure, Salesforce, Oracle, PostgreSQL, Redis, EMS, Kafka, SAP; flow design concepts; unit testing.
- **[GraphQL Demo](./demos/flogo-graphql/)** — GraphQL trigger with MongoDB resolvers for device data queries, with Docker Compose and Postman collection.
- **[SSH Extension](./extensions/ssh/)** — Execute commands over SSH with password or key-based authentication.
- **[GCP Extension](./extensions/gcp/)** — Generate OIDC ID tokens from GCP metadata server.
- **[OpenPGP Extension](./extensions/openpgp/)** — Encrypt, decrypt, and generate OpenPGP key pairs.
- **[Custom Log Palette Extension](./extensions/custom-log-palette/)** — Structured logging activities with text and JSON output formats. Contributed by [P4Future](https://www.p4future.com/en/).

---

## **Deployment & DevOps**

Deploy Flogo applications to production with Docker, Kubernetes, and TIBCO Platform.

- **[TIBCO Control Plane Samples](./samples/Tibco_Control_Plane/)** — Custom Docker image deployment for ActiveSpaces and Oracle connectors, plus TLS ingress configuration.
- **[Dockerfile Examples](./samples/DockerFiles/)** — Multi-stage Dockerfiles for 7 Linux distributions and 4 supplemental connector types (EMS, IBM MQ, Oracle, SAP) with compatibility matrices.
- **[ML Anomaly Detection Demo](./demos/flogo-machine-learning-anomaly-detection/)** — Real-time temperature anomaly detection using Python scikit-learn Isolation Forest, deployable to TIBCO Platform.

---

## **Flogo Skill Library**

A library of **skills for AI coding agents** (such as **Claude Code**) to design, build, test, and deploy TIBCO Flogo integration applications. Drop these skills into the `.claude/skills/` directory of any project and the agent will use them to drive the Flogo, build, and platform CLIs end-to-end.

| Skill | Purpose |
|---|---|
| `fda` | Reference for the Flogo Design Assistant CLI — every task to create/modify a `.flogo` file. |
| `fda-mapping` | Focused reference for building, inspecting, and validating Flogo mappings with `fda`. |
| `flogobuild` | Reference for building executables and deployment artifacts from `.flogo` files. |
| `tibcop` | Reference for the TIBCO Platform CLI — manage builds, deployments, scaling. |
| `flogo-deploy` | End-to-end recipe to deploy a `.flogo` app to a TIBCO Platform dataplane. |
| `flogo-unit-testing` | Recipe to create and run unit tests for Flogo apps (test cases, assertions, execution). |
| `mapping-from-excel` | Recipe to build a Flogo flow from an Excel mapping spec (input fields → output fields with rules). |
| `rest-to-database-app` | Recipe to scaffold a REST API Flogo app that queries a database. |
| `agentic-ai-use-case-builder` | Build a **governed-by-default** Agentic AI use case for any vertical — MCP Server + A2A Agents + WebSocket orchestrator, backed by PostgreSQL. Every operation first classified by the decision framework (agent / deterministic / human-owned); identity, scoping, prices and state changes enforced in SQL; two build methods (FDA-CLI default or clone-and-adapt); proven with a 4-rung test ladder through a real chat, including prompt injection. |

For full details, see the [Flogo Skill Library README](./skills-library/README.md).

---

## **Flogo Resources**

| Resource | Link |
|----------|------|
| Documentation | [TIBCO Flogo® Product Documentation](https://docs.tibco.com/products/tibco-flogo-latest) |
| Download | [TIBCO Flogo® Extension for VS Code](https://www.tibco.com/downloads/11810) |
| Blogs | [TIBCO Flogo® Blog Posts](https://www.tibco.com/blog/?s=flogo) |
| Video Tutorials | [TIBCO Flogo® YouTube Playlist](https://www.youtube.com/watch?v=jKYethPuYcg&list=PLnmoGGHHJldiGPd8r3n657cAX3i7V9hMz&index=1) |

### Video Tutorials

Short video walkthroughs to get you started:

1. **Installing TIBCO Flogo Extension for VS Code and Creating Your First Flogo App** — Setup, configuration, and hello-world walkthrough
2. **Creation of Unit Testing & Play Test Case in Flogo** — Test and debug flows without building the app
3. **Building AI Agents in Minutes: Agentic AI Orchestration for the Modern Enterprise using TIBCO Flogo®** — Configure LLM providers, build custom tools, and deploy AI agents
4. **Build Integration Flows in Minutes Using Natural Language Prompts | TIBCO Flogo® AI Design Assistant** — Use the AI Design Assistant to generate flows from plain English

Watch the full playlist: [TIBCO Flogo® Short Videos on YouTube](https://www.youtube.com/watch?v=jKYethPuYcg&list=PLnmoGGHHJldiGPd8r3n657cAX3i7V9hMz&index=1)

---

## **Repository Structure**

```
flogo-enterprise-hub/
├── samples/                  # Ready-to-run product samples
│   ├── Agentic_AI/           #   AI agent feature samples + industry use-case demos (by vertical)
│   ├── Model_Context_Protocol(MCP)/  #   MCP server samples
│   ├── VSCode_Extension/     #   Flogo core samples (APIs, connectors, flows, testing)
│   ├── Tibco_Control_Plane/  #   Platform deployment samples
│   └── DockerFiles/          #   Multi-distro Dockerfile examples
├── demos/                    # Proof-of-concept demonstrations (MCP, GraphQL, ML, alerts)
├── extensions/               # Custom-built Flogo extensions
└── skills-library/           # AI coding agent skills
```

---

## **Contributing**

We welcome contributions! To contribute:
- Fork this repository.
- Make your changes.
- Submit a pull request (PR).

Our maintainers will review your PR and may request changes before merging. For any questions, please reach out to [integration-pm@tibco.com](mailto:integration-pm@tibco.com).

> **Repo maintainers:** For maximum GitHub search discoverability, add **Topics** to this repository via **Settings → Topics**. Suggested topics: `flogo`, `mcp`, `mcp-server`, `ai-agents`, `agentic-ai`, `low-code`, `no-code`, `ipaas`, `integration`, `tibco`, `golang`, `enterprise-integration`

---

## **Feedback**

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

## **License**

Copyright 2026 Cloud Software Group, Inc.
This project is Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

---

Thank you for being part of the Flogo® community!

---

<!-- SEO Keywords: TIBCO Flogo, MCP Server, Model Context Protocol, Build MCP Server, AI Agents, Agentic AI, LLM Orchestration, Low-Code Integration, No-Code Integration, iPaaS, Integration Platform as a Service, Enterprise Integration, API Development, REST API, gRPC, GraphQL, Visual Flow Designer, Event-Driven Architecture, Microservices, Edge Computing, Serverless Integration, AI Workflow Automation, Prompt Engineering, RAG, Retrieval Augmented Generation, Vector Store, Vector Search, Semantic Search, Embeddings, Image Generation, OpenAI, Anthropic Claude, Google Gemini, Ollama, Enterprise Connectors, Salesforce Integration, SAP Integration, Kafka, PostgreSQL, Oracle Database, Redis, Azure Service Bus, Docker Deployment, Kubernetes, TIBCO Platform, Go Golang, VS Code Extension, AI Design Assistant, MCP Tools, MCP Resources, MCP Prompts, Custom AI Guardrails, Multi-Agent Systems, AI-Powered Automation, B2B Integration, Machine Learning Integration, Real-Time Processing, Cloud-Native Integration -->

**Topics:** `MCP Server` · `AI Agents` · `Agentic AI` · `Low-Code` · `No-Code` · `iPaaS` · `Enterprise Integration` · `LLM Orchestration`
